# MeetingNotes Apple Silicon 验证清单

更新日期：2026-07-14
目标平台：macOS 15+、Apple Silicon（arm64）

## 自动化前置条件

- [x] Xcode 可构建 arm64 App、单元测试和 UI 测试 Runner。
- [x] UI 自动化使用 `-uiTesting`，只在 `#if DEBUG` 中注入内存数据库与假服务。
- [x] 直接启动 Debug App 的 `-uiTesting` 路径后，进程保持运行且未崩溃。
- [ ] macOS Developer Mode 已启用。

当前机器的 `DevToolsSecurity -status` 返回 `Developer mode is currently disabled.`。因此 UI Runner 在建立 XCTest 连接前被系统以 SIGKILL 终止；这不是测试断言或 App 启动崩溃。启用 Developer Mode 后重新运行以下命令：

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests \
  -only-testing:MeetingNotesTests/LongRecordingHarnessTests
```

## UI 自动化场景

- [ ] 首页恰有“线下会议”和“在线会议”两个入口。
- [ ] 开始录音后悬浮面板可见，且恰有录音、暂停、结束、书签四个按钮。
- [ ] 暂停/继续只改变暂停按钮语义，不增加第五个按钮。
- [ ] 添加书签后详情页出现书签，结束会议后仍保留。
- [ ] 设置页有两个独立的“测试连接”按钮，并显示 DeepSeek 模型和 Notion 页面标题。
- [ ] “总结并归档”依次显示正在总结、正在归档、已归档与 Notion 链接。

对应自动化：`MeetingNotesUITests/MeetingFlowUITests.swift`。

## 一小时等价稳定性

- [x] 快速注入 3,600 个一秒逻辑音频帧，writer 计数等于 57,600,000 个逻辑样本。
- [x] 模型准备被挂起时，实时转录内存队列不超过 8 个分片。
- [x] 超出实时队列容量的样本不继续驻留内存；完整音频写入路径不丢帧，并保留会话内待补转录范围。
- [x] 一小时等价生产循环在 2 秒内返回，不受转录准备阻塞。

对应自动化：`MeetingNotesTests/LongRecordingHarnessTests.swift`。真实 PCM 分片边界和文件帧数另由 `SegmentedPCMWriterTests` 覆盖。

## 真机端到端检查（Task 23）

每项记录日期、macOS 版本、机器型号、结果和证据路径。

- [ ] 麦克风权限与线下录音。
- [ ] 屏幕录制权限与在线系统音频 + 麦克风。
- [ ] 在线模式不产生屏幕视频文件。
- [ ] 录音、暂停、继续、结束与书签。
- [ ] WhisperKit 模型首次下载、本地转录和失败重试。
- [ ] 强制结束 App 后恢复已落盘会议。
- [ ] DeepSeek Key 保存、重启、测试连接和真实总结。
- [ ] Notion Token 保存、重启、父页面测试、归档和失败重试。
- [ ] 普通日志中不存在 Key、Token、完整转录或音频内容。
- [ ] VoiceOver、全键盘、浅色与深色模式。

## 证据记录

| 日期 | 检查项 | 结果 | 证据/备注 |
|---|---|---|---|
| 2026-07-14 | 长录音 harness | 通过 | `LongRecordingHarnessTests` 及相关队列/协调器测试共 14 项通过 |
| 2026-07-14 | UI Runner 启动 | 系统阻塞 | Developer Mode disabled；Runner 在 XCTest 连接前 SIGKILL |
| 2026-07-14 | `-uiTesting` App 直接启动 | 通过 | Debug App 进程正常保持运行，随后主动退出 |
