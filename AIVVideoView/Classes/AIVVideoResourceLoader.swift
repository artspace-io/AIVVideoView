import Foundation
import AVFoundation

final class AIVVideoResourceLoader: NSObject {
    let originalURL: URL
    private var loadingRequests: [AVAssetResourceLoadingRequest] = []
    private var downloadTask: AIVVideoDownloadTask?
    private let cache = AIVVideoCache.shared
    private let lock = NSLock()

    init(url: URL) {
        self.originalURL = url
        super.init()
    }

    static func assetURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.scheme = "AIVCache"
        return components.url!
    }

    func makePlayerItem() -> AVPlayerItem {
        let assetURL = Self.assetURL(for: originalURL)
        let urlAsset = AVURLAsset(url: assetURL)
        urlAsset.resourceLoader.setDelegate(self, queue: .main)
        let item = AVPlayerItem(asset: urlAsset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    func cancel() {
        lock.lock()
        let requests = loadingRequests
        loadingRequests.removeAll()
        lock.unlock()
        for req in requests {
            req.finishLoading(with: URLError(.cancelled) as NSError)
        }
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func startDownloadIfNeeded() {
        guard downloadTask == nil else { return }
        guard !cache.isCacheComplete(for: originalURL) else {
            respondToAllLoadingRequests()
            return
        }

        let task = AIVVideoDownloadTask(url: originalURL, startOffset: cache.cachedLength(for: originalURL))
        downloadTask = task

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
        for req in safeGetRequests() {
            _ = respond(to: req)
        }
    }

    private func respond(to loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if loadingRequest.isCancelled || loadingRequest.isFinished { return false }

        let info = cache.info(for: originalURL)
        guard info.contentLength > 0 else { return false }

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

// MARK: - AVAssetResourceLoaderDelegate

extension AIVVideoResourceLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        addRequest(loadingRequest)
        startDownloadIfNeeded()
        _ = respond(to: loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        removeRequest(loadingRequest)
        if safeGetRequests().isEmpty {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }
}
