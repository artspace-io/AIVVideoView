import Foundation

/// 限制同时进行的视频下载数量：列表快速滚动时，每个可见 cell 都会各自触发一次下载，
/// 如果不加限制，会同时创建大量 URLSessionDataTask（进而在代理回调、磁盘写入上
/// 产生大量并发线程/锁竞争）。这里用 actor 实现一个等待队列式的信号量，
/// 达到上限后 acquire() 挂起等待，release() 时把名额直接转交给下一个等待者
/// （而不是先减后加），避免"释放与新 acquire 抢跑"导致同时运行数短暂超过上限的竞态。
actor AIVVideoDownloadLimiter {
    static let shared = AIVVideoDownloadLimiter(maxConcurrent: 3)

    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            running -= 1
            return
        }
        // 名额直接转交给下一个等待者，running 计数不变，避免中间出现"看似有空位"的竞态窗口。
        waiters.removeFirst().resume()
    }
}
