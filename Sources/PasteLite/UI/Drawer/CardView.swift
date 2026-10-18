import AppKit
import SwiftUI

/// 单张历史卡片：彩色类型头带 + 白/炭黑正文。
/// 头带按内容类型着色（文本=蓝/富文本=紫/图片=红/文件=橙），承载类型名、相对时间与来源应用图标；
/// hover 时卡片上浮提亮、浮现玻璃质感圆形工具按钮。点击交给 onSelect（Option=纯文本语义由控制器判定）
struct CardView: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipboardStore
    let onSelect: (ClipboardItem) -> Void
    /// 卡片高度 = 抽屉卡片区实测可用高度（DrawerView 按当前屏高传入），近方形观感随屏自适应
    let height: CGFloat

    @State private var hovering = false

    private static let cornerRadius: CGFloat = 14
    private static let cardWidth: CGFloat = 240

    // 图片解码缓存：卡片随 store 变化频繁重建，避免滚动/更新时反复解码 PNG/TIFF
    private static let imageCache = NSCache<NSUUID, NSImage>()

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            headband
            bodyArea
        }
        .frame(width: Self.cardWidth, height: height)
        .background(Color(nsColor: .controlBackgroundColor))   // 浅色=白底、深色=炭黑底，语义色自动适配
        .clipShape(cardShape)
        // 轻微提亮：hover 蒙极淡白纱，深浅色下均成立
        .overlay(cardShape.fill(Color.white.opacity(hovering ? 0.05 : 0)))
        .overlay(cardShape.strokeBorder(.quaternary))
        .overlay(alignment: .topTrailing) { hoverToolbar }
        // 上浮只做视觉偏移不参与布局，不挤动相邻卡片
        .offset(y: hovering ? -3 : 0)
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.14),
                radius: hovering ? 16 : 8, x: 0, y: hovering ? 8 : 4)
        .contentShape(cardShape)
        .onHover { hovering = $0 }
        .onTapGesture { onSelect(item) }
        .contextMenu { contextButtons }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: - 头带

    /// 头带（卡片顶部约 22%）：类型名 + 相对时间 + 来源图标，按内容类型着色
    private var headband: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kindName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(relativeTimeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            if item.pinnedAt != nil && !hovering {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
            }
            sourceIcon
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: height * 0.22, alignment: .center)
        .background(kindColor)
    }

    private var kindName: String {
        switch item.kind {
        case .text: "文本"
        case .richText: "富文本"
        case .image: "图片"
        case .file: "文件"
        }
    }

    /// 类型色带用系统色相：深浅色模式下同一色相自动微调，双模式均成立
    private var kindColor: Color {
        switch item.kind {
        case .text: .blue
        case .richText: .purple
        case .image: .red
        case .file: .orange
        }
    }

    /// 相对时间：刚刚 / N 分钟前 / 今天 HH:mm / 昨天 / 更早
    private var relativeTimeText: String {
        let interval = Date().timeIntervalSince(item.createdAt)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDateInToday(item.createdAt) {
            return "今天 " + Self.timeFormatter.string(from: item.createdAt)
        }
        if calendar.isDateInYesterday(item.createdAt) { return "昨天" }
        return "更早"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 来源应用图标：按复制时刻前台应用的 bundleID 反查应用路径取图标；查不到整个省略。
    /// hover 时淡出让位给玻璃工具按钮（浮层切换无布局位移，不会抖动）
    @ViewBuilder
    private var sourceIcon: some View {
        Group {
            if let bundleID = item.sourceAppBundleID,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .opacity(hovering ? 0 : 1)
    }

    // MARK: - 正文

    @ViewBuilder
    private var bodyArea: some View {
        switch item.kind {
        case .text, .richText: textBody
        case .image: imageBody
        case .file: fileBody
        }
    }

    /// 文本/富文本正文：预览最多 6 行，底部居中字数脚注
    private var textBody: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            footerText("\(item.plainText.count) 个字符")
        }
    }

    /// 富文本尽量按原始样式渲染（RTF 解析为 NSAttributedString 保留字体颜色）；解析失败退纯文本兜底
    @ViewBuilder
    private var preview: some View {
        if item.kind == .richText, let rtf = item.rtfData,
           let attributed = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            Text(AttributedString(attributed))
                .lineLimit(6)
        } else {
            Text(item.plainText)
                .font(.system(size: 13))
                .lineLimit(6)
        }
    }

    /// 图片正文：满铺裁切 + 右下角白色半透明尺寸胶囊（图片卡无字数脚注）
    private var imageBody: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = cachedImage {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                Text("图片")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let dimensions = imageDimensions {
                Text(dimensions)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.8)))
                    .padding(10)
            }
        }
    }

    /// 图片像素尺寸文案（如「1920 × 1080」）；优先取位图表示的真实像素，退回 NSImage 点尺寸
    private var imageDimensions: String? {
        guard let image = cachedImage else { return nil }
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    private var cachedImage: NSImage? {
        guard let data = item.imageData else { return nil }
        if let hit = Self.imageCache.object(forKey: item.id as NSUUID) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        Self.imageCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }

    /// 文件正文：大图标 + 粗体文件名 + 灰色路径（中段截断），底部居中「N 个文件」
    private var fileBody: some View {
        let paths = item.filePaths ?? []
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let first = paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                        .resizable()
                        .frame(width: 52, height: 52)
                }
                Text(paths.first.map { ($0 as NSString).lastPathComponent } ?? "文件")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                if let first = paths.first {
                    Text((first as NSString).deletingLastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footerText("\(paths.count) 个文件")
        }
    }

    /// 底部脚注：11pt 次要灰、水平居中
    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
    }

    // MARK: - 悬停工具与右键菜单

    /// hover 浮现的玻璃质感圆形按钮：白色半透明底 + 白色 SF Symbol，压在彩色头带上不抢戏
    @ViewBuilder
    private var hoverToolbar: some View {
        if hovering {
            HStack(spacing: 6) {
                glassButton(icon: item.pinnedAt == nil ? "pin" : "pin.slash",
                            help: item.pinnedAt == nil ? "置顶" : "取消置顶") {
                    store.togglePin(item.id)
                }
                glassButton(icon: "trash", help: "删除") {
                    store.delete(item.id)
                }
            }
            .padding(8)
        }
    }

    private func glassButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.22)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var contextButtons: some View {
        Button("复制") { copyToPasteboard() }
        Button(item.pinnedAt == nil ? "置顶" : "取消置顶") { store.togglePin(item.id) }
        Divider()
        Button("删除", role: .destructive) { store.delete(item.id) }
    }

    /// 右键菜单「复制」：仅回填系统剪贴板，不合成按键、不收起抽屉（与点击卡片走 onPaste/PasteEngine 的路径区分）
    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.plainText, forType: .string)
        case .richText:
            if let rtf = item.rtfData {
                pasteboard.setData(rtf, forType: .rtf)
            }
            pasteboard.setString(item.plainText, forType: .string)
        case .image:
            // 原始数据可能是 PNG 或兜底 TIFF，经 NSImage 写入由系统按实际格式声明 UTI
            if let data = item.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .file:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls)
            }
        }
    }
}
