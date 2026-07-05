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

    private var videos: [VideoItem]
    private let category: String?

    /// 只有落在这块区域内（按 minimumVisibleRatioToPlay 判定）的 cell 才会播放；nil 表示不限制，沿用 collectionView 的可见范围。
    /// 用 view 自己的坐标系描述，不随 collectionView 滚动而变化。暂不处理屏幕旋转/尺寸变化，需要调用方在合适的时机自行更新。
    var playableFrame: CGRect? {
        didSet { updateVisibility() }
    }

    /// category 为 nil 时展示全部视频；传入分类名时只展示该分类下的视频（从首页某个分区箭头进来的场景）
    init(category: String? = nil) {
        self.category = category
        if let category {
            self.videos = VideoItem.loadAll().filter { $0.category == category }
        } else {
            self.videos = VideoItem.loadAll()
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.category = nil
        self.videos = VideoItem.loadAll()
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = category
        view.backgroundColor = .black
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
        // 每次布局都无条件调用，避免只跑一次时恰好赶上 visibleCells 还是空的那一帧（导致首屏永远播不起来）；
        // 是否要真的创建播放器完全由 VideoFeedCell 自己根据可见比例决定，这里只负责算比例、报给 cell。
        updateVisibility()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 从首页 push 过来 / 从上层页面 pop 回来时，重新按当前可见情况决定播放
        updateVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 被别的页面 push 盖住时，这个页面本身不会再收到滚动相关的回调，
        // 必须主动让所有可见 cell 释放播放器/播放名额，否则会一直在背后偷偷解码
        for cell in collectionView.visibleCells {
            (cell as? VideoFeedCell)?.didLeaveVisibleArea()
        }
    }

    // MARK: - Visibility

    /// 只负责计算每个当前可见 cell 落在"可播放区域"里的面积占比，播不播、跟谁抢播放名额完全交给 cell 自己（通过 AIVVideoPlayerCoordinator）
    private func updateVisibility() {
        var playableBounds = collectionView.bounds
        if let playableFrame {
            let convertedFrame = view.convert(playableFrame, to: collectionView)
            playableBounds = collectionView.bounds.intersection(convertedFrame)
        }

        for cell in collectionView.visibleCells {
            guard let feedCell = cell as? VideoFeedCell else { continue }
            let visibleArea = cell.frame.intersection(playableBounds)
            let cellArea = cell.bounds.width * cell.bounds.height
            let ratio = cellArea > 0 ? (visibleArea.width * visibleArea.height) / cellArea : 0
            feedCell.updateVisibility(ratio: ratio)
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
        // didEndDisplaying 触发时 cell 已经从 visibleCells 里移除了，updateVisibility() 不会再扫到它，
        // 必须显式通知一次，否则完全滑出屏幕的 cell 不会主动释放播放器和播放名额
        (cell as? VideoFeedCell)?.didLeaveVisibleArea()
    }
}

// MARK: - UIScrollViewDelegate

extension ViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateVisibility()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateVisibility()
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
