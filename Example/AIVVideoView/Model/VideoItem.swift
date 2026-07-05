import Foundation

struct VideoItem: Hashable {
    let id: String
    let title: String
    let category: String
    let url: URL
    let coverURL: URL
}

/// 首页每个主题分区对应的一组视频
struct VideoSection: Hashable {
    let category: String
    let videos: [VideoItem]
}

/// 首页 Hero 轮播的一张卡片：标题用分区名，副标题用该分区代表视频的标题
struct HeroItem: Hashable {
    let title: String
    let subtitle: String
    let videoURL: URL
    let coverURL: URL
}

// MARK: - JSON 解析

struct VideoCategory: Decodable {
    let category: String
    let videos: [VideoJSON]
}

struct VideoJSON: Decodable {
    let title: String
    let url: String
    let cover_url: String
}

extension VideoItem {
    /// 按分区分组加载，用于首页的主题分区列表
    static func loadSections() -> [VideoSection] {
        guard let url = Bundle.main.url(forResource: "videos", withExtension: "json") else {
            print("[VideoItem] ❌ videos.json not found in bundle")
            return []
        }
        guard let data = try? Data(contentsOf: url) else {
            print("[VideoItem] ❌ failed to read data from \(url)")
            return []
        }
        guard let categories = try? JSONDecoder().decode([VideoCategory].self, from: data) else {
            print("[VideoItem] ❌ JSON decode failed, data size: \(data.count) bytes")
            return []
        }

        var sections: [VideoSection] = []
        var runningCount = 0
        for cat in categories {
            let videos: [VideoItem] = cat.videos.map { v in
                runningCount += 1
                return VideoItem(id: "\(runningCount)", title: v.title, category: cat.category, url: URL(string: v.url)!, coverURL: URL(string: v.cover_url)!)
            }
            sections.append(VideoSection(category: cat.category, videos: videos))
        }
        print("[VideoItem] ✅ loaded \(runningCount) videos from \(sections.count) categories")
        return sections
    }

    /// 拍平成单个列表，用于视频网格 feed
    static func loadAll() -> [VideoItem] {
        loadSections().flatMap(\.videos)
    }
}

extension HeroItem {
    /// 取每个分区的第一条视频作为该分区的 Hero 代表卡片
    static func loadAll(from sections: [VideoSection], limit: Int = 5) -> [HeroItem] {
        sections.prefix(limit).compactMap { section in
            guard let first = section.videos.first else { return nil }
            return HeroItem(title: section.category, subtitle: first.title, videoURL: first.url, coverURL: first.coverURL)
        }
    }
}
