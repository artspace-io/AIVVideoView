import XCTest
@testable import AIVVideoView

/// AIVCellPlaybackController 创建的是真实的 AIVVideoPlayer（连带真实的 resourceLoader/下载），
/// 但这里测的都是“申请到名额就同步创建播放器”这一步的结构性行为，不需要等网络真正返回，
/// 所以用 Tier3/4 同一套 StubURLProtocol 注入，让后台请求安全地失败/挂起，不碰真实网络即可。
@MainActor
final class AIVCellPlaybackControllerTests: XCTestCase {
    private var controllers: [AIVCellPlaybackController] = []
    private var originalMaxConcurrentPlayers = 0

    override func setUp() {
        super.setUp()
        AIVVideoDownloadTask.sessionConfigurationProvider = {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            return config
        }
        StubURLProtocol.handler = { _ in nil }
        originalMaxConcurrentPlayers = AIVVideoPlayerCoordinator.shared.maxConcurrentPlayers
    }

    override func tearDown() {
        for controller in controllers {
            controller.deactivate()
        }
        controllers = []
        AIVVideoPlayerCoordinator.shared.maxConcurrentPlayers = originalMaxConcurrentPlayers
        StubURLProtocol.handler = nil
        AIVVideoDownloadTask.sessionConfigurationProvider = {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return config
        }
        super.tearDown()
    }

    private func makeController() -> AIVCellPlaybackController {
        let controller = AIVCellPlaybackController()
        controllers.append(controller)
        return controller
    }

    private func makeURL(_ tag: String = "") -> URL {
        URL(string: "https://cellplayback-test.invalid/\(tag)-\(UUID().uuidString).mp4")!
    }

    func testBelowMinimumRatioDoesNotCreatePlayer() {
        let controller = makeController()
        let url = makeURL()

        controller.updateVisibility(ratio: 0.1, minimumRatio: 0.5) { url }

        XCTAssertNil(controller.playerView.player)
    }

    func testReachingThresholdCreatesPlayer() {
        let controller = makeController()
        let url = makeURL()

        controller.updateVisibility(ratio: 0.6, minimumRatio: 0.5) { url }

        XCTAssertNotNil(controller.playerView.player)
    }

    func testSameURLRepeatedUpdateVisibilityDoesNotRecreatePlayer() {
        let controller = makeController()
        let url = makeURL()
        controller.updateVisibility(ratio: 0.6, minimumRatio: 0.5) { url }
        let firstPlayer = controller.playerView.player

        controller.updateVisibility(ratio: 0.8, minimumRatio: 0.5) { url }

        XCTAssertTrue(controller.playerView.player === firstPlayer, "同一个 URL 重复达到阈值不应该重建播放器，只应该更新可见比例")
    }

    func testURLChangeWhileHoldingPlayerDeactivatesAndRecreates() {
        let controller = makeController()
        let urlA = makeURL("A")
        let urlB = makeURL("B")
        controller.updateVisibility(ratio: 0.6, minimumRatio: 0.5) { urlA }
        let firstPlayer = controller.playerView.player
        XCTAssertNotNil(firstPlayer)

        var deactivateCount = 0
        controller.onDeactivated = { deactivateCount += 1 }
        controller.updateVisibility(ratio: 0.6, minimumRatio: 0.5) { urlB }

        XCTAssertEqual(deactivateCount, 1, "view 被复用来展示不同内容时应该先 deactivate 一次，释放旧内容的名额")
        XCTAssertNotNil(controller.playerView.player)
        XCTAssertFalse(controller.playerView.player === firstPlayer, "URL 变了应该拿到一个全新的播放器，而不是复用旧的")
    }

    func testSetActiveFalseReleasesSlotAndFiresOnDeactivated() {
        let controller = makeController()
        let url = makeURL()
        controller.setActive(true) { url }
        XCTAssertNotNil(controller.playerView.player)

        var deactivated = false
        controller.onDeactivated = { deactivated = true }
        controller.setActive(false) { url }

        XCTAssertTrue(deactivated)
        XCTAssertNil(controller.playerView.player)
    }

    func testEvictionByCoordinatorReleasesPlayerAndFiresOnDeactivated() {
        AIVVideoPlayerCoordinator.shared.maxConcurrentPlayers = 1
        let occupant = makeController()
        let challenger = makeController()

        occupant.updateVisibility(ratio: 0.3, minimumRatio: 0.1) { self.makeURL("occupant") }
        XCTAssertNotNil(occupant.playerView.player)

        var occupantDeactivated = false
        occupant.onDeactivated = { occupantDeactivated = true }

        challenger.updateVisibility(ratio: 0.9, minimumRatio: 0.1) { self.makeURL("challenger") }

        XCTAssertTrue(occupantDeactivated, "名额被可见比例更高的 challenger 挤占时，原占用者应该收到 onDeactivated 回调")
        XCTAssertNil(occupant.playerView.player)
        XCTAssertNotNil(challenger.playerView.player)
    }

    func testPlayModeDefaultsToSingleAndIsPassedToCreatedPlayer() {
        let controller = makeController()
        let url = makeURL()

        controller.updateVisibility(ratio: 0.6, minimumRatio: 0.5) { url }

        XCTAssertEqual(controller.playerView.player?.playMode, .single)
    }

    func testCustomPlayModeIsPassedToCreatedPlayer() {
        let controller = makeController()
        controller.playMode = .circle
        let url = makeURL()

        controller.updateVisibility(ratio: 0.6, minimumRatio: 0.5) { url }

        XCTAssertEqual(controller.playerView.player?.playMode, .circle, "宿主设置的 playMode 应该透传给新建的 AIVVideoPlayer")
    }
}
