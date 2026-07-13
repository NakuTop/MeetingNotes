# Apple Silicon 原生会议记录 App Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 构建一款仅支持 Apple Silicon、可录制线下与在线会议、本地转录、用 DeepSeek 总结并归档到 Notion 的原生 macOS App。

**Architecture:** SwiftUI 主窗口与 AppKit 浮窗共享一个 actor 隔离的 `MeetingCoordinator`。AVFoundation/ScreenCaptureKit 产生统一的 16 kHz 单声道音频帧，分片落盘并交给 WhisperKit；SwiftData 保存领域状态，URLSession 服务调用 DeepSeek 与 Notion，Keychain 保存凭据。

**Tech Stack:** Swift 6.2、SwiftUI、AppKit、AVFoundation、ScreenCaptureKit、SwiftData、Security、URLSession、XCTest、WhisperKit/Argmax OSS、XcodeGen、macOS 15+、arm64。

---

## 开始前约定

- 工作目录：`/Users/shenminghao/Documents/会议记录app`
- 工程名：`MeetingNotes`
- App target：`MeetingNotes`
- 单元测试 target：`MeetingNotesTests`
- UI 测试 target：`MeetingNotesUITests`
- Bundle ID：`com.shenminghao.MeetingNotes`
- 所有构建都把 DerivedData 写入仓库内的 `.deriveddata`，并加入 `.gitignore`。
- 每个实现步骤都遵循 TDD：先写失败测试、确认失败、写最小实现、确认通过、提交。
- 需要真实权限、真实音频设备或外部服务的测试必须标为手动/端到端测试；可确定的业务逻辑不得只依赖手测。

通用测试命令：

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO
```

## Task 1: 建立可测试的 macOS arm64 工程

**Files:**

- Create: `.gitignore`
- Create: `project.yml`
- Create: `MeetingNotes/Resources/Info.plist`
- Create: `MeetingNotes/Resources/MeetingNotes.entitlements`
- Create: `MeetingNotes/App/MeetingNotesApp.swift`
- Create: `MeetingNotes/Views/RootView.swift`
- Create: `MeetingNotesTests/BootstrapTests.swift`
- Create: `MeetingNotesUITests/MeetingNotesUITests.swift`

**Step 1: 安装并确认工程生成器**

Run:

```bash
command -v xcodegen || brew install xcodegen
xcodegen --version
```

Expected: 输出 XcodeGen 版本；安装动作需要用户授权时先请求授权。

**Step 2: 写工程清单与失败的启动测试**

`project.yml` 必须包含以下完整基线：

```yaml
name: MeetingNotes
options:
  deploymentTarget:
    macOS: "15.0"
settings:
  base:
    ARCHS: arm64
    EXCLUDED_ARCHS: x86_64
    SWIFT_VERSION: 6.0
    MACOSX_DEPLOYMENT_TARGET: 15.0
targets:
  MeetingNotes:
    type: application
    platform: macOS
    sources:
      - MeetingNotes
    info:
      path: MeetingNotes/Resources/Info.plist
    entitlements:
      path: MeetingNotes/Resources/MeetingNotes.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.shenminghao.MeetingNotes
        PRODUCT_NAME: MeetingNotes
        CODE_SIGN_ENTITLEMENTS: MeetingNotes/Resources/MeetingNotes.entitlements
  MeetingNotesTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - MeetingNotesTests
    dependencies:
      - target: MeetingNotes
  MeetingNotesUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - MeetingNotesUITests
    dependencies:
      - target: MeetingNotes
schemes:
  MeetingNotes:
    build:
      targets:
        MeetingNotes: all
        MeetingNotesTests: [test]
        MeetingNotesUITests: [test]
    test:
      targets:
        - MeetingNotesTests
        - MeetingNotesUITests
```

`MeetingNotesTests/BootstrapTests.swift`：

```swift
import XCTest
@testable import MeetingNotes

final class BootstrapTests: XCTestCase {
    func testRootViewCanBeConstructed() {
        XCTAssertNotNil(RootView())
    }
}
```

**Step 3: 生成工程并确认测试失败**

Run:

```bash
xcodegen generate
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests/BootstrapTests
```

Expected: FAIL，提示 `RootView` 或 App target 尚未定义。

**Step 4: 写最小 App、权限描述和沙盒能力**

`Info.plist` 包含 `NSMicrophoneUsageDescription`、`NSScreenCaptureUsageDescription`、`LSMinimumSystemVersion=15.0`；entitlements 包含 App Sandbox、audio input 与 outgoing network client。

`MeetingNotes/App/MeetingNotesApp.swift`：

```swift
import SwiftUI

@main
struct MeetingNotesApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
        Settings { Text("设置") }
    }
}
```

`MeetingNotes/Views/RootView.swift`：

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        Text("会议记录")
            .frame(minWidth: 900, minHeight: 600)
    }
}
```

`.gitignore` 至少包含 `.deriveddata/`、`*.xcuserstate`、`xcuserdata/` 和 `.DS_Store`。

**Step 5: 重新生成、测试并提交**

Run:

```bash
xcodegen generate
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests/BootstrapTests
git add .gitignore project.yml MeetingNotes MeetingNotesTests MeetingNotesUITests MeetingNotes.xcodeproj
git commit -m "build: bootstrap native macOS app"
```

Expected: `BootstrapTests` PASS；生成工程只包含 arm64 App target。

## Task 2: 实现录音领域状态机

**Files:**

- Create: `MeetingNotes/Domain/RecordingState.swift`
- Create: `MeetingNotes/Domain/RecordingStateMachine.swift`
- Test: `MeetingNotesTests/RecordingStateMachineTests.swift`

**Step 1: 写状态转换失败测试**

覆盖以下转换：

- `idle -> preparing -> recording`
- `recording <-> paused`
- `recording/paused -> finalizing -> ready`
- `ready -> summarizing -> summaryReady -> archiving -> archived`
- `summarizing -> ready` 和 `archiving -> summaryReady` 的失败回退
- 所有非法转换抛出 `invalidTransition`

核心测试示例：

```swift
func testPauseAndResume() throws {
    var machine = RecordingStateMachine(state: .recording)
    try machine.send(.pause)
    XCTAssertEqual(machine.state, .paused)
    try machine.send(.resume)
    XCTAssertEqual(machine.state, .recording)
}

func testCannotBookmarkWhenIdle() {
    var machine = RecordingStateMachine()
    XCTAssertThrowsError(try machine.send(.bookmark))
}
```

**Step 2: 运行并确认失败**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests/RecordingStateMachineTests
```

Expected: FAIL，领域类型不存在。

**Step 3: 写最小状态机**

`RecordingState`、`RecordingAction` 必须是 `String, Codable, Sendable`；`RecordingStateMachine` 用显式 switch 定义合法转换，`bookmark` 在 `.recording` 和 `.paused` 下保持原状态，其余状态抛错。不得用“默认允许”分支。

```swift
struct RecordingStateMachine: Sendable {
    private(set) var state: RecordingState = .idle

    mutating func send(_ action: RecordingAction) throws {
        switch (state, action) {
        case (.idle, .prepare): state = .preparing
        case (.preparing, .start): state = .recording
        case (.recording, .pause): state = .paused
        case (.paused, .resume): state = .recording
        case (.recording, .stop), (.paused, .stop): state = .finalizing
        case (.finalizing, .finalized): state = .ready
        case (.recording, .bookmark), (.paused, .bookmark): break
        case (.ready, .summarize): state = .summarizing
        case (.summarizing, .summarySucceeded): state = .summaryReady
        case (.summarizing, .summaryFailed): state = .ready
        case (.summaryReady, .archive): state = .archiving
        case (.archiving, .archiveSucceeded): state = .archived
        case (.archiving, .archiveFailed): state = .summaryReady
        default: throw RecordingStateError.invalidTransition(state, action)
        }
    }
}
```

**Step 4: 运行测试并提交**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests/RecordingStateMachineTests
git add MeetingNotes/Domain MeetingNotesTests/RecordingStateMachineTests.swift
git commit -m "feat: add meeting recording state machine"
```

Expected: PASS。

## Task 3: 实现有效录音时间轴与书签

**Files:**

- Create: `MeetingNotes/Domain/ActiveRecordingTimeline.swift`
- Create: `MeetingNotes/Domain/BookmarkWindow.swift`
- Test: `MeetingNotesTests/ActiveRecordingTimelineTests.swift`
- Test: `MeetingNotesTests/BookmarkWindowTests.swift`

**Step 1: 写失败测试**

测试开始于 100 秒、120 秒暂停、140 秒恢复时，150 秒的有效录音时间为 30 秒；暂停时书签固定在暂停前时间；书签窗口限制为前后 30 秒且不小于零。

```swift
func testPausedWallClockTimeIsExcluded() throws {
    var timeline = ActiveRecordingTimeline(startedAt: 100)
    try timeline.pause(at: 120)
    try timeline.resume(at: 140)
    XCTAssertEqual(timeline.activeTime(at: 150), 30, accuracy: 0.001)
}
```

**Step 2: 运行并确认失败**

Run the two test classes with `-only-testing`。Expected: FAIL，类型不存在。

**Step 3: 写纯值类型实现**

`ActiveRecordingTimeline` 只接收单调时钟的 `TimeInterval`，不直接读取 `Date`；记录累计暂停时长并拒绝重复暂停/恢复。`BookmarkWindow` 返回与转录片段相交的闭区间。

**Step 4: 运行测试并提交**

Expected: 两个测试类 PASS。

```bash
git add MeetingNotes/Domain MeetingNotesTests/ActiveRecordingTimelineTests.swift MeetingNotesTests/BookmarkWindowTests.swift
git commit -m "feat: add active timeline and bookmarks"
```

## Task 4: 建立 SwiftData 会议存储

**Files:**

- Create: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Create: `MeetingNotes/Persistence/Models/TranscriptRecord.swift`
- Create: `MeetingNotes/Persistence/Models/BookmarkRecord.swift`
- Create: `MeetingNotes/Persistence/Models/SummaryRecord.swift`
- Create: `MeetingNotes/Persistence/Models/ArchiveCheckpointRecord.swift`
- Create: `MeetingNotes/Persistence/MeetingRepository.swift`
- Test: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: 写内存容器失败测试**

测试创建会议、追加最终转录、追加书签、保存总结、保存 archive checkpoint、查询列表和级联删除。

```swift
@MainActor
func testCreateAppendAndReloadMeeting() throws {
    let repository = try MeetingRepository.inMemory()
    let id = try repository.createMeeting(mode: .offline, startedAt: .now)
    try repository.appendTranscript(meetingID: id, start: 0, end: 5, text: "项目开始")
    let meeting = try repository.meeting(id: id)
    XCTAssertEqual(meeting.transcripts.first?.text, "项目开始")
}
```

**Step 2: 运行并确认失败**

Expected: FAIL，repository/model 不存在。

**Step 3: 写模型与 repository**

- `MeetingRecord` 保存状态 raw value、模式、时间、相对 manifest 路径、Notion page ID/URL 和最后错误代码。
- `TranscriptRecord` 保存起止秒数、正文、是否最终、预留的可空 speaker ID。
- `BookmarkRecord` 保存有效录音时间。
- `SummaryRecord` 把数组字段编码为 JSON Data，避免不透明 transformable。
- `ArchiveCheckpointRecord` 保存 section 与 batch index。
- `MeetingRepository` 标记 `@MainActor`，所有写操作显式 `context.save()`。

**Step 4: 运行测试并提交**

Run repository tests, then full unit suite. Expected: PASS。

```bash
git add MeetingNotes/Persistence MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat: persist meetings with SwiftData"
```

## Task 5: 建立会议文件目录和分片清单

**Files:**

- Create: `MeetingNotes/Recording/AudioSegmentManifest.swift`
- Create: `MeetingNotes/Recording/MeetingFileStore.swift`
- Test: `MeetingNotesTests/MeetingFileStoreTests.swift`

**Step 1: 写失败测试**

使用临时目录验证：

- 每个 meeting 使用独立 UUID 目录。
- manifest 原子写入并可重新加载。
- 只能解析根目录内的受控相对路径，拒绝 `..` 路径逃逸。
- 删除会议目录不影响其他会议。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 actor 隔离的文件存储**

`AudioSegmentManifest` 使用 Codable，记录版本、采样率 16000、声道 1、分片文件名、起止时间、frame count 与 complete 标记。`MeetingFileStore` 接收可注入 root URL，使用临时文件加 replace/move 实现原子 manifest 写入。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Recording/AudioSegmentManifest.swift MeetingNotes/Recording/MeetingFileStore.swift MeetingNotesTests/MeetingFileStoreTests.swift
git commit -m "feat: add recoverable meeting file store"
```

## Task 6: 实现 16 kHz PCM 分片写入

**Files:**

- Create: `MeetingNotes/Recording/CapturedAudioFrame.swift`
- Create: `MeetingNotes/Recording/SegmentedPCMWriter.swift`
- Test: `MeetingNotesTests/SegmentedPCMWriterTests.swift`

**Step 1: 写失败测试**

构造 16 kHz 正弦波 Float 数组，写入超过一个短测试分片阈值，断言产生多个可由 `AVAudioFile` 打开的 CAF 文件、frame 总数一致、manifest 只把关闭后的分片标为 complete。

```swift
let frame = CapturedAudioFrame(timestamp: 0, sampleRate: 16_000, samples: samples)
try await writer.append(frame)
let manifest = try await writer.finish()
XCTAssertEqual(manifest.segments.reduce(0) { $0 + $1.frameCount }, Int64(samples.count))
```

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写最小分片写入器**

- `CapturedAudioFrame` 为 `Sendable` 值类型，只包含 Float 样本，避免跨 actor 传递 `AVAudioPCMBuffer`。
- writer 拒绝非 16 kHz 单声道输入。
- 正式分片目标为 15 秒；测试可注入更短 frame limit。
- 使用 `AVAudioFile(forWriting:settings:)` 写 Float32 CAF。
- 每次关闭分片后 fsync/close，再更新 manifest。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Recording/CapturedAudioFrame.swift MeetingNotes/Recording/SegmentedPCMWriter.swift MeetingNotesTests/SegmentedPCMWriterTests.swift
git commit -m "feat: write recoverable PCM audio segments"
```

## Task 7: 实现异常会话恢复

**Files:**

- Create: `MeetingNotes/Recovery/MeetingRecoveryService.swift`
- Test: `MeetingNotesTests/MeetingRecoveryServiceTests.swift`

**Step 1: 写失败测试**

覆盖：

- `recording/paused/finalizing` 会话启动后被标记为可恢复。
- 丢弃 manifest 中 incomplete 尾段。
- 保留 complete 分片、转录和书签。
- 已完成/归档会话不进入恢复列表。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写恢复服务**

服务扫描 repository 中断状态和文件 manifest，产出 `RecoveryCandidate`。确认恢复时把状态改为 `.ready` 或 `.finalizing`，排队补转录；绝不自动宣称仍在采集。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Recovery MeetingNotesTests/MeetingRecoveryServiceTests.swift
git commit -m "feat: recover interrupted meeting sessions"
```

## Task 8: 实现 Keychain 与非敏感设置存储

**Files:**

- Create: `MeetingNotes/Security/CredentialStore.swift`
- Create: `MeetingNotes/Security/KeychainCredentialStore.swift`
- Create: `MeetingNotes/Settings/AppSettingsStore.swift`
- Test: `MeetingNotesTests/KeychainCredentialStoreTests.swift`
- Test: `MeetingNotesTests/AppSettingsStoreTests.swift`

**Step 1: 写失败测试**

使用随机 service/account 验证保存、读取、覆盖、删除和不存在；使用独立 UserDefaults suite 验证模型名称与 Notion 页面链接持久化。增加显示掩码测试：短 key 全遮挡，长 key 只暴露末四位。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 Keychain 实现**

协议：

```swift
protocol CredentialStore: Sendable {
    func value(for key: CredentialKey) throws -> String?
    func save(_ value: String, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
}
```

Keychain query 使用 generic password、固定 service、不同 account，保存属性使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。所有 `OSStatus` 映射为不包含凭据的 typed error。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Security MeetingNotes/Settings MeetingNotesTests/KeychainCredentialStoreTests.swift MeetingNotesTests/AppSettingsStoreTests.swift
git commit -m "feat: store service credentials in Keychain"
```

## Task 9: 建立可测试 HTTP 层与脱敏日志

**Files:**

- Create: `MeetingNotes/Networking/HTTPClient.swift`
- Create: `MeetingNotes/Networking/URLSessionHTTPClient.swift`
- Create: `MeetingNotes/Logging/RedactingLogger.swift`
- Create: `MeetingNotesTests/Support/URLProtocolStub.swift`
- Test: `MeetingNotesTests/HTTPClientTests.swift`
- Test: `MeetingNotesTests/RedactingLoggerTests.swift`

**Step 1: 写失败测试**

- stub 返回指定 status/data。
- 非 2xx 映射为包含 status 但不包含 body secret 的错误。
- logger 删除 Authorization、API Key、Notion Token 和会议正文，只保留 request ID、状态码、路径和错误类别。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写协议与实现**

```swift
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

`URLSessionHTTPClient` 使用 ephemeral configuration，不启用 URLCache；request timeout 由各服务显式设置。`RedactingLogger` 只接受结构化白名单字段，不接受任意响应正文。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Networking MeetingNotes/Logging MeetingNotesTests/Support MeetingNotesTests/HTTPClientTests.swift MeetingNotesTests/RedactingLoggerTests.swift
git commit -m "feat: add testable redacted networking layer"
```

## Task 10: 实现 DeepSeek 连接测试与结构化总结

**Files:**

- Create: `MeetingNotes/DeepSeek/DeepSeekModels.swift`
- Create: `MeetingNotes/DeepSeek/DeepSeekClient.swift`
- Create: `MeetingNotes/DeepSeek/MeetingSummaryPrompt.swift`
- Test: `MeetingNotesTests/DeepSeekClientTests.swift`
- Test: `MeetingNotesTests/MeetingSummaryPromptTests.swift`

**Step 1: 写失败测试**

测试：

- `GET https://api.deepseek.com/models` 带 Bearer header，能解析模型列表。
- 总结请求使用 `/chat/completions`、配置模型、`response_format=json_object`。
- 解析建议标题、摘要、关键点、决定、行动项和书签洞察。
- `finish_reason=length`、401、429、5xx、超时和无效 JSON 映射为不同错误。
- 错误 description 不包含 key 或完整转录。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 DeepSeek client**

结构化输出模型：

```swift
struct GeneratedMeetingSummary: Codable, Equatable, Sendable {
    let suggestedTitle: String
    let overview: String
    let keyPoints: [String]
    let decisions: [String]
    let actionItems: [ActionItem]
    let bookmarkInsights: [String]
}

struct ActionItem: Codable, Equatable, Sendable {
    let task: String
    let owner: String?
    let dueDate: String?
}
```

system prompt 明确要求只输出 JSON、不得捏造负责人或日期、缺失值用 null。长输入策略封装为 `SummaryInputChunker`：超过预算时先按转录段聚合局部摘要，再对局部摘要做最终汇总。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/DeepSeek MeetingNotesTests/DeepSeekClientTests.swift MeetingNotesTests/MeetingSummaryPromptTests.swift
git commit -m "feat: summarize meetings with DeepSeek"
```

## Task 11: 实现 Notion 链接解析与内容分块

**Files:**

- Create: `MeetingNotes/Notion/NotionPageLinkParser.swift`
- Create: `MeetingNotes/Notion/NotionBlockBuilder.swift`
- Test: `MeetingNotesTests/NotionPageLinkParserTests.swift`
- Test: `MeetingNotesTests/NotionBlockBuilderTests.swift`

**Step 1: 写失败测试**

覆盖带标题 slug、32 位无连字符 ID、UUID、查询参数和非法域名；内容分块测试 emoji/中文等扩展字符不会从 grapheme 中间切断，每个 rich text content 不超过 1900 字符，每批最多 100 blocks。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写纯函数实现**

Parser 只接受 `notion.so` 与 `www.notion.so` 的 https URL，并把 32 hex 规范化为 UUID。Block builder 按“元信息、摘要、关键结论、决定事项、行动项、书签、完整转录”生成 heading 与 paragraph/list blocks；切分阈值使用 1900，给 API 限制留余量。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Notion/NotionPageLinkParser.swift MeetingNotes/Notion/NotionBlockBuilder.swift MeetingNotesTests/NotionPageLinkParserTests.swift MeetingNotesTests/NotionBlockBuilderTests.swift
git commit -m "feat: build safe Notion meeting blocks"
```

## Task 12: 实现 Notion 连接测试和幂等归档

**Files:**

- Create: `MeetingNotes/Notion/NotionModels.swift`
- Create: `MeetingNotes/Notion/NotionClient.swift`
- Create: `MeetingNotes/Notion/NotionArchiveService.swift`
- Test: `MeetingNotesTests/NotionClientTests.swift`
- Test: `MeetingNotesTests/NotionArchiveServiceTests.swift`

**Step 1: 写失败测试**

测试连接依次调用 `/v1/users/me` 与 `/v1/pages/{pageID}`，header 包含 Bearer 和 `Notion-Version: 2026-03-11`。归档测试验证：

- 没有 page ID 时只创建一次子页面。
- 创建响应后立即保存 page ID/URL。
- blocks 分批 PATCH。
- 中途失败保存 checkpoint。
- 重试继续同一 page，不重复创建、不重复已确认批次。
- 401/403/404/429 映射为可执行错误。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 client 与 archive service**

`NotionClient` 仅负责 REST 编解码；`NotionArchiveService` 负责 repository checkpoint。所有写入操作必须先读本地 `notionPageID` 和 checkpoint，再决定 create 或 append。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Notion MeetingNotesTests/NotionClientTests.swift MeetingNotesTests/NotionArchiveServiceTests.swift
git commit -m "feat: archive meetings to Notion idempotently"
```

## Task 13: 实现音频转换与麦克风采集

**Files:**

- Create: `MeetingNotes/Recording/AudioCaptureSource.swift`
- Create: `MeetingNotes/Recording/PCMConverter.swift`
- Create: `MeetingNotes/Recording/MicrophoneCaptureSource.swift`
- Create: `MeetingNotes/Permissions/CapturePermissionClient.swift`
- Test: `MeetingNotesTests/PCMConverterTests.swift`
- Test: `MeetingNotesTests/CapturePermissionClientTests.swift`

**Step 1: 写失败测试**

- 48 kHz 双声道输入转换为 16 kHz 单声道，时长误差在一个 frame 内。
- 静音保持静音，最大幅度不超过 1。
- 权限状态映射 authorized/denied/notDetermined。
- 线下模式只请求麦克风，在线模式需要麦克风和屏幕捕获。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写采集协议与麦克风实现**

```swift
protocol AudioCaptureSource: Sendable {
    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error>
    func pause() async throws
    func resume() async throws
    func stop() async
}
```

`MicrophoneCaptureSource` 在 `AVAudioEngine.inputNode` 安装 tap，在专用队列用 `AVAudioConverter` 转为 16 kHz mono Float；只把 `CapturedAudioFrame` 值传出。stop 必须移除 tap、停止 engine 并结束 stream。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Recording MeetingNotes/Permissions MeetingNotesTests/PCMConverterTests.swift MeetingNotesTests/CapturePermissionClientTests.swift
git commit -m "feat: capture and normalize microphone audio"
```

## Task 14: 实现在线会议双路音频与实时混音

**Files:**

- Create: `MeetingNotes/Recording/RealtimeAudioMixer.swift`
- Create: `MeetingNotes/Recording/ScreenAudioCaptureSource.swift`
- Test: `MeetingNotesTests/RealtimeAudioMixerTests.swift`
- Test: `MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift`

**Step 1: 写失败测试**

- 相同时间戳的 mic/system 样本平均混合。
- 单路缺失时保留现有音频。
- 过载时钳制到 -1...1。
- 抖动/不同起始时间按固定 frame 窗口对齐。
- 配置必须 `capturesAudio=true`、`captureMicrophone=true`、`excludesCurrentProcessAudio=true`，且不注册 screen output。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 mixer 与 ScreenCaptureKit adapter**

`SCStream` 只添加 `.audio` 与 `.microphone` stream outputs。各回调把 CMSampleBuffer 转为统一 PCM frame，并用样本时间戳送入 actor 隔离 mixer。mixer 输出固定时间窗的 16 kHz mono samples；App 不写视频帧。

使用 `SCShareableContent` 取得主显示器并建立 content filter，排除当前 App。系统授权失败转换为 `CapturePermissionError.screenRecordingDenied`。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Recording/RealtimeAudioMixer.swift MeetingNotes/Recording/ScreenAudioCaptureSource.swift MeetingNotesTests/RealtimeAudioMixerTests.swift MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift
git commit -m "feat: capture online meeting system audio"
```

## Task 15: 集成 WhisperKit 本地转录

**Files:**

- Modify: `project.yml`
- Create: `MeetingNotes/Transcription/TranscriptionService.swift`
- Create: `MeetingNotes/Transcription/WhisperKitTranscriptionService.swift`
- Create: `MeetingNotes/Transcription/TranscriptionQueue.swift`
- Create: `MeetingNotes/Transcription/TranscriptMerger.swift`
- Test: `MeetingNotesTests/TranscriptionQueueTests.swift`
- Test: `MeetingNotesTests/TranscriptMergerTests.swift`

**Step 1: 添加包声明并写失败测试**

在 `project.yml` 增加：

```yaml
packages:
  ArgmaxOSS:
    url: https://github.com/argmaxinc/argmax-oss-swift.git
    from: 1.0.0
```

App target dependencies 增加 `package: ArgmaxOSS, product: WhisperKit`。

测试使用 fake `TranscriptionService` 验证：分片按序处理、录音写入不等待转录、失败分片可重新排队、结束时 drain queue、相邻转录去除重复边界文本并保留时间戳。

**Step 2: 解析包并确认测试失败**

Run:

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project MeetingNotes.xcodeproj -scheme MeetingNotes
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests/TranscriptionQueueTests \
  -only-testing:MeetingNotesTests/TranscriptMergerTests
```

Expected: 包解析成功，测试因实现缺失而 FAIL。

**Step 3: 写协议、队列与 WhisperKit adapter**

```swift
protocol TranscriptionService: Sendable {
    func prepare() async throws
    func transcribe(samples: [Float], startingAt: TimeInterval) async throws -> [TranscriptDraft]
}
```

adapter 延迟创建 `WhisperKit`，`prepare()` 负责首次模型准备/下载状态，`transcribe` 调用当前包版本的 `transcribe(audioArray:)`，把结果转换为 App 自有 `TranscriptDraft`。WhisperKit 类型不得泄漏到领域层。

`TranscriptionQueue` 每完成一个 15 秒分片就排队；严格单消费者，避免多个模型推理并发挤占内存。UI 可观察 waiting/processing/failed 状态。

**Step 4: 运行测试并提交**

```bash
xcodegen generate
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests/TranscriptionQueueTests \
  -only-testing:MeetingNotesTests/TranscriptMergerTests
git add project.yml MeetingNotes.xcodeproj MeetingNotes/Transcription MeetingNotesTests/TranscriptionQueueTests.swift MeetingNotesTests/TranscriptMergerTests.swift
git commit -m "feat: transcribe meeting audio on device"
```

## Task 16: 实现 MeetingCoordinator

**Files:**

- Create: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Create: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Test: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: 写失败测试**

用 fake capture/writer/transcriber/repository/panel presenter 覆盖：

- 选择模式后权限成功才进入 recording。
- 开始失败回滚并关闭已启动资源。
- pause/resume 同时控制采集与有效时间轴。
- bookmark 保存有效时间且不弹 UI。
- stop 的顺序是停止 capture、finish writer、drain transcription、保存 ready、隐藏 panel。
- 重复 start/stop 被状态机拒绝。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 actor coordinator**

`MeetingCoordinator` 是状态与副作用的唯一入口。公开方法只包含 `start(mode:)`、`pauseOrResume()`、`bookmark()`、`stop()`、`summarizeAndArchive()`；SwiftUI 通过 MainActor view model 观察快照，不直接修改状态。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Coordinator MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "feat: coordinate recording lifecycle"
```

## Task 17: 构建只有四个控件的悬浮录音条

**Files:**

- Create: `MeetingNotes/FloatingPanel/FloatingControl.swift`
- Create: `MeetingNotes/FloatingPanel/FloatingRecorderView.swift`
- Create: `MeetingNotes/FloatingPanel/FloatingPanelController.swift`
- Create: `MeetingNotes/FloatingPanel/FloatingPanelPresenter.swift`
- Test: `MeetingNotesTests/FloatingControlTests.swift`

**Step 1: 写失败测试**

```swift
func testFloatingPanelHasExactlyFourControlsInRequiredOrder() {
    XCTAssertEqual(FloatingControl.allCases, [.record, .pause, .stop, .bookmark])
}
```

再测试每个 control 有唯一 SF Symbol 和 VoiceOver label；pause 在 paused 状态只改变图标/label，不增加第五个 resume 控件。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 NSPanel 与 SwiftUI 内容**

- `NSPanel` 使用 `.nonactivatingPanel`、无标题、透明背景、floating level、可拖动。
- collectionBehavior 包含 `.canJoinAllSpaces` 与 `.fullScreenAuxiliary`。
- SwiftUI view 仅遍历 `FloatingControl.allCases` 生成四个按钮。
- 不添加 Text、计时器、波形或转录。
- panel 位置保存到非敏感 settings。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/FloatingPanel MeetingNotesTests/FloatingControlTests.swift
git commit -m "feat: add four-control floating recorder"
```

## Task 18: 构建会议列表、开始页和详情页

**Files:**

- Modify: `MeetingNotes/Views/RootView.swift`
- Create: `MeetingNotes/Views/MeetingSidebarView.swift`
- Create: `MeetingNotes/Views/StartMeetingView.swift`
- Create: `MeetingNotes/Views/MeetingDetailView.swift`
- Create: `MeetingNotes/Views/TranscriptView.swift`
- Create: `MeetingNotes/Views/BookmarkListView.swift`
- Create: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Test: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`

**Step 1: 写 view model 失败测试**

测试按 startedAt 倒序加载、选择会议、删除会议级联文件清理、线下/在线入口调用正确 coordinator mode、详情页在 ready 前禁用总结按钮。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写最小原生双栏 UI**

使用 `NavigationSplitView`。空状态只显示“线下会议”“在线会议”两个主按钮。详情按音频、转录、书签、总结/归档状态分区；转录按时间排序并高亮书签 ±30 秒范围。支持浅色/深色、键盘与 VoiceOver。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Views MeetingNotes/ViewModels MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "feat: add meeting library and detail views"
```

## Task 19: 构建凭据设置与两个连接测试按钮

**Files:**

- Create: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Create: `MeetingNotes/Views/SettingsView.swift`
- Modify: `MeetingNotes/App/MeetingNotesApp.swift`
- Test: `MeetingNotesTests/SettingsViewModelTests.swift`

**Step 1: 写失败测试**

覆盖：

- 保存时 Key/Token 进入 CredentialStore，模型/链接进入 AppSettingsStore。
- 重新加载只显示 masked 状态，不把完整 secret 放入公开属性。
- DeepSeek 测试使用当前输入或已保存 key，成功后更新模型列表。
- Notion 测试验证 token 与父页面并显示标题。
- 清除分别删除 credential。
- 测试期间按钮防重复点击，错误消息不包含 secret。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写设置 UI 与 view model**

使用 `SecureField`、模型 Picker、Notion URL TextField、两个独立“测试连接”、一个“保存设置”和对应清除按钮。连接状态使用 idle/testing/succeeded/failed enum，成功显示模型或页面标题，失败显示具体修复提示。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/ViewModels/SettingsViewModel.swift MeetingNotes/Views/SettingsView.swift MeetingNotes/App/MeetingNotesApp.swift MeetingNotesTests/SettingsViewModelTests.swift
git commit -m "feat: add persistent service settings"
```

## Task 20: 串联“总结并归档”单一操作

**Files:**

- Create: `MeetingNotes/Summary/SummarizeAndArchiveUseCase.swift`
- Create: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Test: `MeetingNotesTests/SummarizeAndArchiveUseCaseTests.swift`
- Test: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: 写失败测试**

覆盖：

- 没有最终转录时拒绝开始。
- DeepSeek 成功先本地保存 summary，再调用 Notion。
- 建议标题只替换默认标题，不覆盖用户手改标题。
- DeepSeek 失败保持 ready，不调用 Notion。
- Notion 失败保持 summaryReady，并显示“重试归档”。
- 重试归档复用本地 summary，不再次收费调用 DeepSeek。
- 处理中拒绝重复点击。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写 use case 与进度 UI**

详情按钮根据状态显示“总结并归档”“正在总结”“正在归档”“重试归档”或“已归档”。use case 通过 repository 判断是否已有 summary/page/checkpoint，并严格执行幂等路径。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Summary MeetingNotes/ViewModels/MeetingDetailViewModel.swift MeetingNotes/Views/MeetingDetailView.swift MeetingNotesTests/SummarizeAndArchiveUseCaseTests.swift MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: summarize and archive in one action"
```

## Task 21: 完成首次使用、权限修复和模型状态界面

**Files:**

- Create: `MeetingNotes/Onboarding/OnboardingState.swift`
- Create: `MeetingNotes/Views/OnboardingView.swift`
- Create: `MeetingNotes/Views/ModelStatusView.swift`
- Create: `MeetingNotes/System/SystemRequirements.swift`
- Modify: `MeetingNotes/Views/RootView.swift`
- Test: `MeetingNotesTests/SystemRequirementsTests.swift`
- Test: `MeetingNotesTests/OnboardingStateTests.swift`

**Step 1: 写失败测试**

测试 arm64/macOS 15 门槛、录音许可确认只提示一次、权限拒绝展示对应 System Settings 路径、模型未就绪允许录音但不宣称实时转录、下载失败可重试、磁盘阈值不足阻止开始。

**Step 2: 运行并确认失败**

Expected: FAIL。

**Step 3: 写首次使用与系统状态 UI**

启动时展示简短隐私说明与录音许可确认。权限请求保持按需：线下只请求 mic，在线再请求 screen capture。模型状态展示未下载/下载中/可用/失败；录音与转录准备解耦。

**Step 4: 运行测试并提交**

```bash
git add MeetingNotes/Onboarding MeetingNotes/System MeetingNotes/Views/OnboardingView.swift MeetingNotes/Views/ModelStatusView.swift MeetingNotes/Views/RootView.swift MeetingNotesTests/SystemRequirementsTests.swift MeetingNotesTests/OnboardingStateTests.swift
git commit -m "feat: add privacy onboarding and readiness checks"
```

## Task 22: 增加 UI 自动化与一小时稳定性测试工具

**Files:**

- Create: `MeetingNotes/App/LaunchArguments.swift`
- Create: `MeetingNotesUITests/MeetingFlowUITests.swift`
- Create: `MeetingNotesTests/LongRecordingHarnessTests.swift`
- Create: `docs/testing/manual-apple-silicon-checklist.md`

**Step 1: 写 UI 测试与稳定性测试**

UI test 使用 launch argument 注入 fake coordinator/services，验证：

- 首页只有两种会议入口。
- 启动录音后悬浮面板可见且恰有四个按钮。
- pause/resume 不增加按钮。
- 书签后详情出现书签。
- 设置页有两个测试连接按钮，能显示成功状态。
- 总结并归档显示两个阶段并最终出现 Notion URL。

长录音 harness 不等待真实一小时，而是快速注入等价于一小时的音频帧，断言 writer 无丢帧、队列有界、capture 生产不被 transcription 阻塞。

**Step 2: 运行并确认失败**

Run UI test class and harness. Expected: 初始 FAIL，测试注入入口不存在。

**Step 3: 写仅测试构建可用的依赖注入入口**

解析 `-uiTesting` launch argument，构建内存 repository、fake capture、fake DeepSeek/Notion。生产构建路径不得包含假成功逻辑。

**Step 4: 运行测试并提交**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesUITests/MeetingFlowUITests \
  -only-testing:MeetingNotesTests/LongRecordingHarnessTests
git add MeetingNotes/App/LaunchArguments.swift MeetingNotesUITests/MeetingFlowUITests.swift MeetingNotesTests/LongRecordingHarnessTests.swift docs/testing/manual-apple-silicon-checklist.md
git commit -m "test: cover end-to-end meeting workflows"
```

## Task 23: 全量验证、真机检查与 Release 构建

**Files:**

- Modify: `docs/testing/manual-apple-silicon-checklist.md`
- Create: `README.md`

**Step 1: 运行静态与全量测试**

Run:

```bash
git diff --check
xcodegen generate
xcodebuild clean test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`，无 Swift 6 concurrency error。

**Step 2: 运行 Release arm64 构建并检查二进制**

Run:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO
file .deriveddata/Build/Products/Release/MeetingNotes.app/Contents/MacOS/MeetingNotes
lipo -archs .deriveddata/Build/Products/Release/MeetingNotes.app/Contents/MacOS/MeetingNotes
```

Expected: Mach-O 64-bit executable arm64；`lipo` 只输出 `arm64`。

**Step 3: 在真实 Apple Silicon Mac 执行手动检查表**

必须逐项记录结果：

1. 麦克风权限与线下录音。
2. 屏幕录制权限与在线系统音频 + 麦克风。
3. 不产生屏幕视频文件。
4. 录音/暂停/继续/结束/书签。
5. 模型下载、离线转录和失败重试。
6. 强制结束 App 后恢复。
7. DeepSeek Key 保存、重启、测试、总结。
8. Notion Token 保存、重启、页面测试、归档和失败重试。
9. 日志中不存在 Key、Token、完整转录或音频内容。
10. VoiceOver、键盘、浅色和深色模式。

**Step 4: 写 README 并做完成审计**

README 说明系统要求、首次权限、模型下载、设置 DeepSeek/Notion、Notion 页面授权、数据存放与删除、构建/测试命令。逐条对照设计文档第 11 节的 13 项验收标准，给出测试或真机证据；任何缺失项都保持目标未完成。

**Step 5: 提交验证文档**

```bash
git add README.md docs/testing/manual-apple-silicon-checklist.md
git commit -m "docs: add setup and verified release checklist"
git status --short --branch
```

Expected: 工作树干净；所有自动化测试、Release arm64 检查和手动检查表均有证据。
