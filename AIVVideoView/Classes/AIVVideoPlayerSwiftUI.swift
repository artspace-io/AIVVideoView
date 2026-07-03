import SwiftUI
import AVFoundation

@available(iOS 14.0, *)
public struct AIVVideoPlayerSwiftUI: UIViewRepresentable {
    @ObservedObject public var player: AIVVideoPlayer

    /// videoGravity 现在是 AIVVideoPlayer 自身的状态（player.videoGravity），这里只是一个可选的初始化便利参数
    public init(player: AIVVideoPlayer, videoGravity: AVLayerVideoGravity? = nil) {
        self.player = player
        if let videoGravity {
            player.videoGravity = videoGravity
        }
    }

    public func makeUIView(context: Context) -> AIVVideoPlayerView {
        let view = AIVVideoPlayerView()
        view.player = player
        return view
    }

    public func updateUIView(_ uiView: AIVVideoPlayerView, context: Context) {}
}
