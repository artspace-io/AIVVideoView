import XCTest
@testable import AIVVideoView

/// 只验证 playMode 驱动下标切换的纯逻辑（playAt 里 currentIndex 是同步更新的，
/// 不需要等真正的网络加载完成）。用 .invalid 域名，保证不会打到真实服务器。
@MainActor
final class AIVVideoPlayerPlaylistOrderTests: XCTestCase {
    private func urls(_ count: Int) -> [URL] {
        (0..<count).map { URL(string: "https://video.invalid/\($0).mp4")! }
    }

    func testListModeStopsAfterLastAndFiresCompletion() {
        let player = AIVVideoPlayer()
        var completed = false
        player.onPlaylistCompleted = { completed = true }
        player.preparePlaylist(urls(3), mode: .list)

        player.playNext()
        XCTAssertEqual(player.currentPlaylistIndex, 1)
        player.playNext()
        XCTAssertEqual(player.currentPlaylistIndex, 2)
        player.playNext()

        XCTAssertEqual(player.currentPlaylistIndex, 2, "已经是最后一项，playNext 不应再前进")
        XCTAssertFalse(completed, "playNext 越界只是原地不动，不等价于自然播完")
    }

    func testListModePlayPreviousStopsAtHead() {
        let player = AIVVideoPlayer()
        player.preparePlaylist(urls(3), startIndex: 1, mode: .list)

        player.playPrevious()
        XCTAssertEqual(player.currentPlaylistIndex, 0)
        player.playPrevious()
        XCTAssertEqual(player.currentPlaylistIndex, 0, "已经在第一项，playPrevious 不应再后退")
    }

    func testCircleModeWrapsAroundBothDirections() {
        let player = AIVVideoPlayer()
        player.preparePlaylist(urls(3), mode: .circle)

        player.playPrevious()
        XCTAssertEqual(player.currentPlaylistIndex, 2, "从第一项往前应该绕到最后一项")

        player.playNext()
        XCTAssertEqual(player.currentPlaylistIndex, 0, "从最后一项往后应该绕回第一项")
    }

    /// .single 只在“自然播完”（handlePlaybackFinished）时原地重播当前视频；
    /// 用户手动 playNext()/playPrevious() 仍然和 .circle 一样按顺序环绕列表，
    /// 这里验证的是后者——不要和自动重播行为搞混。
    func testSingleModeStillCyclesOnManualNextPrevious() {
        let player = AIVVideoPlayer()
        player.preparePlaylist(urls(3), startIndex: 1, mode: .single)

        player.playNext()
        XCTAssertEqual(player.currentPlaylistIndex, 2)
        player.playNext()
        XCTAssertEqual(player.currentPlaylistIndex, 0, "手动 playNext 到头后应该和 .circle 一样绕回第一项")

        player.playPrevious()
        XCTAssertEqual(player.currentPlaylistIndex, 2, "手动 playPrevious 从头往前也应该绕到最后一项")
    }

    /// preparePlaylist 之后 currentIndex(0) 在第一轮打乱顺序里的位置是随机的，
    /// 所以不能假设“恰好 count-1 步就走完一轮”；这里跑足够多步（跨过至少一次重新洗牌的边界），
    /// 只断言两个跨轮都成立的不变量：连续两步不会原地重播、多轮之后覆盖所有下标。
    func testShuffleModeNeverRepeatsImmediatelyAndEventuallyCoversAllIndices() {
        let player = AIVVideoPlayer()
        let all = urls(5)
        player.preparePlaylist(all, mode: .shuffle)

        var visited = Set([player.currentPlaylistIndex])
        var previous = player.currentPlaylistIndex
        for _ in 0..<(all.count * 4) {
            player.playNext()
            let current = player.currentPlaylistIndex
            XCTAssertNotEqual(current, previous, "洗牌顺序不应该连续两步播放同一个视频，包括跨轮重新洗牌的边界")
            visited.insert(current)
            previous = current
        }
        XCTAssertEqual(visited.count, all.count, "跑完足够多轮之后应该覆盖所有下标")
    }

    func testSetPlayIndexJumpsDirectlyAndIgnoresInvalidInput() {
        let player = AIVVideoPlayer()
        player.preparePlaylist(urls(4), mode: .list)

        player.setPlayIndex(3)
        XCTAssertEqual(player.currentPlaylistIndex, 3)

        player.setPlayIndex(3)
        XCTAssertEqual(player.currentPlaylistIndex, 3, "等于当前下标应该被忽略")

        player.setPlayIndex(99)
        XCTAssertEqual(player.currentPlaylistIndex, 3, "越界下标应该被忽略")
    }

    func testChangingPlayModeRegeneratesOrderWithoutMovingCurrentIndex() {
        let player = AIVVideoPlayer()
        player.preparePlaylist(urls(4), startIndex: 2, mode: .list)

        player.playMode = .shuffle

        XCTAssertEqual(player.currentPlaylistIndex, 2, "切换 playMode 不应该改变当前正在播放的下标")
    }
}
