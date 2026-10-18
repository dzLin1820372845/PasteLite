import AppKit

/// PasteLite 的单色品牌图标加载器。
/// 菜单栏图标必须使用模板图，系统才能根据浅色/深色菜单栏自动反色。
enum PasteLiteBranding {
    static func applicationImage(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }

    static func templateImage(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "PasteLiteTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        let aspectRatio = image.size.width / image.size.height
        image.size = NSSize(width: size * aspectRatio, height: size)
        return image
    }
}
