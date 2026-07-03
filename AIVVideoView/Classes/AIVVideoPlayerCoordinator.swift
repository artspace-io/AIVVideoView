import Foundation

/// 全局播放名额协调器：限制同时存在的播放实例数量（AVPlayer 渲染通道有上限，经验值约 18），
/// 按"可见面积"仲裁谁该播放——不属于任何一个 cell 或某个 ViewController，
/// 是可以在多个列表/多个页面之间共用的基础设施，定位类似 AIVVideoCache。
@MainActor
public final class AIVVideoPlayerCoordinator {
    public static let shared = AIVVideoPlayerCoordinator()

    /// 全局最多允许同时播放的数量，需要明显低于系统渲染通道上限，留出安全余量
    public var maxConcurrentPlayers: Int = 15

    private struct Slot {
        var visibleRatio: CGFloat
        let onEvicted: () -> Void
    }
    
    private var slots: [ObjectIdentifier: Slot] = [:]

    private init() {}

    /// 申请一个播放名额。token 通常就是持有播放器的 cell 自身（用身份而非值做 key）。
    /// - Returns: true 表示拿到了名额，调用方应该去创建/播放；false 表示名额已满且当前可见面积不够抢占，应维持封面图状态。
    /// - Note: 如果名额已满，会挑选当前占用名额里可见面积最小的一个，只有比它更大才会挤占成功；
    ///         被挤占的一方会同步收到 onEvicted 回调，用来释放自己的播放器。
    @discardableResult
    public func requestSlot(for token: AnyObject, visibleRatio: CGFloat, onEvicted: @escaping () -> Void) -> Bool {
        let key = ObjectIdentifier(token)

        if slots[key] != nil {
            slots[key] = Slot(visibleRatio: visibleRatio, onEvicted: onEvicted)
            return true
        }

        if slots.count < maxConcurrentPlayers {
            slots[key] = Slot(visibleRatio: visibleRatio, onEvicted: onEvicted)
            return true
        }

        guard let (lowestKey, lowestSlot) = slots.min(by: { $0.value.visibleRatio < $1.value.visibleRatio }),
              visibleRatio > lowestSlot.visibleRatio
        else {
            return false
        }

        slots.removeValue(forKey: lowestKey)
        lowestSlot.onEvicted()
        slots[key] = Slot(visibleRatio: visibleRatio, onEvicted: onEvicted)
        return true
    }

    /// 更新已经持有名额的 token 的可见比例，供后续别的 token 申请名额时比较优先级
    public func updateVisibleRatio(_ ratio: CGFloat, for token: AnyObject) {
        let key = ObjectIdentifier(token)
        guard let existing = slots[key] else { return }
        slots[key] = Slot(visibleRatio: ratio, onEvicted: existing.onEvicted)
    }

    /// 主动放弃名额（滑出屏幕、cell 被复用等场景）
    public func releaseSlot(for token: AnyObject) {
        slots.removeValue(forKey: ObjectIdentifier(token))
    }
}
