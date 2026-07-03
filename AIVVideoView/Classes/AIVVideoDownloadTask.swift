import Foundation

final class AIVVideoDownloadTask: NSObject {
    let url: URL
    private(set) var contentLength: Int64 = 0
    private(set) var mimeType = ""
    private(set) var isCancelled = false
    private(set) var downloadedLength: Int64

    private var startOffset: Int64
    private let cache = AIVVideoCache.shared
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?

    var onReceiveData: (() -> Void)?
    var onComplete: ((AIVVideoDownloadTask, Error?) -> Void)?
    var onContentInfo: ((Int64, String) -> Void)?

    init(url: URL, startOffset: Int64 = 0) {
        self.url = url
        self.startOffset = startOffset
        self.downloadedLength = startOffset
        super.init()
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        if startOffset > 0 {
            request.addValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
        }
        dataTask = session?.dataTask(with: request)
    }

    func start() {
        dataTask?.resume()
    }

    func cancel() {
        isCancelled = true
        dataTask?.cancel()
        session?.invalidateAndCancel()
    }
}

extension AIVVideoDownloadTask: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cache.write(data, at: downloadedLength, for: url)
        downloadedLength += Int64(data.count)
        onReceiveData?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete?(self, error)
    }
}
