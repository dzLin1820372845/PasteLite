// swift-tools-version:5.9
// PasteLite — macOS 菜单栏剪贴板历史管理器
// tools 5.9 锁定 Swift 5 语言模式，规避严格并发检查
import PackageDescription

let package = Package(
    name: "PasteLite",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PasteLite",
            path: "Sources/PasteLite"
        )
    ]
)
