# MeetingNotes

一款仅面向 Apple Silicon 的原生 macOS 会议记录 App。它支持线下麦克风录音、在线会议系统音频与麦克风混合录制、本地 WhisperKit 转录、DeepSeek 结构化总结，以及向指定 Notion 父页面归档。

当前状态：功能实现、arm64 单元测试和 UI 自动化流程已完成；真实麦克风/系统音频权限与真实 DeepSeek、Notion 端到端验收仍需使用者凭据完成，详见[真机检查表](docs/testing/manual-apple-silicon-checklist.md)。

## 系统要求

- Apple Silicon Mac（arm64），不支持 Intel Mac。
- macOS 15 或更高版本。
- Xcode 及 macOS 15+ SDK。
- 首次准备 WhisperKit 模型和调用 DeepSeek/Notion 时需要网络。
- 开始录音前至少保留 2 GB 可用磁盘空间。

## 隐私与数据流

- 原始音频和本地转录保留在这台 Mac，不发送给 DeepSeek。
- 只有点击“总结并归档”后，转录、会议元数据和书签上下文才会发送给 DeepSeek。
- DeepSeek 返回的总结、书签上下文和完整转录随后写入用户指定的 Notion 页面。
- DeepSeek API Key 与 Notion Token 存在 Keychain；普通设置只保存模型名与 Notion 父页面链接。
- 在线会议使用 ScreenCaptureKit 的音频输出，不写入屏幕视频文件。
- 第一次使用必须确认已了解隐私说明，并承诺在录音前取得必要许可。

## 使用方法

1. 首次启动时阅读隐私说明，确认会在录音前告知参会者并取得许可。
2. 首页查看本地转录模型状态。模型未就绪时仍可录音，App 不会宣称正在实时转录；失败后可重试模型准备。
3. 点击“线下会议”录制麦克风；点击“在线会议”录制系统音频与麦克风。
4. 首次使用相应模式时，按系统提示授予麦克风或屏幕录制权限。拒绝后可从错误条直接打开对应系统设置。
5. 悬浮条始终只有四项：录音状态、暂停/继续、结束、书签。
6. 结束后在详情页查看转录和书签；点击一次“总结并归档”生成本地总结并写入 Notion。
7. Notion 失败时点击“重试归档”。重试复用本地总结，不会再次调用 DeepSeek。

## DeepSeek 与 Notion 设置

使用 `⌘,` 打开设置。

### DeepSeek

1. 输入 DeepSeek API Key。
2. 点击“测试连接”。测试使用模型列表接口，不生成付费总结。
3. 从测试返回的模型中选择总结模型。
4. 点击“保存设置”。完整 Key 写入 Keychain，界面只显示掩码和末四位。

### Notion

1. 在 Notion 创建 integration 并取得 Token。
2. 将目标父页面共享给该 integration；仅有 Token 但未授权页面会得到权限或找不到页面错误。
3. 在设置中粘贴 Token 与父页面完整链接。
4. 点击“测试连接”，确认 App 能显示实际父页面标题。
5. 点击“保存设置”。归档会在该父页面下创建独立会议子页面。

## 本地数据与删除

App 启用了 macOS App Sandbox。生产环境中的录音位于 App 容器内的：

```text
~/Library/Containers/com.shenminghao.MeetingNotes/Data/Library/Application Support/MeetingNotes/Recordings/
```

会议、转录、书签、总结、恢复信息和 Notion 归档检查点由 SwiftData 管理，也位于 App 沙盒容器。模型文件由 WhisperKit 的本地缓存管理。

从左侧会议列表删除会议时，App 会删除对应本地音频目录和 SwiftData 记录（包括转录、书签、总结与检查点）。已经创建的 Notion 页面不会自动删除。

## 构建

项目由 [`project.yml`](project.yml) 描述。若修改了工程结构，先安装并运行 XcodeGen：

```bash
brew install xcodegen
xcodegen generate
```

Debug 构建：

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO
```

未签名构建仅用于本机开发与测试；正式分发需要配置开发者签名、公证和发布流程。

## 测试

arm64 单元测试：

```bash
xcodebuild clean test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests
```

UI 流程与一小时等价稳定性测试：

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests \
  -only-testing:MeetingNotesTests/LongRecordingHarnessTests
```

macOS UI Runner 需要启用 Developer Mode，并使用上面的本机临时签名参数；`CODE_SIGNING_ALLOWED=NO` 会使 UI Runner 的 XCTest 框架签名失效。测试 App 只有在 Debug 构建且明确传入 `-uiTesting` 时才注入内存数据库和假服务；Release 二进制不包含假凭据与假成功载荷。

Release arm64 检查：

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO

file .deriveddata/Build/Products/Release/MeetingNotes.app/Contents/MacOS/MeetingNotes
lipo -archs .deriveddata/Build/Products/Release/MeetingNotes.app/Contents/MacOS/MeetingNotes
```

## 验收证据（2026-07-14）

- 干净构建目录中的 arm64 单元测试：124/124 通过，无 Swift 6 concurrency error。
- 全新构建目录中的 UI 流程与长录音 harness：5/5 通过；覆盖双入口、悬浮四键、暂停/继续、书签持久化、设置双连接测试，以及总结/归档完整状态链和 Notion 链接。
- 一小时等价 harness：57,600,000 个逻辑样本全部到达 writer 计数；模型阻塞时实时转录内存队列不超过 8 个分片，生产循环少于 2 秒。
- Release：Mach-O 64-bit executable arm64，`lipo` 仅输出 `arm64`。
- Release 假数据审计：二进制中未发现 UI 测试 Key、Token、页面标题或假总结文本。
- `-uiTesting` Debug App 可直接启动并保持运行。
- UI Runner：本机 Developer Mode 已启用，并通过临时签名完成全部 UI 自动化。
- XcodeGen：当前机器未安装 `xcodegen`，因此本轮未重新生成工程；已提交的 `MeetingNotes.xcodeproj` 可正常完成上述构建。

### 13 项设计验收审计

| # | 验收项 | 当前证据 | 状态 |
|---|---|---|---|
| 1 | Release 为 arm64，运行于 macOS 15+ Apple Silicon | Release `file`/`lipo` 已通过；真实发布签名运行待检查 | 部分通过 |
| 2 | 线下麦克风录音与带时间戳本地转录 | 采集、协调器、PCM、转录单元测试通过 | 待真实麦克风验证 |
| 3 | 在线系统音频 + 麦克风，不保存视频 | ScreenCaptureKit 配置、混音和权限测试通过 | 待真实在线会议验证 |
| 4 | 悬浮条严格四个图标 | 枚举、SwiftUI 实现与 UI 流程测试通过 | 自动化通过 |
| 5 | 暂停/继续/结束/书签使用有效音频时间轴 | 状态机、时间轴、Coordinator 测试通过 | 自动化通过，待真机 |
| 6 | 一小时录音不被转录积压阻塞 | 一小时等价有界队列 harness 通过 | 自动化通过，待真实一小时 |
| 7 | 异常退出后恢复音频、文本和书签 | 恢复服务与分片清单测试通过 | 待真机强制退出 |
| 8 | DeepSeek 结构化总结，失败保留本地会议 | 客户端、解析、用例与失败恢复测试通过 | 待真实 Key |
| 9 | Notion 单页面幂等归档全部内容 | blocks、批次检查点、失败重试测试通过 | 待真实 Token/页面 |
| 10 | Key/Token 存入 Keychain，重启仍可用 | Keychain 保存/替换/删除测试通过 | 待重启验证 |
| 11 | 两个测试连接按钮给出成功或具体错误 | SettingsViewModel 与 UI 场景通过 | 自动化通过，待真实服务 |
| 12 | 日志不含凭据、完整转录和音频 | 网络与日志脱敏测试通过 | 待真机日志/崩溃日志审计 |
| 13 | 自动化与 Apple Silicon 真机端到端通过 | 124 项单元测试、4 项 UI 流程与 1 项长录音 harness 通过 | 自动化通过，真机真实服务清单待完成 |

任何标记为“待验证”的项目都不是已通过项。完整操作记录在[真机检查表](docs/testing/manual-apple-silicon-checklist.md)。
