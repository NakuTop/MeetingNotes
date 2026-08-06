# MeetingNotes Apple Silicon 验证清单

更新日期：2026-08-01
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
- [x] 设置页显示 MeetingNotes 专用输入/输出设备、测试按钮、权限修复、智能诊断、本地预览、发送同意和取消流程。
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

## 音频设备与智能诊断真机验收（待用户手动确认）

### 设备作用范围

- [ ] 输入设备选择只控制 MeetingNotes：线下会议和在线会议的本机麦克风轨使用该设备；不修改 macOS 全局输入设备。
- [ ] 输出设备选择只控制 MeetingNotes 的录音回放和测试音；不修改 macOS 全局输出设备或其他 App。
- [ ] 设置页打开时接入、断开或切换系统默认设备，列表会自动刷新；快速连续变化后显示最后一次设备状态。
- [ ] 所选设备断开时，界面提示回退到系统默认或其他可用设备；原设备重新连接后仍保留原偏好。
- [ ] 正式录音开始后，设备选择、设备测试和智能诊断均不可启动；结束录音后恢复可用。

### 约 8 秒智能诊断步骤

1. 使用 `⌘,` 打开设置，选择输入和输出设备，点击“保存设置”。
2. 点击“开始智能诊断”；确认 1 秒测试音是否听到。
3. 麦克风检测阶段持续正常说话约 3 秒。
4. 系统音频检测阶段保持扬声器可播放，等待约 3 秒。
5. 确认本地问题、解决方案和“将发送的数据预览”立即出现；此时尚未请求 DeepSeek。
6. 检查预览后勾选发送同意，再点击“发送给 DeepSeek”；不勾选时按钮应保持禁用。
7. 若 DeepSeek 成功，确认只得到简短问题和解决方案；若 Key 缺失、断网、超时或响应无效，确认本地结论仍保留。
8. 中途点击“取消”或关闭设置，确认测试音、麦克风与临时系统音频采集立即停止，随后可正常开始会议录音。

### DeepSeek 数据边界

发送内容仅包括所选模型、固定诊断提示和界面预览中的白名单 JSON：应用版本、Mac 型号类别、macOS 版本、权限枚举、经截断和控制字符过滤的设备显示名称、连接/默认/占用状态、帧数、分桶信号等级、采样率、声道数、观察时长、测试音结果、本地问题/建议代码及 API 错误类别。DeepSeek API Key 仅作为 HTTPS 授权请求头使用，不进入诊断 JSON。

- [ ] 预览和请求中不存在录音或测试音频样本。
- [ ] 不存在转录、总结、会议标题、书签或 Notion 内容。
- [ ] 不存在 DeepSeek API Key、Notion Token、设备稳定 ID、用户名、绝对路径、会议文件名或原始系统日志。
- [ ] 发送前必须由用户逐次勾选同意；重新运行诊断后不能沿用上一次同意。

### 权限说明

macOS 首次麦克风和屏幕录制授权由系统隐私机制控制。MeetingNotes 只能请求权限并打开相应系统设置，不能绕过、静默开启或替用户修改授权。诊断会区分“已授权”“已拒绝”“尚未决定”和“系统当前不可探测”；按系统提示完成授权后重新运行诊断。

### 手动硬件矩阵

| 场景 | 操作与期望 | 结果 |
|---|---|---|
| 内置输入 | 选择内置麦克风，测试与线下录音均有可见电平和可播放声音 | [ ] |
| USB/Bluetooth 输入（如有） | 选择外接麦克风，测试、线下录音及在线“我”轨都使用该设备 | [ ] |
| 内置输出 | 播放测试音及会议回放均从内置扬声器输出 | [ ] |
| 外部输出（如有） | 选择耳机/显示器后，测试音及会议回放从所选设备输出 | [ ] |
| 线下录音 | 正常说话后停止，主录音可播放、转录存在；持续静音会给出警告 | [ ] |
| 在线双轨 | 播放远端声音并对麦克风说话；主录音可播放，“我”与“远端”来源保持分离 | [ ] |
| 设备断开 | 断开已选输入/输出，确认出现回退提示且仍可使用可用设备 | [ ] |
| 权限拒绝 | 分别拒绝麦克风/屏幕录制，确认诊断给出对应问题和权限修复入口 | [ ] |
| DeepSeek 可用 | 检查预览并同意发送，获得简短通俗解释 | [ ] |
| DeepSeek 不可用 | 移除 Key 或断网，本地结论保留且没有发送成功误报 | [ ] |
| 无有效帧 | 开始录音后约 5 秒仍无音频帧，确认停止为失败并提示前往设置运行智能诊断 | [ ] |
| 单轨静音 | 在线会议只让一轨有声，确认健康轨继续保存，静音轨显示降级警告 | [ ] |

## 说话人分离与详情布局真机验收（待用户手动确认）

- [ ] 设置中的 FluidAudio 说话人分离实验功能默认关闭；开始会议时保存本次会议的设置快照，录制中途修改设置只影响后续新会议。
- [ ] 详情页内容顺序依次为本地录音、总结与归档、可折叠的完整转录内容、书签。
- [ ] 生成总结后完整转录内容默认折叠；用户手动展开或折叠后，后续状态更新尊重当前展开状态。
- [ ] 在线会议且实验功能关闭时，麦克风内容标记为“我”，系统音频内容按粗粒度标记为“远端”。
- [ ] 在线会议且实验功能开启时，麦克风内容仍标记为“我”，系统音频中的远端说话人编号显示为“远端 N”。
- [ ] 线下会议且实验功能开启时，不同说话人编号显示为“说话人 N”。
- [ ] FluidAudio 首次使用时按需准备或下载模型；完成后断网再次使用可复用本地模型。
- [ ] 来源音轨写入或说话人分离降级后，混合主录音仍可播放；详情页显示不阻塞其他操作、且可关闭的警告。
- [ ] 旧会议仍可播放并显示原有转录；缺少可信说话人身份时不显示误导性的说话人徽标。

## 真机端到端检查（待用户手动确认）

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
| 2026-08-01 | 完整 arm64 单元回归 | 通过 | 662/662、0 失败；包含设备回退、热插拔刷新合并、设置会话隔离和采集取消竞态测试；`.deriveddata-audio-diagnostics-final/Logs/Test/Test-MeetingNotes-2026.08.01_23-41-24-+0800.xcresult` |
| 2026-08-01 | 完整 MeetingFlow UI 回归 | 通过 | 最近一次成功进入用例的回归为 9/9、0 失败；包含音频设备与智能诊断 UI；`~/Library/Developer/Xcode/DerivedData/MeetingNotes-aadthspcjnfjcacraljrzxdobzyr/Logs/Test/Test-MeetingNotes-2026.08.01_23-07-39-+0800.xcresult` |
| 2026-08-01 | 最终 MeetingFlow UI 重跑 | 环境阻塞 | macOS XCTest 在 0 个用例执行前报 `Timed out while enabling automation mode`，不是产品断言失败；`~/Library/Developer/Xcode/DerivedData/MeetingNotes-aadthspcjnfjcacraljrzxdobzyr/Logs/Test/Test-MeetingNotes-2026.08.01_23-41-56-+0800.xcresult` |
| 2026-08-01 | Debug 构建与诊断隐私静态检查 | 通过 | `BUILD SUCCEEDED`；`git diff --check` 无错误；诊断目录的敏感词搜索仅命中 API Key 的 HTTPS 授权请求头边界，未进入诊断 JSON |
| 2026-08-06 | 线上分轨重建与中断恢复定向回归 | 通过 | 6 个相关测试组 159/159、0 失败；`/tmp/MeetingNotes-online-recovery-focused-20260806-1653.xcresult` |
| 2026-08-06 | 完整 arm64 单元回归 | 通过 | `MeetingNotesTests` 900/900、0 失败；`/tmp/MeetingNotes-online-recovery-all-20260806-1654.xcresult` |
| 2026-08-06 | arm64 Debug 构建与差异检查 | 通过 | `xcodebuild build` 退出码 0；`git diff --check` 无错误 |
