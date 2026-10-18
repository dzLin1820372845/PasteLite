import AppKit
import SwiftUI

/// 菜单栏常驻入口：状态栏图标 + 菜单（打开抽屉 / 设置… / 退出），并持有设置窗口单例。
/// NSStatusItem 必须被强引用（本控制器持有，控制器由应用委托持有），否则图标立即消失。
@MainActor
final class MenuBarController: NSObject {

    private let settings: SettingsStore
    private let store: ClipboardStore
    private let drawer: DrawerController

    /// 强持有防图标消失（NSStatusBar 不保留无引用的 status item）
    private let statusItem: NSStatusItem

    /// 设置窗口单例：只建一次，复用同一窗口（位置/状态保留）；
    /// isReleasedWhenClosed 必须关闭，否则点红点关闭后窗口对象被释放、本引用悬空
    private var settingsWindow: NSWindow?

    private static let accessibilityGuideShownKey = "accessibilityGuideShown"

    init(settings: SettingsStore, store: ClipboardStore, drawer: DrawerController) {
        self.settings = settings
        self.store = store
        self.drawer = drawer
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureButton()
        configureMenu()
        guideAccessibilityOnFirstLaunch()
    }

    // MARK: - 菜单栏

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "PasteLite")
        icon?.isTemplate = true   // 模板图：菜单栏明暗模式自动反色
        button.image = icon
    }

    private func configureMenu() {
        let menu = NSMenu()

        let drawerItem = NSMenuItem(title: "打开抽屉", action: #selector(openDrawer), keyEquivalent: "")
        drawerItem.target = self
        menu.addItem(drawerItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // target 置空走响应链，terminate: 由 NSApplication 自身实现
        menu.addItem(NSMenuItem(title: "退出 PasteLite",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// 首次启动引导：辅助功能未授权时自动打开设置窗口，指向授权入口（仅首次；
    /// 授权与否由用户在系统设置完成，之后可随时从菜单打开设置查看权限状态）
    private func guideAccessibilityOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.accessibilityGuideShownKey),
              !PasteEngine.isAccessibilityGranted() else { return }
        UserDefaults.standard.set(true, forKey: Self.accessibilityGuideShownKey)
        openSettings()
    }

    // MARK: - 动作

    @objc private func openDrawer() {
        guard !drawer.isVisible else { return }
        drawer.toggle()
    }

    @objc private func openSettings() {
        makeSettingsWindowIfNeeded()
        // 设置窗口需要键盘焦点（快捷键录制、排除列表编辑）。焦点红线约束的是抽屉/粘贴路径
        // （DrawerController 全程未用 activate，目标应用保持前台）；此处是用户主动打开设置窗口的正常激活
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowIfNeeded() {
        guard settingsWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "PasteLite 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, store: store))
        window.center()
        settingsWindow = window
    }
}
