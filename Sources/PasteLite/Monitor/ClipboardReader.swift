import AppKit
import CryptoKit

/// 剪贴板内容读取与判型。类型判定优先级：file → image → richText → text，命中即返回；
/// 无法归类（既无文件 URL、无图片数据、无字符串）或图片转换失败则返回 nil 丢弃本次变化。
/// 读他应用剪贴板内容首次会触发系统授权弹窗，属 macOS 平台机制，本层不做处理。
enum ClipboardReader {

    /// 读取当前剪贴板一次，产出历史条目。
    /// 顺序红线：先取前台应用做来源并跑排除检查（命中直接 nil，不发生任何内容读取），
    /// 再读内容判型——既保住"复制时刻"的真实来源，也让被排除来源（密码管理器）零读取。
    static func readCurrent(isExcludedBundleID: ((String) -> Bool)?) -> ClipboardItem? {
        // 剪贴板 API 不提供来源，以复制时刻的前台应用作近似判定（业界通行做法）
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        let appName = frontmost?.localizedName
        if let bundleID, let isExcluded = isExcludedBundleID, isExcluded(bundleID) {
            return nil
        }

        let board = NSPasteboard.general

        // 1. 文件：仅认文件 URL；http/https 的 URL 不满足条件，自然落到 text 分支
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [NSURL],
           !urls.isEmpty {
            let paths = urls.compactMap { $0.filePathURL?.path }
            if !paths.isEmpty {
                return item(kind: .file,
                            plainText: paths.joined(separator: "\n"),
                            filePaths: paths,
                            sourceAppBundleID: bundleID,
                            sourceAppName: appName)
            }
        }

        // 2. 图片：PNG 优先直取；只有 TIFF 时统一转 PNG 存储；两路都失败丢弃本次变化（不落回文本，避免把图片误记成乱码文本）
        if let png = board.data(forType: .png) {
            return item(kind: .image, imageData: png,
                        sourceAppBundleID: bundleID, sourceAppName: appName)
        }
        if let tiff = board.data(forType: .tiff) {
            guard let converted = NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]) else { return nil }
            return item(kind: .image, imageData: converted,
                        sourceAppBundleID: bundleID, sourceAppName: appName)
        }

        // 3. 富文本：RTF 或 HTML 任一存在即按 richText 收录，并同步取纯文本兜底（搜索与纯文本粘贴依赖它）
        if board.data(forType: .rtf) != nil || board.data(forType: .html) != nil {
            return item(kind: .richText,
                        plainText: board.string(forType: .string) ?? "",
                        rtfData: board.data(forType: .rtf),
                        htmlData: board.data(forType: .html),
                        sourceAppBundleID: bundleID,
                        sourceAppName: appName)
        }

        // 4. 纯文本兜底
        if let text = board.string(forType: .string) {
            return item(kind: .text, plainText: text,
                        sourceAppBundleID: bundleID, sourceAppName: appName)
        }

        return nil
    }

    /// 组装条目。dedupKey 契约：image → 图片数据 SHA256，其余 → plainText；
    /// 重复复制因此能被 store 识别为同一条（自粘贴回写触发的 changeCount 变化也靠它良性收敛，勿加抑制逻辑）。
    private static func item(kind: ClipboardContentKind,
                             plainText: String = "",
                             rtfData: Data? = nil,
                             htmlData: Data? = nil,
                             imageData: Data? = nil,
                             filePaths: [String]? = nil,
                             sourceAppBundleID: String?,
                             sourceAppName: String?) -> ClipboardItem {
        ClipboardItem(id: UUID(),
                      kind: kind,
                      plainText: plainText,
                      rtfData: rtfData,
                      htmlData: htmlData,
                      imageData: imageData,
                      filePaths: filePaths,
                      sourceAppBundleID: sourceAppBundleID,
                      sourceAppName: sourceAppName,
                      createdAt: Date(),
                      pinnedAt: nil,
                      dedupKey: kind == .image ? sha256Hex(imageData ?? Data()) : plainText)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
