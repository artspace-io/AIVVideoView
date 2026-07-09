import XCTest
import AVFoundation
@testable import AIVVideoView

final class AIVVideoResourceLoaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
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
        super.tearDown()
    }

    /// 回归测试：之前列表滑动卡顿的根因是 resourceLoader 代理回调被派发在主线程（.main queue），
    /// 回调内部又同步做磁盘/网络 I/O，直接卡住 UI（见 AIVVideoResourceLoader.makePlayerItem() 里
    /// 把 setDelegate 的 queue 从 .main 换成专用后台队列的那次修复）。这里断言不管回调触发几次，
    /// 全部都不在主线程上执行，防止以后有人不小心把 delegate queue 改回 .main。
    func testDelegateCallbackNeverFiresOnMainThread() {
        let url = URL(string: "https://resourceloader-test.invalid/\(UUID().uuidString).mp4")!
        let payload = Data(repeating: 0x1, count: 4096)
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                statusCode: 200,
                headers: ["Content-Length": "\(payload.count)", "Content-Type": "video/mp4"],
                body: payload
            )
        }

        let loader = AIVVideoResourceLoader(url: url)
        var capturedIsMainThread: [Bool] = []
        let callbackExpectation = expectation(description: "resourceLoader callback fired at least once")
        callbackExpectation.assertForOverFulfill = false
        loader.onDelegateCallback = { isMainThread in
            capturedIsMainThread.append(isMainThread)
            callbackExpectation.fulfill()
        }

        let item = loader.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false

        wait(for: [callbackExpectation], timeout: 5)

        XCTAssertFalse(capturedIsMainThread.isEmpty)
        XCTAssertTrue(
            capturedIsMainThread.allSatisfy { $0 == false },
            "resourceLoader 代理回调不应该在主线程上执行，否则会在列表滑动时卡住 UI"
        )

        loader.cancel()
        _ = player // 保持强引用到断言结束，避免 AVPlayer 提前释放导致回调提前停止
    }

    /// 回归测试：本地 file:// URL 之前会被送进专门为 http(s) 边下边播设计的资源加载器，
    /// AIVVideoDownloadTask 只认 HTTPURLResponse，对本地文件请求收到的是普通 URLResponse，
    /// 会在 didReceive response 里被直接 cancel 掉，导致 contentLength 永远是 0、所有
    /// loadingRequest 永远等不到数据——播放器卡在 preparing 永远不会 readyToPlay，
    /// didPlayToEndTimeNotification 自然也永远不会触发。修复后本地文件应该完全绕开
    /// resourceLoader，直接用原始 file:// URL 构建 AVPlayerItem。
    func testLocalFileURLBypassesResourceLoaderEntirely() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try? Data("not a real video, only the wiring is under test".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let loader = AIVVideoResourceLoader(url: fileURL)
        var callbackFired = false
        loader.onDelegateCallback = { _ in callbackFired = true }

        let item = loader.makePlayerItem()

        guard let urlAsset = item.asset as? AVURLAsset else {
            XCTFail("本地文件也应该是用 AVURLAsset 承载的")
            return
        }
        XCTAssertEqual(urlAsset.url, fileURL, "本地文件应该直接用原始 file:// URL 播放，不应该被改写成 AIVCache scheme")

        // 给 AVFoundation 一点时间去 resolve asset，确认它确实不会来问 resourceLoader 要数据
        // （因为压根没有给它注册 resourceLoader 代理）。
        let player = AVPlayer(playerItem: item)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 1)

        XCTAssertFalse(callbackFired, "本地文件不应该触发 resourceLoader 代理回调")
        loader.cancel()
        _ = player
    }
}
