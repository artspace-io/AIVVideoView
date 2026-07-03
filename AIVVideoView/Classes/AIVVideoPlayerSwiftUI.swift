import SwiftUI
import AVFoundation

@available(iOS 14.0, *)
public struct AIVVideoPlayerSwiftUI: UIViewRepresentable {
    @ObservedObject public var player: AIVVideoPlayer
    public let videoGravity: AVLayerVideoGravity

    public init(player: AIVVideoPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.videoGravity = videoGravity
    }

    public func makeUIView(context: Context) -> AIVVideoPlayerView {
        let view = AIVVideoPlayerView()
        view.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    public func updateUIView(_ uiView: AIVVideoPlayerView, context: Context) {}
}
