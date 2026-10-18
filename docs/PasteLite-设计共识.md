# PasteLite 设计共识

> 状态：共识已达成（2026-10-15），待实施。本文档是项目的唯一需求/设计依据；实现过程中的任何偏差须回写本文档。

## 1. 定位

自用 macOS 剪贴板历史管理器，提供原生 macOS 风格的剪贴板历史体验：

后台监听复制 → **⌘⇧V** 从屏幕底部弹出抽屉 → 横向历史卡片流（最新在左）→ **鼠标点击卡片即粘贴回当前前台应用**。

## 2. 需求对标（剪贴板管理器需求摘要）

- **核心功能**（本项目范围）：剪贴板历史；全局快捷键默认 ⌘⇧V；屏幕底部横向抽屉；卡片预览（文本/图片/文件）+ 来源应用图标；点击即粘贴并收起；全文搜索；菜单栏常驻；排除指定应用（密码管理器等）。
- **进阶功能**（本项目不做）：多板收藏与团队共享、iCloud 多设备同步、iOS 端、应用深度集成、PDF/代码高亮预览。
- **竞品 MVP 底线**（Maccy / CopyClip / Pastebot 共性）：菜单栏常驻 + 剪贴板轮询 + 历史列表 + 点击回贴 + 历史上限 + 排除应用 + 本地持久化。开源的 [Maccy](https://github.com/p0deje/Maccy) 可作实现参照。

## 3. 设计树（全部已定决策）

| 分支 | 决定 |
|---|---|
| 内容类型 | 纯文本；富文本（RTF/HTML，同时存纯文本兜底）；图片（缩略图卡片）；文件（文件名+图标卡片） |
| 剪贴板监听 | `NSPasteboard.general.changeCount` 0.5s 轮询；首次读取他应用剪贴板内容时系统弹授权框（平台机制，非缺陷） |
| 历史存储 | 本地落盘：JSON 索引 + 图片/富文本二进制文件，存于 `~/Library/Application Support/PasteLite/`；默认上限 100 条（设置可调 50–1000），FIFO 淘汰；重复复制不重复存储、移到最前 |
| 唤起与关闭 | 全局快捷键 ⌘⇧V（设置中可改）+ 菜单栏图标点击；Esc 或点击抽屉外部关闭；抽屉在鼠标所在屏幕底部弹出，滑出动画 |
| 抽屉 UI | 顶部常驻搜索框即时过滤；Pin 组固定最左端（图钉标识），取消置顶回到时间序；卡片显示来源应用图标 |
| 粘贴行为 | 点击卡片 = 按原格式自动粘贴（回填剪贴板 + 合成 Cmd+V，需**辅助功能**授权）；Option+点击 = 粘贴纯文本（富文本）/ 文件路径（文件）；授权被拒时降级为仅回填剪贴板 |
| 来源应用 | 取**复制时刻的前台应用**（剪贴板 API 不提供来源，业界通行近似判定） |
| 排除列表 | 默认预置 1Password、KeePassXC 等常见密码管理器，设置中可增删；被排除应用产生的复制不记录 |
| 系统 | 开机自启（SMAppService，设置中开关）；暗色模式跟随系统；界面文案中文 |
| 应用形态 | 菜单栏常驻（Info.plist `LSUIElement=1`，无 Dock 图标、无主窗口）；菜单：打开抽屉 / 设置 / 退出 |
| 技术栈 | 原生 SwiftUI；SwiftPM + 完整 Xcode 构建；`build.sh` 分别编译 arm64/x86_64，组装 Universal .app bundle、生成拖拽安装 DMG 并 ad-hoc 签名；不上 Mac App Store（辅助功能授权与沙箱冲突） |
| 命名 | **PasteLite**，bundle ID `com.tclx.pastelite` |

## 4. 核心链路

1. **常驻监听**：每 0.5s 比对 `changeCount`；变化则读取内容（判定类型：文本/富文本/图片/文件），同时记录 `NSWorkspace.frontmostApplication` 作为来源应用；来源在排除列表中则丢弃。
2. **去重**：新内容与既有记录相同 → 已有记录移到最前，不重复存储。
3. **唤起**：⌘⇧V 或点菜单栏图标 → 在鼠标所在屏幕底部滑出抽屉（非激活面板，不抢目标应用焦点）。
4. **选择粘贴**：点击卡片 = 内容回填系统剪贴板 + 合成 Cmd+V 发给前台应用 + 抽屉收起；Option+点击 = 粘贴纯文本/文件路径；辅助功能未授权或安全输入状态 = 降级为仅回填剪贴板。
5. **关闭**：Esc 或点击抽屉外部区域。

## 5. 明确不做

- iCloud 同步（CloudKit 签名需付费开发者账号 + Xcode，本次不做）
- ⌘1-9 直贴、方向键选卡等键盘选卡交互（鼠标点击即可）
- App Store 上架、iOS 端
- Pin 多板 / 团队共享
- 一切云同步能力（历史纯本地，无网络依赖）

## 6. 实施计划（4 阶段，每阶段带验证）

| 阶段 | 内容 | 验证 |
|---|---|---|
| Phase 0 脚手架 | `build.sh`（SwiftPM release → Universal PasteLite.app → DMG → ad-hoc 签名）；Info.plist（LSUIElement、`NSAccessibilityUsageDescription`、`NSPasteboardFullAccessUsageDescription`）；`git init` + `.gitignore` | 应用可启动，菜单栏出现图标；Intel 与 Apple Silicon 均可安装 |
| Phase 1 核心闭环 | changeCount 轮询采集文本+图片；去重置顶（内存态）；无边框非激活抽屉面板（滑出动画、横向卡片流）；点击卡片 = 回填 + 合成 Cmd+V（`AXIsProcessTrusted` 检查 + 降级）；Esc/点外关闭；菜单栏菜单 | 手动全链路：复制 → ⌘⇧V → 点卡片贴进 TextEdit |
| Phase 2 持久化 | Application Support 落盘/启动恢复 + FIFO 容量淘汰 | 重启后历史保留；超限正确淘汰 |
| Phase 3 扩展 | 搜索过滤；Pin；来源应用图标；富文本/文件支持（含 Option 纯文本/路径）；排除列表；快捷键配置；容量设置；开机自启；设置窗口；首次运行权限引导；空态 | 逐项手动清单 + 全链路回归 |

实现按多代理工作流编排，每阶段完成后由独立代理对照本文档审查偏差。

## 7. 技术要点备忘

- **剪贴板监听**：系统无变更通知，轮询 `changeCount` 是主流做法（Maccy 同款）；仅比对 changeCount 不触发剪贴板授权弹窗，读取内容才触发（macOS 15+ 起，Info.plist 需声明 `NSPasteboardFullAccessUsageDescription`）。
- **自动粘贴**：`AXIsProcessTrusted()` 检查 + CGEvent 合成 Cmd+V（virtualKey 9 / `.maskCommand`，post 到 `kCGHIDEventTap`）；与 App Sandbox 冲突，故不上 MAS；Info.plist 需声明 `NSAccessibilityUsageDescription`。
- **合成事件限制**：系统"安全输入"状态（密码框等）下合成按键被拦截 → 自动降级为仅回填剪贴板。
- **菜单栏常驻**：`LSUIElement=1`；`NSStatusItem` 必须强引用，否则图标消失。
- **Release 构建**：`build.sh` 固定使用 `/Applications/Xcode.app`，通过 SwiftPM 分别以 `arm64-apple-macosx13.0` 和 `x86_64-apple-macosx13.0` 编译，再用 `lipo` 合并 Universal 二进制，组装 `.app`、ad-hoc 签名并用 `hdiutil` 生成拖拽安装 DMG。SwiftPM 的 `swift-tools-version` 为 5.9，最低部署目标为 macOS 13。
- **开机自启**：`SMAppService.mainApp`（macOS 13+）。
- **抽屉窗口**：NSPanel 非激活样式（`.nonactivatingPanel`），保证粘贴目标应用保持前台。

参考：[NSPasteboard.changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) · [LSUIElement](https://developer.apple.com/documentation/bundleresources/information_property_list/lsuielement) · [CGEvent 键盘事件](https://developer.apple.com/documentation/coregraphics/cgevent/keyboard-events) · [SO: 合成 Cmd+V](https://stackoverflow.com/questions/28389580) · [Maccy 源码](https://github.com/p0deje/Maccy)

## 8. 风险与已知局限

- 合成 Cmd+V 在"安全输入"状态被系统拦截——该场景自动降级为仅回填剪贴板（用户需手动 Cmd+V）。
- 来源应用图标为近似判定（复制时刻的前台应用），后台窗口右键复制等场景可能误标。
- Release 使用 ad-hoc 签名且未经过 Apple 公证；换机器分发时可能需要在 Finder 中右键“打开”。
- 首次运行遇到两次系统授权弹窗（剪贴板读取、辅助功能），属平台机制，需在首次运行引导中说明。
- 自用 ad-hoc 签名，无公证：换机器分发需右键打开绕过 Gatekeeper。

## 9. 决策记录

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 内容类型 | 文本+图片起步，富文本/文件一并做 |
| 2 | 持久化 | 本地落盘，重启保留，无云 |
| 3 | 容量 | 默认 100 条，设置可调 50–1000 |
| 4 | 唤起 | ⌘⇧V（可配置）+ 菜单栏图标 |
| 5 | 粘贴 | 点击自动粘贴（辅助功能授权），降级回填 |
| 6 | 技术栈 | 原生 SwiftUI + SwiftPM，使用完整 Xcode 构建 |
| 7 | 形态 | 菜单栏常驻应用 |
| 8 | 范围 | 搜索/Pin/来源应用/富文本/文件/自启/排除/设置全做；iCloud 不做 |
| 9 | 标准行为 | 去重置顶、Esc/点外关闭、鼠标所在屏弹出 |
| 10 | 选卡交互 | 仅鼠标点击（否决 ⌘1-9） |
| 11 | 命名 | PasteLite / com.tclx.pastelite |
| 12 | 界面语言 | 中文 |
| 13 | 构建方式 | SwiftPM 分别构建 arm64/x86_64，`lipo` 合并 Universal，组装 `.app`、ad-hoc 签名并生成 DMG |
