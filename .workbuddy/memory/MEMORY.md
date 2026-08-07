# SnapInk 项目长期笔记

## 项目概况
- macOS 截图工具（SwiftPM，Swift 6 严格并发），状态栏常驻 App（.accessory）。
- 入口 `Sources/SnapInk/main.swift`（单文件，2500+ 行）。
- 构建：`swift build --disable-sandbox`（当前开发环境 sandbox-exec 被禁，必须加 `--disable-sandbox`，测试同理 `swift test --disable-sandbox`）。

## 核心架构
- **快捷键**：Carbon `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget(), ...)`。`KeyboardShortcut.modifiers` 是 UInt32（Carbon 常量 cmdKey/shiftKey/optionKey/controlKey 按位或）。
- **PreCaptureStore**（main.swift）：线程安全预截图缓存，`CGWindowListCreateImage` 同步截所有显示器。`capture()` 填充，`retrieve()` 取用并清空。
- **截图流程**：热键 → 预截图 → 呈现 overlay（冻结屏幕效果）→ 选区 → `cropFromPreCaptured` 裁剪或现场截图。

## Tooltip 预截图机制（2026-08-07 引入）
- **问题**：tooltip 在 App 收到修饰键时被消除，Carbon 回调在 AppKit 层已来不及。
- **解决**：`TooltipPreCaptureEventTap`（CGEventTap，`.cgSessionEventTap`）在事件派发前拦截 `flagsChanged`，修饰键上升沿时同步预截图存入 PreCaptureStore。Carbon 回调仅在 tap 未激活时降级 capture。
- **权限**：CGEventTap 需辅助功能权限（`AXIsProcessTrusted`）。屏幕录制权限用 `CGPreflightScreenCaptureAccess` + `SCShareableContent`。两者独立。
- **Swift 6 注意**：`kAXTrustedCheckOptionPrompt` 是 non-Sendable C 全局，用字符串字面量 `"AXTrustedCheckOptionPrompt"` 绕过。CGEventTap C API 须用 Swift overlay（`CGEvent.tapCreate/tapEnable/tapIsEnabled`）。

## 权限模型
- 屏幕录制：截图必需。
- 辅助功能：tooltip 预截图必需（可选，无则降级）。
- 两者都在首次使用时弹系统对话框请求，一次性授权。

## 文件结构
- `main.swift`：AppDelegate、CaptureController、PreCaptureStore、TooltipPreCaptureEventTap、快捷键/偏好/overlay/OCR 等几乎所有逻辑。
- 其他 Source 文件：Annotation*、GIF*、LongCapture、OCR、Pinning、ScreenRegionCapturer、StreamScreenshotCapturer。
