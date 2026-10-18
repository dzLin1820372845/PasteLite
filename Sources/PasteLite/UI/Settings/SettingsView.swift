import SwiftUI
import AppKit

/// 设置窗口：用分栏承载独立设置任务，避免把所有控制项压在同一张表单中。
/// 业务状态仍由 SettingsStore 与 ClipboardStore 持有，本视图只负责呈现与交互编排。
struct SettingsView: View {
    @ObservedObject private var settings: SettingsStore
    private let store: ClipboardStore

    @State private var selectedPage: SettingsPage? = .general
    @State private var accessibilityGranted = false
    @State private var showClearConfirm = false

    init(settings: SettingsStore, store: ClipboardStore) {
        self.settings = settings
        self.store = store
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selectedPage, accessibilityGranted: accessibilityGranted)
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            detailView
        }
        .frame(minWidth: 700, minHeight: 480)
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
            refreshAccessibilityStatus()
        }
        // 从系统设置返回时，窗口不一定会再次触发 didBecomeKey；短轮询只在设置窗口存活期间运行，
        // 用来捕捉 TCC 授权的异步变化，避免用户已经点允许但界面继续显示旧状态。
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshAccessibilityStatus()
        }
    }

    private func refreshAccessibilityStatus() {
        accessibilityGranted = PasteEngine.isAccessibilityGranted()
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPage ?? .general {
        case .general:
            GeneralSettingsPage(accessibilityGranted: accessibilityGranted, settings: settings)
        case .hotKey:
            HotKeySettingsPage(settings: settings)
        case .history:
            HistorySettingsPage(settings: settings, showClearConfirm: $showClearConfirm)
        case .privacy:
            PrivacySettingsPage(excludedBundleIDs: $settings.excludedBundleIDs)
        }
    }
}

private enum SettingsPage: String, CaseIterable, Hashable {
    case general
    case hotKey
    case history
    case privacy

    var title: String {
        switch self {
        case .general: return "常规"
        case .hotKey: return "快捷键"
        case .history: return "历史"
        case .privacy: return "隐私"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "启动与权限"
        case .hotKey: return "唤起抽屉"
        case .history: return "容量与清理"
        case .privacy: return "排除应用"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .hotKey: return "command"
        case .history: return "clock"
        case .privacy: return "hand.raised"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage?
    let accessibilityGranted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                PasteLiteLogoView(size: 34)
                Text("PasteLite")
                    .font(.title3.weight(.semibold))
                Text("菜单栏剪贴板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(selection: $selection) {
                Section("设置") {
                    ForEach(SettingsPage.allCases, id: \.self) { page in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(page.title)
                                Text(page.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: page.systemImage)
                                .frame(width: 20)
                        }
                        .tag(page)
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                Circle()
                    .fill(accessibilityGranted ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(accessibilityGranted ? "辅助功能已授权" : "需要辅助功能授权")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PasteLiteLogoView: View {
    let size: CGFloat

    var body: some View {
        if let image = PasteLiteBranding.templateImage(size: size) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "clipboard.fill")
                .font(.system(size: size * 0.75, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: size, height: size)
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct GeneralSettingsPage: View {
    let accessibilityGranted: Bool
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(title: "常规", subtitle: "控制 PasteLite 的启动方式与系统权限", systemImage: "gearshape")

                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(accessibilityGranted ? Color.green : Color.orange)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("辅助功能")
                                    .font(.headline)
                                StatusBadge(text: accessibilityGranted ? "已授权" : "需要授权",
                                            color: accessibilityGranted ? .green : .orange)
                            }
                            Text(accessibilityGranted
                                 ? "点击历史卡片即可自动粘贴到当前应用。"
                                 : "授权后，PasteLite 才能替你向当前应用发送粘贴快捷键。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                openAccessibilitySettings()
                            } label: {
                                Label("打开系统设置", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }
                }

                SettingsCard {
                    Toggle(isOn: $settings.launchAtLogin) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("登录时启动 PasteLite")
                                .font(.headline)
                            Text("登录 macOS 后自动在菜单栏运行。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("剪贴板访问")
                                .font(.headline)
                            Text("首次读取其他应用的剪贴板内容时，macOS 可能会请求剪贴板访问权限。历史记录只保存在本机。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct HotKeySettingsPage: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(title: "快捷键", subtitle: "设置唤起剪贴板抽屉的全局组合键", systemImage: "command")
                SettingsCard {
                    HotKeyRecorderView(settings: settings)
                }
                Text("组合键必须包含 ⌘、⌃、⌥ 或 ⇧ 中至少一个修饰键。按 Esc 可以取消录制。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            .padding(24)
        }
    }
}

/// 快捷键录制器。局部 monitor 只拦截发往本设置窗口的 keyDown，窗口失焦即自然中断。
private struct HotKeyRecorderView: View {
    @ObservedObject var settings: SettingsStore

    @State private var isRecording = false
    @State private var monitorToken: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("唤起抽屉")
                        .font(.headline)
                    Text(isRecording ? "按下新的组合键，或按 Esc 取消" : "点击下方按键后录制新的组合键")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRecording ? "取消" : "修改") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                if isRecording {
                    Text("请按下新的组合键…")
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    KeyCapsView(caps: keyCaps)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isRecording ? 2 : 1)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var keyCaps: [String] {
        Self.symbols(for: settings.hotKeyModifiers) + [Self.keyGlyph(for: settings.hotKeyCode)]
    }

    private func startRecording() {
        isRecording = true
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
            guard carbonModifiers != 0 else { return event }
            settings.hotKeyCode = UInt32(event.keyCode)
            settings.hotKeyModifiers = carbonModifiers
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
        isRecording = false
    }

    /// NSEvent 掩码转 Carbon 掩码（cmdKey=0x0100 shiftKey=0x0200 optionKey=0x0800 controlKey=0x1000）。
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= 0x0100 }
        if flags.contains(.shift) { carbon |= 0x0200 }
        if flags.contains(.option) { carbon |= 0x0800 }
        if flags.contains(.control) { carbon |= 0x1000 }
        return carbon
    }

    private static func symbols(for carbonModifiers: UInt32) -> [String] {
        var symbols: [String] = []
        if carbonModifiers & 0x1000 != 0 { symbols.append("⌃") }
        if carbonModifiers & 0x0800 != 0 { symbols.append("⌥") }
        if carbonModifiers & 0x0200 != 0 { symbols.append("⇧") }
        if carbonModifiers & 0x0100 != 0 { symbols.append("⌘") }
        return symbols
    }

    /// 常用键的字形映射；未收录键码回退为「键 N」，保证录制结果始终可读。
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

private struct KeyCapsView: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(minWidth: 34, minHeight: 30)
                    .padding(.horizontal, 4)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                    }
            }
        }
    }
}

private struct HistorySettingsPage: View {
    @ObservedObject var settings: SettingsStore
    @Binding var showClearConfirm: Bool

    private static let capacityOptions = Array(stride(from: 50, through: 1000, by: 50))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(title: "历史", subtitle: "控制本地剪贴板记录的容量与清理", systemImage: "clock")

                SettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("历史上限")
                                    .font(.headline)
                                Text("超出上限后，会优先淘汰最早的未置顶记录。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("历史上限", selection: $settings.capacity) {
                                ForEach(Self.capacityOptions, id: \.self) { value in
                                    Text("\(value) 条").tag(value)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        Text("当前最多保存 \(settings.capacity) 条记录")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }

                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "trash")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("清空全部历史")
                                .font(.headline)
                            Text("删除所有剪贴板记录，包括已置顶项。此操作不可恢复。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("清空历史…", role: .destructive) {
                            showClearConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct PrivacySettingsPage: View {
    @Binding var excludedBundleIDs: [String]
    @State private var draftBundleID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(title: "隐私", subtitle: "选择不写入剪贴板历史的应用", systemImage: "hand.raised")

                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("排除的应用")
                                .font(.headline)
                            Spacer()
                            Text("\(excludedBundleIDs.count) 个")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if excludedBundleIDs.isEmpty {
                            EmptyStateView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(excludedBundleIDs, id: \.self) { bundleID in
                                    ExcludedAppRow(bundleID: bundleID) {
                                        excludedBundleIDs.removeAll { $0 == bundleID }
                                    }
                                    if bundleID != excludedBundleIDs.last {
                                        Divider().padding(.leading, 44)
                                    }
                                }
                            }
                        }

                        Divider()
                        HStack(spacing: 8) {
                            TextField("输入 Bundle ID，如 com.example.app", text: $draftBundleID)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addDraft)
                            Button("添加", action: addDraft)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(draftBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("密码管理器等敏感应用建议加入排除列表，避免凭据进入本地历史。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private func addDraft() {
        let trimmed = draftBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !excludedBundleIDs.contains(trimmed) else { return }
        excludedBundleIDs.append(trimmed)
        draftBundleID = ""
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("暂无排除应用")
                .font(.headline)
            Text("来自所有应用的复制内容都会进入历史。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.weight(.medium))
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("删除", action: onDelete)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.vertical, 7)
    }

    private var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let applicationURL else { return bundleID }
        return FileManager.default.displayName(atPath: applicationURL.path)
    }

    private var appIcon: NSImage {
        guard let applicationURL else { return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}
