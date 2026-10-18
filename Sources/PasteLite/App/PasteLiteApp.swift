import AppKit
import Combine

/// 应用入口与装配根：创建全部组件、按契约接线并强持有直至进程退出。
/// 形态红线：菜单栏常驻应用——Info.plist `LSUIElement=1` 为主保险，
/// didFinishLaunching 里 `setActivationPolicy(.accessory)` 为双保险（覆盖不经 bundle 直接运行二进制的场景）。
@main
@MainActor
final class PasteLiteApp: NSObject, NSApplicationDelegate {

    /// 单实例保护的通知名：检测到已有实例时的"再次启动"请求，转发给已有实例弹抽屉
    private static let showDrawerNotification = Notification.Name("com.tclx.pastelite.showDrawer")

    /// AppKit 引导：先做单实例检查，再建 NSApplication 与委托进入事件循环；
    /// 全部装配在 applicationDidFinishLaunching（主线程、AppKit 就绪）完成。
    static func main() {
        // 单实例保护：双实例 = 双状态栏图标 + 两个轮询定时器写同一份持久化文件（互相覆盖）。
        // 已有实例在跑时，通知它弹出抽屉（对用户而言"再次启动"=再次唤起）并退出自己
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tclx.pastelite"
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !existing.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showDrawerNotification, object: nil,
                userInfo: nil, deliverImmediately: true)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = PasteLiteApp()
        app.delegate = delegate
        app.run()
    }

    /// 装配根强持有：monitor 的轮询定时器、hotKeyManager 的热键句柄、menuBarController 的
    /// NSStatusItem 都依赖引用链存活，任何一环被释放对应功能即静默失效。
    private var settings: SettingsStore?
    private var store: ClipboardStore?
    private var monitor: ClipboardMonitor?
    private var engine: PasteEngine?
    private var drawer: DrawerController?
    private var hotKeyManager: HotKeyManager?
    private var menuBarController: MenuBarController?

    private var cancellables: Set<AnyCancellable> = []

    /// 信号源需强持有：释放后信号回退默认终止行为
    private var signalSources: [DispatchSourceSignal] = []

    /// block 观察者令牌需强持有，释放即注销
    private var showDrawerObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 装配链：Persistence → store → settings → engine → drawer → monitor → hotKey → 菜单栏
        let store = ClipboardStore(persistence: Persistence())
        let settings = SettingsStore(store: store)

        let engine = PasteEngine()
        // 抽屉点击后 D 已同步离屏面板再回调，这里直接交给引擎回填+合成按键
        let drawer = DrawerController(store: store, onPaste: engine.paste)

        let monitor = ClipboardMonitor()
        monitor.onNewContent = { item in store.record(item) }
        // 轮询定时器挂在主 RunLoop，回调必然在主线程，assumeIsolated 断言成立；
        // 该闭包发生在读内容之前，被排除来源零读取、不触发授权弹窗
        monitor.isExcludedBundleID = { bundleID in
            MainActor.assumeIsolated {
                settings.excludedBundleIDs.contains(bundleID)
            }
        }

        let hotKeyManager = HotKeyManager()
        hotKeyManager.onHotKey = {
            // HotKeyManager 内部经 DispatchQueue.main 派发回调，此处运行在主线程
            MainActor.assumeIsolated {
                drawer.toggle()
            }
        }
        // 初值注册；后续变更由 Combine 订阅重注册
        hotKeyManager.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)

        // 热键设置变更 → 重注册；combineLatest 订阅即发当前值，初值已手动注册过，跳过首帧
        settings.$hotKeyCode
            .combineLatest(settings.$hotKeyModifiers)
            .dropFirst()
            .sink { [weak hotKeyManager] keyCode, modifiers in
                hotKeyManager?.register(keyCode: keyCode, modifiers: modifiers)
            }
            .store(in: &cancellables)

        monitor.start()

        let menuBarController = MenuBarController(settings: settings, store: store, drawer: drawer)

        self.settings = settings
        self.store = store
        self.monitor = monitor
        self.engine = engine
        self.drawer = drawer
        self.hotKeyManager = hotKeyManager
        self.menuBarController = menuBarController

        installSignalHandlers()
        observeShowDrawerRequest()
    }

    // MARK: - 信号与重复启动

    /// 优雅退出：pkill(SIGTERM)/Ctrl+C(SIGINT) 默认直接终止、不走 AppKit 清理，
    /// 菜单栏会残留"僵尸图标"残影；接管信号转 NSApp.terminate 走正常退出路径，图标随进程干净移除
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)   // 置忽略后由 DispatchSource 接管
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 收到"再次启动"通知（来自单实例检查中的新进程）→ 唤起抽屉
    private func observeShowDrawerRequest() {
        let drawer = self.drawer
        showDrawerObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.showDrawerNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { drawer?.toggle() }
        }
    }
}
