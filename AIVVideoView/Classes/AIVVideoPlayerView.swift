import UIKit
import AVFoundation
import Combine

public final class AIVVideoPlayerView: UIView {
    /// 把所有会引起隐式动画的 key 都映射成 NSNull()，用来关掉 AVPlayerLayer 以及它内部
    /// content sublayer 的默认动画。
    ///
    /// 背景：真正渲染视频画面的不是这个 view 的 backing layer 本身，而是 AVPlayerLayer 内部
    /// 自建的 content sublayer——它不是任何 UIView 的 backing layer，delegate 为 nil，所以走的是
    /// CALayer 的默认 action，UIKit 给 backing layer 做的"关隐式动画"保护对它无效。首帧解码完成、
    /// presentationSize 从 .zero 变成视频真实尺寸的那一刻，AVFoundation 会按 videoGravity 重新
    /// 布局这一层，bounds/transform 的变化带上默认 0.25s 隐式动画，宿主看到的就是"视频从大缩到
    /// 容器大小"。
    private static let disabledActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "transform": NSNull(),
        "sublayerTransform": NSNull(),
        "contents": NSNull(),
        "contentsRect": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "onOrderIn": NSNull(),
        "onOrderOut": NSNull()
    ]

    public weak var player: AIVVideoPlayer? {
        didSet {
            gravitySubscription = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let player {
                playerLayer.player = player.player
                playerLayer.videoGravity = player.videoGravity
                playerLayer.isHidden = false
                disableImplicitAnimations()
                gravitySubscription = player.$videoGravity
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] gravity in
                        self?.playerLayer.videoGravity = gravity
                    }
            } else {
                playerLayer.player = nil
                playerLayer.isHidden = true
            }
            CATransaction.commit()
        }
    }

    private var gravitySubscription: AnyCancellable?

    public var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    public override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // content sublayer 是 AVPlayerLayer 在首帧时才创建/替换的，赋值 player 那一次盖不全，
        // 每次 layout 补一遍；只是写几个字典引用，成本可以忽略。
        // 注意不要改成重写 layoutSublayers(of:)——UIView 自己就是 backing layer 的 delegate 并已
        // 实现该方法，覆盖它会截断 AVPlayerLayer 的内部布局。
        disableImplicitAnimations()
    }

    /// 停掉 playerLayer 及其内部内容层上"已经提交、正在跑"的动画，让它们立刻跳到 model 层终态。
    /// disabledActions 只能阻止新动画产生，对已经在跑的那一段无能为力，所以两者要配合使用。
    public func stopLayerAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.removeAllAnimations()
        playerLayer.sublayers?.forEach { $0.removeAllAnimations() }
        CATransaction.commit()
    }

    private func disableImplicitAnimations() {
        playerLayer.actions = Self.disabledActions
        playerLayer.sublayers?.forEach { $0.actions = Self.disabledActions }
    }
}
