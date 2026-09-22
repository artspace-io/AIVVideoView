import XCTest
@testable import AIVVideoView

final class AIVVideoDownloadLimiterTests: XCTestCase {
    /// 用独立实例而非 .shared，避免和别的测试/生产代码共享限流状态。
    func testAcquireGrantsImmediatelyUnderCapacityAndReleaseIsReusable() async {
        let limiter = AIVVideoDownloadLimiter(maxConcurrent: 2)
        await limiter.acquire()
        await limiter.acquire()
        // 两次 acquire 都应该立刻返回（不阻塞），能执行到这里就说明没有卡住。
        await limiter.release()
        await limiter.release()

        // 释放完之后应该能重新拿到许可，证明 release 没有把计数减出负数导致状态错乱。
        await limiter.acquire()
        await limiter.release()
    }

    /// 这是这次改动要保证的核心不变式：不管多少个下载同时发起，真正“在跑”的数量
    /// 永远不超过 maxConcurrent——之前 AIVVideoDownloadLimiter 被整体删除、又在
    /// AIVVideoView 包里重新实现，用这个测试钉住这个行为，防止未来又被静默删掉或改错。
    func testNeverExceedsMaxConcurrentUnderConcurrentLoad() async {
        let maxConcurrent = 3
        let limiter = AIVVideoDownloadLimiter(maxConcurrent: maxConcurrent)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.acquire()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await tracker.leave()
                    await limiter.release()
                }
            }
        }

        let maxObserved = await tracker.maxConcurrent
        XCTAssertLessThanOrEqual(maxObserved, maxConcurrent, "同时在跑的下载数不应该超过限流器的上限")
        XCTAssertEqual(maxObserved, maxConcurrent, "20 个任务抢 3 个名额，应该确实打满过上限并发，而不是被意外串行化")
    }
}

extension AIVVideoDownloadLimiterTests {
    /// 调高上限时必须立刻放行正在等待的任务。如果只是改了数字而不唤醒等待者，
    /// 它们要一直挂到某个在跑的下载结束才能受益——对"临时提高并发跑几路混音"
    /// 这种用法来说，等于配置没生效。
    func testRaisingMaxConcurrentWakesWaitersImmediately() async {
        let limiter = AIVVideoDownloadLimiter(maxConcurrent: 1)
        await limiter.acquire()

        let waiter = Task { await limiter.acquire() }
        // 给 waiter 一点时间真正挂起到等待队列里
        try? await Task.sleep(nanoseconds: 20_000_000)

        await limiter.setMaxConcurrent(3)

        // 不能直接 await waiter.value：真出问题时会永久挂起、拖死整个测试进程。
        // 用超时赛跑，超时就判失败。
        let wokenUp = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await waiter.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(wokenUp, "调高上限后，已经在等待的任务应该立刻拿到名额，而不是继续等")
    }

    /// 调低上限不打断已经在跑的任务，但超出的部分要随着 release 收回去，
    /// 不能被转交给等待者——否则并发数永远降不到新上限。
    func testLoweringMaxConcurrentConvergesInsteadOfHandingOff() async {
        let limiter = AIVVideoDownloadLimiter(maxConcurrent: 3)
        await limiter.acquire()
        await limiter.acquire()
        await limiter.acquire()

        await limiter.setMaxConcurrent(1)

        // 超额状态下连续释放两个，名额应该被真正收回而不是转交
        await limiter.release()
        await limiter.release()

        // 此时 running 应为 1，已经打满新上限；再 release 一次就该腾出位置
        await limiter.release()

        let acquired = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await limiter.acquire()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(acquired, "全部释放之后应该能按新上限重新拿到名额")
    }
}

private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var maxConcurrent = 0

    func enter() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func leave() {
        current -= 1
    }
}
