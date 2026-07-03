import UIKit
import AVFoundation
import Combine

public final class AIVVideoPlayerView: UIView {
    public weak var player: AIVVideoPlayer? {
        didSet {
            gravitySubscription = nil
            if let player {
                playerLayer.player = player.player
                playerLayer.videoGravity = player.videoGravity
                playerLayer.isHidden = false
                gravitySubscription = player.$videoGravity
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] gravity in
                        self?.playerLayer.videoGravity = gravity
                    }
            } else {
                playerLayer.player = nil
                playerLayer.isHidden = true
            }
        }
    }

    private var gravitySubscription: AnyCancellable?

    public var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    public override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }
}
