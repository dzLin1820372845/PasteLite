import Foundation
import CryptoKit

/// 剪贴板内容类型。richText 同时保留 RTF/HTML 数据与 plainText 兜底；image 以 PNG 二进制存储。
enum ClipboardContentKind: String, Codable {
    case text
    case richText
    case image
    case file
}

/// 一条剪贴板历史。
/// 持久化约定：blob 字段（rtfData/htmlData/imageData）不进 history.json 索引，
/// 由 Persistence 写为 <uuid>.png/.rtf/.html 独立文件、load 时回填（见文件底部 Codable 定制）。
struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipboardContentKind
    /// 搜索与纯文本粘贴兜底；text 时为全文；file 时为换行连接的路径串
    var plainText: String
    /// richText 的 RTF
    var rtfData: Data?
    var htmlData: Data?
    /// 图片二进制（PNG 优先，转换失败存原始 TIFF）
    var imageData: Data?
    var filePaths: [String]?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    /// nil = 未置顶；置顶组内按此值降序排列
    var pinnedAt: Date?
    /// 去重键：image → 图片数据 SHA256；其余 → plainText（统一由 makeDedupKey 计算）
    var dedupKey: String
}

// MARK: - 去重键

extension ClipboardItem {
    /// dedupKey 唯一计算入口：image 取图片数据 SHA256 十六进制；无图片数据或非 image 取 plainText。
    /// record() 入库前会用它重算归一，调用方计算不一致也不会破坏去重（自粘贴回写收敛依赖此键）。
    static func makeDedupKey(kind: ClipboardContentKind, plainText: String, imageData: Data?) -> String {
        guard kind == .image, let data = imageData else { return plainText }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 持久化编码（索引 JSON 不含 blob 字段）

extension ClipboardItem {
    private enum CodingKeys: String, CodingKey {
        case id, kind, plainText, filePaths
        case sourceAppBundleID, sourceAppName
        case createdAt, pinnedAt, dedupKey
    }

    /// 解码不读 blob：二进制由 Persistence.load() 从 <uuid>.png/.rtf/.html 文件回填
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  kind: try container.decode(ClipboardContentKind.self, forKey: .kind),
                  plainText: try container.decode(String.self, forKey: .plainText),
                  rtfData: nil,
                  htmlData: nil,
                  imageData: nil,
                  filePaths: try container.decodeIfPresent([String].self, forKey: .filePaths),
                  sourceAppBundleID: try container.decodeIfPresent(String.self, forKey: .sourceAppBundleID),
                  sourceAppName: try container.decodeIfPresent(String.self, forKey: .sourceAppName),
                  createdAt: try container.decode(Date.self, forKey: .createdAt),
                  pinnedAt: try container.decodeIfPresent(Date.self, forKey: .pinnedAt),
                  dedupKey: try container.decode(String.self, forKey: .dedupKey))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(plainText, forKey: .plainText)
        try container.encode(filePaths, forKey: .filePaths)
        try container.encode(sourceAppBundleID, forKey: .sourceAppBundleID)
        try container.encode(sourceAppName, forKey: .sourceAppName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(pinnedAt, forKey: .pinnedAt)
        try container.encode(dedupKey, forKey: .dedupKey)
    }
}
