import UIKit
import SDWebImage
import AIVVideoView

final class VideoFeedCell: UICollectionViewCell {
    let playerView = AIVVideoPlayerView()

    /// 封面图 + 标题的容器，作为一个整体在播放器首帧就绪前后淡入淡出
    private let coverContainer = UIView()
    private let coverImageView = UIImageView()
    private let coverLabel = UILabel()

    // 注意：AIVVideoPlayer.isReadyForDisplay 挂在它自己私有、从未被创建的 AVPlayerLayer 上（
    // AIVVideoPlayerView 用的是自己 layerClass 覆盖出来的另一个 AVPlayerLayer），订阅它永远不会触发。
    // 必须直接观察 playerView.playerLayer 这个真正在渲染画面的 layer。
    private var readyForDisplayObservation: NSKeyValueObservation?

    /// cell 自己创建/持有播放器，ViewController 不再管理 AIVVideoPlayer 的生命周期，
    /// 只负责把"当前可见面积占比"这一个数字传进来
    private var player: AIVVideoPlayer?
    private var video: VideoItem?

    /// 可见面积低于这个比例就不参与播放名额的竞争，只展示封面图
    private let minimumVisibleRatioToPlay: CGFloat = 0.5

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

        coverContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverContainer)
        NSLayoutConstraint.activate([
            coverContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = .darkGray
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.addSubview(coverImageView)
        NSLayoutConstraint.activate([
            coverImageView.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor)
        ])

        coverLabel.textColor = .white
        coverLabel.numberOfLines = 2
        coverLabel.font = .boldSystemFont(ofSize: 13)
        coverLabel.textAlignment = .left
        coverLabel.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.addSubview(coverLabel)
        NSLayoutConstraint.activate([
            coverLabel.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor, constant: 8),
            coverLabel.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor, constant: -8),
            coverLabel.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        releasePlayerAndSlot()
        coverImageView.sd_cancelCurrentImageLoad()
        coverImageView.image = nil
        coverContainer.alpha = 1
    }

    func bind(_ video: VideoItem) {
        self.video = video
        coverLabel.text = "\(video.category)\n\(video.title)"
        coverImageView.sd_setImage(with: video.coverURL)
    }

    /// 由 ViewController 在滚动停止（或初次布局）后，对每个当前可见的 cell 调用一次。
    /// ratio 是这个 cell 当前可见面积占自身总面积的比例（0...1），播不播、播谁完全由 cell 自己决定。
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

    /// 由 ViewController 在 didEndDisplaying（cell 完全滑出屏幕）时调用
    func didLeaveVisibleArea() {
        releasePlayerAndSlot()
    }

    private func attachPlayer(_ player: AIVVideoPlayer) {
        // Feed 里的每个 cell 只对应一个视频，播完应该循环，而不是停在最后一帧
        player.playMode = .single
        player.isMuted = true
        playerView.player = player
        coverContainer.alpha = 1

        readyForDisplayObservation = playerView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.2) {
                    self?.coverContainer.alpha = 0
                }
            }
        }

        if player.isCachingSuspended {
            player.becomeActive(autoPlay: true)
        } else {
            player.play()
        }
    }

    private func detachPlayer(_ player: AIVVideoPlayer) {
        player.resignActive(stopPlayback: true)
        playerView.player = nil
        readyForDisplayObservation = nil
        coverContainer.alpha = 1
    }

    private func releasePlayerAndSlot() {
        guard let player else { return }
        detachPlayer(player)
        self.player = nil
        AIVVideoPlayerCoordinator.shared.releaseSlot(for: self)
    }
}
