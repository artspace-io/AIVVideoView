import AVFoundation
import Combine

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

    public func togglePlay() {
        switch status {
        case .playing:
            pause()
        case .ended, .failed:
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

        player.seek(to: time, toleranceBefore: .invalid, toleranceAfter: .invalid) { [weak self] finished in
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
            self.hasPlayedToEnd = true
            self.userPaused = false
            self.status = .ended
        }
        .store(in: &subscriptions)
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

        player.seek(to: time, toleranceBefore: .invalid, toleranceAfter: .invalid) { [weak self] _ in
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
