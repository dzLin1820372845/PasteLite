import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// 粘贴结果。pasted = 已回填剪贴板并合成 Cmd+V；clipboardFilledOnly = 仅回填剪贴板
/// （系统"安全输入"拦截或辅助功能未授权时的降级结果，用户需手动 Cmd+V）。
enum PasteOutcome {
    case pasted
    case clipboardFilledOnly
}

/// 粘贴引擎：把历史条目回填系统剪贴板，条件允许时合成 Cmd+V 交给前台应用。
/// 调用边界：paste 须在主线程调用（NSPasteboard 与事件合成都按主线程时序处理），
/// 且调用方必须已收起抽屉，保证合成按键落到目标前台应用而非抽屉自身。
final class PasteEngine {

    /// 回填系统剪贴板；辅助功能已授权且当前无安全输入拦截时，进一步合成 Cmd+V 发给前台应用
    func paste(_ item: ClipboardItem, asPlainText: Bool) -> PasteOutcome {
        fillPasteboard(item, asPlainText: asPlainText)

        // 系统"安全输入"状态（密码框、sudo 提示等）下合成按键事件被系统拦截——
        // 此时剪贴板回填仍有效，但不再尝试自动粘贴
        if IsSecureEventInputEnabled() {
            return .clipboardFilledOnly
        }

        guard Self.isAccessibilityGranted() else {
            return .clipboardFilledOnly
        }

        synthesizeCommandV()
        return .pasted
    }

    /// 辅助功能授权状态，是合成按键事件的前提（系统设置 → 隐私与安全性 → 辅助功能）
    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - 私有实现

    /// 按条目类型回填剪贴板，写入的格式组合决定目标应用最终贴出的内容
    private func fillPasteboard(_ item: ClipboardItem, asPlainText: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 图片没有纯文本语义（plainText 恒为空串）：Option 点击忽略纯文本标记仍走图片回填，
        // 否则剪贴板被写成空串——目标应用贴不出任何内容，且回读会生成一条空文本垃圾记录
        if asPlainText, item.kind != .image {
            pasteboard.setString(item.plainText, forType: .string)
            return
        }

        switch item.kind {
        case .text:
            pasteboard.setString(item.plainText, forType: .string)
        case .richText:
            // RTF/HTML/纯文本三格式同写：文档类应用取 RTF 保格式，浏览器类取 HTML，
            // 不认格式的目标兜底取纯文本；单写任一格式都会丢失另一类目标的支持
            if let rtf = item.rtfData {
                pasteboard.setData(rtf, forType: .rtf)
            }
            if let html = item.htmlData {
                pasteboard.setData(html, forType: .html)
            }
            pasteboard.setString(item.plainText, forType: .string)
        case .image:
            guard let data = item.imageData else { break }
            // 存储侧 PNG 优先、转换失败存原始 TIFF；回填按数据魔数选对应类型原样写回，
            // 不经 NSImage 重编码，避免透明通道/压缩质量失真
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                pasteboard.setData(data, forType: .png)
            } else {
                pasteboard.setData(data, forType: .tiff)
            }
        case .file:
            // 文件 URL 数组走 writeObjects：多文件粘贴在 Finder/文件对话框等目标才能一次生效
            let urls = (item.filePaths ?? []).map { NSURL(fileURLWithPath: $0) }
            pasteboard.writeObjects(urls)
        }
    }

    /// 合成 Cmd+V 注入系统输入流。virtualKey 9 = kVK_ANSI_V；
    /// post 到 kCGHIDEventTap（HID 层）保证被前台应用接收；
    /// 事件源用 combinedSessionState，与系统输入状态一致（Maccy 同款做法）。
    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
