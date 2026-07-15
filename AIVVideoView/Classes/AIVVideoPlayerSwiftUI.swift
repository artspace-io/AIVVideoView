import SwiftUI
import AVFoundation

@available(iOS 14.0, *)
public struct AIVVideoPlayerSwiftUI: UIViewRepresentable {
    @ObservedObject public var player: AIVVideoPlayer

    public init(player: AIVVideoPlayer) {
        self.player = player
    }

    public func makeUIView(context: Context) -> AIVVideoPlayerView {
        let view = AIVVideoPlayerView()
        view.player = player
        return view
    }

    public func updateUIView(_ uiView: AIVVideoPlayerView, context: Context) {}
}
