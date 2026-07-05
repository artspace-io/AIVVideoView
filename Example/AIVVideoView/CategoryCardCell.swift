import UIKit
import SDWebImage
import AIVVideoView

/// 主题分区里的一张卡片：大圆角、静音自动播放视频 + 封面兜底 + 底部白色标题。
/// 和 VideoFeedCell 是同一套模式：自己持有播放器，通过 AIVVideoPlayerCoordinator 竞争播放名额。
final class CategoryCardCell: UICollectionViewCell {
    private let playerView = AIVVideoPlayerView()
    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let gradientLayer = CAGradientLayer()

    private var readyForDisplayObservation: NSKeyValueObservation?
    private var player: AIVVideoPlayer?
    private var video: VideoItem?

    /// 可见面积低于这个比例就不参与播放名额的竞争，只展示封面图
    private let minimumVisibleRatioToPlay: CGFloat = 0.01

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.layer.cornerRadius = 18
        contentView.layer.masksToBounds = true
        contentView.backgroundColor = .darkGray

        playerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerView)

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverImageView)

        gradientLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
        gradientLayer.locations = [0.5, 1]
        contentView.layer.addSublayer(gradientLayer)

        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            coverImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releasePlayerAndSlot()
        coverImageView.sd_cancelCurrentImageLoad()
        coverImageView.image = nil
    }

    func configure(_ video: VideoItem) {
        self.video = video
        titleLabel.text = video.title
        coverImageView.sd_setImage(with: video.coverURL)
    }

    /// ratio 是这张卡片当前可见面积占自身总面积的比例（0...1），播不播完全由 cell 自己决定
    func updateVisibility(ratio: CGFloat) {
        guard ratio >= minimumVisibleRatioToPlay else {
            releasePlayerAndSlot()
            return
        }

        guard player == nil else {
            AIVVideoPlayerCoordinator.shared.updateVisibleRatio(ratio, for: self)
            return
        }

        guard let video else { return }
        let granted = AIVVideoPlayerCoordinator.shared.requestSlot(for: self, visibleRatio: ratio) { [weak self] in
            self?.releasePlayerAndSlot()
        }
        guard granted else { return }

        let newPlayer = AIVVideoPlayer(url: video.url)
        player = newPlayer
        attachPlayer(newPlayer)
    }

    /// 完全滑出可见范围（横向划走或纵向滚出屏幕）时调用
    func didLeaveVisibleArea() {
        releasePlayerAndSlot()
    }

    private func attachPlayer(_ player: AIVVideoPlayer) {
        player.playMode = .single
        player.isMuted = true
        playerView.player = player

        readyForDisplayObservation = playerView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.2) {
                    self?.coverImageView.alpha = 0
                }
            }
        }

        player.play()
    }

    private func releasePlayerAndSlot() {
        coverImageView.alpha = 1
        readyForDisplayObservation = nil
        guard let player else { return }
        player.resignActive(stopPlayback: true)
        playerView.player = nil
        self.player = nil
        AIVVideoPlayerCoordinator.shared.releaseSlot(for: self)
    }
}
