import Foundation
import AVFoundation

public enum AIVVideoPlayerStatus: Equatable, Sendable {
    case idle
    case preparing
    case readyToPlay
    case playing
    case paused
    case buffering
    case seeking
    case ended
    case failed
}

public enum AIVVideoPlayerError: LocalizedError, Equatable, Sendable {
    case resourceLoaderFailed
    case playbackFailed
    case cacheFailed
    case invalidURL
    case unknown

    public var errorDescription: String? {
        switch self {
        case .resourceLoaderFailed: return "资源加载失败"
        case .playbackFailed: return "播放失败"
        case .cacheFailed: return "缓存失败"
        case .invalidURL: return "无效的 URL"
        case .unknown: return "未知错误"
        }
    }
}
