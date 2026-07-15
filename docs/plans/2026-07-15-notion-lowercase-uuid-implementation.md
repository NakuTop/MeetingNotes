# Notion UUID Lowercase Normalization Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure every locally serialized UUID sent to Notion uses lowercase text so valid parent pages are retrieved and used for archive creation.

**Architecture:** Keep link parsing strongly typed as `UUID`, then normalize only at the `NotionClient` serialization boundary through one private helper. Apply the helper to the parent-page GET path and create-page JSON body; leave page IDs returned by Notion untouched.

**Tech Stack:** Swift 6, Foundation `UUID`/`URLRequest`, XCTest, Xcode 16 `xcodebuild`, native macOS arm64 app.

---

### Task 1: Add Request-Serialization Regression Tests

**Files:**

- Modify: `MeetingNotesTests/NotionClientTests.swift:5-100`
- Test: `MeetingNotesTests/NotionClientTests.swift`

**Step 1: Make the test-connection URL require lowercase**

Change the page URL assertion to:

```swift
XCTAssertEqual(
    requests[1].url?.absoluteString,
    "https://api.notion.com/v1/pages/\(parentID.uuidString.lowercased())"
)
```

**Step 2: Make the create-page body require lowercase**

Use a fixed mixed-case-producing UUID and assert its serialized lower-case form:

```swift
let parentID = try XCTUnwrap(
    UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")
)

// after decoding the request body
XCTAssertEqual(parent["page_id"], parentID.uuidString.lowercased())
```

**Step 3: Run the focused test suite and verify it fails for the right reason**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-notion-uuid-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/NotionClientTests
```

Expected: `NotionClientTests` fails only where the actual GET path and `parent.page_id` remain uppercase, proving the regression tests exercise production serialization.

### Task 2: Normalize UUIDs at the Notion Client Boundary

**Files:**

- Modify: `MeetingNotes/Notion/NotionClient.swift:22-76`
- Test: `MeetingNotesTests/NotionClientTests.swift`

**Step 1: Add the minimal private helper**

Inside `NotionClient`, add:

```swift
private static func serializedID(_ id: UUID) -> String {
    id.uuidString.lowercased()
}
```

**Step 2: Use it in the parent-page GET path**

Replace the raw `uuidString` component with:

```swift
path: ["pages", Self.serializedID(parentPageID)]
```

**Step 3: Use it in the create-page request body**

Serialize the parent as:

```swift
parent: .init(
    type: "page_id",
    pageID: Self.serializedID(parentPageID)
)
```

Do not change `append(blocks:to:)`, because its page ID is a server-returned opaque `String`.

**Step 4: Run the focused suite and verify it passes**

Run the Task 1 command again.

Expected: all `NotionClientTests` pass and the build reports `** TEST SUCCEEDED **`.

**Step 5: Commit the regression fix**

```bash
git add MeetingNotes/Notion/NotionClient.swift MeetingNotesTests/NotionClientTests.swift
git commit -m "fix: normalize Notion UUIDs to lowercase"
```

### Task 3: Full Regression, Signed Build, and Real Connection Acceptance

**Files:**

- Verify: `MeetingNotes/Notion/NotionClient.swift`
- Verify: `MeetingNotesTests/NotionClientTests.swift`
- Optionally update after real acceptance: `docs/testing/manual-apple-silicon-checklist.md`

**Step 1: Run formatting and the complete unit suite**

Run:

```bash
git diff --check
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-notion-uuid-tests \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests
```

Expected: all unit tests pass with `** TEST SUCCEEDED **`.

**Step 2: Build an ad-hoc-signed real app**

Run:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-real-acceptance-derived \
  -clonedSourcePackagesDirPath /tmp/meetingnotes-task15-sourcepackages \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: `** BUILD SUCCEEDED **` and a native app at `/tmp/meetingnotes-real-acceptance-derived/Build/Products/Debug/MeetingNotes.app`.

**Step 3: Launch the new build and test the real parent page**

Quit any earlier `MeetingNotes` process, launch the new app, then in Settings re-save the Notion Token if macOS treats the rebuilt ad-hoc signature as a new Keychain client. Use the already supplied parent-page link and click Notion “测试连接”.

Expected: the app displays a successful connection and the actual parent-page title; it does not display “找不到该 Notion 页面”. Never print the Token in terminal or diagnostics.

**Step 4: Inspect only non-secret request evidence if needed**

If UI acceptance still fails, inspect only the request URL and HTTP status. The expected page path is:

```text
/v1/pages/39c48749-eaf5-80b8-a7a7-d2e9e1d27b3e
```

Do not print request headers, local variables, Keychain contents, or stack frames that can contain credentials.

**Step 5: Record acceptance only after the real result**

Update the manual checklist only if the UI confirms the live page test. Otherwise preserve the exact non-secret status and continue diagnosis without claiming completion.
