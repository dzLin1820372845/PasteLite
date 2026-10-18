import AppKit
import CoreGraphics

/// 抽屉打开期间的数字选卡事件拦截器。
/// 使用辅助功能权限下的 CGEventTap 读取系统键盘流，兼容不激活的 NSPanel；抽屉关闭后立即移除。
final class NumberSelectionHotKeyManager {
    var onHotKey: ((Int) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var modifiers: UInt32 = NumberSelectionShortcut.defaultModifiers
    private var isActive = false

    private static let keyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func register(modifiers: UInt32) {
        unregister()
        self.modifiers = modifiers

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<NumberSelectionHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handle(event: event, type: type)
            },
            userInfo: userInfo
        )

        guard let eventTap else {
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isActive = true
    }

    func unregister() {
        guard eventTap != nil || runLoopSource != nil else { return }
        isActive = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isActive, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let eventModifiers = Self.carbonModifiers(from: event.flags)
        guard eventModifiers == modifiers,
              let index = Self.keyCodes.firstIndex(of: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onHotKey?(index)
        }
        return nil
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= NumberSelectionShortcut.command }
        if flags.contains(.maskShift) { modifiers |= NumberSelectionShortcut.shift }
        if flags.contains(.maskAlternate) { modifiers |= NumberSelectionShortcut.option }
        if flags.contains(.maskControl) { modifiers |= NumberSelectionShortcut.control }
        return modifiers
    }
}
