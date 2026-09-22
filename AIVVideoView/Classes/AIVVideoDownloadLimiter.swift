import Foundation

/// 限制同时进行的视频下载数量：列表快速滚动时，每个可见 cell 都会各自触发一次下载，
/// 如果不加限制，会同时创建大量 URLSessionDataTask（进而在代理回调、磁盘写入上
/// 产生大量并发线程/锁竞争）。这里用 actor 实现一个等待队列式的信号量，
/// 达到上限后 acquire() 挂起等待，release() 时把名额直接转交给下一个等待者
/// （而不是先减后加），避免"释放与新 acquire 抢跑"导致同时运行数短暂超过上限的竞态。
actor AIVVideoDownloadLimiter {
    static let shared = AIVVideoDownloadLimiter(maxConcurrent: 3)

    private var maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    /// 调整上限。调高时立刻把空出来的名额发给正在等待的任务，否则它们要一直等到
    /// 某个在跑的下载结束才能受益；调低时不打断已经在跑的，超出的部分随着它们
    /// 陆续 release 自然收敛回来。
    func setMaxConcurrent(_ value: Int) {
        let newValue = max(1, value)
        guard newValue != maxConcurrent else { return }
        maxConcurrent = newValue
        while running < maxConcurrent, !waiters.isEmpty {
            running += 1
            waiters.removeFirst().resume()
        }
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        // running > maxConcurrent 说明上限刚被调低、当前是超额运行状态，这时要把名额真正收回
        // 而不是转交给等待者，否则并发数永远降不下来。
        guard running <= maxConcurrent, !waiters.isEmpty else {
            running -= 1
            return
        }
        // 名额直接转交给下一个等待者，running 计数不变，避免中间出现"看似有空位"的竞态窗口。
        waiters.removeFirst().resume()
    }
}

extension AIVVideoPlayer {
    /// 同时进行的下载任务数上限，默认 3。
    ///
    /// 多路并发播放的场景（例如混音时同时播 4 路音频）需要调到路数以上，否则多出来的那几路
    /// 要排队等前面的下载让出名额才能开始缓冲，表现为迟迟不出声。反过来，视频列表类场景不建议
    /// 随意调大：每个可见 cell 都会各自触发下载，并发数一高就会在代理回调和磁盘写入上产生
    /// 明显的线程与锁竞争。
    ///
    /// 全局生效，进程内所有播放器共用这一个限流器。
    public static func setMaxConcurrentDownloads(_ count: Int) {
        Task { await AIVVideoDownloadLimiter.shared.setMaxConcurrent(count) }
    }
}
