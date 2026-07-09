import XCTest
@testable import AIVVideoView

/// AIVVideoPlayerCoordinator 是全局单例，没有可注入的“重置”入口，
/// 所以每个用例必须自己追踪申请过的 token 并在 tearDown 里全部 releaseSlot，
/// 否则会污染后续用例的 slots 状态。
@MainActor
final class AIVVideoPlayerCoordinatorTests: XCTestCase {
    private var coordinator: AIVVideoPlayerCoordinator!
    private var originalMaxConcurrentPlayers = 0
    private var tokens: [AnyObject] = []

    override func setUp() {
        super.setUp()
        coordinator = AIVVideoPlayerCoordinator.shared
        originalMaxConcurrentPlayers = coordinator.maxConcurrentPlayers
    }

    override func tearDown() {
        for token in tokens {
            coordinator.releaseSlot(for: token)
        }
        tokens = []
        coordinator.maxConcurrentPlayers = originalMaxConcurrentPlayers
        super.tearDown()
    }

    private func makeToken() -> AnyObject {
        let token = NSObject()
        tokens.append(token)
        return token
    }

    func testGrantsSlotWhenUnderCapacity() {
        coordinator.maxConcurrentPlayers = 2
        let token = makeToken()

        let granted = coordinator.requestSlot(for: token, visibleRatio: 0.5) { XCTFail("不应该被驱逐") }

        XCTAssertTrue(granted)
    }

    func testReRequestingSameTokenUpdatesInPlaceWithoutConsumingExtraCapacity() {
        coordinator.maxConcurrentPlayers = 1
        let token = makeToken()

        XCTAssertTrue(coordinator.requestSlot(for: token, visibleRatio: 0.3) { })
        // 容量只有 1，如果重复申请被当成新名额，第二次这里就会因为“已满”而走仲裁分支
        XCTAssertTrue(coordinator.requestSlot(for: token, visibleRatio: 0.9) { })

        let other = makeToken()
        XCTAssertFalse(
            coordinator.requestSlot(for: other, visibleRatio: 0.1) { },
            "容量已被同一个 token 占满，可见比例更低的新 token 不应该抢到名额"
        )
    }

    func testRequestFailsWhenFullAndNewRatioNotHigherThanLowest() {
        coordinator.maxConcurrentPlayers = 1
        let occupant = makeToken()
        var occupantEvicted = false
        XCTAssertTrue(coordinator.requestSlot(for: occupant, visibleRatio: 0.5) { occupantEvicted = true })

        let challenger = makeToken()
        let granted = coordinator.requestSlot(for: challenger, visibleRatio: 0.5) { }

        XCTAssertFalse(granted, "可见比例没有严格大于最低占用者，不应该抢占成功")
        XCTAssertFalse(occupantEvicted)
    }

    func testHigherRatioEvictsLowestOccupant() {
        coordinator.maxConcurrentPlayers = 1
        let occupant = makeToken()
        var occupantEvicted = false
        XCTAssertTrue(coordinator.requestSlot(for: occupant, visibleRatio: 0.4) { occupantEvicted = true })

        let challenger = makeToken()
        let granted = coordinator.requestSlot(for: challenger, visibleRatio: 0.9) { }

        XCTAssertTrue(granted)
        XCTAssertTrue(occupantEvicted, "可见比例更高的新 token 应该驱逐原占用者并触发它的 onEvicted")
    }

    func testUpdateVisibleRatioProtectsTokenFromLaterEviction() {
        coordinator.maxConcurrentPlayers = 1
        let occupant = makeToken()
        var occupantEvicted = false
        XCTAssertTrue(coordinator.requestSlot(for: occupant, visibleRatio: 0.2) { occupantEvicted = true })

        // 占用者的可见比例被更新到 0.95，理应不再是仲裁时最容易被挤占的那个
        coordinator.updateVisibleRatio(0.95, for: occupant)

        let challenger = makeToken()
        let granted = coordinator.requestSlot(for: challenger, visibleRatio: 0.5) { }

        XCTAssertFalse(granted)
        XCTAssertFalse(occupantEvicted)
    }

    func testUpdateVisibleRatioForUnknownTokenIsNoOp() {
        let unknown = makeToken()
        // 从未 requestSlot 过，updateVisibleRatio 不应该崩溃，也不应该凭空产生一个名额
        coordinator.updateVisibleRatio(0.9, for: unknown)

        coordinator.maxConcurrentPlayers = 1
        let occupant = makeToken()
        XCTAssertTrue(coordinator.requestSlot(for: occupant, visibleRatio: 0.1) { })
    }

    func testReleaseSlotFreesCapacityForNextRequest() {
        coordinator.maxConcurrentPlayers = 1
        let occupant = makeToken()
        XCTAssertTrue(coordinator.requestSlot(for: occupant, visibleRatio: 0.5) { })

        coordinator.releaseSlot(for: occupant)

        let newcomer = makeToken()
        XCTAssertTrue(coordinator.requestSlot(for: newcomer, visibleRatio: 0.01) { })
    }

    func testReleaseSlotForUnknownTokenIsNoOp() {
        let unknown = makeToken()
        coordinator.releaseSlot(for: unknown)
    }
}
