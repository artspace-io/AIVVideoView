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

public enum AIVVideoPlayMode: Equatable, Sendable {
    /// 列表播放：按顺序播放，最后一个播放完停止，并触发 onPlaylistCompleted 回调
    case list
    /// 顺序循环播放：播完最后一个后回到第一个继续播放
    case circle
    /// 随机循环播放：每次播完随机切到列表中的另一个视频
    case shuffle
    /// 单个视频循环播放：忽略列表其余部分，反复播放当前视频
    case single
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
