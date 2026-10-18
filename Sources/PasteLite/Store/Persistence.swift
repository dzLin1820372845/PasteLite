import Foundation
import os

/// 历史落盘。history.json 只存索引（不含二进制），blob 分别写为 <uuid>.png/.rtf/.html；
/// load 时按 uuid 从文件回填 blob 字段。目录默认 ~/Library/Application Support/PasteLite，可注入便于测试。
/// 仅被 @MainActor 的 ClipboardStore 调用，无并发防护。
final class Persistence {
    private let directory: URL
    private let indexURL: URL
    /// 视为本项目产物的 blob 扩展名；目录下其他文件一律不动（用户可能另存了无关文件）
    private static let blobExtensions: Set<String> = ["png", "rtf", "html"]
    private let logger = Logger(subsystem: "com.tclx.pastelite", category: "persistence")
    /// 已成功落盘的 rtf/html 内容指纹（id → 上次写入的数据引用）：save 时内容未变化即跳过重写，
    /// 避免历史填满后每次复制在主线程触发约 2×N 次原子写；仅在整次 save 成功后推进，
    /// 失败路径指纹不更新，下次 save 仍按全量重试
    private var persistedBlobs: [UUID: (rtf: Data?, html: Data?)] = [:]
    /// 上次成功落盘时的存活 id 集合：孤儿 blob 只可能由条目删除/淘汰产生，
    /// id 集合未变化时跳过整目录扫描
    private var persistedIDs: Set<UUID> = []

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/PasteLite", isDirectory: true)
    }

    /// - Parameter directory: 存储目录；不存在则创建，创建失败不阻断启动（save/load 各自报错）
    init(directory: URL = Persistence.defaultDirectory) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 读回全部历史（保持保存时的排序）。索引缺失或损坏返回空数组：
    /// 坏文件不重试不阻塞启动，其残留 blob 成为孤儿、由下次 save 清理。
    func load() -> [ClipboardItem] {
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            var items = try JSONDecoder().decode([ClipboardItem].self, from: data)
            for index in items.indices {
                items[index].imageData = try? Data(contentsOf: blobURL(items[index].id, "png"))
                items[index].rtfData = try? Data(contentsOf: blobURL(items[index].id, "rtf"))
                items[index].htmlData = try? Data(contentsOf: blobURL(items[index].id, "html"))
            }
            // 读回的内容即磁盘现状，作为 save 的跳过基线；坏索引路径走 catch/提前返回，基线保持空（下次全量写）
            persistedBlobs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, (rtf: $0.rtfData, html: $0.htmlData)) })
            persistedIDs = Set(items.map(\.id))
            return items
        } catch {
            logger.fault("history.json 读取或解码失败，已按空历史处理：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 全量落盘：写变化的 blob 文件 → 原子重写索引 → id 集合变化时清理孤儿 blob。
    /// 任一步失败则中止（旧索引保持完整，指纹不推进），下次 record 触发的 save 会整体重试。
    func save(_ items: [ClipboardItem]) {
        do {
            for item in items {
                // 图片内容随 dedupKey=SHA256 固定：同 id 必同内容，文件已存在即跳过重写（避免每次复制重写全部大图）
                if let data = item.imageData,
                   !FileManager.default.fileExists(atPath: blobURL(item.id, "png").path(percentEncoded: false)) {
                    try data.write(to: blobURL(item.id, "png"), options: .atomic)
                }
                // rtf/html 与上次成功落盘内容一致即跳过（自贴回写/未变化条目占绝大多数），
                // 新复制覆盖旧格式或新条目时才真正写盘
                if let data = item.rtfData, persistedBlobs[item.id]?.rtf != data {
                    try data.write(to: blobURL(item.id, "rtf"), options: .atomic)
                }
                if let data = item.htmlData, persistedBlobs[item.id]?.html != data {
                    try data.write(to: blobURL(item.id, "html"), options: .atomic)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
            let aliveIDs = Set(items.map(\.id))
            if aliveIDs != persistedIDs {
                removeOrphanBlobs(keepingIDs: aliveIDs)
            }
            // 整体成功后推进指纹；放在最后保证失败路径下指纹始终描述"已完整落盘"的状态
            persistedBlobs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, (rtf: $0.rtfData, html: $0.htmlData)) })
            persistedIDs = aliveIDs
        } catch {
            logger.fault("历史落盘失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 清空：删除索引与全部 blob 文件；目录本身保留（不做整体删除，避免误伤无关文件）
    func clearAll() {
        try? FileManager.default.removeItem(at: indexURL)
        for url in blobFiles() {
            try? FileManager.default.removeItem(at: url)
        }
        // 磁盘已清空，落盘基线同步归零，后续 save 按全新历史全量写
        persistedBlobs = [:]
        persistedIDs = []
    }

    // MARK: - 私有

    private func blobURL(_ id: UUID, _ ext: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    private func blobFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { url in
            guard Persistence.blobExtensions.contains(url.pathExtension.lowercased()),
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return false }
            return true
        }
    }

    /// 删除不再被任何存活条目引用的 blob（条目删除/淘汰后由 save 调用）
    private func removeOrphanBlobs(keepingIDs ids: Set<UUID>) {
        for url in blobFiles() {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            if !ids.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
