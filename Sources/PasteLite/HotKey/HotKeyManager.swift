import Carbon.HIToolbox
import Foundation

/// 全局快捷键管理。用 Carbon RegisterEventHotKey 而非 NSEvent 全局监听：
/// 抽屉唤起发生在目标应用前台时，系统级热键注册不依赖本应用激活状态，且无须辅助功能授权。
/// EventHotKeyRef 必须由 self 强持有，句柄被释放会导致热键静默失效。
final class HotKeyManager {
    /// 热键触发回调。Carbon 事件在主 RunLoop 派发，此处再显式派发主线程，保证消费方无须关心线程
    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// InstallEventHandler 的 userData 需要一个越过 ARC 的 self 指针，登记在此以便 deinit 归还
    private var retainedSelf: Unmanaged<HotKeyManager>?
    /// 四字符签名用于在共享回调里识别本应用注册的热键，避免响应他人的 kEventClassKeyboard 事件
    private static let hotKeySignature: FourCharCode = {
        let chars = Array("PLhk".utf8)
        return (FourCharCode(chars[0]) << 24) | (FourCharCode(chars[1]) << 16)
             | (FourCharCode(chars[2]) << 8) | FourCharCode(chars[3])
    }()

    init() {
        installHandlerIfNeeded()
    }

    deinit {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
        // hotKeyRef 不显式注销：进程退出时系统回收全部热键注册，主动注销反而可能与重装 handler 竞态
        retainedSelf?.release()
    }

    /// 注册全局热键。重复调用视为改键：先注销旧注册再注册新的，防止同一组合注册两份导致双触发
    /// - Parameters:
    ///   - keyCode: Carbon 虚拟键码（如 kVK_ANSI_V = 9）
    ///   - modifiers: Carbon 掩码（cmdKey=0x0100 shiftKey=0x0200 optionKey=0x0800 controlKey=0x1000）
    func register(keyCode: UInt32, modifiers: UInt32) {
        if let old = hotKeyRef {
            UnregisterEventHotKey(old)
            hotKeyRef = nil
        }
        installHandlerIfNeeded()

        let eventID = EventHotKeyID(signature: HotKeyManager.hotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            eventID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            // 典型失败：组合键已被其他应用占用。此时处于无热键状态，用户可在设置中改键重试，不崩溃
            NSLog("PasteLite 热键注册失败 OSStatus=%d", status)
            return
        }
        hotKeyRef = ref
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let unmanaged = Unmanaged.passRetained(self)
        retainedSelf = unmanaged

        var outRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var actualID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &actualID
                )
                // 只响应匹配签名的热键事件；应用级 target 理论上还可能收到其他键盘事件类
                if paramStatus == noErr,
                   actualID.signature == HotKeyManager.hotKeySignature {
                    DispatchQueue.main.async { manager.onHotKey?() }
                }
                return noErr
            },
            1,
            &eventType,
            unmanaged.toOpaque(),
            &outRef
        )
        guard status == noErr, let handler = outRef else {
            // 归还 passRetained 的引用，避免 self 永久泄漏
            retainedSelf?.release()
            retainedSelf = nil
            NSLog("PasteLite 热键事件 handler 安装失败 OSStatus=%d", status)
            return
        }
        eventHandler = handler
    }
}
