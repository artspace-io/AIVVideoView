import Foundation

struct VideoItem {
    let id: String
    let title: String
    let category: String
    let url: URL
}

// MARK: - JSON 解析

struct VideoCategory: Decodable {
    let category: String
    let videos: [VideoJSON]
}

struct VideoJSON: Decodable {
    let title: String
    let url: String
}

extension VideoItem {
    static func loadAll() -> [VideoItem] {
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
        var result: [VideoItem] = []
        for cat in categories {
            for v in cat.videos {
                let id = "\(result.count + 1)"
                result.append(VideoItem(id: id, title: v.title, category: cat.category, url: URL(string: v.url)!))
            }
        }
        print("[VideoItem] ✅ loaded \(result.count) videos from \(categories.count) categories")
        if let first = result.first {
            print("[VideoItem]   first: \(first.title) — \(first.url)")
        }
        return result
    }
}
