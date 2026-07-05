import UIKit

/// App 首页：顶部全屏 Hero 轮播（自动播放静音视频）+ 下方多个主题分区（横向卡片列表，同样自动播放静音视频）。
/// 点击分区右侧箭头会带着分类名 push 到视频网格（ViewController），网格里只显示这个分类。
final class HomeViewController: UIViewController {

    private static let headerElementKind = "sectionHeader"

    private enum SectionID: Hashable {
        case hero
        case category(String)
    }

    private enum ItemID: Hashable {
        case hero(HeroItem)
        case video(VideoItem)
    }

    private let sections: [VideoSection] = VideoItem.loadSections()
    private lazy var heroItems: [HeroItem] = HeroItem.loadAll(from: sections)

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()

    private let heroSectionIndex = 0
    private var currentHeroPage = 0

    /// Hero 区域的高度，可以在外部自定义；改动后会自动触发重新布局。
    var heroHeight: CGFloat = UIScreen.main.bounds.height * 0.4 {
        didSet {
            guard heroHeight != oldValue else { return }
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// 横向分区的卡片可见比例更新有防抖，避免在分区内部横向滑动的过程中连续创建/销毁播放器
    private var categoryVisibilityWorkItem: DispatchWorkItem?

    /// Hero 的 playableFrame 复核有防抖，等分页动画稳定了再查一次可见比例
    private var heroVisibilityWorkItem: DispatchWorkItem?

    /// 只有落在这块区域内的内容才会播放（Hero 和分区卡片都受影响）；nil 表示不限制，沿用 collectionView 的可见范围。
    /// 用 view 自己的坐标系描述，不随 collectionView 滚动而变化。暂不处理屏幕旋转/尺寸变化，需要调用方在合适的时机自行更新。
    var playableFrame: CGRect? {
        didSet {
            updateHeroPlayback()
            updateCategoryVisibility()
        }
    }

    /// Hero 是分页轮播，本身没有连续的可见比例概念；这个阈值只用来判断"当前页"是否被 playableFrame 挡住太多而不该播放
    private let minimumHeroVisibleRatioToPlay: CGFloat = 0.5

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        collectionView.backgroundColor = .black
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        applySnapshot()

        self.playableFrame = CGRect(
            x: 0,
            y: view.safeAreaInsets.top,
            width: view.bounds.width,
            height: view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 64
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCategoryVisibility()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateHeroPlayback()
        updateCategoryVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 被别的页面 push 盖住时，Hero 和分区卡片都不会再收到滚动相关的回调，
        // 必须主动释放，否则会一直在背后偷偷解码
        for indexPath in collectionView.indexPathsForVisibleItems {
            let cell = collectionView.cellForItem(at: indexPath)
            (cell as? HeroCell)?.setActive(false)
            (cell as? CategoryCardCell)?.didLeaveVisibleArea()
        }
    }

    // MARK: - Data

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<SectionID, ItemID>()

        snapshot.appendSections([.hero])
        snapshot.appendItems(heroItems.map { .hero($0) }, toSection: .hero)

        for section in sections {
            let sectionID = SectionID.category(section.category)
            snapshot.appendSections([sectionID])
            snapshot.appendItems(section.videos.map { .video($0) }, toSection: sectionID)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionID, ItemID> {
        let heroRegistration = UICollectionView.CellRegistration<HeroCell, HeroItem> { [weak self] cell, indexPath, item in
            cell.configure(item, totalPages: self?.heroItems.count ?? 0)
            cell.setCurrentPage(self?.currentHeroPage ?? 0)
        }
        let cardRegistration = UICollectionView.CellRegistration<CategoryCardCell, VideoItem> { cell, _, item in
            cell.configure(item)
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionID, ItemID>(collectionView: collectionView) { collectionView, indexPath, itemID in
            switch itemID {
            case .hero(let item):
                return collectionView.dequeueConfiguredReusableCell(using: heroRegistration, for: indexPath, item: item)
            case .video(let item):
                return collectionView.dequeueConfiguredReusableCell(using: cardRegistration, for: indexPath, item: item)
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderView>(elementKind: Self.headerElementKind) { [weak self] header, _, indexPath in
            guard let self else { return }
            guard case .category(let name) = self.dataSource.snapshot().sectionIdentifiers[indexPath.section] else { return }
            header.configure(title: name)
            header.onTapArrow = { [weak self] in
                self?.openGrid(category: name)
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        return dataSource
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            guard let self else { return nil }
            let sectionID = self.dataSource.snapshot().sectionIdentifiers[sectionIndex]
            switch sectionID {
            case .hero:
                return self.makeHeroSection()
            case .category:
                return self.makeCategorySection()
            }
        }
    }

    private func makeHeroSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(heroHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .groupPagingCentered
        section.visibleItemsInvalidationHandler = { [weak self] _, offset, environment in
            guard let self else { return }
            let pageWidth = environment.container.contentSize.width
            guard pageWidth > 0 else { return }
            let page = Int((offset.x / pageWidth).rounded())
            guard page != self.currentHeroPage, self.heroItems.indices.contains(page) else { return }
            self.currentHeroPage = page
            // 这个回调是跟布局计算同步触发的，此刻新出现的 cell 可能还没在 collectionView 里挂好，
            // 查 cellForItem(at:) 可能拿不到；丢到下一个 runloop 再查，保证布局已经跑完
            DispatchQueue.main.async { [weak self] in
                self?.updateHeroPlayback()
            }
        }
        return section
    }

    private func makeCategorySection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(130), heightDimension: .absolute(190))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .estimated(130), heightDimension: .absolute(190))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        group.interItemSpacing = .fixed(12)

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 28, trailing: 16)
        section.interGroupSpacing = 12
        // 分区内部横向滑动不会触发外层 UIScrollViewDelegate，用这个 handler 感知横向滚动，
        // 防抖之后再去更新可见比例，避免划动过程中连续创建/销毁播放器
        section.visibleItemsInvalidationHandler = { [weak self] _, _, _ in
            self?.scheduleCategoryVisibilityUpdate()
        }

        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: Self.headerElementKind, alignment: .top)
        section.boundarySupplementaryItems = [header]

        return section
    }

    // MARK: - Visibility

    /// collectionView 的可见范围；如果设置了 playableFrame，会再和它（转换坐标系后）取交集，逻辑和 ViewController 一致
    private func playableBounds() -> CGRect {
        var bounds = collectionView.bounds
        if let playableFrame {
            let convertedFrame = view.convert(playableFrame, to: collectionView)
            bounds = bounds.intersection(convertedFrame)
        }
        return bounds
    }

    /// 分区自己是横向正交滚动的，cell.frame 反映的是分区内部滚动前的逻辑位置（不会随内部横向滚动改变），
    /// 跟 collectionView.bounds 完全不是同一个坐标系，直接比较永远算不对。
    /// 用 convert(_:to:) 走真实视图层级换算，才能拿到 cell 当前真正的屏幕位置。
    private func ratio(of cell: UICollectionViewCell, in bounds: CGRect) -> CGFloat {
        let frameInCollectionView = cell.convert(cell.bounds, to: collectionView)
        let visibleArea = frameInCollectionView.intersection(bounds)
        let cellArea = cell.bounds.width * cell.bounds.height
        return cellArea > 0 ? (visibleArea.width * visibleArea.height) / cellArea : 0
    }

    // MARK: - Hero playback

    /// 切页那一刻立刻让"当前页"播放，不在这里查 playableFrame 比例——
    /// 分页动画（回弹归位）这时候可能还没结束，cell.frame 还没到最终位置，量出来的可见比例不准，
    /// 拿它来决定播不播会把刚变成当前页的 cell 误判成"被挡住了"，而且没有后续动作能纠正这个误判。
    private func updateHeroPlayback() {
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section == heroSectionIndex {
            guard let cell = collectionView.cellForItem(at: indexPath) as? HeroCell else { continue }
            cell.setCurrentPage(currentHeroPage)
            cell.setActive(indexPath.item == currentHeroPage)
        }
        scheduleHeroPlayableAreaRecheck()
    }

    private func scheduleHeroPlayableAreaRecheck() {
        heroVisibilityWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.applyHeroPlayableAreaGate() }
        heroVisibilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    /// 等分页动画真正稳定之后再复核一次：如果当前页确实被 playableFrame 挡住了，这里才把它停掉
    private func applyHeroPlayableAreaGate() {
        let bounds = playableBounds()
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section == heroSectionIndex {
            guard indexPath.item == currentHeroPage, let cell = collectionView.cellForItem(at: indexPath) as? HeroCell else { continue }
            let isWithinPlayableArea = ratio(of: cell, in: bounds) >= minimumHeroVisibleRatioToPlay
            if !isWithinPlayableArea {
                cell.setActive(false)
            }
        }
    }

    // MARK: - Category cards visibility

    private func scheduleCategoryVisibilityUpdate() {
        categoryVisibilityWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.updateCategoryVisibility() }
        categoryVisibilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    /// 只负责计算每张卡片当前可见面积占比，播不播、跟谁抢播放名额完全交给 cell 自己（通过 AIVVideoPlayerCoordinator）
    private func updateCategoryVisibility() {
        let bounds = playableBounds()
        for cell in collectionView.visibleCells {
            guard let cardCell = cell as? CategoryCardCell else { continue }
            cardCell.updateVisibility(ratio: ratio(of: cell, in: bounds))
        }
    }

    // MARK: - Navigation

    private func openGrid(category: String) {
        let vc = ViewController(category: category)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension HomeViewController: UICollectionViewDelegate {
    // visibleItemsInvalidationHandler 在横向正交滚动时不够可靠（新滑出来的 cell 那一刻查 cellForItem(at:)
    // 可能还拿不到，导致新出现的 cell 收不到播放判定）。willDisplay 是标准的 UIKit 回调，
    // 不管是纵向滚动还是某个分区自己的横向滚动，只要有新 cell 进入可见范围就一定会触发，
    // 而且直接把 cell 实例给我们，不需要再反查一次。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let heroCell = cell as? HeroCell {
            // 同样先只按"是不是当前页"立刻决定播不播，playableFrame 的比例复核交给防抖之后的 applyHeroPlayableAreaGate
            let isCurrentPage = indexPath.item == currentHeroPage
            heroCell.setCurrentPage(currentHeroPage)
            heroCell.setActive(isCurrentPage)
            if isCurrentPage {
                scheduleHeroPlayableAreaRecheck()
            }
        } else if let cardCell = cell as? CategoryCardCell {
            let r = ratio(of: cell, in: playableBounds())
            cardCell.updateVisibility(ratio: r)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? CategoryCardCell)?.didLeaveVisibleArea()
    }
}

// MARK: - UIScrollViewDelegate

extension HomeViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCategoryVisibility()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateCategoryVisibility()
        }
    }
}
