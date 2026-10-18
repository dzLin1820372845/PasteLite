import AppKit
import SwiftUI

/// 底部抽屉面板：无边框 + 非激活样式。弹出全程不激活本应用（焦点红线：不调用 NSApp.activate），目标应用保持前台
private final class DrawerPanel: NSPanel {
    // 无边框窗口默认不可成为 key；覆写让搜索框能接收键盘输入。
    // 配合 .nonactivatingPanel，收键不伴随应用激活
    override var canBecomeKey: Bool { true }
}

/// 抽屉内数字选卡快捷键的键码、修饰键和展示文案。
/// 修饰键只在抽屉已经打开时由本地事件监听处理，不注册为系统级热键。
enum NumberSelectionShortcut {
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000
    static let defaultModifiers = command

    static let modifierOptions: [UInt32] = [
        command, option, control, shift,
        command | option, command | control, command | shift,
        option | control, option | shift, control | shift,
        command | option | control, command | option | shift,
        command | control | shift, option | control | shift,
        command | option | control | shift
    ]

    private static let numberKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func index(for event: NSEvent, modifiers: UInt32) -> Int? {
        guard carbonModifiers(from: event.modifierFlags) == modifiers,
              let index = numberKeyCodes.firstIndex(of: event.keyCode) else { return nil }
        return index
    }

    static func label(for index: Int, modifiers: UInt32) -> String {
        "\(modifierSymbols(for: modifiers))\(index + 1)"
    }

    static func modifierLabel(for modifiers: UInt32) -> String {
        let names = [
            (command, "Command"),
            (option, "Option"),
            (control, "Control"),
            (shift, "Shift")
        ].compactMap { mask, name in modifiers & mask != 0 ? name : nil }
        return "\(modifierSymbols(for: modifiers))  \(names.joined(separator: " + "))"
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= command }
        if flags.contains(.shift) { modifiers |= shift }
        if flags.contains(.option) { modifiers |= option }
        if flags.contains(.control) { modifiers |= control }
        return modifiers
    }

    private static func modifierSymbols(for modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & control != 0 { symbols += "⌃" }
        if modifiers & option != 0 { symbols += "⌥" }
        if modifiers & shift != 0 { symbols += "⇧" }
        if modifiers & command != 0 { symbols += "⌘" }
        return symbols
    }
}

@MainActor
final class DrawerController: ObservableObject {
    var isVisible: Bool { panel.isVisible }
    var numberSelectionModifiers: UInt32 {
        didSet {
            guard NumberSelectionShortcut.modifierOptions.contains(numberSelectionModifiers) else {
                numberSelectionModifiers = oldValue
                return
            }
            hostingView.rootView = makeDrawerView(generation: showGeneration)
        }
    }

    private let store: ClipboardStore
    private let onPaste: (ClipboardItem, Bool) -> PasteOutcome
    private let panel: DrawerPanel
    private let hostingView: NSHostingView<DrawerView>
    private var displayedItems: [ClipboardItem] = []
    private var showGeneration = 0
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?

    init(store: ClipboardStore,
         onPaste: @escaping (ClipboardItem, Bool) -> PasteOutcome) {
        self.store = store
        self.onPaste = onPaste
        self.numberSelectionModifiers = NumberSelectionShortcut.defaultModifiers

        let panel = DrawerPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 非激活面板默认 hidesOnDeactivate=true，而本应用从不激活；必须关闭，
        // 否则任何其他应用前置时抽屉都会被动消失
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear   // 圆角与材质背景由 SwiftUI 绘制，窗口本体透明
        panel.hasShadow = true
        self.panel = panel

        // 逃逸闭包不能捕获未完成两段式初始化的 self：先以空回调占位，
        // self 完整初始化后立即换入真实回调（初始面板未显示，show() 唤出时也会重建 rootView）
        self.hostingView = NSHostingView(rootView: DrawerView(store: store,
                                                              generation: 0,
                                                              numberSelectionModifiers: NumberSelectionShortcut.defaultModifiers,
                                                              onSelect: { _ in },
                                                              onItemsChanged: { _ in }))
        panel.contentView = hostingView
        hostingView.rootView = makeDrawerView(generation: 0)
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitors()
        let dropFrame = panel.frame.offsetBy(dx: 0, dy: -panel.frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(dropFrame, display: true)
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    // MARK: - 私有实现

    /// 唤出：在鼠标所在屏幕底部悬浮（项目视觉规格——高约屏高 30%、左右边距 12pt、
    /// 贴 visibleFrame 上方 32pt 自动避 Dock），从屏外（下沉一个屏高）滑入
    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        let width = screen.frame.width - 24
        let height = screen.frame.height * 0.30
        let finalFrame = NSRect(x: screen.frame.midX - width / 2,
                                y: screen.visibleFrame.minY + 32,
                                width: width,
                                height: height)
        let initialFrame = finalFrame.offsetBy(dx: 0, dy: -screen.frame.height)

        // 每次唤出以递增 generation 重建内容：清空上次搜索词，并让搜索框重新聚焦
        showGeneration += 1
        displayedItems = []
        hostingView.rootView = makeDrawerView(generation: showGeneration)

        panel.setFrame(initialFrame, display: false)
        panel.orderFrontRegardless()   // 显示但不激活应用
        panel.makeKey()                // 非激活面板收键即可输入，不影响目标应用前台
        installMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            // 弹簧感缓动：末端轻微过冲再回落（y1 > 1），比纯 easeOut 更利落不拖沓
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.12, 0.36, 1.0)
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    /// 卡片点击统一入口。
    /// 红线：必须先让面板真正离屏再触发 onPaste。hide() 的收起是 0.18s 动画、orderOut
    /// 延迟到完成回调，期间面板仍是 key window（搜索框持有键盘焦点），合成 Cmd+V 会被
    /// 抽屉自身消费（回填内容贴进搜索框）而非目标应用——因此这里同步 orderOut。
    /// Option 按下时按纯文本/路径语义粘贴
    private func select(_ item: ClipboardItem, asPlainText: Bool? = nil) {
        let shouldPastePlainText = asPlainText ?? NSEvent.modifierFlags.contains(.option)
        removeMonitors()
        panel.orderOut(nil)
        _ = onPaste(item, shouldPastePlainText)
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        // Esc 关闭、数字快捷键选卡：只拦截发往本面板的按键，其他窗口不受影响。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 /* kVK_Escape */ {
                self.hide()
                return nil
            }
            guard let index = NumberSelectionShortcut.index(for: event,
                                                            modifiers: self.numberSelectionModifiers),
                  index < self.displayedItems.count else { return event }
            self.select(self.displayedItems[index], asPlainText: false)
            return nil
        }
        // 点击面板外关闭：应用未激活时点击其他应用窗口只有全局 monitor 能看到；
        // 命中点在面板 frame 外才收起，面板内点击交给 SwiftUI
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.hide()
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func makeDrawerView(generation: Int) -> DrawerView {
        DrawerView(store: store,
                   generation: generation,
                   numberSelectionModifiers: numberSelectionModifiers,
                   onSelect: { [weak self] item in
                       self?.select(item)
                   },
                   onItemsChanged: { [weak self] items in
                       self?.displayedItems = items
                   })
    }
}
