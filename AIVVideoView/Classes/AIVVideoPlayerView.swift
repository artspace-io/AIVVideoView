import UIKit
import AVFoundation

public final class AIVVideoPlayerView: UIView {
    public weak var player: AIVVideoPlayer? {
        didSet {
            if let player {
                playerLayer.player = player.player
                playerLayer.isHidden = false
            } else {
                playerLayer.player = nil
                playerLayer.isHidden = true
            }
        }
    }

    public var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    public override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        playerLayer.videoGravity = .resizeAspect
    }
}
