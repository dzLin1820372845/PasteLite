import SwiftUI
import AppKit

/// 设置窗口单页表单。权限状态只在窗口成为 key 时刷新：用户从系统设置授权返回必然重新聚焦本窗口，
/// 无须轮询 AXIsProcessTrusted。
struct SettingsView: View {
    @ObservedObject private var settings: SettingsStore
    private let store: ClipboardStore

    @State private var accessibilityGranted = false
    @State private var showClearConfirm = false

    init(settings: SettingsStore, store: ClipboardStore) {
        self.settings = settings
        self.store = store
    }

    var body: some View {
        Form {
            Section("权限") {
                permissionRow
            }
            Section("快捷键") {
                HotKeyRecorderView(settings: settings)
            }
            Section("历史") {
                Picker("历史上限", selection: $settings.capacity) {
                    ForEach(Self.capacityOptions, id: \.self) { value in
                        Text("\(value) 条").tag(value)
                    }
                }
                Button("清空全部历史…", role: .destructive) {
                    showClearConfirm = true
                }
            }
            Section("排除的应用") {
                ExcludedAppsEditor(excludedBundleIDs: $settings.excludedBundleIDs)
            }
            Section("通用") {
                Toggle("登录时启动 PasteLite", isOn: $settings.launchAtLogin)
            }
        }
        .padding()
        .frame(width: 460)
        .alert("确认清空全部历史？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                store.clearAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有剪贴板记录（含已置顶项），操作不可恢复。")
        }
        .onAppear {
            accessibilityGranted = PasteEngine.isAccessibilityGranted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            accessibilityGranted = PasteEngine.isAccessibilityGranted()
        }
    }

    private static let capacityOptions = Array(stride(from: 50, through: 1000, by: 50))

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accessibilityGranted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("辅助功能")
                Text(accessibilityGranted ? "已授权，点击卡片即可自动粘贴" : "未授权，粘贴将降级为仅回填剪贴板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开系统设置") {
                // 仅打开授权面板，不代点任何授权控件
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// 快捷键录制器。展示态点击进入录制；局部 monitor 只拦截发往本设置窗口的 keyDown，
/// 窗口失焦即自然中断，无须全局监听。
private struct HotKeyRecorderView: View {
    @ObservedObject var settings: SettingsStore

    @State private var isRecording = false
    @State private var monitorToken: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isRecording {
                    stopRecording(cancel: true)
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "请按下新的组合键…" : displayCombo)
                    .frame(minWidth: 180)
            }
            Text(isRecording ? "按 Esc 取消；组合键需包含 ⌘ / ⌃ / ⌥ / ⇧ 至少一个修饰键" : "点击后按下组合键以修改唤起抽屉的快捷键")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear {
            stopRecording(cancel: true)
        }
    }

    private var displayCombo: String {
        Self.symbol(for: settings.hotKeyModifiers) + Self.keyGlyph(for: settings.hotKeyCode)
    }

    private func startRecording() {
        isRecording = true
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc（keyCode 53）约定为取消录制
            if event.keyCode == 53 {
                stopRecording(cancel: true)
                return nil
            }
            let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
            // 纯字母/数字键注册为全局热键会干扰所有应用内的正常输入，必须带修饰键才接受
            guard carbonModifiers != 0 else { return event }
            settings.hotKeyCode = UInt32(event.keyCode)
            settings.hotKeyModifiers = carbonModifiers
            stopRecording(cancel: false)
            return nil // 已消费的 keyDown 不再下发，避免录制键漏进输入框
        }
    }

    private func stopRecording(cancel: Bool) {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
        isRecording = false
    }

    /// NSEvent 掩码转 Carbon 掩码（cmdKey=0x0100 shiftKey=0x0200 optionKey=0x0800 controlKey=0x1000）
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= 0x0100 }
        if flags.contains(.shift) { carbon |= 0x0200 }
        if flags.contains(.option) { carbon |= 0x0800 }
        if flags.contains(.control) { carbon |= 0x1000 }
        return carbon
    }

    private static func symbol(for carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & 0x1000 != 0 { symbols += "⌃" }
        if carbonModifiers & 0x0800 != 0 { symbols += "⌥" }
        if carbonModifiers & 0x0200 != 0 { symbols += "⇧" }
        if carbonModifiers & 0x0100 != 0 { symbols += "⌘" }
        return symbols
    }

    /// 常用键的字形映射；未收录键码回退为「键 N」，保证录制结果始终可读
    private static func keyGlyph(for keyCode: UInt32) -> String {
        let glyphs: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "␣",
            51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return glyphs[keyCode] ?? "键 \(keyCode)"
    }
}

/// 排除应用列表增删。列表存 bundle ID 原文（持久化与匹配的真实键），
/// 展示名仅作辅助，找不到对应应用时直接展示 ID。
private struct ExcludedAppsEditor: View {
    @Binding var excludedBundleIDs: [String]

    @State private var draftBundleID = ""

    var body: some View {
        List {
            ForEach(excludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: bundleID))
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除") {
                        excludedBundleIDs.removeAll { $0 == bundleID }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(height: 160)
        HStack {
            TextField("输入 Bundle ID，如 com.example.app", text: $draftBundleID)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addDraft)
            Button("添加", action: addDraft)
        }
    }

    private func addDraft() {
        let trimmed = draftBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !excludedBundleIDs.contains(trimmed) else { return }
        excludedBundleIDs.append(trimmed)
        draftBundleID = ""
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
