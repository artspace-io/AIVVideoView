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
}
