import Foundation

/// 封装单个 cell 的播放器生命周期：向 AIVVideoPlayerCoordinator 申请/释放播放名额、
/// 创建/持有 AIVVideoPlayer、监听首帧就绪。宿主 cell 只需要提供视频 URL 和封面淡入淡出的回调，
/// 不用重复写"申请名额 -> 建播放器 -> 监听首帧 -> 播放 / 失去名额 -> 释放"这一整套逻辑。
///
/// 两种典型驱动方式：
/// - 连续可见比例（网格 feed、横向卡片列表）：`updateVisibility(ratio:minimumRatio:urlProvider:)`
/// - 二元判断（分页轮播，同一时刻只有一页是当前页）：`setActive(_:urlProvider:)`
@MainActor
public final class AIVCellPlaybackController {
    public let playerView = AIVVideoPlayerView()

    /// 播放器首帧真正渲染出来的时机，宿主 cell 用来淡出自己的封面图
    public var onFirstFrameReady: (() -> Void)?

    /// 名额被释放/播放器被拆掉的时机（不管是主动让出还是被别的 cell 挤占），宿主 cell 用来恢复封面图
    public var onDeactivated: (() -> Void)?

    /// 默认拿到播放器就直接 play()；如果宿主需要特殊的启动方式（比如 VideoFeedCell 判断
    /// isCachingSuspended 后走 becomeActive），可以通过这个闭包接管
    public var startPlayback: ((AIVVideoPlayer) -> Void)?

    /// 申请到名额、创建播放器时使用的播放模式，宿主可以在 updateVisibility/setActive 之前设置。
    /// 默认 .single（循环播放当前这一个视频），适合列表 feed 场景
    public var playMode: AIVVideoPlayMode = .single

    private var player: AIVVideoPlayer?
    /// 当前播放器实际加载的地址，用来识别"view 被复用了，但还挂着别的内容的播放器"这种情况
    private var currentURL: URL?
    private var readyForDisplayObservation: NSKeyValueObservation?

    public init() {}

    /// ratio 是当前可见面积占自身总面积的比例（0...1）；低于 minimumRatio 就释放，
    /// 达到了但还没有播放器就去协调器抢名额，已经有播放器就只更新比例供后续仲裁参考
    public func updateVisibility(ratio: CGFloat, minimumRatio: CGFloat, urlProvider: () -> URL?) {
        guard ratio >= minimumRatio else {
            deactivate()
            return
        }

        let requestedURL = urlProvider()
        if player != nil {
            guard requestedURL != currentURL else {
                AIVVideoPlayerCoordinator.shared.updateVisibleRatio(ratio, for: self)
                return
            }
            // 走到这说明宿主 view 被复用来展示别的内容了（比如 iCarousel 这类不会调用
            // prepareForReuse 的场景），但手上的播放器还是旧内容的，URL 对不上，必须先释放
            // 名额再重新申请，否则新内容永远没机会真正播放。
            deactivate()
        }

        guard let url = requestedURL else { return }
        requestSlotAndPlay(url: url, ratio: ratio)
    }

    /// active 为 true 时立刻申请名额播放；false 时立刻释放。用于分页轮播这类二元场景
    public func setActive(_ active: Bool, urlProvider: () -> URL?) {
        guard active else {
            deactivate()
            return
        }

        let requestedURL = urlProvider()
        if player != nil {
            guard requestedURL != currentURL else { return }
            deactivate()
        }

        guard let url = requestedURL else { return }
        requestSlotAndPlay(url: url, ratio: 1)
    }

    /// 完全离开可见范围（滑出屏幕、cell 被复用）时调用
    public func deactivate() {
        onDeactivated?()
        readyForDisplayObservation = nil
        currentURL = nil
        guard let player else { return }
        player.resignActive(stopPlayback: true)
        playerView.player = nil
        self.player = nil
        AIVVideoPlayerCoordinator.shared.releaseSlot(for: self)
    }

    private func requestSlotAndPlay(url: URL, ratio: CGFloat) {
        let granted = AIVVideoPlayerCoordinator.shared.requestSlot(for: self, visibleRatio: ratio) { [weak self] in
            self?.deactivate()
        }
        guard granted else { return }

        let newPlayer = AIVVideoPlayer(url: url)
        newPlayer.playMode = playMode
        newPlayer.isMuted = true
        player = newPlayer
        currentURL = url
        playerView.player = newPlayer

        readyForDisplayObservation = playerView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                self?.onFirstFrameReady?()
            }
        }

        if let startPlayback {
            startPlayback(newPlayer)
        } else {
            newPlayer.play()
        }
    }
}
