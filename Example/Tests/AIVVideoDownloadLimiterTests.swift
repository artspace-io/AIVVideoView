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
