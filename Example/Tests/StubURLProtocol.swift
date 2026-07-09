import Foundation

/// 全局注册的 URLProtocol，用来拦截 AIVVideoDownloadTask 内部自建的
/// URLSession(configuration: .default) 发出的请求——它没有对外暴露任何注入点，
/// 只能靠这种“系统级”的 stub 机制在测试里假装有一个支持 Range 的视频服务器。
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        /// 分成多片依次 didLoad，模拟真实网络分块到达，驱动 onReceiveData 多次触发
        let chunkSize: Int

        init(statusCode: Int, headers: [String: String], body: Data, chunkSize: Int? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.chunkSize = chunkSize ?? body.count
        }
    }

    /// 请求进来时调用，返回 nil 表示这个请求应该直接失败（模拟网络错误）
    static var handler: ((URLRequest) -> StubResponse?)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let stub = handler(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // 注意：即使这里按 chunkSize 分开调用 didLoad，URLSession 仍然可能在内部把它们合并成
        // 更少次数的 didReceive data 回调——那是系统自己的缓冲策略，不保证 1:1 透传。
        var offset = 0
        while offset < stub.body.count {
            let end = min(offset + stub.chunkSize, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
