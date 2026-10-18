import Foundation
import ServiceManagement

/// 设置项中枢：五个设置的全部读写都经此，didSet 统一落 UserDefaults；
/// init 只读不写（初始化赋值不触发属性观察器），持久化值在下次变更时自然覆盖。
@MainActor final class SettingsStore: ObservableObject {
    static let defaultCapacity = 100

    @Published var hotKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotKeyCode), forKey: Self.hotKeyCodeKey) }
    }
    @Published var hotKeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotKeyModifiers), forKey: Self.hotKeyModifiersKey) }
    }
    @Published var numberSelectionModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(numberSelectionModifiers), forKey: Self.numberSelectionModifiersKey) }
    }
    /// 历史上限；didSet 同步进 store.capacity 使淘汰立即生效（落盘持久化由 store 侧负责）
    @Published var capacity: Int {
        didSet {
            UserDefaults.standard.set(capacity, forKey: Self.capacityKey)
            store.capacity = capacity
        }
    }
    /// 排除列表存 bundle ID 原文；展示名由设置界面按需解析，删除预置项后不会随重启回归
    @Published var excludedBundleIDs: [String] {
        didSet { UserDefaults.standard.set(excludedBundleIDs, forKey: Self.excludedKey) }
    }
    /// SMAppService 注册状态本身跨启动持久，didSet 只在开关切换时增删注册，失败仅记日志
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Self.launchAtLoginKey)
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // 开机自启失败不影响主功能（如 AppTranslocation 环境会拒绝注册），不崩
                NSLog("PasteLite 开机自启设置失败: \(error.localizedDescription)")
            }
        }
    }

    private let store: ClipboardStore

    private static let hotKeyCodeKey = "hotKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let numberSelectionModifiersKey = "numberSelectionModifiers"
    private static let capacityKey = "capacity"
    private static let excludedKey = "excludedBundleIDs"
    private static let launchAtLoginKey = "launchAtLogin"

    /// 默认排除的密码管理器：命中其复制不入库，防止凭据落入历史与落盘文件
    static let presetExcludedBundleIDs = [
        "com.1password.1password",
        "org.keepassxc.KeePassXC",
        "com.apple.keychainaccess"
    ]

    init(store: ClipboardStore) {
        self.store = store
        let defaults = UserDefaults.standard

        let storedCode = defaults.object(forKey: Self.hotKeyCodeKey) as? Int
        self.hotKeyCode = UInt32(storedCode ?? 9) // 9 = kVK_ANSI_V

        let storedModifiers = defaults.object(forKey: Self.hotKeyModifiersKey) as? Int
        self.hotKeyModifiers = UInt32(storedModifiers ?? 0x0300) // cmdKey|shiftKey

        let storedNumberModifiers = defaults.object(forKey: Self.numberSelectionModifiersKey) as? Int
        let numberModifiers = UInt32(storedNumberModifiers ?? Int(NumberSelectionShortcut.defaultModifiers))
        self.numberSelectionModifiers = NumberSelectionShortcut.modifierOptions.contains(numberModifiers)
            ? numberModifiers
            : NumberSelectionShortcut.defaultModifiers

        let storedCapacity = defaults.object(forKey: Self.capacityKey) as? Int ?? Self.defaultCapacity
        self.capacity = min(max(storedCapacity, 50), 1000)

        let storedExcluded = defaults.stringArray(forKey: Self.excludedKey)
        self.excludedBundleIDs = storedExcluded ?? Self.presetExcludedBundleIDs

        self.launchAtLogin = defaults.bool(forKey: Self.launchAtLoginKey)

        // init 内赋值不触发 didSet，容量初值在此显式同步进 store（后续变更由 capacity.didSet 负责）
        store.capacity = capacity
    }
}
