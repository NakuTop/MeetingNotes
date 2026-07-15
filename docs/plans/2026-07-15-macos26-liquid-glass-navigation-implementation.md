# macOS 26 Liquid Glass、悬浮窗与导航优化 Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the floating recorder as soon as stopping enters finalization, add an explicit return-home action that preserves the history sidebar, and introduce native macOS 26 Liquid Glass with material fallbacks and accessible motion.

**Architecture:** Move panel hiding to the coordinator boundary immediately after the meeting is durably marked finalizing. Keep navigation ownership in `MeetingLibraryViewModel`/`RootView`, and centralize availability-gated Glass surfaces, button styles, and motion profiles in one SwiftUI design-system file. Existing macOS 15 deployment support remains unchanged.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPanel`/`NSAnimationContext`, macOS 26.2 SDK (`glassEffect`, `GlassEffectContainer`, glass button styles), XCTest, XCUITest, Apple Silicon arm64.

---

### Task 1: Hide the Recorder Immediately After Entering Finalization

**Files:**

- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift:75-130, 205-230, 550-610`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift:205-270`

**Step 1: Change the safe-order test to require early hiding**

Make the fake repository record the finalizing transition:

```swift
func updateState(meetingID: UUID, state: RecordingState) async throws {
    _ = meetingID
    if state == .finalizing {
        await events.append("repository.finalizing")
    }
}
```

Update the expected stop order:

```swift
XCTAssertEqual(
    events,
    [
        "repository.finalizing",
        "panel.hide",
        "capture.stop",
        "writer.finish",
        "transcriber.drain",
        "repository.finalize"
    ]
)
```

Keep the writer-failure assertion `panelCalls == ["show", "hide"]` to prove later failures do not reopen the panel.

**Step 2: Add a pre-finalization failure test**

Extend `FakeCoordinatorRepository` with `failsFinalizingUpdate`. Add:

```swift
func testFinalizingPersistenceFailureKeepsRecorderVisibleForRetry() async throws {
    let fixture = makeFixture(repositoryFailsFinalizingUpdate: true)
    try await fixture.coordinator.start(mode: .offline)

    do {
        try await fixture.coordinator.stop()
        XCTFail("Expected finalizing persistence failure")
    } catch {
        XCTAssertEqual(error as? CoordinatorTestError, .repositoryUpdate)
    }

    XCTAssertEqual(await fixture.panel.calls(), ["show"])
    XCTAssertFalse((await fixture.events.values()).contains("capture.stop"))
}
```

**Step 3: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: the safe-order test fails because `panel.hide` still occurs after finalization; the new repository failure test requires missing fixture support.

**Step 4: Move panel hiding to the finalizing boundary**

In `MeetingCoordinator.stop()`, hide immediately after the repository and in-memory state both enter finalizing:

```swift
try await dependencies.repository.updateState(
    meetingID: meetingID,
    state: .finalizing
)
stateMachine = finalizingMachine
await dependencies.panel.hide()

do {
    let task = streamTask
    await capture.stop()
    // existing finalization pipeline
```

Remove the later `panel.hide()` calls from both success and catch blocks. A failure before this new call keeps the panel visible; a failure after it keeps the panel closed.

**Step 5: Run the focused tests and verify GREEN**

Run the Task 1 focused command again.

Expected: all `MeetingCoordinatorTests` pass and the event order proves the panel closes before capture/transcription finalization.

**Step 6: Commit**

```bash
git add MeetingNotes/Coordinator/MeetingCoordinator.swift MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "fix: close recorder when stopping begins"
```

### Task 2: Add Return Home Without Rebuilding the History Sidebar

**Files:**

- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift:1-70`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift:75-90`
- Modify: `MeetingNotes/Views/RootView.swift:32-60`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift:1-30`

**Step 1: Add a navigation-state regression test**

```swift
func testReturnHomeClearsOnlySelectionAndPreservesHistory() {
    let first = makeMeeting(seconds: 100, title: "第一次会议")
    let second = makeMeeting(seconds: 200, title: "第二次会议")
    let repository = LibraryRepositorySpy(meetings: [first, second])
    let viewModel = makeViewModel(repository: repository)
    viewModel.load()
    viewModel.select(second.id)

    viewModel.returnHome()

    XCTAssertNil(viewModel.selectedMeetingID)
    XCTAssertEqual(viewModel.meetings.map(\.id), [second.id, first.id])
}
```

**Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests
```

Expected: compile failure because `returnHome()` does not exist.

**Step 3: Implement the semantic navigation action**

```swift
func returnHome() {
    selectedMeetingID = nil
}
```

**Step 4: Inject and render the return action**

Change `MeetingDetailView` to accept a closure:

```swift
private let onReturnHome: () -> Void

init(
    viewModel: MeetingDetailViewModel,
    onReturnHome: @escaping () -> Void
) {
    _viewModel = State(initialValue: viewModel)
    self.onReturnHome = onReturnHome
}
```

Add a leading toolbar button:

```swift
.toolbar {
    ToolbarItem(placement: .navigation) {
        Button("返回首页", systemImage: "chevron.backward") {
            onReturnHome()
        }
        .accessibilityIdentifier("meeting.returnHome")
        .help("返回录音首页，保留历史会议")
    }
}
```

Pass the closure from `RootView`:

```swift
MeetingDetailView(
    viewModel: makeDetailViewModel(meeting.id),
    onReturnHome: viewModel.returnHome
)
```

Do not move `MeetingSidebarView` out of the `NavigationSplitView`; clearing the selection must only replace the detail column.

**Step 5: Run the focused tests and a build**

Run the Task 2 command, then:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO
```

Expected: focused tests and build pass.

**Step 6: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingLibraryViewModel.swift MeetingNotes/Views/RootView.swift MeetingNotes/Views/MeetingDetailView.swift MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "feat: add return-home navigation"
```

### Task 3: Create the Adaptive Glass and Motion Foundation

**Files:**

- Create: `MeetingNotes/Views/AppVisualStyle.swift`
- Create: `MeetingNotesTests/AppVisualStyleTests.swift`

The project uses file-system-synchronized Xcode groups, so files under `MeetingNotes` and `MeetingNotesTests` are picked up without manual `.pbxproj` entries. Keep `project.yml` and the deployment target unchanged at macOS 15.

**Step 1: Write policy tests first**

```swift
final class AppVisualStyleTests: XCTestCase {
    func testLiquidGlassStartsAtMacOS26() {
        XCTAssertEqual(
            AppVisualPolicy.treatment(forMajorVersion: 25),
            .material
        )
        XCTAssertEqual(
            AppVisualPolicy.treatment(forMajorVersion: 26),
            .liquidGlass
        )
    }

    func testReducedMotionRemovesScaleAndSpring() {
        XCTAssertEqual(
            AppVisualPolicy.motion(reduceMotion: true),
            AppMotionProfile(duration: 0.12, scale: 1, usesSpring: false)
        )
        XCTAssertEqual(
            AppVisualPolicy.motion(reduceMotion: false),
            AppMotionProfile(duration: 0.24, scale: 0.985, usesSpring: true)
        )
    }
}
```

**Step 2: Run the new suite and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/AppVisualStyleTests
```

Expected: compile failure because the visual policy does not exist.

**Step 3: Implement pure policy values**

```swift
enum AppVisualTreatment: Equatable, Sendable {
    case material
    case liquidGlass
}

struct AppMotionProfile: Equatable, Sendable {
    let duration: TimeInterval
    let scale: CGFloat
    let usesSpring: Bool

    var animation: Animation {
        usesSpring
            ? .snappy(duration: duration, extraBounce: 0.02)
            : .easeOut(duration: duration)
    }
}

enum AppVisualPolicy {
    static func treatment(forMajorVersion majorVersion: Int)
        -> AppVisualTreatment {
        majorVersion >= 26 ? .liquidGlass : .material
    }

    static func motion(reduceMotion: Bool) -> AppMotionProfile {
        reduceMotion
            ? AppMotionProfile(duration: 0.12, scale: 1, usesSpring: false)
            : AppMotionProfile(duration: 0.24, scale: 0.985, usesSpring: true)
    }
}
```

**Step 4: Add availability-gated SwiftUI helpers**

Provide helpers with `@ViewBuilder`, keeping every macOS 26 symbol inside `if #available(macOS 26.0, *)`:

```swift
extension View {
    @ViewBuilder
    func adaptiveGlassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func adaptivePrimaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func adaptiveSecondaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
```

Add an `AdaptiveGlassCard` wrapper for key sections. It must use the surface helper and must not be applied to the long transcript body.

**Step 5: Run tests and compile against deployment target 15**

Run the Task 3 test command, then the Task 2 build command.

Expected: tests pass; the app compiles with `MACOSX_DEPLOYMENT_TARGET=15.0`, proving all macOS 26 symbols are availability-guarded.

**Step 6: Commit**

```bash
git add MeetingNotes/Views/AppVisualStyle.swift MeetingNotesTests/AppVisualStyleTests.swift
git commit -m "feat: add adaptive liquid glass styles"
```

### Task 4: Smooth and Glassify the Floating Recorder Without Adding Controls

**Files:**

- Modify: `MeetingNotesTests/FloatingControlTests.swift:35-85`
- Modify: `MeetingNotes/FloatingPanel/FloatingPanelController.swift:35-130`
- Modify: `MeetingNotes/FloatingPanel/FloatingRecorderView.swift:1-55`

**Step 1: Add panel reuse and repeat-cycle tests**

Create the controller with a zero animation duration:

```swift
let controller = FloatingPanelController(
    defaults: defaults,
    animationDuration: 0,
    reduceMotion: { false },
    action: { _ in }
)
let contentView = controller.panel.contentView

controller.show()
XCTAssertTrue(controller.panel.isVisible)
controller.setPaused(true)
XCTAssertTrue(controller.panel.contentView === contentView)
controller.hide()
XCTAssertFalse(controller.panel.isVisible)
XCTAssertEqual(controller.panel.alphaValue, 1)
controller.show()
XCTAssertTrue(controller.panel.isVisible)
XCTAssertEqual(controller.panel.alphaValue, 1)
```

Keep the existing assertion that `FloatingControl.allCases.count == 4`.

**Step 2: Run the focused suite and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/FloatingControlTests
```

Expected: compile failure for the new initializer and content-view reuse expectations.

**Step 3: Keep one hosting view and update its root value**

Store a single `NSHostingView<FloatingRecorderView>` in the controller. `setPaused` updates `hostingView.rootView`; it must never replace `panel.contentView`.

**Step 4: Add deterministic AppKit fading**

Add injectable `animationDuration` and `reduceMotion`. Production defaults are approximately 0.16 seconds and `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

For `show()`:

```swift
panel.alphaValue = shouldAnimate ? 0 : 1
panel.orderFrontRegardless()
animateAlpha(to: 1)
```

For `hide()`:

```swift
guard panel.isVisible else {
    panel.alphaValue = 1
    return
}
animateAlpha(to: 0) { [weak panel] in
    panel?.orderOut(nil)
    panel?.alphaValue = 1
}
```

When duration is zero or Reduce Motion is enabled, perform the state change synchronously.

**Step 5: Apply native Glass to the four controls**

In the macOS 26 branch, place the controls inside `GlassEffectContainer` and apply interactive circular Glass with semantic tint. In the fallback branch, retain the capsule material and circle backgrounds. Read `accessibilityReduceMotion` in the view and animate pause/resume symbol replacement using `AppVisualPolicy.motion`.

Do not add a fifth close button or change any existing accessibility identifier.

**Step 6: Run focused tests and commit**

Run the Task 4 command again.

Expected: all floating control tests pass, including repeated show/hide and exactly-four-controls assertions.

```bash
git add MeetingNotes/FloatingPanel/FloatingPanelController.swift MeetingNotes/FloatingPanel/FloatingRecorderView.swift MeetingNotesTests/FloatingControlTests.swift
git commit -m "feat: animate liquid glass recorder panel"
```

### Task 5: Apply the Visual System and Add End-to-End Navigation Coverage

**Files:**

- Modify: `MeetingNotes/Views/RootView.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/Views/StartMeetingView.swift`
- Modify: `MeetingNotes/Views/SettingsView.swift`
- Modify: `MeetingNotes/Views/OnboardingView.swift`
- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift:20-55`

**Step 1: Extend the existing UI flow test**

After clicking stop, require the recorder to disappear, then return home and verify both the start entries and history remain:

```swift
app.buttons["floating.stop"].click()
XCTAssertTrue(waitForNonExistence(app.buttons["floating.stop"], timeout: 3))

let returnHome = app.buttons["meeting.returnHome"]
XCTAssertTrue(returnHome.waitForExistence(timeout: 5))
XCTAssertTrue(app.staticTexts["UI 测试会议"].firstMatch.exists)
returnHome.click()

XCTAssertTrue(app.buttons["meeting.start.offline"].waitForExistence(timeout: 5))
XCTAssertTrue(app.buttons["meeting.start.online"].exists)
XCTAssertTrue(app.staticTexts["UI 测试会议"].firstMatch.exists)
```

Add a local predicate-based `waitForNonExistence` helper if the SDK method is unavailable.

**Step 2: Run the UI test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-ui-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testFloatingRecorderAlwaysHasFourControlsAndBookmarkPersists
```

Expected: the test fails before the return button and immediate panel lifecycle are fully wired.

**Step 3: Apply restrained Glass surfaces**

- `StartMeetingView`: use adaptive prominent buttons.
- `MeetingDetailView`: use adaptive secondary style for return, Glass cards for header/audio/summary actions, and keep the full transcript on a plain readable background.
- `SettingsView`: apply adaptive surfaces to DeepSeek and Notion groups and adaptive prominent style to Save.
- `OnboardingView`: use a restrained Glass surface and adaptive prominent confirmation button.
- `RootView`: use an adaptive surface for the error banner; keep the system `NavigationSplitView` and `List` native so macOS 26 supplies its own sidebar Glass behavior.

**Step 4: Add accessible detail transitions**

Read `accessibilityReduceMotion` in `RootView`. Apply a detail-only opacity/scale transition keyed by `selectedMeetingID`, using `AppVisualPolicy.motion`; never animate the sidebar list or continuously changing recording duration.

**Step 5: Run the UI test and verify GREEN**

Run the Task 5 UI command again.

Expected: the panel disappears, the return button is operable, the home entries reappear, and the history row remains.

**Step 6: Commit**

```bash
git add MeetingNotes/Views/RootView.swift MeetingNotes/Views/MeetingDetailView.swift MeetingNotes/Views/StartMeetingView.swift MeetingNotes/Views/SettingsView.swift MeetingNotes/Views/OnboardingView.swift MeetingNotesUITests/MeetingFlowUITests.swift
git commit -m "feat: apply adaptive glass navigation polish"
```

### Task 6: Full Regression and Real macOS 26 Acceptance

**Files:**

- Modify after verification: `docs/testing/manual-apple-silicon-checklist.md`

**Step 1: Run formatting and all unit tests**

```bash
git diff --check
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests
```

Expected: the existing 125 tests plus all new tests pass with zero failures.

**Step 2: Run the full signed UI suite**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-ui-polish-ui-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests
```

Expected: every UI workflow passes with the four-control recorder contract unchanged.

**Step 3: Build and inspect the real app**

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-real-acceptance-derived \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

file /tmp/meetingnotes-real-acceptance-derived/Build/Products/Debug/MeetingNotes.app/Contents/MacOS/MeetingNotes
codesign --verify --deep --strict /tmp/meetingnotes-real-acceptance-derived/Build/Products/Debug/MeetingNotes.app
```

Expected: arm64 Mach-O, valid local signature, `** BUILD SUCCEEDED **`.

**Step 4: Perform real macOS 26 visual acceptance**

Verify on the current Mac:

1. Start a recording and confirm the four-control panel uses native Liquid Glass.
2. Pause/resume and confirm symbol/tint motion is smooth.
3. Stop and confirm the panel begins closing immediately while finalization continues.
4. Use “返回首页” and confirm the history sidebar remains.
5. Select a history meeting and confirm only the detail column animates.
6. Enable Reduce Motion and confirm scale/spring effects are removed.
7. Confirm long transcript text remains readable in light and dark appearances.

Do not claim subjective smoothness or accessibility acceptance until these checks are observed.

**Step 5: Record only verified evidence and commit**

Update the manual checklist with separate automated and manual results. Leave any unobserved item unchecked.

```bash
git add docs/testing/manual-apple-silicon-checklist.md
git commit -m "docs: record liquid glass UI acceptance"
```
