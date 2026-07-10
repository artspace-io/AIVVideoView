import Foundation
import CryptoKit

/// 基于磁盘的视频缓存管理器：按偏移量增量写入，支持边下边播、断点续存与 LRU 清理。
public final class AIVVideoCache {
    public static let shared = AIVVideoCache()

    public struct Info {
        public var contentLength: Int64 = 0
        public var cachedLength: Int64 = 0
        public var mimeType: String = ""
        public var isComplete: Bool = false
    }

    /// 磁盘缓存总大小上限，超出后按最近访问时间淘汰已完整下载的视频
    public var maxCacheSize: Int64 = 500 * 1024 * 1024

    private struct Meta: Codable {
        var contentLength: Int64 = 0
        var cachedLength: Int64 = 0
        var mimeType: String = ""
        var lastAccessedAt: TimeInterval = Date().timeIntervalSince1970
    }

    /// 每个视频（按 hash）独立的状态：锁 + 内存态 meta + 复用的文件句柄。
    /// 所有字段只在持有 lock 期间被读写，天然线程安全，不需要额外加锁保护字段本身。
    private final class HashState {
        let lock = NSLock()
        /// 内存里的权威状态；磁盘上的 .meta 文件只是用来跨进程重启恢复断点续传进度，
        /// 运行期间的读写都直接走这份内存态，不用每次都读盘。
        var meta: Meta?
        var isComplete = false
        var readHandle: FileHandle?
        var writeHandle: FileHandle?
        /// 上一次把 meta 落盘的时间，用来节流高频写入（见 persistMeta）
        var lastPersistedAt: TimeInterval = 0

        /// 已写入区间的合并列表，只在内存里维护，用来算出"从 0 开始连续覆盖到哪"这个
        /// 真正的 cachedLength。不能像原来那样直接用 max(cachedLength, offset+length)：
        /// 那等于"目前为止见过的最远 offset"，一旦分片乱序/并发到达（比如最后一个分片
        /// 先落盘），会让 cachedLength 直接跳到 contentLength，误判成"全部写完"提前
        /// finalize、rename 成最终文件；而真正还没写的低 offset 分片后续到达时，
        /// write() 顶部"文件已经是完整态，直接 no-op"的短路会让它们被无声丢弃——最终
        /// 文件长度是对的，内容却是错的（缺的地方是 sparse file 补的 0）。
        /// 真实下载场景永远是从 downloadedLength 严格顺序写入，这里只是让并发/乱序场景
        /// 下这个不变式也严格成立，不需要跨进程重启持久化（重启后断点续传本来就是从磁盘上
        /// 的 cachedLength 继续顺序写）。
        var writtenRanges: [Range<Int64>] = []

        func closeHandles() {
            try? writeHandle?.close()
            try? readHandle?.close()
            writeHandle = nil
            readHandle = nil
        }

        /// 插入一段新写入的区间并与已有区间合并排序，返回合并后"从 0 开始连续覆盖到"的
        /// 长度；如果 0 这个起点还没被任何区间覆盖到，返回 0。
        @discardableResult
        func recordWritten(_ range: Range<Int64>) -> Int64 {
            var ranges = writtenRanges
            ranges.append(range)
            ranges.sort { $0.lowerBound < $1.lowerBound }

            var merged: [Range<Int64>] = []
            for r in ranges {
                if let last = merged.last, r.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                } else {
                    merged.append(r)
                }
            }
            writtenRanges = merged
            guard let first = merged.first, first.lowerBound == 0 else { return 0 }
            return first.upperBound
        }
    }

    /// 用一条并发队列统一收纳所有请求：不同视频之间的读写可以真正并行执行，互不阻塞；
    /// 只有 clearAll() 这种要清空整个缓存目录的操作才用 barrier 换取一次性的全局互斥。
    /// 同一个视频内部的互斥，由下面每个 HashState 自带的锁保证——原来是一整条全局串行队列，
    /// 任意两个视频的缓存读写都要排队，哪怕彼此毫无关系（比如列表在后台缓存 A 的同时，
    /// 详情页只是想问一句"B 是否已经缓存完成"，也会被 A 的写入卡住）。
    private let queue = DispatchQueue(label: "com.aivvideocache.io", attributes: .concurrent)

    private var hashStates: [String: HashState] = [:]
    private let registryLock = NSLock()

    private let fileManager = FileManager.default

    /// meta 落盘的节流间隔：内存态 (HashState.meta) 永远是最新的，只有真正写到磁盘这一步
    /// 按时间节流。代价仅仅是"进程被杀时最多丢这么久的断点续传进度"，不影响运行期间任何
    /// 能读到的状态（cachedLength/lastAccessedAt 等一律直接读内存）。
    /// 之前 write() 每收到一个下载分片就无条件 readMeta+writeMeta（JSON 编解码 + 整个
    /// .meta 文件覆盖写一次），大文件按小 chunk 下载时是几百次没必要的磁盘落盘。
    private let metaPersistInterval: TimeInterval = 2

    private lazy var cacheDir: String = {
        let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        return (paths.first! as NSString).appendingPathComponent("videos")
    }()

    private init() {
        try? fileManager.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    private func hash(for url: URL) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func path(hash: String, ext: String) -> String {
        (cacheDir as NSString).appendingPathComponent(hash + "." + ext)
    }

    public func filePath(for url: URL) -> String { path(hash: hash(for: url), ext: "mp4") }
    private func metaPath(hash: String) -> String { path(hash: hash, ext: "meta") }

    // MARK: - Per-hash state

    private func state(for hash: String) -> HashState {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = hashStates[hash] { return existing }
        let created = HashState()
        hashStates[hash] = created
        return created
    }

    /// 拿到某个视频专属的状态后加锁执行；不同 hash 之间靠并发队列真正并行，
    /// 同一个 hash 内部靠 HashState.lock 序列化，语义上等价于原来的单条全局串行队列，
    /// 但粒度收窄到了"每个视频"而不是"全局"。
    @discardableResult
    private func withState<T>(for url: URL, _ body: (HashState, String) -> T) -> T {
        let hash = hash(for: url)
        let s = state(for: hash)
        return queue.sync {
            s.lock.lock()
            defer { s.lock.unlock() }
            return body(s, hash)
        }
    }

    // MARK: - Metadata

    /// 第一次访问某个视频时从磁盘加载 meta（比如进程重启后恢复断点续传进度），
    /// 之后同一个 HashState 生命周期内都直接用内存态，不再重复读盘。
    private func loadMetaIfNeeded(_ state: HashState, hash: String) -> Meta {
        if let meta = state.meta { return meta }
        let meta = readMetaFromDisk(hash: hash)
        // 把上一次进程持久化下来的 cachedLength 预置成"已经确认从 0 连续写到这里"的区间，
        // 这样断点续传恢复后第一个从 cachedLength 位置续写的分片才能正确地和它合并、继续
        // 往后延伸，而不是被当成一段孤立于 0 之外的区间、白白损失掉之前所有进度的记录。
        if meta.cachedLength > 0 {
            state.writtenRanges = [0..<meta.cachedLength]
        }
        state.meta = meta
        return meta
    }

    private func readMetaFromDisk(hash: String) -> Meta {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath(hash: hash))),
              let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return Meta() }
        return meta
    }

    /// force = true 用于必须立刻落盘的时机（拿到 contentLength、下载刚完成、clear 之外的
    /// 其它一次性事件）；其余高频场景（每个 chunk 写入、每次 read）按 metaPersistInterval 节流。
    private func persistMeta(_ state: HashState, hash: String, force: Bool) {
        guard let meta = state.meta else { return }
        let now = Date().timeIntervalSince1970
        guard force || now - state.lastPersistedAt >= metaPersistInterval else { return }
        state.lastPersistedAt = now
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: URL(fileURLWithPath: metaPath(hash: hash)))
    }

    private func infoLocked(_ state: HashState, hash: String) -> Info {
        if !state.isComplete, fileManager.fileExists(atPath: path(hash: hash, ext: "mp4")) {
            state.isComplete = true
        }
        var meta = loadMetaIfNeeded(state, hash: hash)
        if state.isComplete, meta.contentLength == 0 {
            let size = (try? fileManager.attributesOfItem(atPath: path(hash: hash, ext: "mp4"))[.size] as? Int64) ?? 0
            meta.contentLength = size
            state.meta = meta
        }
        return Info(
            contentLength: meta.contentLength,
            cachedLength: state.isComplete ? meta.contentLength : meta.cachedLength,
            mimeType: meta.mimeType,
            isComplete: state.isComplete
        )
    }

    public func info(for url: URL) -> Info {
        withState(for: url) { state, hash in infoLocked(state, hash: hash) }
    }

    public func isCacheComplete(for url: URL) -> Bool { info(for: url).isComplete }
    func cachedLength(for url: URL) -> Int64 { info(for: url).cachedLength }
    func contentLength(for url: URL) -> Int64 { info(for: url).contentLength }

    func updateContentInfo(contentLength: Int64, mimeType: String, for url: URL) {
        withState(for: url) { state, hash in
            guard !state.isComplete, !fileManager.fileExists(atPath: path(hash: hash, ext: "mp4")) else { return }
            var meta = loadMetaIfNeeded(state, hash: hash)
            meta.contentLength = contentLength
            meta.mimeType = mimeType
            state.meta = meta
            persistMeta(state, hash: hash, force: true)
        }
    }

    // MARK: - Read / Write

    /// 将下载到的数据块写入指定偏移量，达到完整长度后自动落盘为最终缓存文件。
    @discardableResult
    func write(_ chunk: Data, at offset: Int64, for url: URL) -> Bool {
        withState(for: url) { state, hash in
            if !state.isComplete, fileManager.fileExists(atPath: path(hash: hash, ext: "mp4")) {
                state.isComplete = true
            }
            guard !state.isComplete else { return true }

            let tmp = path(hash: hash, ext: "tmp")
            if state.writeHandle == nil {
                if !fileManager.fileExists(atPath: tmp) {
                    fileManager.createFile(atPath: tmp, contents: nil)
                }
                state.writeHandle = FileHandle(forWritingAtPath: tmp)
            }
            guard let handle = state.writeHandle else { return false }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: chunk)
            } catch {
                return false
            }

            var meta = loadMetaIfNeeded(state, hash: hash)
            let contiguousLength = state.recordWritten(offset..<(offset + Int64(chunk.count)))
            meta.cachedLength = max(meta.cachedLength, contiguousLength)
            meta.lastAccessedAt = Date().timeIntervalSince1970
            state.meta = meta
            persistMeta(state, hash: hash, force: false)
            finalizeIfNeeded(state, hash: hash, meta: meta)
            return true
        }
    }

    /// 从缓存文件中读取任意偏移区间，无需将整段视频加载进内存。
    func read(offset: Int64, length: Int, for url: URL) -> Data? {
        withState(for: url) { state, hash in
            if !state.isComplete, fileManager.fileExists(atPath: path(hash: hash, ext: "mp4")) {
                state.isComplete = true
                // 文件已经从 .tmp 变成了 .mp4（完整态），之前如果开着指向 .tmp 的读句柄，
                // 换掉重开一个指向最终文件的句柄，避免继续读一个可能已经不存在的路径。
                try? state.readHandle?.close()
                state.readHandle = nil
            }

            if state.readHandle == nil {
                let source = path(hash: hash, ext: state.isComplete ? "mp4" : "tmp")
                state.readHandle = FileHandle(forReadingAtPath: source)
            }
            guard let handle = state.readHandle else { return nil }
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: length)
                var meta = loadMetaIfNeeded(state, hash: hash)
                meta.lastAccessedAt = Date().timeIntervalSince1970
                state.meta = meta
                persistMeta(state, hash: hash, force: false)
                return data
            } catch {
                return nil
            }
        }
    }

    private func finalizeIfNeeded(_ state: HashState, hash: String, meta: Meta) {
        guard meta.contentLength > 0, meta.cachedLength >= meta.contentLength else { return }
        let tmp = path(hash: hash, ext: "tmp")
        let final = path(hash: hash, ext: "mp4")
        guard fileManager.fileExists(atPath: tmp) else { return }

        state.closeHandles()
        try? fileManager.removeItem(atPath: final)
        try? fileManager.moveItem(atPath: tmp, toPath: final)
        state.isComplete = true
        persistMeta(state, hash: hash, force: true)
        trimIfNeeded(excludingCurrent: hash)
    }

    // MARK: - Cleanup

    public func clear(for url: URL) {
        withState(for: url) { state, hash in
            state.closeHandles()
            state.meta = nil
            state.isComplete = false
            state.writtenRanges = []
            try? fileManager.removeItem(atPath: path(hash: hash, ext: "mp4"))
            try? fileManager.removeItem(atPath: path(hash: hash, ext: "tmp"))
            try? fileManager.removeItem(atPath: metaPath(hash: hash))
        }
    }

    public func clearAll() {
        // barrier 会等所有已经在跑的 read/write/info 先跑完，并且挡住新的请求进来，
        // 直到这个 block 结束——保证清空整个目录期间不会有任何并发读写踩坑。
        queue.sync(flags: .barrier) {
            registryLock.lock()
            let states = hashStates
            hashStates.removeAll()
            registryLock.unlock()

            states.values.forEach { $0.closeHandles() }
            try? fileManager.removeItem(atPath: cacheDir)
            try? fileManager.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        }
    }

    public func totalCacheSize() -> Int64 {
        queue.sync { totalCacheSizeLocked() }
    }

    private func totalCacheSizeLocked() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(atPath: cacheDir) else { return 0 }
        return files.filter { $0.hasSuffix(".mp4") }.reduce(Int64(0)) { total, name in
            let size = (try? fileManager.attributesOfItem(atPath: (cacheDir as NSString).appendingPathComponent(name))[.size] as? Int64) ?? 0
            return total + size
        }
    }

    /// 按最近访问时间淘汰已完整下载的视频，直到总大小回落到上限以内。
    /// 调用方（finalizeIfNeeded）已经持有 currentHash 这个视频自己的锁，
    /// 所以这里把它排除在候选之外——不重入自己的锁（NSLock 非递归，重入会死锁），
    /// 顺带也避免了"刚下载完就把自己淘汰掉"这种糟糕体验；其余候选逐个按需加锁淘汰，
    /// 不需要拿全局 barrier，不影响其它视频此刻的并发读写。
    private func trimIfNeeded(excludingCurrent currentHash: String) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: cacheDir) else { return }
        let mp4s = files.filter { $0.hasSuffix(".mp4") }

        var total: Int64 = 0
        var candidates: [(hash: String, path: String, size: Int64, lastAccessedAt: TimeInterval)] = []
        for name in mp4s {
            let filePath = (cacheDir as NSString).appendingPathComponent(name)
            let size = (try? fileManager.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
            total += size
            let candidateHash = (name as NSString).deletingPathExtension
            guard candidateHash != currentHash else { continue }
            candidates.append((candidateHash, filePath, size, readMetaFromDisk(hash: candidateHash).lastAccessedAt))
        }
        guard total > maxCacheSize else { return }

        for entry in candidates.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            guard total > maxCacheSize else { break }
            evict(hash: entry.hash, path: entry.path)
            total -= entry.size
        }
    }

    private func evict(hash: String, path: String) {
        let s = state(for: hash)
        s.lock.lock()
        defer { s.lock.unlock() }
        // 状态重置和实际删文件必须在同一把锁里做完：如果提前解锁，删除文件那两行还没
        // 跑完时，万一另一个线程正好为同一个 hash 发起了新一轮下载（state 已经被重置成
        // "干净"，会认为可以直接创建新文件），这里滞后的 removeItem 有极小概率把它刚
        // 写好的新文件也删掉。
        s.closeHandles()
        s.meta = nil
        s.isComplete = false
        s.writtenRanges = []
        try? fileManager.removeItem(atPath: path)
        try? fileManager.removeItem(atPath: metaPath(hash: hash))
    }
}
