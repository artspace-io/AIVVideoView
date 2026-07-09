import XCTest
import AVFoundation
@testable import AIVVideoView

@MainActor
final class AIVVideoPlayerViewTests: XCTestCase {
    func testAssigningPlayerWiresUpPlayerLayer() {
        let view = AIVVideoPlayerView()
        let player = AIVVideoPlayer()
        player.videoGravity = .resizeAspect

        view.player = player

        XCTAssertTrue(view.playerLayer.player === player.player)
        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)
        XCTAssertFalse(view.playerLayer.isHidden)
    }

    func testClearingPlayerHidesLayerAndDetachesAVPlayer() {
        let view = AIVVideoPlayerView()
        let player = AIVVideoPlayer()
        view.player = player

        view.player = nil

        XCTAssertNil(view.playerLayer.player)
        XCTAssertTrue(view.playerLayer.isHidden)
    }

    func testVideoGravityChangesAfterAssignmentPropagateToLayer() {
        let view = AIVVideoPlayerView()
        let player = AIVVideoPlayer()
        view.player = player

        player.videoGravity = .resizeAspectFill

        // player.$videoGravity 的订阅是 .receive(on: .main)，即使已经在主线程也会重新派发一次，
        // 用同一个串行主队列上再排一个任务，等它排到前面那个转发完成后再断言。
        let propagated = expectation(description: "gravity propagated to layer")
        DispatchQueue.main.async { propagated.fulfill() }
        wait(for: [propagated], timeout: 1)

        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspectFill)
    }
}
