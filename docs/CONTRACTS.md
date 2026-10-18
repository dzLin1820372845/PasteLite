# PasteLite 模块契约

多代理并行开发的接口对齐文件。**共享类型签名以下文为准，任何偏差都会导致集成失败。**

## 文件归属（严格隔离，越界即事故）

| 代理 | 名下文件 |
|---|---|
| A 模型与存储 | `Sources/PasteLite/Models/ClipboardItem.swift` · `Sources/PasteLite/Store/ClipboardStore.swift` · `Sources/PasteLite/Store/Persistence.swift` |
| B 剪贴板监听 | `Sources/PasteLite/Monitor/ClipboardMonitor.swift`（可加 `Monitor/ClipboardReader.swift`） |
| C 粘贴引擎 | `Sources/PasteLite/Paste/PasteEngine.swift` |
| D 抽屉 UI | `Sources/PasteLite/UI/Drawer/DrawerController.swift` · `DrawerView.swift` · `CardView.swift` |
| E 设置与快捷键 | `Sources/PasteLite/HotKey/HotKeyManager.swift` · `Sources/PasteLite/UI/Settings/SettingsStore.swift` · `SettingsView.swift` |
| 集成 | `Sources/PasteLite/App/PasteLiteApp.swift` · `App/MenuBarController.swift`（允许修任何编译阻塞点） |

## 共享类型（签名逐字为准）

```swift
// Models/ClipboardItem.swift —— A 拥有，其他人只消费
enum ClipboardContentKind: String, Codable { case text, richText, image, file }

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipboardContentKind
    var plainText: String            // 搜索与纯文本粘贴兜底；text 时为全文；file 时为换行连接的路径串
    var rtfData: Data?               // richText 的 RTF
    var htmlData: Data?
    var imageData: Data?             // 图片二进制（PNG 优先，转换失败存原始 TIFF）
    var filePaths: [String]?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var pinnedAt: Date?              // nil = 未置顶
    var dedupKey: String             // image → 图片数据 SHA256；其余 → plainText
}
```

```swift
// Store/ClipboardStore.swift —— A 拥有
@MainActor final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem]   // 置顶组最前(pinnedAt 降序)，其余 createdAt 降序
    var capacity: Int                                    // 默认 100；set 后按上限淘汰最旧未置顶
    init(persistence: Persistence)
    func record(_ item: ClipboardItem)   // dedupKey 相同→更新并移到最前(不新建)；超容量 FIFO；触发落盘
    func togglePin(_ id: UUID)
    func delete(_ id: UUID)
    func clearAll()                      // 清内存 + 清落盘
    func items(matching query: String) -> [ClipboardItem]   // plainText 大小写不敏感包含
}

// Store/Persistence.swift —— A 拥有
final class Persistence {
    init(directory: URL)                 // 默认 ~/Library/Application Support/PasteLite，不存在则建
    func load() -> [ClipboardItem]       // 读 history.json，blob 字段从 <uuid>.png/.rtf/.html 文件回填
    func save(_ items: [ClipboardItem])  // 全量重写 index；blob 字段编码为文件、不进 JSON
    func clearAll()
}
```

```swift
// Monitor/ClipboardMonitor.swift —— B 拥有
final class ClipboardMonitor {
    var onNewContent: (@MainActor (ClipboardItem) -> Void)?
    var isExcludedBundleID: ((String) -> Bool)?   // 命中则本次复制不入库
    func start()   // 0.5s Timer 轮询 NSPasteboard.general.changeCount；首帧只记基线不读取
    func stop()
}
```

```swift
// Paste/PasteEngine.swift —— C 拥有
enum PasteOutcome { case pasted, clipboardFilledOnly }
final class PasteEngine {
    /// 回填系统剪贴板；辅助功能已授权则合成 Cmd+V 发给前台应用
    func paste(_ item: ClipboardItem, asPlainText: Bool) -> PasteOutcome
    static func isAccessibilityGranted() -> Bool   // AXIsProcessTrusted()
}
```

```swift
// HotKey/HotKeyManager.swift —— E 拥有
final class HotKeyManager {
    var onHotKey: (() -> Void)?    // 主线程回调
    /// Carbon RegisterEventHotKey；先注销旧注册再注册新的
    func register(keyCode: UInt32, modifiers: UInt32)   // modifiers 为 Carbon 掩码
}
```

```swift
// UI/Drawer/DrawerController.swift —— D 拥有
@MainActor final class DrawerController: ObservableObject {
    var isVisible: Bool { get }
    init(store: ClipboardStore,
         onPaste: @escaping (ClipboardItem, Bool) -> PasteOutcome)   // (条目, 是否纯文本)
    func toggle()   // 隐藏→定位鼠标所在屏底部滑出；可见→收起
    func hide()
}

// UI/Settings/SettingsStore.swift —— E 拥有
@MainActor final class SettingsStore: ObservableObject {
    @Published var hotKeyCode: UInt32           // 默认 9（kVK_ANSI_V）
    @Published var hotKeyModifiers: UInt32      // 默认 cmdKey|shiftKey = 0x0300
    @Published var capacity: Int                // 50...1000，默认 100；didSet 同步 store.capacity
    @Published var excludedBundleIDs: [String]  // 预置 1Password/KeePassXC/钥匙串访问
    @Published var launchAtLogin: Bool          // didSet 走 SMAppService.mainApp
    init(store: ClipboardStore)                 // 初值读 UserDefaults；didSet 持久化
}

// UI/Settings/SettingsView.swift —— E 拥有
struct SettingsView: View {
    init(settings: SettingsStore, store: ClipboardStore)   // 清空历史按钮调 store.clearAll()
}
```

## 数据流（集成代理装配）

1. `monitor.onNewContent` → `store.record(item)`
2. `monitor.isExcludedBundleID` ← `settings.excludedBundleIDs.contains($0)`
3. `hotKey.onHotKey` → `drawer.toggle()`
4. 卡片点击（D 内部）→ **先同步收起面板（orderOut 离屏，不走带动画的 `hide()`）** → `onPaste(item, optionPressed)`
5. `settings.$hotKeyCode` + `$hotKeyModifiers` 变化 → `hotKeyManager.register(...)` 重注册
6. 菜单栏：打开抽屉 / 设置… / 退出；首次启动未授权辅助功能 → 自动打开设置窗口

## 全局规则

- 零外部依赖，只用系统框架；SwiftPM 构建（`swift-tools-version: 5.9`），构建统一走 `./build.sh`。Release 构建分别生成 arm64/x86_64 后合并 Universal，并组装 DMG。
- UI 文案一律中文；注释只写业务意图/边界/非直觉实现，禁复述式注释
- 模块代理**不得做任何全量编译/构建**（他人文件未就绪）；可用 Swift 编译器的语法检查能力自检单文件。
- **粘贴顺序红线**：D 必须先让面板真正离屏（同步 orderOut；`hide()` 的收起动画期间面板仍是 key window）再触发 `onPaste`，保证合成 Cmd+V 落到目标应用
- **焦点红线**：抽屉是 `.nonactivatingPanel`，任何代码不得调用 `NSApp.activate`——目标应用必须保持前台
- **自写回环**：粘贴回填会触发 changeCount 变化 → monitor 再读 → dedupKey 命中既有记录仅移最前，行为良性，**禁止**为此加抑制逻辑

## 已定 UI 参数（2026-10-15 UI 重塑，PasteLite 视觉规范；D/E 在此范围内自由发挥）

- 抽屉：高=屏高 30%，左右边距各 12pt，底部悬浮（visibleFrame 上方）32pt，圆角 22pt；背景 NSVisualEffectView `.sidebar` 材质（behindWindow vibrancy，浅色白半透明透壁纸/深色近黑玻璃）
- 工具栏：高 48pt，居中胶囊搜索框（高 30pt、宽上限 460pt、底色 primary 6% 透明度）+ magnifyingglass 图标
- 卡片：宽 240pt，高=卡片区实测可用高度（GeometryReader 传入，约 200–256pt，近方形观感），间距 16pt，圆角 14pt；正文底色 `controlBackgroundColor`（浅色白底/深色炭黑底）
- 彩色头带：高=卡片 22%；文本=蓝、富文本=紫、图片=红、文件=橙（系统色相，深浅色自动微调）；白色 semibold 15pt 类型名 + 70% 白 11pt 相对时间（刚刚/N 分钟前/今天 HH:mm/昨天/更早）；来源应用图标 26pt 圆角方形居头带右端，查不到省略
- 预览：文本/富文本 13pt ≤6 行（富文本按 RTF 样式渲染）；图片卡满铺裁切 + 右下白色 80% 尺寸胶囊（像素尺寸）；文件卡 52pt 图标 + 粗体 13pt 文件名 + 11pt 灰路径（中段截断）；脚注 11pt 次要灰居中「N 个字符 / N 个文件」
- 悬停：卡片上浮 3pt + 投影加深 + 5% 白提亮；置顶/删除为 24pt 白色半透明圆形玻璃按钮（SF Symbol）
- 动效：滑出 0.3s、timing function controlPoints(0.22, 1.12, 0.36, 1.0)（轻过冲弹簧感）；收起 0.18s easeIn
- 搜索框占位：「搜索剪贴板历史」；空历史占位：「暂无复制记录 / 复制内容后自动收集」；无匹配占位：「无匹配结果 / 换个关键词试试」（均居中 + 大号 SF Symbol）
- 卡片 hover 工具条：置顶/取消置顶、删除；右键菜单：复制、置顶切换、删除
- 排除列表默认：`com.1password.1password`（1Password）、`org.keepassxc.KeePassXC`（KeePassXC）、`com.apple.keychainaccess`（钥匙串访问）
- Carbon 掩码参考：cmdKey=0x0100、shiftKey=0x0200、optionKey=0x0800、controlKey=0x1000；kVK_ANSI_V=9
