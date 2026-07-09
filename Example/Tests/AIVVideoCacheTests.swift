import XCTest
@testable import AIVVideoView

/// AIVVideoCache 是读写真实磁盘（系统 Caches 目录）的单例，没有可注入的存储层。
/// 用每个用例专属的哑 URL（.invalid 域名 + UUID）隔离，tearDown 里按 URL clear，
/// 避免用例之间通过共享的磁盘文件互相污染。
final class AIVVideoCacheTests: XCTestCase {
    private let cache = AIVVideoCache.shared
    private var testURLs: [URL] = []
    private var originalMaxCacheSize: Int64 = 0

    override func setUp() {
        super.setUp()
        originalMaxCacheSize = cache.maxCacheSize
    }

    override func tearDown() {
        for url in testURLs {
            cache.clear(for: url)
        }
        testURLs = []
        cache.maxCacheSize = originalMaxCacheSize
        super.tearDown()
    }

    private func makeURL(_ tag: String = "") -> URL {
        let url = URL(string: "https://cache-test.invalid/\(tag)-\(UUID().uuidString).mp4")!
        testURLs.append(url)
        return url
    }

    func testWriteThenReadRoundTrip() {
        let url = makeURL()
        let payload = Data("hello cache".utf8)

        XCTAssertTrue(cache.write(payload, at: 0, for: url))
        XCTAssertEqual(cache.read(offset: 0, length: payload.count, for: url), payload)
    }

    func testReadRespectsOffsetAndLength() {
        let url = makeURL()
        cache.write(Data("0123456789".utf8), at: 0, for: url)

        XCTAssertEqual(cache.read(offset: 3, length: 4, for: url), Data("3456".utf8))
    }

    func testReadForNeverWrittenURLReturnsNil() {
        let url = makeURL()

        XCTAssertNil(cache.read(offset: 0, length: 4, for: url), "从没写过的 URL 对应的缓存文件都不存在，应该返回 nil 而不是崩溃")
    }

    func testCachedLengthAccumulatesAcrossWritesByOffsetNotByLastChunk() {
        let url = makeURL()
        cache.write(Data(repeating: 0xAA, count: 10), at: 0, for: url)
        XCTAssertEqual(cache.cachedLength(for: url), 10)

        cache.write(Data(repeating: 0xBB, count: 5), at: 10, for: url)
        XCTAssertEqual(cache.cachedLength(for: url), 15, "断点续传应该按“已经覆盖到的最远偏移”累加，不是取最后一次写入的字节数")
    }

    func testBecomesCompleteAndFinalizesOnceCachedLengthReachesContentLength() {
        let url = makeURL()
        let payload = Data(repeating: 0x42, count: 20)
        cache.updateContentInfo(contentLength: Int64(payload.count), mimeType: "video/mp4", for: url)
        XCTAssertFalse(cache.isCacheComplete(for: url), "只设置了 contentLength，还没写够数据，不应该被判定为完整")

        cache.write(payload, at: 0, for: url)

        XCTAssertTrue(cache.isCacheComplete(for: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.filePath(for: url)), "写满 contentLength 后应该自动落盘成最终的 .mp4 文件")
        XCTAssertEqual(cache.read(offset: 0, length: payload.count, for: url), payload)
    }

    func testWriteAfterCompleteIsNoOpAndDoesNotCorruptFinalFile() {
        let url = makeURL()
        let payload = Data(repeating: 0x1, count: 8)
        cache.updateContentInfo(contentLength: Int64(payload.count), mimeType: "video/mp4", for: url)
        cache.write(payload, at: 0, for: url)
        XCTAssertTrue(cache.isCacheComplete(for: url))

        let ok = cache.write(Data(repeating: 0xFF, count: 8), at: 0, for: url)

        XCTAssertTrue(ok, "已经完成的缓存再次 write 应该直接返回 true（no-op），不是失败")
        XCTAssertEqual(cache.read(offset: 0, length: payload.count, for: url), payload, "已经落盘的最终文件不应该被后续 write 覆盖")
    }

    func testUpdateContentInfoIgnoredOnceFileIsComplete() {
        let url = makeURL()
        let payload = Data(repeating: 0x7, count: 4)
        cache.updateContentInfo(contentLength: Int64(payload.count), mimeType: "video/mp4", for: url)
        cache.write(payload, at: 0, for: url)
        XCTAssertTrue(cache.isCacheComplete(for: url))

        cache.updateContentInfo(contentLength: 999, mimeType: "text/plain", for: url)

        XCTAssertEqual(cache.contentLength(for: url), Int64(payload.count), "已经完成的缓存不应该再被 updateContentInfo 覆盖元数据")
    }

    func testClearRemovesAllTracesAndResetsInfo() {
        let url = makeURL()
        let payload = Data(repeating: 0x9, count: 4)
        cache.updateContentInfo(contentLength: Int64(payload.count), mimeType: "video/mp4", for: url)
        cache.write(payload, at: 0, for: url)
        XCTAssertTrue(cache.isCacheComplete(for: url))

        cache.clear(for: url)

        let info = cache.info(for: url)
        XCTAssertFalse(info.isComplete)
        XCTAssertEqual(info.contentLength, 0)
        XCTAssertEqual(info.cachedLength, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.filePath(for: url)))
    }

    /// 模拟边下边播时，下载线程不断 write() 新分片，播放线程同时 read() 已有数据，
    /// 都会命中同一个 url 对应的 ioQueue.sync —— 这里验证串行化本身没被破坏：
    /// 不会崩溃、不会死锁，且所有分片写完后最终内容完全正确。
    func testConcurrentWritesAndReadsDoNotCrashAndConvergeToCorrectContent() {
        let url = makeURL()
        let chunkSize = 16
        let chunkCount = 50
        let full = (0..<chunkCount).reduce(into: Data()) { data, i in
            data.append(Data(repeating: UInt8(i % 256), count: chunkSize))
        }
        cache.updateContentInfo(contentLength: Int64(full.count), mimeType: "video/mp4", for: url)

        let group = DispatchGroup()
        for i in 0..<chunkCount {
            group.enter()
            DispatchQueue.global().async {
                let chunk = full.subdata(in: (i * chunkSize)..<((i + 1) * chunkSize))
                self.cache.write(chunk, at: Int64(i * chunkSize), for: url)
                _ = self.cache.read(offset: 0, length: chunkSize, for: url)
                group.leave()
            }
        }
        let waitResult = group.wait(timeout: .now() + 10)

        XCTAssertEqual(waitResult, .success, "并发读写不应该卡死或超时")
        XCTAssertTrue(cache.isCacheComplete(for: url))
        XCTAssertEqual(cache.read(offset: 0, length: full.count, for: url), full, "所有分片并发写完后，最终内容应该和预期完全一致，不能因为竞争而丢块/错位")
    }

    func testTrimEvictsLeastRecentlyAccessedCompleteEntryWhenOverBudget() {
        cache.clearAll()

        let urlA = makeURL("A")
        let urlB = makeURL("B")
        let urlC = makeURL("C")
        let payload = Data(repeating: 0x5, count: 1024)

        func finish(_ url: URL) {
            cache.updateContentInfo(contentLength: Int64(payload.count), mimeType: "video/mp4", for: url)
            cache.write(payload, at: 0, for: url)
        }

        finish(urlA)
        Thread.sleep(forTimeInterval: 0.02)
        finish(urlB)

        // 上限只够放 2 个文件；写第 3 个触发 finalize -> trim 时应该淘汰 lastAccessedAt 最早的 A，
        // 保留更晚被访问的 B 和刚写完的 C。
        cache.maxCacheSize = Int64(Double(payload.count) * 2.5)
        Thread.sleep(forTimeInterval: 0.02)
        finish(urlC)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.filePath(for: urlA)), "超出容量上限时应该优先淘汰最久没被访问的完整文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.filePath(for: urlB)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.filePath(for: urlC)))
    }
}
