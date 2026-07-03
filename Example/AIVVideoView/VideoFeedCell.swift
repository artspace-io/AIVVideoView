import UIKit
import AIVVideoView

final class VideoFeedCell: UICollectionViewCell {
    let playerView = AIVVideoPlayerView()
    private let coverLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .darkGray

        playerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        coverLabel.textColor = .white
        coverLabel.font = .boldSystemFont(ofSize: 20)
        coverLabel.textAlignment = .center
        coverLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverLabel)
        NSLayoutConstraint.activate([
            coverLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            coverLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerView.player = nil
        coverLabel.isHidden = false
    }

    func bind(_ video: VideoItem) {
        coverLabel.text = "\(video.category)\n\(video.title)"
        print("[Cell] bind — \(video.title)")
    }

    func attachPlayer(_ player: AIVVideoPlayer) {
        print("[Cell] attachPlayer isCachingSuspended=\(player.isCachingSuspended)")
        playerView.player = player
        coverLabel.isHidden = true
        if player.isCachingSuspended {
            player.becomeActive(autoPlay: true)
        } else {
            player.play()
        }
    }

    func detachPlayer(_ player: AIVVideoPlayer) {
        print("[Cell] detachPlayer")
        player.resignActive(stopPlayback: true)
        playerView.player = nil
        coverLabel.isHidden = false
    }
}
