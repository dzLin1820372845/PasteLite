import Foundation
import Combine

/// 剪贴板历史的内存态（唯一事实来源）与落盘触发点。
/// 排序红线：置顶组最前（pinnedAt 降序），其余 createdAt 降序——任何变更后都必须回到该序。
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem]

    /// 历史上限。缩小后立即按新上限淘汰最旧未置顶并落盘（SettingsStore 启动与设置变更时同步此值）
    var capacity: Int = 100 {
        didSet {
            guard capacity != oldValue else { return }
            enforceCapacity()
            persistence.save(items)
        }
    }

    private let persistence: Persistence

    init(persistence: Persistence) {
        self.persistence = persistence
        self.items = persistence.load()
        sortItems()
    }

    /// 入库/去重：dedupKey 命中既有条目 → 用新内容更新原条目并移到最前（不新建，id 与置顶状态保留；
    /// 纯文本回读命中富条目时保留存量富数据与来源，见下方合并逻辑）；未命中 → 新条目。
    /// 结束统一回排序、按容量淘汰并触发落盘。
    func record(_ item: ClipboardItem) {
        var item = item
        // dedupKey 统一收口重算：与 ClipboardItem.makeDedupKey 保持单一规则，调用方自算不一致也不破坏去重
        item.dedupKey = ClipboardItem.makeDedupKey(kind: item.kind, plainText: item.plainText, imageData: item.imageData)

        if let index = items.firstIndex(where: { $0.dedupKey == item.dedupKey }) {
            var existing = items[index]
            // 纯文本回读（自贴回写最常见：Option 纯文本粘贴 0.5s 后被监听读回）只带 plainText、富字段全空。
            // 直接覆盖会把存量 RTF/HTML/文件列表与来源永久抹平（历史条目降级并随 save 落盘），
            // 故按“同一内容的降级表示”合并：保留富数据与来源，kind 回提为富类型以与保留的数据一致；
            // 真实重复制（新内容自带富数据，或存量本就是纯文本/图片）不受影响，仍走正常覆盖更新
            let isPlainReadback = item.kind == .text
                && item.rtfData == nil && item.htmlData == nil && item.filePaths == nil
            if isPlainReadback,
               existing.rtfData != nil || existing.htmlData != nil || existing.filePaths != nil {
                item.rtfData = existing.rtfData
                item.htmlData = existing.htmlData
                item.filePaths = existing.filePaths
                item.kind = existing.filePaths != nil ? .file : .richText
                item.sourceAppBundleID = existing.sourceAppBundleID
                item.sourceAppName = existing.sourceAppName
            }
            existing.kind = item.kind
            existing.plainText = item.plainText
            existing.rtfData = item.rtfData
            existing.htmlData = item.htmlData
            existing.imageData = item.imageData
            existing.filePaths = item.filePaths
            existing.sourceAppBundleID = item.sourceAppBundleID
            existing.sourceAppName = item.sourceAppName
            existing.createdAt = item.createdAt
            // 已置顶条目被重复复制时刷新置顶时间，使“移到最前”落在置顶组首位
            if existing.pinnedAt != nil {
                existing.pinnedAt = item.createdAt
            }
            items[index] = existing
        } else {
            items.append(item)
        }
        sortItems()
        enforceCapacity()
        persistence.save(items)
    }

    /// 置顶切换。置顶时间取当前时刻：置顶组内“越晚置顶越靠前”
    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinnedAt = items[index].pinnedAt == nil ? Date() : nil
        sortItems()
        persistence.save(items)
    }

    /// 删除单条；落盘时 Persistence 按存活 id 清孤儿 blob，被删条目的图片/富文本文件随之清理
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        persistence.save(items)
    }

    /// 清空内存历史并删除落盘索引与全部 blob 文件
    func clearAll() {
        items = []
        persistence.clearAll()
    }

    /// 搜索过滤：plainText 大小写（本地化）不敏感包含；结果保持现有排序
    func items(matching query: String) -> [ClipboardItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return items }
        return items.filter { $0.plainText.localizedCaseInsensitiveContains(keyword) }
    }

    // MARK: - 私有

    private func sortItems() {
        items.sort { lhs, rhs in
            let lhsPinned = lhs.pinnedAt
            let rhsPinned = rhs.pinnedAt
            if let lp = lhsPinned, let rp = rhsPinned {
                return lp != rp ? lp > rp : lhs.createdAt > rhs.createdAt
            }
            if lhsPinned != nil { return true }
            if rhsPinned != nil { return false }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// 超容量时淘汰最旧未置顶（置顶不参与淘汰，故条目数可能高于 capacity）
    private func enforceCapacity() {
        let overflow = items.count - capacity
        guard overflow > 0 else { return }
        // 未置顶组位于数组后部且 createdAt 降序，从尾部向前取 overflow 个即“最旧未置顶”
        let doomed = Set(items.reversed().filter { $0.pinnedAt == nil }.prefix(overflow).map(\.id))
        guard !doomed.isEmpty else { return }
        items.removeAll { doomed.contains($0.id) }
    }
}
