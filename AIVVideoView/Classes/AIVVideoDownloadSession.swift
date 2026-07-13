import Foundation

/// 所有 AIVVideoDownloadTask 共用同一个 URLSession，而不是每个任务各自
/// `URLSession(delegate:self, delegateQueue: nil)`——那样每个任务都会让系统
/// 单独开一条私有线程处理代理回调，列表滚动时并发下载一多，线程数会跟着线性增长
/// （Time Profiler 里实测能看到几十条常驻线程）。这里把代理回调统一收敛到一条
/// 并发数受限的 OperationQueue 上，httpMaximumConnectionsPerHost 之类的连接层
/// 限制也因此变成全局生效，而不是每个 session 各算各的。
final class AIVVideoDownloadSession: NSObject {
    static let shared = AIVVideoDownloadSession()

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.aiv.videodownload.delegate"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    private var session: URLSession!
    private let lock = NSLock()
    private var owners: [Int: AIVVideoDownloadTask] = [:]

    override init() {
        super.init()
        session = URLSession(configuration: AIVVideoDownloadTask.sessionConfigurationProvider(), delegate: self, delegateQueue: delegateQueue)
    }

    /// 仅供测试使用：sessionConfigurationProvider 换成桩协议后，需要重建底层 session
    /// 新配置才会生效（URLSession 的 configuration 在创建后不可变）。生产环境不会调用。
    func reload() {
        lock.lock()
        owners.removeAll()
        lock.unlock()
        session.invalidateAndCancel()
        session = URLSession(configuration: AIVVideoDownloadTask.sessionConfigurationProvider(), delegate: self, delegateQueue: delegateQueue)
    }

    func makeDataTask(for request: URLRequest, owner: AIVVideoDownloadTask) -> URLSessionDataTask {
        let dataTask = session.dataTask(with: request)
        lock.lock()
        owners[dataTask.taskIdentifier] = owner
        lock.unlock()
        return dataTask
    }

    private func owner(for task: URLSessionTask) -> AIVVideoDownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return owners[task.taskIdentifier]
    }

    private func removeOwner(for task: URLSessionTask) {
        lock.lock()
        owners.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}

extension AIVVideoDownloadSession: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let owner = owner(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        owner.handleReceive(response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(for: dataTask)?.handleReceive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskOwner = owner(for: task)
        removeOwner(for: task)
        taskOwner?.handleComplete(error: error)
    }
}
