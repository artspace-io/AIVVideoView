import XCTest
import AVFoundation
@testable import AIVVideoView

/// 播放控制与可配项的纯逻辑验证。status 是同步更新的，不需要等真正的网络加载完成；
/// 统一用 .invalid 域名，保证不会打到真实服务器。
@MainActor
final class AIVVideoPlayerPlaybackControlTests: XCTestCase {
    private let url = URL(string: "https://video.invalid/clip.mp4")!

    /// playFromBeginning 走的是 seek 回 0，不该重新加载资源——重新加载会让已经缓冲好的
    /// 内容白白丢掉，从头播反而比继续播还慢。
    func testPlayFromBeginningSeeksWithoutRebuilding() {
        let player = AIVVideoPlayer()
        player.prepare(url: url)
        XCTAssertEqual(player.status, .preparing, "prepare 必然要加载一次")

        player.playFromBeginning()

        XCTAssertEqual(player.status, .seeking, "应该只是 seek 回 0，不重新加载")
    }

    func testPlayFromBeginningKeepsPlaylistPosition() {
        let player = AIVVideoPlayer()
        let urls = (0..<3).map { URL(string: "https://video.invalid/\($0).mp4")! }
        player.preparePlaylist(urls, startIndex: 1, mode: .list)

        player.playFromBeginning()

        XCTAssertEqual(player.currentPlaylistIndex, 1, "从头播的是当前这一项，不该跳回列表第一项")
    }

    func testTimeObserverIntervalDefaultsToTenthOfSecond() {
        let player = AIVVideoPlayer()
        XCTAssertEqual(player.timeObserverInterval, CMTimeMake(value: 1, timescale: 10))
    }

    /// 改间隔时会重建周期观察者。这里主要钉住"有播放项在手时修改不会崩"——
    /// 实现里如果忘了先摘掉旧 token 再加新的，AVPlayer 会在 removeTimeObserver 时抛异常，
    /// 或者叠加出多个回调。
    func testTimeObserverIntervalIsConfigurableWhileLoaded() {
        let player = AIVVideoPlayer()
        player.prepare(url: url)

        player.timeObserverInterval = CMTimeMake(value: 1, timescale: 60)
        XCTAssertEqual(player.timeObserverInterval, CMTimeMake(value: 1, timescale: 60))

        player.timeObserverInterval = CMTimeMake(value: 1, timescale: 30)
        XCTAssertEqual(player.timeObserverInterval, CMTimeMake(value: 1, timescale: 30))
    }

    func testTimeObserverIntervalIsConfigurableBeforeLoading() {
        let player = AIVVideoPlayer()

        player.timeObserverInterval = CMTimeMake(value: 1, timescale: 60)

        XCTAssertEqual(player.timeObserverInterval, CMTimeMake(value: 1, timescale: 60))
        XCTAssertEqual(player.status, .idle, "只改配置不应该触发任何加载")
    }
}
