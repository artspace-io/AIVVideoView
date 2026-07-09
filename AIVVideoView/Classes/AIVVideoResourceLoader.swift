import Foundation
import AVFoundation

public final class AIVVideoResourceLoader: NSObject {
    let originalURL: URL
    private var loadingRequests: [AVAssetResourceLoadingRequest] = []
    private var downloadTask: AIVVideoDownloadTask?
    private let cache = AIVVideoCache.shared
    private let lock = NSLock()
    /// resourceLoader 回调必须避开主线程：AVFoundation 会同步在这个队列上派发代理方法，
    /// 若指定 .main，回调里的磁盘 I/O 会直接阻塞主线程，滑动列表时表现为掉帧。
    private let callbackQueue = DispatchQueue(label: "com.aiv.resourceloader")

    /// 测试用的注入点：每次 resourceLoader 代理回调触发时上报调用线程是否是主线程，
    /// 用来在单测里给“回调不能卡主线程”这个之前修过的 bug 做回归验证。生产环境不设置，零开销。
    var onDelegateCallback: ((Bool) -> Void)?

    public init(url: URL) {
        self.originalURL = url
        super.init()
    }

    static func assetURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.scheme = "AIVCache"
        return components.url!
    }

    public func makePlayerItem() -> AVPlayerItem {
        // 本地文件已经完整可用，不需要下载也不需要缓存；AIVVideoDownloadTask 是按 HTTP 语义写的
        // （只认 HTTPURLResponse），对 file:// URL 发起请求时系统返回的是普通 URLResponse，
        // 会在 didReceive response 里直接被当成非法响应 cancel 掉，导致 contentLength 永远是 0、
        // 所有 loadingRequest 永远等不到数据——播放器卡在 preparing，永远不会 readyToPlay。
        // 所以本地文件直接绕开整套 resourceLoader/下载/缓存机制，走原生的 file:// 播放。
        guard !originalURL.isFileURL else {
            return AVPlayerItem(url: originalURL)
        }

        let assetURL = Self.assetURL(for: originalURL)
        let urlAsset = AVURLAsset(url: assetURL)
        urlAsset.resourceLoader.setDelegate(self, queue: callbackQueue)
        let item = AVPlayerItem(asset: urlAsset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    public func cancel() {
        lock.lock()
        let requests = loadingRequests
        loadingRequests.removeAll()
        let task = downloadTask
        downloadTask = nil
        lock.unlock()
        for req in requests {
            req.finishLoading(with: URLError(.cancelled) as NSError)
        }
        task?.cancel()
    }

    public var isCacheCompleted: Bool {
        cache.isCacheComplete(for: originalURL)
    }

    public var cacheProgressValue: Double {
        let info = cache.info(for: originalURL)
        return Double(info.cachedLength) / Double(max(info.contentLength, 1))
    }

    public func cleanCache() {
        cache.clear(for: originalURL)
    }

    public static func cleanAllCache() {
        AIVVideoCache.shared.clearAll()
    }

    private func startDownloadIfNeeded() {
        lock.lock()
        let alreadyDownloading = downloadTask != nil
        lock.unlock()
        guard !alreadyDownloading else { return }

        let info = cache.info(for: originalURL)
        guard !info.isComplete else {
            respondToAllLoadingRequests()
            return
        }

        let task = AIVVideoDownloadTask(url: originalURL, startOffset: info.cachedLength)
        lock.lock()
        downloadTask = task
        lock.unlock()

        task.onContentInfo = { [weak self] _, _ in
            self?.respondToAllLoadingRequests()
        }
        task.onReceiveData = { [weak self] in
            self?.respondToAllLoadingRequests()
        }
        task.onComplete = { [weak self] _, error in
            guard let self else { return }
            if let error, (error as NSError).domain != NSURLErrorDomain || (error as NSError).code != NSURLErrorCancelled {
                for req in self.safeGetRequests() {
                    req.finishLoading(with: error as NSError)
                }
            } else {
                self.respondToAllLoadingRequests()
            }
        }

        task.start()
    }

    private func respondToAllLoadingRequests() {
        // 一批请求共用同一次 cache.info(for:) 结果，避免每个 request 都各自触发一次磁盘元数据读取
        let info = cache.info(for: originalURL)
        guard info.contentLength > 0 else { return }
        for req in safeGetRequests() {
            _ = respond(to: req, info: info)
        }
    }

    private func respond(to loadingRequest: AVAssetResourceLoadingRequest, info: AIVVideoCache.Info) -> Bool {
        if loadingRequest.isCancelled || loadingRequest.isFinished { return false }

        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = info.mimeType.isEmpty ? "video/mp4" : info.mimeType
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.contentLength = info.contentLength
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            removeRequest(loadingRequest)
            return true
        }

        let requestedOffset = Int64(dataRequest.requestedOffset)
        let requestedLength = dataRequest.requestsAllDataToEndOfResource
            ? Int(info.contentLength - requestedOffset)
            : dataRequest.requestedLength
        let endOffset = requestedOffset + Int64(requestedLength)

        // 用 currentOffset 而非 requestedOffset，避免多次 respond 时重复推送已提供的数据
        let currentOffset = Int64(dataRequest.currentOffset)
        guard currentOffset >= 0, currentOffset < endOffset, currentOffset < info.cachedLength else { return false }

        let available = min(info.cachedLength, endOffset) - currentOffset
        guard available > 0, let data = cache.read(offset: currentOffset, length: Int(available), for: originalURL) else { return false }
        dataRequest.respond(with: data)

        if Int64(dataRequest.currentOffset) >= endOffset {
            loadingRequest.finishLoading()
            removeRequest(loadingRequest)
            return true
        }

        return false
    }

    private func safeGetRequests() -> [AVAssetResourceLoadingRequest] {
        lock.lock()
        let copy = loadingRequests
        lock.unlock()
        return copy
    }

    private func addRequest(_ request: AVAssetResourceLoadingRequest) {
        lock.lock()
        loadingRequests.append(request)
        lock.unlock()
    }

    private func removeRequest(_ request: AVAssetResourceLoadingRequest) {
        lock.lock()
        loadingRequests.removeAll { $0 == request }
        lock.unlock()
    }
}

// MARK: - Preload

public extension AIVVideoResourceLoader {
    static func preload(url: URL) async throws -> URL {
        if url.isFileURL { return url }

        let cache = AIVVideoCache.shared
        if cache.isCacheComplete(for: url) {
            return URL(fileURLWithPath: cache.filePath(for: url))
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = AIVVideoDownloadTask(url: url)
            task.onComplete = { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: URL(fileURLWithPath: cache.filePath(for: url)))
                }
            }
            task.start()
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension AIVVideoResourceLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        onDelegateCallback?(Thread.isMainThread)
        addRequest(loadingRequest)
        startDownloadIfNeeded()
        let info = cache.info(for: originalURL)
        if info.contentLength > 0 {
            _ = respond(to: loadingRequest, info: info)
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        removeRequest(loadingRequest)
        if safeGetRequests().isEmpty {
            lock.lock()
            let task = downloadTask
            downloadTask = nil
            lock.unlock()
            task?.cancel()
        }
    }
}
