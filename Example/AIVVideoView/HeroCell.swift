import UIKit
import SDWebImage
import AIVVideoView

/// 首页顶部 Hero 轮播的一张卡片：全屏铺满的静音自动播放视频，配封面兜底和居中标题/副标题。
/// 同一时间只有"当前居中的那一页"会真正播放，通过 AIVVideoPlayerCoordinator 和 grid 页共用同一套播放名额机制。
final class HeroCell: UICollectionViewCell {
    private let playerView = AIVVideoPlayerView()
    private let coverImageView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let pageControl = UIPageControl()

    private var player: AIVVideoPlayer?
    private var heroItem: HeroItem?
    private var readyForDisplayObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black

        playerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerView)

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverImageView)

        gradientLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
        gradientLayer.locations = [0.4, 1]
        contentView.layer.addSublayer(gradientLayer)

        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 34)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subtitleLabel.textColor = .white.withAlphaComponent(0.8)
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        pageControl.currentPageIndicatorTintColor = .white
        pageControl.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.4)
        pageControl.isUserInteractionEnabled = false
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pageControl)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            coverImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            pageControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -100),

            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            subtitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -8)
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

    func configure(_ item: HeroItem, totalPages: Int) {
        heroItem = item
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        coverImageView.sd_setImage(with: item.coverURL)
        pageControl.numberOfPages = totalPages
    }

    /// 相邻的 Hero cell 在同一时刻会显示同样的分页点状态，划动切换时看起来就像一条连续、不跟着挪动的分页指示
    func setCurrentPage(_ page: Int) {
        pageControl.currentPage = page
    }

    /// 是否是当前居中显示的那一页；只有 active 的时候才会去竞争播放名额
    func setActive(_ active: Bool) {
        guard active else {
            releasePlayerAndSlot()
            return
        }
        guard player == nil else { return }
        guard let heroItem else { return }

        let granted = AIVVideoPlayerCoordinator.shared.requestSlot(for: self, visibleRatio: 1) { [weak self] in
            self?.releasePlayerAndSlot()
        }
        guard granted else { return }

        let newPlayer = AIVVideoPlayer(url: heroItem.videoURL)
        player = newPlayer
        attachPlayer(newPlayer)
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
