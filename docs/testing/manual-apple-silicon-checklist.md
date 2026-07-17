# MeetingNotes Apple Silicon 验证清单

更新日期：2026-07-17
目标平台：macOS 15+、Apple Silicon（arm64）

## 自动化前置条件

- [x] Xcode 可构建 arm64 App、单元测试和 UI 测试 Runner。
- [x] UI 自动化使用 `-uiTesting`，只在 `#if DEBUG` 中注入内存数据库与假服务。
- [x] 直接启动 Debug App 的 `-uiTesting` 路径后，进程保持运行且未崩溃。
- [x] macOS Developer Mode 已启用。

当前机器的 `DevToolsSecurity -status` 返回 `Developer mode is currently enabled.`。UI Runner 必须使用本机临时签名；若设置 `CODE_SIGNING_ALLOWED=NO`，复制 XCTest 框架后 Runner 签名会失效并在建立连接前被系统终止。

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests \
  -only-testing:MeetingNotesTests/LongRecordingHarnessTests
```

## UI 自动化场景

- [x] 首页恰有“线下会议”和“在线会议”两个入口。
- [x] 开始录音后悬浮面板可见，且恰有录音、暂停、结束、书签四个按钮。
- [x] 暂停/继续只改变暂停按钮语义，不增加第五个按钮。
- [x] 添加书签后详情页出现书签，结束会议后仍保留。
- [x] 点击结束后录音浮窗在 3 秒内消失，再进入转录收尾阶段。
- [x] 详情页可返回录音首页，返回前后历史会议侧栏和会议行都保留。
- [x] 设置页有两个独立的“测试连接”按钮，并显示 DeepSeek 模型和 Notion 页面标题。
- [x] “总结并归档”依次显示正在总结、正在归档、已归档与 Notion 链接。
- [x] 右键菜单的重命名、最近置顶/取消置顶、删除取消与确认流程可用，详情页也可重命名。
- [x] 本地录音播放器显示竖线波形，支持播放/暂停和键盘拖动等效的实际跳转，暂停后时间保持稳定。
- [x] 详情页打开时会议从录制中变为可播放后，播放器自动准备。

## macOS 26 视觉与动效回归

- [x] 整个主窗口与历史会议侧栏共享窗口级原生 Liquid Glass，侧栏列表背景透明且会议行可读。
- [x] macOS 26.5 上首页主按钮、详情关键卡片、设置卡片、返回按钮和录音浮窗显示原生 Liquid Glass。
- [x] 长转录、书签和长总结区未叠加高强度玻璃，文字可读性正常。
- [x] 详情切换动画只作用于主内容，不动画侧栏和时长数字。
- [x] Reduce Motion 策略和浮窗零动画路径由单元测试覆盖。
- [x] macOS 15 部署目标编译通过；macOS 26 API 均受可用性检查保护，旧系统使用 Material/系统按钮回退。

对应自动化：`MeetingNotesUITests/MeetingFlowUITests.swift`。

## 一小时等价稳定性

- [x] 快速注入 3,600 个一秒逻辑音频帧，writer 计数等于 57,600,000 个逻辑样本。
- [x] 模型准备被挂起时，实时转录内存队列不超过 8 个分片。
- [x] 超出实时队列容量的样本不继续驻留内存；完整音频写入路径不丢帧，并保留会话内待补转录范围。
- [x] 一小时等价生产循环在 2 秒内返回，不受转录准备阻塞。

对应自动化：`MeetingNotesTests/LongRecordingHarnessTests.swift`。真实 PCM 分片边界和文件帧数另由 `SegmentedPCMWriterTests` 覆盖。

## 真机端到端检查（Task 12，待用户手动确认）

每项记录日期、macOS 版本、机器型号、结果和证据路径。

- [ ] 启动固定验收 App 后，确认一致快照中的现有历史会议在侧栏可见且未置顶。
- [ ] 右键重命名/置顶/删除和触控板左右滑动均在真实历史会议上可用。
- [ ] 麦克风权限与中文线下录音；停止后播放并拖动真实波形进度。
- [ ] 紧接着开始第二次线下会议并正常停止，确认上一次资源已释放。
- [ ] 录制英文或中英混合片段，确认转录保留会议中实际使用的语言且无 Whisper 控制码。
- [ ] 屏幕录制权限与在线系统音频 + 麦克风。
- [ ] 在线模式不产生屏幕视频文件。
- [ ] 录音、暂停、继续、结束与书签。
- [ ] WhisperKit 模型首次下载、本地转录和失败重试。
- [ ] 强制结束 App 后恢复已落盘会议。
- [ ] DeepSeek Key 保存、重启、测试连接和真实总结。
- [ ] Notion Token 保存、重启、父页面测试、归档和失败重试。
- [ ] 归档会议后重命名，确认对应 Notion 页面标题同步更新。
- [ ] 模拟 Notion Token 缺失或网络失败，确认本地已归档标题不会与 Notion 分叉。
- [ ] 普通日志中不存在 Key、Token、完整转录或音频内容。
- [ ] VoiceOver、全键盘、浅色与深色模式。

## 证据记录

| 日期 | 检查项 | 结果 | 证据/备注 |
|---|---|---|---|
| 2026-07-14 | 长录音 harness | 通过 | `LongRecordingHarnessTests` 及相关队列/协调器测试共 14 项通过 |
| 2026-07-14 | arm64 干净单元回归 | 通过 | 全新 DerivedData，124/124 通过，0 失败 |
| 2026-07-14 | Release 架构 | 通过 | `file`: Mach-O 64-bit executable arm64；`lipo`: arm64 |
| 2026-07-14 | Release 假数据审计 | 通过 | 二进制中无 UI 测试 Key、Token、页面标题或假总结文本 |
| 2026-07-14 | UI 流程 + 长录音 harness | 通过 | Developer Mode enabled；本机临时签名；全新 DerivedData，5/5 通过 |
| 2026-07-14 | `-uiTesting` App 直接启动 | 通过 | Debug App 进程正常保持运行，随后主动退出 |
| 2026-07-14 | Xcode 工程再生成 | 环境缺失 | 当前机器未安装 `xcodegen`；已提交工程可正常构建 |
| 2026-07-15 | 真实 Notion 父页面连接 | 通过 | 重启临时签名 App 后复用 Keychain Token；父页面链接测试显示“连接成功：会议记录”，两次真实请求均返回 HTTP 200。实际归档与失败重试仍待验收 |
| 2026-07-15 | Liquid Glass 实机视觉回归 | 通过 | macOS 26.5 / arm64；首页、浮窗、结束后详情、返回首页、设置、已归档详情共 6 张 XCTest 截图已逐张检查；结果包为 `/tmp/meetingnotes-visual-ui/Logs/Test/Test-MeetingNotes-2026.07.15_10-49-24-+0800.xcresult` |
| 2026-07-15 | 完整回归 | 通过 | arm64 单元测试 130/130；UI 流程 4/4；0 失败 |
| 2026-07-15 | 签名与架构 | 通过 | macOS 15 部署目标构建成功；`file` 为 Mach-O 64-bit executable arm64；`codesign --verify --deep --strict` 通过 |
| 2026-07-15 | 整窗 Liquid Glass 回归 | 通过 | macOS 26.5 / arm64；主窗口、历史侧栏、详情页、设置页及浮窗共 6 张 XCTest 截图逐张检查；结果包为 `/tmp/meetingnotes-window-glass-ui-full/Logs/Test/Test-MeetingNotes-2026.07.15_11-52-45-+0800.xcresult` |
| 2026-07-17 | 旧 store 主文件保护副本 | 已被一致备份取代 | `/tmp/MeetingNotes-default-store-before-pin-20260717-115107.store` 与当时主文件 SHA-256 一致，但在 SQLite WAL 模式下，单独复制主文件不能证明获得了完整逻辑快照。该副本保留，不再作为完整备份证据 |
| 2026-07-17 | 真实 store 一致性验收前备份 | 通过 | 通过 SQLite `.backup` 生成 `/tmp/MeetingNotes-consistent-before-manual-fixes-20260717-124928.store`；`PRAGMA quick_check=ok`，包含 1 条会议、0 条转录；SHA-256 `17f2562833b2d160e2f52adf83dac3a8cca4f57a419fe5f397eac86685bd7c8f` |
| 2026-07-17 | clean arm64 单元回归 | 通过 | 全新 DerivedData，276/276、0 失败；`/tmp/meetingnotes-task12-unit-20260717-115107/Logs/Test/Run-MeetingNotes-2026.07.17_11-53-49-+0800.xcresult` |
| 2026-07-17 | 签名 UI 流程 + 长录音 harness | 通过 | 完整 UI 8/8、harness 1/1、0 失败；`/tmp/meetingnotes-task12-ui-20260717-115107/Logs/Test/Test-MeetingNotes-2026.07.17_11-55-10-+0800.xcresult`。`-uiTesting` 使用假服务，不代表真实 DeepSeek/Notion 通过 |
| 2026-07-17 | 固定 Debug 验收包 | 自动化通过 | `/tmp/meetingnotes-feature-real-build/Build/Products/Debug/MeetingNotes.app`；`file` = Mach-O 64-bit executable arm64，`lipo` = arm64，严格 `codesign --verify` 通过；仅 ad-hoc 本机签名，不可用于分发 |
| 2026-07-17 | 真实录音、在线捕获、Notion 归档/标题同步 | 待用户手动确认 | 自动化证据不足以声称这些真实权限、语音或外部服务流程已通过 |
