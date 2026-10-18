import AppKit
import SwiftUI

/// 抽屉内容：48pt 工具栏（居中胶囊搜索框）+ 横向历史卡片流，
/// 整体铺 behindWindow vibrancy 毛玻璃并裁统一圆角。
/// generation 每次唤出递增并作为 view id，强制重建视图状态——清空上次搜索词、搜索框重新聚焦
struct DrawerView: View {
    @ObservedObject var store: ClipboardStore
    let generation: Int
    let onSelect: (ClipboardItem) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let cornerRadius: CGFloat = 22

    // 卡片顺序即展示顺序：store 已按「置顶组在前（pinnedAt 降序）+ 时间倒序」排好
    private var filteredItems: [ClipboardItem] {
        query.isEmpty ? store.items : store.items(matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 用 AppKit vibrancy 而非 SwiftUI Material：浅色=白色半透明透壁纸、深色=近黑玻璃，保持项目毛玻璃规范
            VibrancyBackground()
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.quaternary)
        )
        .id(generation)
        .task { searchFocused = true }
    }

    /// 顶部工具栏（48pt）：居中半透明胶囊搜索框
    private var searchBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索剪贴板历史", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 460)
            Spacer()
        }
        .frame(height: 48)
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geo in
            // 卡片高度 = 卡片区实测高度（上下各留 10pt），卡片随屏高自适应保持近方形观感
            let cardHeight = geo.size.height - 20
            if store.items.isEmpty {
                emptyState(icon: "doc.on.clipboard", title: "暂无复制记录", caption: "复制内容后自动收集")
            } else if filteredItems.isEmpty {
                emptyState(icon: "magnifyingglass", title: "无匹配结果", caption: "换个关键词试试")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(filteredItems) { item in
                            CardView(item: item, store: store, onSelect: onSelect, height: cardHeight)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// 占位态：居中、大号 SF Symbol 点缀、主/副两行文案（15pt 次要灰 + 13pt 更淡）
    private func emptyState(icon: String, title: String, caption: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 项目毛玻璃底：AppKit behindWindow vibrancy 材质，深浅色随系统自动适配
private struct VibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
