import UIKit
import AIVVideoView

class ViewController: UIViewController {

    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 4
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.register(VideoFeedCell.self, forCellWithReuseIdentifier: "cell")
        return cv
    }()

    private var videos: [VideoItem] = VideoItem.loadAll()
    private var visiblePlayers: [IndexPath: AIVVideoPlayer] = [:]
    private var hasInitialSetup = false

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.dataSource = self
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.contentInset = UIEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.contentInset = UIEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
        if !hasInitialSetup {
            hasInitialSetup = true
            updateVisiblePlayers()
        }
    }

    // MARK: - Player Lifecycle

    private func setupPlayer(for cell: VideoFeedCell, at indexPath: IndexPath) {
        guard visiblePlayers[indexPath] == nil else { return }
        let video = videos[indexPath.item]
        let player = AIVVideoPlayer(url: video.url)
        visiblePlayers[indexPath] = player
        cell.attachPlayer(player)
    }

    private func releasePlayer(at indexPath: IndexPath, cell: VideoFeedCell) {
        guard let player = visiblePlayers.removeValue(forKey: indexPath) else { return }
        cell.detachPlayer(player)
    }

    private func updateVisiblePlayers() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? VideoFeedCell else { continue }
            setupPlayer(for: cell, at: indexPath)
        }
    }
}

// MARK: - UICollectionViewDataSource

extension ViewController: UICollectionViewDataSource {
    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        videos.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! VideoFeedCell
        cell.bind(videos[indexPath.item])
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension ViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // didEndDisplaying 触发时 cell 已从可见列表移除，collectionView.cellForItem(at:) 会返回 nil，
        // 必须直接使用回调传入的 cell，否则 detachPlayer 永远不会执行，导致播放器/下载任务未释放
        guard let feedCell = cell as? VideoFeedCell else { return }
        releasePlayer(at: indexPath, cell: feedCell)
    }
}

// MARK: - UIScrollViewDelegate

extension ViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateVisiblePlayers()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateVisiblePlayers()
        }
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension ViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt _: IndexPath) -> CGSize {
        let spacing: CGFloat = 4
        let totalSpacing = spacing * 3
        let itemWidth = (collectionView.bounds.width - totalSpacing) / 2
        let itemHeight = itemWidth * 648.0 / 480.0
        return CGSize(width: itemWidth, height: itemHeight)
    }

    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, insetForSectionAt _: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    }

    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, minimumLineSpacingForSectionAt _: Int) -> CGFloat {
        4
    }

    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, minimumInteritemSpacingForSectionAt _: Int) -> CGFloat {
        4
    }
}
