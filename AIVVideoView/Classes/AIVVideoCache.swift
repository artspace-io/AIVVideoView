import Foundation
import CryptoKit

/// 基于磁盘的视频缓存管理器：按偏移量增量写入，支持边下边播、断点续存与 LRU 清理。
final class AIVVideoCache {
    static let shared = AIVVideoCache()

    struct Info {
        var contentLength: Int64 = 0
        var cachedLength: Int64 = 0
        var mimeType: String = ""
        var isComplete: Bool = false
    }

    /// 磁盘缓存总大小上限，超出后按最近访问时间淘汰已完整下载的视频
    var maxCacheSize: Int64 = 500 * 1024 * 1024

    private struct Meta: Codable {
        var contentLength: Int64 = 0
        var cachedLength: Int64 = 0
        var mimeType: String = ""
        var lastAccessedAt: TimeInterval = Date().timeIntervalSince1970
    }

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.aivvideocache.io")

    private var cacheDir: String {
        let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        return (paths.first! as NSString).appendingPathComponent("videos")
    }

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

    func filePath(for url: URL) -> String { path(hash: hash(for: url), ext: "mp4") }
    private func tmpPath(for url: URL) -> String { path(hash: hash(for: url), ext: "tmp") }
    private func metaPath(hash: String) -> String { path(hash: hash, ext: "meta") }
    private func metaPath(for url: URL) -> String { metaPath(hash: hash(for: url)) }

    // MARK: - Metadata

    private func readMeta(hash: String) -> Meta {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath(hash: hash))),
              let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return Meta() }
        return meta
    }

    private func writeMeta(_ meta: Meta, hash: String) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: URL(fileURLWithPath: metaPath(hash: hash)))
    }

    private func infoLocked(for url: URL) -> Info {
        let hash = hash(for: url)
        let complete = fileManager.fileExists(atPath: path(hash: hash, ext: "mp4"))
        var meta = readMeta(hash: hash)
        if complete, meta.contentLength == 0 {
            let size = (try? fileManager.attributesOfItem(atPath: path(hash: hash, ext: "mp4"))[.size] as? Int64) ?? 0
            meta.contentLength = size ?? 0
        }
        return Info(
            contentLength: meta.contentLength,
            cachedLength: complete ? meta.contentLength : meta.cachedLength,
            mimeType: meta.mimeType,
            isComplete: complete
        )
    }

    func info(for url: URL) -> Info {
        ioQueue.sync { infoLocked(for: url) }
    }

    func isCacheComplete(for url: URL) -> Bool { info(for: url).isComplete }
    func cachedLength(for url: URL) -> Int64 { info(for: url).cachedLength }
    func contentLength(for url: URL) -> Int64 { info(for: url).contentLength }

    func updateContentInfo(contentLength: Int64, mimeType: String, for url: URL) {
        ioQueue.sync {
            let hash = hash(for: url)
            guard !fileManager.fileExists(atPath: path(hash: hash, ext: "mp4")) else { return }
            var meta = readMeta(hash: hash)
            meta.contentLength = contentLength
            meta.mimeType = mimeType
            writeMeta(meta, hash: hash)
        }
    }

    // MARK: - Read / Write

    /// 将下载到的数据块写入指定偏移量，达到完整长度后自动落盘为最终缓存文件。
    @discardableResult
    func write(_ chunk: Data, at offset: Int64, for url: URL) -> Bool {
        ioQueue.sync {
            let hash = hash(for: url)
            guard !fileManager.fileExists(atPath: path(hash: hash, ext: "mp4")) else { return true }

            let tmp = path(hash: hash, ext: "tmp")
            if !fileManager.fileExists(atPath: tmp) {
                fileManager.createFile(atPath: tmp, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: tmp) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: chunk)
            } catch {
                return false
            }

            var meta = readMeta(hash: hash)
            meta.cachedLength = max(meta.cachedLength, offset + Int64(chunk.count))
            meta.lastAccessedAt = Date().timeIntervalSince1970
            writeMeta(meta, hash: hash)
            finalizeIfNeededLocked(url: url, hash: hash, meta: meta)
            return true
        }
    }

    /// 从缓存文件中读取任意偏移区间，无需将整段视频加载进内存。
    func read(offset: Int64, length: Int, for url: URL) -> Data? {
        ioQueue.sync {
            let hash = hash(for: url)
            let complete = fileManager.fileExists(atPath: path(hash: hash, ext: "mp4"))
            let source = path(hash: hash, ext: complete ? "mp4" : "tmp")
            guard let handle = FileHandle(forReadingAtPath: source) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: length)
                var meta = readMeta(hash: hash)
                meta.lastAccessedAt = Date().timeIntervalSince1970
                writeMeta(meta, hash: hash)
                return data
            } catch {
                return nil
            }
        }
    }

    private func finalizeIfNeededLocked(url: URL, hash: String, meta: Meta) {
        guard meta.contentLength > 0, meta.cachedLength >= meta.contentLength else { return }
        let tmp = path(hash: hash, ext: "tmp")
        let final = path(hash: hash, ext: "mp4")
        guard fileManager.fileExists(atPath: tmp) else { return }
        try? fileManager.removeItem(atPath: final)
        try? fileManager.moveItem(atPath: tmp, toPath: final)
        trimIfNeededLocked()
    }

    // MARK: - Cleanup

    func clear(for url: URL) {
        ioQueue.sync {
            let hash = hash(for: url)
            try? fileManager.removeItem(atPath: path(hash: hash, ext: "mp4"))
            try? fileManager.removeItem(atPath: path(hash: hash, ext: "tmp"))
            try? fileManager.removeItem(atPath: metaPath(hash: hash))
        }
    }

    func clearAll() {
        ioQueue.sync {
            try? fileManager.removeItem(atPath: cacheDir)
            try? fileManager.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        }
    }

    func totalCacheSize() -> Int64 {
        ioQueue.sync { totalCacheSizeLocked() }
    }

    private func totalCacheSizeLocked() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(atPath: cacheDir) else { return 0 }
        return files.filter { $0.hasSuffix(".mp4") }.reduce(Int64(0)) { total, name in
            let size = (try? fileManager.attributesOfItem(atPath: (cacheDir as NSString).appendingPathComponent(name))[.size] as? Int64) ?? 0
            return total + (size ?? 0)
        }
    }

    /// 按最近访问时间淘汰已完整下载的视频，直到总大小回落到上限以内。
    private func trimIfNeededLocked() {
        guard let files = try? fileManager.contentsOfDirectory(atPath: cacheDir) else { return }
        let mp4s = files.filter { $0.hasSuffix(".mp4") }

        var entries: [(path: String, hash: String, size: Int64, lastAccessedAt: TimeInterval)] = []
        var total: Int64 = 0
        for name in mp4s {
            let filePath = (cacheDir as NSString).appendingPathComponent(name)
            let size = (try? fileManager.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
            let hash = (name as NSString).deletingPathExtension
            entries.append((filePath, hash, size ?? 0, readMeta(hash: hash).lastAccessedAt))
            total += size ?? 0
        }
        guard total > maxCacheSize else { return }

        for entry in entries.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            guard total > maxCacheSize else { break }
            try? fileManager.removeItem(atPath: entry.path)
            try? fileManager.removeItem(atPath: metaPath(hash: entry.hash))
            total -= entry.size
        }
    }
}
