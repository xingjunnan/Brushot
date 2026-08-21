# Brushot AI 开发规范

本文件是仓库级 AI 开发指令。开始工作前先确认用户当前请求，再按需阅读下列资料：

- 项目背景与代码导航：`docs/PROJECT_CONTEXT.md`
- 待办、优先级与需求状态：`TODO.md`
- 已确认且不应被随意推翻的决策：`docs/DECISIONS.md`
- 用户功能与使用方式：`README.zh-CN.md`

`TODO.md` 只是需求台账，不代表用户授权自动实现其中的所有条目。只实现用户当前明确要求的内容。

## 项目事实

- Brushot 是原生 macOS 菜单栏截图与录屏应用。
- 技术栈为 Swift 6、AppKit、ScreenCaptureKit、AVFoundation、Vision 和 Swift Package Manager。
- 最低支持 macOS 13，发布产物为 arm64 + x86_64 Universal 2 应用。
- Bundle ID 固定为 `com.brushot.app`。
- 主源码目录是 `Sources/Brushot/`，入口及主要 UI 编排位于 `Sources/Brushot/main.swift`。
- 应用内文案集中在 `Sources/Brushot/Localization.swift`；`Resources/*.lproj/InfoPlist.strings` 只负责系统展示的 Bundle 文案。
- 本地安装位置为 `/Applications/Brushot.app`，DMG 输出为 `dist/Brushot.dmg`。

## 开发原则

- 先理解现有实现和相邻测试，再修改代码；优先复用现有组件。
- 修复根因，不以隐藏错误、吞掉异常或增加无依据的延时作为最终方案。
- 保持改动聚焦，不顺手重构与当前需求无关的代码。
- 不覆盖、回滚或删除用户已有的无关改动；工作区可能不是干净状态。
- 未经用户同意，不新增第三方生产依赖，不改变最低系统版本、Bundle ID、签名策略或沙盒权限。
- `main.swift` 体积较大是当前架构现状；除非任务确实需要，不做大规模拆分。
- Swift 6 并发边界必须安全。跨 actor、任务或队列传递的值要满足 `Sendable` 或具有明确隔离。
- UI 和录制状态优先在 `@MainActor` 管理；底层回调不得直接在非主线程操作 AppKit。
- 新增用户可见文案时，通过 `Localization.swift` 维护简中、繁中、英文、日文、韩文行为；不要只改一种语言。
- README 内容发生用户可见变化时，同步维护五份 README 的对应章节。
- 遵守 `docs/DECISIONS.md`。若用户明确改变既有决策，完成实现后同步更新决策记录。

## 功能相关约束

- 截图、长截图、录屏、实时标注、贴图、水印和 OCR 共享部分底层能力，修改时检查是否影响相邻链路。
- OCR 始终读取冻结的原始截图，不读取已经烧入的标注或水印。
- 录屏模式仅包含区域录屏、窗口录屏和全屏录屏；不要恢复“应用录屏”，除非用户明确改变该产品决策。
- 窗口录屏只捕获用户选择的单个窗口，窗口以外的透明区域使用纯黑色合成。
- 实时标注应进入视频和 GIF 像素；倒计时、红色边框和控制栏不应进入成片。
- GIF 最长录制 3 分钟，视频最长录制 2 小时；剩余磁盘空间低于 1 GB 时不得继续不安全录制。
- 权限测试必须使用 `/Applications/Brushot.app`，不要用 `swift run` 判断 TCC 权限行为。

## 构建与验证

SwiftPM 在受限环境中可能需要关闭自身沙盒：

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

发布构建命令：

```bash
./scripts/build-app.sh
./scripts/build-dmg.sh
```

完成代码修改后，根据风险执行以下检查：

1. 至少运行相关测试；正常情况下运行完整 `swift test --disable-sandbox`。
2. 运行 `git diff --check`。
3. 涉及 UI、截图、窗口、权限、录屏、音频或导出时，必须运行打包后的应用做真实操作验证，不能只依赖单元测试。
4. 用户要求安装或交付可运行版本时，运行 `./scripts/build-app.sh`，确认 `/Applications/Brushot.app` 已更新。
5. 用户要求 DMG 或发布产物时，运行 `./scripts/build-dmg.sh`，再验证应用签名和 DMG 完整性。
6. 删除本次验证产生的临时截图、录像和恢复文件；不要删除用户自己的文件。

## 完成标准

只有在以下条件满足后才能向用户报告“完成”：

- 请求的行为已经实现，而不是只写了计划或隐藏入口。
- 测试与必要的真实场景验证已经通过。
- 没有新增编译警告、明显回归或未说明的失败。
- 相关 README、`TODO.md` 或 `docs/DECISIONS.md` 已在确有变化时同步。
- 最终回复简要说明改了什么、如何验证、产物在哪里，以及仍存在的限制。

## TODO 与记录维护

- 开始需求前可检查 `TODO.md` 是否已有对应编号，避免重复记录。
- 用户只是讨论想法时，将其放入“待评估”，不要写成已经承诺的需求。
- 开始实现后才把条目标记为“进行中”；验证完成后才移入“已完成”。
- 完成重要产品或技术取舍后，在 `docs/DECISIONS.md` 记录结论、原因和影响。
- 不把日常命令输出、长篇调试过程或临时猜测写入长期文档。
