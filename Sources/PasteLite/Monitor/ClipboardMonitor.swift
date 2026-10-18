import AppKit

/// 剪贴板监听器：0.5s 轮询 changeCount 感知复制。
/// 系统不提供剪贴板变更通知，轮询是通行做法；只比对 changeCount 不读内容，
/// 因此启动阶段不会触发粘贴板授权弹窗（读内容才触发）。
/// 须在主线程创建并调用 start()/stop()：Timer 挂在主 RunLoop 上。
final class ClipboardMonitor {
    /// 新内容入库回调（主线程回调）。集成装配为 monitor.onNewContent → store.record(item)。
    var onNewContent: (@MainActor (ClipboardItem) -> Void)?

    /// 排除检查：返回 true 则本次复制不入库（密码管理器等）。
    /// 由 ClipboardReader 在读内容之前消费，保证被排除来源不触发读取、不弹授权框。
    var isExcludedBundleID: ((String) -> Bool)?

    /// 轮询定时器须强持有；stop 或自身释放时（下个 tick）失效
    private var timer: Timer?
    /// 最近一次见到的 changeCount 基线；changeCount 单调递增，不等即视为新内容
    private var lastChangeCount = 0

    func start() {
        guard timer == nil else { return }
        // 首帧只记基线不读取：应用启动前剪贴板里的旧内容不采集入库
        lastChangeCount = NSPasteboard.general.changeCount

        let newTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] firedTimer in
            guard let self else {
                // 监听器已释放：自清定时器，避免僵尸轮询
                firedTimer.invalidate()
                return
            }
            self.poll()
        }
        // .common 模式：菜单展开、模态拖动等事件跟踪期间轮询不中断（default 模式会被挂起）
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        // 无论内容可读与否都先推进基线：本 tick 读不到的内容不回头重读
        lastChangeCount = count

        guard let item = ClipboardReader.readCurrent(isExcludedBundleID: isExcludedBundleID) else { return }

        // Timer 在主 RunLoop 上，此处必然已在主线程；assumeIsolated 仅做隔离声明，不切线程
        MainActor.assumeIsolated {
            onNewContent?(item)
        }
    }
}
