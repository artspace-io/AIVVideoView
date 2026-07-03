import AVFoundation
import Combine
import UIKit

@MainActor
public final class AIVVideoPlayer: NSObject, ObservableObject {

    @Published public private(set) var status: AIVVideoPlayerStatus = .idle
    @Published public private(set) var currentTime: CMTime = .zero
    @Published public private(set) var duration: CMTime = .zero
    @Published public private(set) var cacheProgress: Double = 0
    @Published public private(set) var downloadSpeed: Double = 0
    @Published public private(set) var downloadedBytes: Int64 = 0
    @Published public private(set) var isBufferEmpty: Bool = true
    @Published public private(set) var isBufferFull: Bool = false
    @Published public private(set) var isLikelyToKeepUp: Bool = true
    @Published public private(set) var isReadyForDisplay: Bool = false
    @Published public private(set) var isCachingSuspended: Bool = false
    @Published public private(set) var playerError: AIVVideoPlayerError?

    /// 播放模式：列表播放 / 顺序循环 / 随机循环 / 单个循环，默认 .list
    @Published public var playMode: AIVVideoPlayMode = .list {
        didSet {
            guard playMode != oldValue else { return }
            regeneratePlayOrders()
        }
    }
    /// 内容填充方式，默认铺满裁剪（.resizeAspectFill），与常见的沉浸式视频流保持一致
    @Published public var videoGravity: AVLayerVideoGravity = .resizeAspectFill {
        didSet {
            _playerLayer?.videoGravity = videoGravity
        }
    }
    /// playMode 为 .list 时，播放列表最后一个视频结束后触发
    public var onPlaylistCompleted: (() -> Void)?

    /// 是否静音，同步到 AVPlayer.isMuted
    @Published public var isMuted: Bool = false {
        didSet {
            player.isMuted = isMuted
        }
    }

    /// App 进入后台时自动 stop()，回到前台时自动 playFromCurrentTime()，默认开启
    public var autoPlayWhenAppBeActive: Bool = true

    public let player: AVPlayer

    public var automaticallyWaitsToMinimizeStalling: Bool {
        get { player.automaticallyWaitsToMinimizeStalling }
        set { player.automaticallyWaitsToMinimizeStalling = newValue }
    }

    public var playerLayer: AVPlayerLayer? {
        if _playerLayer == nil {
            let layer = AVPlayerLayer(player: player)
            layer.addObserver(self, forKeyPath: #keyPath(AVPlayerLayer.readyForDisplay), options: [.new], context: &readyForDisplayContext)
            _playerLayer = layer
        }
        return _playerLayer
    }

    private var resourceLoader: AIVVideoResourceLoader?
    private var playerItem: AVPlayerItem?

    private var playlist: [URL] = []
    private var currentIndex = 0
    /// 播放顺序：playlist 下标的一个排列。.shuffle 下是打乱后的顺序，其余模式下是 0..<n 的顺序，
    /// playNext()/playPrevious() 都基于它前进/后退，保证随机模式下也有稳定、可回退的顺序
    private var playOrders: [Int] = []

    private var currentURL: URL?
    private var isSeeking = false
    private var userPaused = false
    private var hasPlayedToEnd = false
    private var wasPlayingBeforeResign = false

    private var subscriptions = Set<AnyCancellable>()
    private var timeObserverToken: Any?
    private var playerItemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []

    private var _playerLayer: AVPlayerLayer?
    private var readyForDisplayContext = "readyForDisplay"

    public override init() {
        player = AVPlayer()
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        setupPlayerObservers()
        setupNotifications()
        setupAppLifecycleObservers()
    }

    public convenience init(url: URL) {
        self.init()
        prepare(url: url)
    }

    deinit {
        playerObservations.forEach { $0.invalidate() }
        playerItemObservations.forEach { $0.invalidate() }
        subscriptions.removeAll()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let layer = _playerLayer {
            layer.removeObserver(self, forKeyPath: #keyPath(AVPlayerLayer.readyForDisplay), context: &readyForDisplayContext)
        }
        resourceLoader?.cancel()
    }

    public func prepare(url: URL) {
        playlist = [url]
        currentIndex = 0
        regeneratePlayOrders()
        loadCurrentItem()
    }

    /// 准备一个播放列表，播放行为由 playMode 决定
    public func preparePlaylist(_ urls: [URL], startIndex: Int = 0, mode: AIVVideoPlayMode? = nil) {
        guard !urls.isEmpty else { return }
        if let mode {
            playMode = mode
        }
        playlist = urls
        currentIndex = min(max(0, startIndex), urls.count - 1)
        regeneratePlayOrders()
        loadCurrentItem()
    }

    /// 当前播放列表（单个 url 播放时即为该 url 组成的单元素数组）
    public var playlistURLs: [URL] { playlist }
    /// 当前播放项在列表中的下标
    public var currentPlaylistIndex: Int { currentIndex }

    private func loadCurrentItem() {
        guard playlist.indices.contains(currentIndex) else { return }
        let url = playlist[currentIndex]

        tearDown()
        playerError = nil
        currentURL = url
        status = .preparing
        hasPlayedToEnd = false

        let loader = AIVVideoResourceLoader(url: url)
        resourceLoader = loader
        let item = loader.makePlayerItem()

        playerItem = item
        player.replaceCurrentItem(with: item)
        setupPlayerItemObservers(for: item)
        setupTimeObserver()
    }

    public func play() {
        if hasPlayedToEnd || status == .ended {
            seekAndPlay(from: .zero)
            return
        }
        userPaused = false
        player.play()
    }

    public func pause() {
        userPaused = true
        player.pause()
    }

    /// 暂停播放并取消资源加载（不改变 userPaused，用于 App 后台等系统级挂起场景，而非用户主动暂停）
    public func stop() {
        player.pause()
        resourceLoader?.cancel()
    }

    /// 从当前进度继续播放（不做“播完了就从头重播”的判断，语义上就是恢复当前进度）
    public func playFromCurrentTime() {
        userPaused = false
        player.play()
    }

    public func togglePlay() {
        switch status {
        case .playing:
            pause()
        case .ended:
            // .ended 只会在 .list 模式播完整个列表后出现，重新从头播放整个列表
            playAt(index: playOrders.first ?? 0)
        case .failed:
            prepare(url: currentURL ?? URL(string: "")!)
        default:
            play()
        }
    }

    public func seek(to time: CMTime) {
        isSeeking = true
        status = .seeking
        let wasPlaying = player.rate > 0
        let wasPaused = userPaused
        userPaused = false

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                guard let self, finished else { return }
                self.isSeeking = false
                if wasPaused || !wasPlaying {
                    self.userPaused = true
                    self.status = .paused
                } else {
                    self.player.play()
                    self.userPaused = false
                }
            }
        }
    }

    public func seek(to progress: Double) {
        let clamped = max(0, min(1, progress))
        guard duration.isNumeric, !duration.isIndefinite else { return }
        let seconds = CMTimeGetSeconds(duration) * clamped
        let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: duration.timescale)
        seek(to: time)
    }

    public func replace(url: URL) {
        prepare(url: url)
    }

    public func resignActive(stopPlayback: Bool = true) {
        guard !isCachingSuspended else { return }
        isCachingSuspended = true
        resourceLoader?.cancel()
        if stopPlayback {
            wasPlayingBeforeResign = (status == .playing)
            player.pause()
        }
    }

    public func becomeActive(autoPlay: Bool = true) {
        guard isCachingSuspended else { return }
        isCachingSuspended = false
        if autoPlay {
            play()
        }
    }

    public var isCacheCompleted: Bool {
        guard let url = currentURL else { return false }
        return AIVVideoCache.shared.isCacheComplete(for: url)
    }

    public var cacheProgressValue: Double {
        guard let url = currentURL else { return 0 }
        let info = AIVVideoCache.shared.info(for: url)
        return Double(info.cachedLength) / Double(max(info.contentLength, 1))
    }

    public func cleanCache() {
        guard let url = currentURL else { return }
        AIVVideoCache.shared.clear(for: url)
    }

    public static func cleanAllCache() {
        AIVVideoCache.shared.clearAll()
    }

    // MARK: - Private

    private func setupPlayerItemObservers(for item: AVPlayerItem) {
        let observations: [NSKeyValueObservation] = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.handlePlayerItemStatusChange(item.status)
                }
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.isBufferEmpty = item.isPlaybackBufferEmpty
                }
            },
            item.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.isBufferFull = item.isPlaybackBufferFull
                }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.isLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
                }
            },
            item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { [weak self] in
                    let d = item.duration
                    if d.isNumeric && !d.isIndefinite {
                        self?.duration = d
                    }
                }
            }
        ]
        playerItemObservations = observations
    }

    private func setupPlayerObservers() {
        let observations: [NSKeyValueObservation] = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.handleTimeControlStatusChange(
                        player.timeControlStatus,
                        reason: player.reasonForWaitingToPlay
                    )
                }
            }
        ]
        playerObservations = observations
    }

    private func setupTimeObserver() {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTimeMake(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self,
                  let item = notification.object as? AVPlayerItem,
                  item == self.playerItem
            else { return }
            self.handlePlaybackFinished()
        }
        .store(in: &subscriptions)
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.autoPlayWhenAppBeActive else { return }
                self.stop()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.autoPlayWhenAppBeActive, !self.userPaused, !self.isCachingSuspended else { return }
                self.playFromCurrentTime()
            }
            .store(in: &subscriptions)
    }

    private func handlePlaybackFinished() {
        switch playMode {
        case .single:
            seekAndPlay(from: .zero)
        case .list:
            let pos = currentOrderPosition
            if pos + 1 < playOrders.count {
                playAt(index: playOrders[pos + 1])
            } else {
                hasPlayedToEnd = true
                userPaused = false
                status = .ended
                onPlaylistCompleted?()
            }
        case .circle, .shuffle:
            playNext()
        }
    }

    /// 根据当前 playMode/playOrders 播放下一个视频；会 prepare 新 URL 并从头播放，更新 currentIndex
    public func playNext() {
        guard !playOrders.isEmpty else { return }
        let pos = currentOrderPosition
        switch playMode {
        case .list:
            guard pos + 1 < playOrders.count else { return }
            playAt(index: playOrders[pos + 1])
        case .circle, .single:
            playAt(index: playOrders[(pos + 1) % playOrders.count])
        case .shuffle:
            if pos + 1 < playOrders.count {
                playAt(index: playOrders[pos + 1])
            } else {
                // 一轮随机顺序播完，重新洗牌开始下一轮；若洗出来第一个恰好还是当前正在播的，
                // 和第二个换一下位置，避免点“下一个”却原地重播同一个视频
                regeneratePlayOrders()
                if playOrders.count > 1, playOrders.first == currentIndex {
                    playOrders.swapAt(0, 1)
                }
                if let first = playOrders.first {
                    playAt(index: first)
                }
            }
        }
    }

    /// 根据当前 playMode/playOrders 播放上一个视频；会 prepare 新 URL 并从头播放，更新 currentIndex
    public func playPrevious() {
        guard !playOrders.isEmpty else { return }
        let pos = currentOrderPosition
        switch playMode {
        case .list, .shuffle:
            // 随机模式没有"上一轮"的顺序可回退，到当前顺序的头就停
            guard pos - 1 >= 0 else { return }
            playAt(index: playOrders[pos - 1])
        case .circle, .single:
            playAt(index: playOrders[(pos - 1 + playOrders.count) % playOrders.count])
        }
    }

    /// 播放指定下标的视频；index 等于当前下标或越界时不处理
    public func setPlayIndex(_ index: Int) {
        guard index != currentIndex, playlist.indices.contains(index) else { return }
        playAt(index: index)
    }

    private var currentOrderPosition: Int {
        playOrders.firstIndex(of: currentIndex) ?? 0
    }

    private func regeneratePlayOrders() {
        guard !playlist.isEmpty else {
            playOrders = []
            return
        }
        switch playMode {
        case .shuffle:
            playOrders = Array(playlist.indices).shuffled()
        case .list, .circle, .single:
            playOrders = Array(playlist.indices)
        }
    }

    /// 切到列表中的某一项；若目标就是当前项（单元素列表循环等场景），直接从头 seek 更轻量
    private func playAt(index: Int) {
        guard playlist.indices.contains(index) else { return }
        if index == currentIndex {
            seekAndPlay(from: .zero)
            return
        }
        currentIndex = index
        loadCurrentItem()
        play()
    }

    private func handlePlayerItemStatusChange(_ itemStatus: AVPlayerItem.Status) {
        switch itemStatus {
        case .unknown:
            if status != .preparing {
                status = .preparing
            }
        case .readyToPlay:
            if status == .preparing || status == .idle {
                status = .readyToPlay
            }
        case .failed:
            playerError = .playbackFailed
            status = .failed
        @unknown default:
            break
        }
    }

    private func handleTimeControlStatusChange(
        _ controlStatus: AVPlayer.TimeControlStatus,
        reason: AVPlayer.WaitingReason?
    ) {
        if isSeeking {
            status = .seeking
            return
        }
        if hasPlayedToEnd {
            status = .ended
            return
        }

        switch controlStatus {
        case .playing:
            status = .playing
        case .paused:
            status = .paused
        case .waitingToPlayAtSpecifiedRate:
            guard let reason else {
                status = .buffering
                return
            }
            switch reason {
            case .toMinimizeStalls, .noItemToPlay:
                status = .buffering
            default:
                status = .buffering
            }
        @unknown default:
            break
        }
    }

    private func seekAndPlay(from time: CMTime) {
        isSeeking = true
        status = .seeking
        hasPlayedToEnd = false
        userPaused = false

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSeeking = false
                self.player.play()
            }
        }
    }

    private func tearDown() {
        removePlayerItemObservers()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        resourceLoader?.cancel()
        resourceLoader = nil
        isSeeking = false
        userPaused = false
        hasPlayedToEnd = false
        isCachingSuspended = false
        wasPlayingBeforeResign = false
    }

    private func removePlayerItemObservers() {
        playerItemObservations.forEach { $0.invalidate() }
        playerItemObservations.removeAll()
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if context == &readyForDisplayContext {
            DispatchQueue.main.async { [weak self] in
                self?.isReadyForDisplay = self?._playerLayer?.isReadyForDisplay ?? false
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
