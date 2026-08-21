# Brushot 项目背景

最后核对：2026-08-21

## 产品定位

Brushot 是一款轻量、原生、菜单栏常驻的 macOS 截图与录屏工具，面向中文用户并同时维护英文、繁体中文、日文和韩文体验。产品重点是缩短“截图或录屏 → 标注 → 复制、保存或贴图”的操作路径，而不是堆叠差异很小的入口。

当前核心能力：

- 区域、全屏、延时和长截图。
- 智能窗口识别与窗口截图。
- 区域、窗口和全屏录屏，输出 MP4 或 GIF。
- 录屏系统声、麦克风、暂停与继续、实时标注。
- 矩形、椭圆、直线、箭头、画笔、文字、序号、马赛克和聚光高亮标注。
- OCR、macOS 15 端上英译简中、截图和录屏水印。
- 截图贴图、贴图库和二次标注。
- 应用沙盒、用户选择文件访问和 Downloads 目录读写。

## 平台与发布信息

- 最低系统：macOS 13。
- 架构：Apple Silicon `arm64` 与 Intel `x86_64`，发布为 Universal 2。
- Swift tools version：6.0。
- Bundle ID：`com.brushot.app`。
- 当前 Info.plist 版本快照：`0.11.0`，build `36`；发布前以 `Resources/Info.plist` 为准。
- 应用类型：`LSUIElement` 菜单栏应用，不显示普通 Dock 主窗口。
- 安装位置：`/Applications/Brushot.app`。
- DMG：`dist/Brushot.dmg`。

## 技术栈

- Swift 6 与 Swift Package Manager。
- AppKit / SwiftUI：菜单栏、窗口、覆盖层和部分界面。
- ScreenCaptureKit / CoreGraphics：截图、窗口识别和屏幕流。
- AVFoundation / CoreMedia / CoreVideo：视频、音频、时间线和导出。
- Vision：设备端 OCR。
- Translation：macOS 15 及以上设备端翻译。
- ImageIO / CoreImage / QuartzCore：图片、GIF、渲染和动画。

## 代码导航

- `Sources/Brushot/main.swift`
  - 应用入口、菜单、快捷键、偏好设置、截图控制器和选区覆盖层。
- `AnnotationModel.swift`、`AnnotationEditor.swift`、`AnnotationRenderer.swift`
  - 标注数据、交互编辑和扁平化渲染。
- `ScreenRegionCapturer.swift`、`StreamScreenshotCapturer.swift`
  - ScreenCaptureKit 过滤器、区域与窗口画面获取。
- `LongCapture.swift`
  - 长截图会话、滚动帧匹配和拼接。
- `GIFSessionController.swift`、`RecordingEngine.swift`
  - 录屏会话 UI、实时标注、ScreenCaptureKit 流和音频采集。
- `RecordingExporter.swift`、`RecordingEditing.swift`、`RecordingPreview.swift`
  - MP4/GIF 导出、编辑和结果预览。
- `RecordingRecovery.swift`、`RecordingTimelineView.swift`
  - 中断恢复和录屏时间线。
- `OCR.swift`、`OCRTranslation.swift`
  - OCR 与端上翻译。
- `Pinning.swift`
  - 贴图窗口和贴图库。
- `Watermark.swift`、`WatermarkQuickSetup.swift`
  - 截图与录屏水印。
- `SandboxFileAccess.swift`
  - 沙盒路径、安全作用域书签和文件访问。
- `Localization.swift`
  - 应用内简中、繁中、英文、日文和韩文字符串映射。

## 测试与构建

- 测试位于 `Tests/BrushotTests/`，使用 XCTest。
- 开发测试：`swift test --disable-sandbox`。
- 构建并安装应用：`./scripts/build-app.sh`。
- 构建 DMG：`./scripts/build-dmg.sh`。
- `build-app.sh` 会直接覆盖 `/Applications/Brushot.app`，以保持稳定的应用路径和 TCC 身份。

## 权限边界

- 屏幕与系统音频录制：截图和录屏的核心权限。
- 麦克风：仅在用户启用麦克风录制时需要。
- 辅助功能：用于特定的预捕获或交互增强；缺失时核心截图功能应尽量降级工作。
- 文件访问：沙盒内默认目录、Downloads，以及用户通过面板选择并授权的位置。

权限相关问题必须用已签名并安装到 `/Applications` 的应用验证。不同签名身份或运行路径可能让 macOS 把它视为不同应用。

## 文档边界

- `README*.md`：用户安装、功能和使用说明。
- `AGENTS.md`：AI 开发必须遵守的稳定规则。
- `TODO.md`：需求状态与发布台账。
- `docs/DECISIONS.md`：已经确认的产品和技术取舍。
- `CONTRIBUTING.md`：面向贡献者的通用协作流程。

若本文件与代码冲突，应先核对实际代码，再修正文档；不要为了符合旧文档而把正确代码改回旧状态。
