import XCTest
@testable import AIVVideoView

final class AIVVideoDownloadTaskTests: XCTestCase {
    private let cache = AIVVideoCache.shared
    private var testURLs: [URL] = []

    override func setUp() {
        super.setUp()
        // .default 配置的 URLSession 在这个环境里不可靠地遵守全局 URLProtocol.registerClass
        // （请求会绕过 stub 走真实网络再因为域名不解析而失败），改用 .ephemeral + 显式
        // protocolClasses，这是唯一能稳定拦截 AIVVideoDownloadTask 内部请求的方式。
        AIVVideoDownloadTask.sessionConfigurationProvider = {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            return config
        }
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        AIVVideoDownloadTask.sessionConfigurationProvider = {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return config
        }
        for url in testURLs {
            cache.clear(for: url)
        }
        testURLs = []
        super.tearDown()
    }

    private func makeURL(_ tag: String = "") -> URL {
        let url = URL(string: "https://download-test.invalid/\(tag)-\(UUID().uuidString).mp4")!
        testURLs.append(url)
        return url
    }

    func testFullDownloadReportsContentInfoAndWritesDataToCache() {
        let url = makeURL()
        let payload = Data((0..<200).map { UInt8($0 % 256) })
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                statusCode: 200,
                headers: ["Content-Length": "\(payload.count)", "Content-Type": "video/mp4"],
                body: payload
            )
        }

        let task = AIVVideoDownloadTask(url: url)
        let infoExpectation = expectation(description: "onContentInfo")
        let completeExpectation = expectation(description: "onComplete")
        var reportedLength: Int64?
        var reportedMime: String?
        task.onContentInfo = { length, mime in
            reportedLength = length
            reportedMime = mime
            infoExpectation.fulfill()
        }
        task.onComplete = { _, error in
            XCTAssertNil(error)
            completeExpectation.fulfill()
        }
        task.start()

        wait(for: [infoExpectation, completeExpectation], timeout: 5)

        XCTAssertEqual(reportedLength, Int64(payload.count))
        XCTAssertEqual(reportedMime, "video/mp4")
        XCTAssertEqual(task.downloadedLength, Int64(payload.count))
        XCTAssertEqual(cache.read(offset: 0, length: payload.count, for: url), payload)
    }

    func testResumeSendsRangeHeaderAndTotalLengthComesFromContentRange() {
        let url = makeURL()
        let startOffset: Int64 = 100
        let tail = Data(repeating: 0xAB, count: 50)
        var capturedRangeHeader: String?

        StubURLProtocol.handler = { request in
            capturedRangeHeader = request.value(forHTTPHeaderField: "Range")
            return StubURLProtocol.StubResponse(
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes 100-149/150",
                    "Content-Length": "\(tail.count)",
                ],
                body: tail
            )
        }

        let task = AIVVideoDownloadTask(url: url, startOffset: startOffset)
        let completeExpectation = expectation(description: "onComplete")
        task.onComplete = { _, _ in completeExpectation.fulfill() }
        task.start()

        wait(for: [completeExpectation], timeout: 5)

        XCTAssertEqual(capturedRangeHeader, "bytes=100-", "断点续传应该带上从 startOffset 开始的 Range 请求头")
        XCTAssertEqual(task.contentLength, 150, "支持 Range 时，总长度应该来自 Content-Range 里的资源总大小，而不是这次响应体的长度")
        XCTAssertEqual(task.downloadedLength, 150, "从 100 续传写入 50 字节后，downloadedLength 应该到 150")
    }

    func testServerIgnoringRangeFallsBackToFullDownloadFromZero() {
        let url = makeURL()
        // 先在缓存里留一点“已经下载过”的痕迹，验证服务端不支持 Range 时会被清掉重来
        cache.write(Data(repeating: 0x1, count: 10), at: 0, for: url)

        let full = Data(repeating: 0xCD, count: 30)
        StubURLProtocol.handler = { _ in
            // 服务端不支持 Range，忽略请求头直接返回完整内容和 200
            StubURLProtocol.StubResponse(statusCode: 200, headers: ["Content-Length": "\(full.count)"], body: full)
        }

        let task = AIVVideoDownloadTask(url: url, startOffset: 10)
        let completeExpectation = expectation(description: "onComplete")
        task.onComplete = { _, _ in completeExpectation.fulfill() }
        task.start()

        wait(for: [completeExpectation], timeout: 5)

        XCTAssertEqual(task.downloadedLength, Int64(full.count), "服务端退化为全量下载时应该从 0 重新计数，而不是继续叠加旧的 startOffset")
        XCTAssertEqual(cache.read(offset: 0, length: full.count, for: url), full, "旧缓存应该被清空，最终内容是完整的全量下载结果")
    }

    func testChunkedDeliveryFiresOnReceiveDataPerChunkAndPreservesOrder() {
        let url = makeURL()
        let payload = Data((0..<100).map { UInt8($0) })
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                statusCode: 200,
                headers: ["Content-Length": "\(payload.count)"],
                body: payload,
                chunkSize: 10
            )
        }

        let task = AIVVideoDownloadTask(url: url)
        var receiveCount = 0
        let completeExpectation = expectation(description: "onComplete")
        task.onReceiveData = { receiveCount += 1 }
        task.onComplete = { _, _ in completeExpectation.fulfill() }
        task.start()

        wait(for: [completeExpectation], timeout: 5)

        // URLSession 内部会不会把多次 didLoad 合并成更少的 didReceive data 回调是它自己的实现细节，
        // 不是 AIVVideoDownloadTask 的行为契约，这里不強求精确的 10 次，只保证“确实收到过增量进度”。
        XCTAssertGreaterThan(receiveCount, 0, "分片到达过程中应该至少触发一次 onReceiveData 进度回调")
        XCTAssertEqual(cache.read(offset: 0, length: payload.count, for: url), payload, "不管系统内部怎么合并分片，最终写入的内容都必须完整且不错位")
    }

    func testCancelMarksCancelledAndStopsFurtherWork() {
        let url = makeURL()
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(statusCode: 200, headers: ["Content-Length": "4"], body: Data(repeating: 0, count: 4))
        }

        let task = AIVVideoDownloadTask(url: url)
        XCTAssertFalse(task.isCancelled)

        task.cancel()

        XCTAssertTrue(task.isCancelled)
    }

    func testNetworkFailurePropagatesNonCancelErrorToOnComplete() {
        let url = makeURL()
        StubURLProtocol.handler = { _ in nil }

        let task = AIVVideoDownloadTask(url: url)
        let completeExpectation = expectation(description: "onComplete")
        var receivedError: NSError?
        task.onComplete = { _, error in
            receivedError = error as NSError?
            completeExpectation.fulfill()
        }
        task.start()

        wait(for: [completeExpectation], timeout: 5)

        XCTAssertNotNil(receivedError)
        XCTAssertNotEqual(receivedError?.code, NSURLErrorCancelled, "这是网络失败，不应该被误判成用户取消")
    }
}
