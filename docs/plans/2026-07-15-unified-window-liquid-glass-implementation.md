# 全窗口 Liquid Glass 最小补丁 Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让主窗口、历史会议侧栏和主内容共享一层 macOS 26 原生 Liquid Glass，并保留 macOS 15–25 Material 回退。

**Architecture:** 在 `RootView` 的 macOS `.window` container background 中注入单一 `AppWindowGlassBackground`，不重构 `NavigationSplitView`。历史 `List` 隐藏自身不透明滚动背景，使窗口玻璃层在侧栏和详情列间连续可见。

**Tech Stack:** Swift 6, SwiftUI, macOS 26 `glassEffect`, macOS 15 `containerBackground`, XCTest, XCUITest, Apple Silicon arm64.

---

### Task 1: 先固定全窗口玻璃结构契约

**Files:**

- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift:4-20`

**Step 1: Write the failing test**

在 `testHomeHasExactlyTwoMeetingEntries()` 现有首页断言后加入：

```swift
let windowGlassSurface = app.descendants(matching: .any)[
    "app.windowGlassSurface"
].firstMatch
XCTAssertTrue(windowGlassSurface.waitForExistence(timeout: 5))
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-window-glass-ui \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testHomeHasExactlyTwoMeetingEntries
```

Expected: FAIL because no element has identifier `app.windowGlassSurface`.

### Task 2: 实现单一窗口玻璃层

**Files:**

- Modify: `MeetingNotes/Views/AppVisualStyle.swift:42-102`
- Modify: `MeetingNotes/Views/RootView.swift:36-132`
- Modify: `MeetingNotes/Views/MeetingSidebarView.swift:3-25`
- Test: `MeetingNotesUITests/MeetingFlowUITests.swift`

**Step 1: Add the adaptive window background**

在 `AppVisualStyle.swift` 增加：

```swift
struct AppWindowGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .adaptiveGlassSurface(in: Rectangle())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
```

`adaptiveGlassSurface` 已保证 macOS 26 使用 `glassEffect(.regular)`，macOS 15–25 使用 `ultraThinMaterial`；不增加第二套可用性分支。

**Step 2: Install it as the shared window container background**

在 `RootView` 最外层 `VStack` 的 frame 之后加入：

```swift
.accessibilityIdentifier("app.windowGlassSurface")
.containerBackground(for: .window) {
    AppWindowGlassBackground()
}
```

这会保留原有 `NavigationSplitView`、侧栏 selection 和详情转场，不引入新容器或新动画。

**Step 3: Let the sidebar reveal the shared surface**

在 `MeetingSidebarView` 的 `List` 修饰链加入：

```swift
.scrollContentBackground(.hidden)
.background(.clear)
```

**Step 4: Run the focused UI test and verify GREEN**

重跑 Task 1 命令。

Expected: PASS; 首页两个入口和 `app.windowGlassSurface` 同时存在。

**Step 5: Build the macOS 15 deployment target**

Run:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-window-glass-build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES
```

Expected: `** BUILD SUCCEEDED **`; all macOS 26 API remains availability-gated.

**Step 6: Commit**

```bash
git add MeetingNotes/Views/AppVisualStyle.swift \
  MeetingNotes/Views/RootView.swift \
  MeetingNotes/Views/MeetingSidebarView.swift \
  MeetingNotesUITests/MeetingFlowUITests.swift
git commit -m "feat: add unified window liquid glass"
```

### Task 3: 完整验证与记录

**Files:**

- Modify: `docs/testing/manual-apple-silicon-checklist.md`

**Step 1: Run all unit tests**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-window-glass-unit \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
  -only-testing:MeetingNotesTests
```

Expected: 130 tests, 0 failures.

**Step 2: Run all UI tests and retain screenshots**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-window-glass-ui \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
  -only-testing:MeetingNotesUITests
```

Expected: 4 tests, 0 failures; screenshots include home, floating recorder, detail, returned home, settings, and archived detail.

**Step 3: Inspect macOS 26 screenshots**

导出 XCTest attachments 到 `/tmp`，目视确认：

- 主窗口与历史侧栏使用连续共享玻璃。
- 四键浮窗在结束后消失。
- 上层卡片、返回按钮和长文本层级仍清晰。

**Step 4: Verify final arm64 signed app**

```bash
file /tmp/meetingnotes-window-glass-build/Build/Products/Debug/MeetingNotes.app/Contents/MacOS/MeetingNotes
codesign --verify --deep --strict --verbose=2 \
  /tmp/meetingnotes-window-glass-build/Build/Products/Debug/MeetingNotes.app
```

Expected: Mach-O 64-bit executable arm64; signature valid on disk.

**Step 5: Update the checklist and commit**

记录 macOS 26.5 视觉验收、单元/UI 数量、arm64 和签名结果，不提交包含用户桌面的截图。

```bash
git add docs/testing/manual-apple-silicon-checklist.md
git commit -m "docs: record unified window glass acceptance"
```
