import Foundation

final class AIVVideoDownloadTask: NSObject {
    let url: URL
    private(set) var contentLength: Int64 = 0
    private(set) var mimeType = ""
    private(set) var isCancelled = false
    private(set) var downloadedLength: Int64

    private var startOffset: Int64
    private let cache = AIVVideoCache.shared
    private var dataTask: URLSessionDataTask?

    var onReceiveData: (() -> Void)?
    var onComplete: ((AIVVideoDownloadTask, Error?) -> Void)?
    var onContentInfo: ((Int64, String) -> Void)?

    /// 测试用的注入点：默认返回和线上完全一致的 .default 配置。
    /// URLProtocol.registerClass 全局注册在 .default 配置下并不总是能可靠拦截请求
    /// （系统可能会走出进程的网络守护进程），单测需要换成 .ephemeral + 显式 protocolClasses
    /// 才能稳定拦截，所以留了这个内部可替换的口子，不影响线上行为。
    /// 所有下载任务共用 AIVVideoDownloadSession.shared 这一个 URLSession，configuration
    /// 只在 session 创建时读取一次，所以这里换了 provider 之后要顺带重建底层 session。
    static var sessionConfigurationProvider: () -> URLSessionConfiguration = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    } {
        didSet { AIVVideoDownloadSession.shared.reload() }
    }

    init(url: URL, startOffset: Int64 = 0) {
        self.url = url
        self.startOffset = startOffset
        self.downloadedLength = startOffset
        super.init()
        var request = URLRequest(url: url)
        if startOffset > 0 {
            request.addValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
        }
        dataTask = AIVVideoDownloadSession.shared.makeDataTask(for: request, owner: self)
    }

    func start() {
        dataTask?.resume()
    }

    func cancel() {
        isCancelled = true
        dataTask?.cancel()
    }
}

/// 由 AIVVideoDownloadSession（所有任务共用的 URLSessionDataDelegate）按 dataTask
/// 转发过来，语义和之前各任务自己当 delegate 时完全一致。
extension AIVVideoDownloadTask {
    func handleReceive(response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        mimeType = response.mimeType ?? "video/mp4"

        // 服务端不支持 Range 请求，退化为从头完整下载
        if startOffset > 0, httpResponse.statusCode == 200 {
            startOffset = 0
            downloadedLength = 0
            cache.clear(for: url)
        }

        if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String,
           let total = contentRange.split(separator: "/").last.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) {
            contentLength = total
        } else {
            contentLength = startOffset + response.expectedContentLength
        }
        cache.updateContentInfo(contentLength: contentLength, mimeType: mimeType, for: url)
        onContentInfo?(contentLength, mimeType)
        completionHandler(.allow)
    }

    func handleReceive(data: Data) {
        cache.write(data, at: downloadedLength, for: url)
        downloadedLength += Int64(data.count)
        onReceiveData?()
    }

    func handleComplete(error: Error?) {
        onComplete?(self, error)
    }
}
