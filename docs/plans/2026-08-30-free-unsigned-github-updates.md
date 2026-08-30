# Free Unsigned GitHub Updates Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish MeetingNotes 1.2.0 (16) as the first free, EdDSA-authenticated stable update seed on GitHub without Apple Developer ID signing or notarization.

**Architecture:** Preserve the existing Developer ID workflow unchanged and add a separately selected `community-unsigned` path. CI builds an ad-hoc signed Release, validates its exact identity and expected lack of Apple trust, signs the archive with the existing Sparkle key, then creates a clearly labelled prerelease and updates only the stable GitHub Pages appcast.

**Tech Stack:** Swift 6, XCTest, Xcode/SPM, Sparkle 2.9.6, Bash, GitHub Actions, GitHub Releases, GitHub Pages, Ed25519/CryptoKit.

---

### Task 1: Establish release provenance and key prerequisites

**Files:**
- Inspect: `.github/workflows/publish-update.yml`
- Inspect: `MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Inspect: existing GitHub repository, `gh-pages`, Releases, Actions secrets

**Step 1: Record the source state**

Run:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
git diff --check
git log --oneline origin/codex/formal-audio-beta-1.2.0..HEAD
```

Expected: `codex/formal-audio-beta-1.2.0`; preserve every existing local change.

**Step 2: Inspect GitHub without mutation**

Run:

```bash
gh auth status
gh repo view NakuTop/MeetingNotes --json nameWithOwner,visibility,url
gh secret list --repo NakuTop/MeetingNotes
gh release list --repo NakuTop/MeetingNotes --limit 20
git ls-remote origin refs/heads/gh-pages
```

Expected: authenticated write access, public repository, `gh-pages` exists, and no conflicting unsigned build-16 release.

**Step 3: Prove the existing Sparkle private key matches**

Use Sparkle's `generate_keys`/key export tooling or the already configured
GitHub secret without printing private bytes. Derive its public key with
CryptoKit and compare it to:

```text
ASh1iXHfL1NE8h97OdgLsUzfy42OybuoywwCtRWXDRc=
```

Expected: exact match. Stop before any release work if the key is unavailable
or differs.

### Task 2: Pin the current secure Sparkle release

**Files:**
- Modify: `MeetingNotesTests/UpdateReleasePolicyTests.swift`
- Modify: `MeetingNotesTests/SparkleUpdateConfigurationTests.swift`
- Modify: `project.yml`
- Modify: `MeetingNotes.xcodeproj/project.pbxproj`
- Modify: `MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `.github/workflows/publish-update.yml`

**Step 1: Add failing version assertions**

Add tests that require `2.9.6` in `project.yml`, `project.pbxproj`, resolved
packages, and the publishing workflow. Require a non-placeholder verified
distribution archive SHA-256 in the workflow.

**Step 2: Run the focused tests and observe failure**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/UpdateReleasePolicyTests \
  -only-testing:MeetingNotesTests/SparkleUpdateConfigurationTests
```

Expected: the new `2.9.6` assertions fail against `2.9.2`.

**Step 3: Update only Sparkle**

Change the exact package requirement to `2.9.6` in both project definitions,
resolve packages, and verify WhisperKit and FluidAudio revisions do not move.
Update the workflow's Sparkle tools version and archive checksum from the
official 2.9.6 distribution.

**Step 4: Re-run focused tests**

Expected: all focused configuration tests pass.

**Step 5: Commit**

```bash
git add project.yml MeetingNotes.xcodeproj/project.pbxproj \
  MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  .github/workflows/publish-update.yml \
  MeetingNotesTests/UpdateReleasePolicyTests.swift \
  MeetingNotesTests/SparkleUpdateConfigurationTests.swift
git commit -m "build(updates): upgrade Sparkle to 2.9.6"
```

### Task 3: Persist stable 1.2.0 (16) identity and safe ad-hoc packaging

**Files:**
- Modify: `MeetingNotesTests/UpdateReleasePolicyTests.swift`
- Modify: `project.yml`
- Modify: `MeetingNotes.xcodeproj/project.pbxproj`
- Modify: `Scripts/build_and_package.sh`

**Step 1: Add failing release identity and entitlement tests**

Require Release to be `会议记录`, `com.shenminghao.MeetingNotes`, `1.2.0 (16)`.
Require the packager to expand the two Sparkle Mach lookup entitlement strings,
remove `get-task-allow`, and retain `PUBLISHABLE=NO` for ad-hoc packages.

**Step 2: Run the policy tests and observe failure**

Expected: Release version/build and processed-entitlement assertions fail.

**Step 3: Implement the minimum packaging changes**

Update Release values in `project.yml`, `project.pbxproj`, and the packaging
expectations. Build an expanded temporary entitlements plist before re-signing,
verify exact `-spks`/`-spki` values, and fail if `get-task-allow` remains.
Emit separate facts:

```text
APPLE_DISTRIBUTABLE=NO
SIGNING_MODE=ad-hoc
NOTARIZATION_STATUS=skipped-ad-hoc
```

Do not set `PUBLISHABLE=YES` for the unsigned package.

**Step 4: Run focused tests and `bash -n`**

Run:

```bash
bash -n Scripts/build_and_package.sh
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/UpdateReleasePolicyTests
```

Expected: pass.

**Step 5: Commit**

```bash
git add project.yml MeetingNotes.xcodeproj/project.pbxproj \
  Scripts/build_and_package.sh MeetingNotesTests/UpdateReleasePolicyTests.swift
git commit -m "build(release): prepare unsigned stable 1.2.0"
```

### Task 4: Add a fail-closed unsigned release validator

**Files:**
- Create: `Scripts/validate_unsigned_update_release.sh`
- Modify: `MeetingNotesTests/UpdateReleasePolicyTests.swift`
- Preserve: `Scripts/validate_update_release.sh`

**Step 1: Add failing policy tests**

Require the unsigned validator to check:

- exact Release identity, feed, update key, and automatic-update settings;
- `hdiutil verify` and mounted app presence;
- `codesign --verify --deep --strict` for the ad-hoc app;
- `Signature=adhoc`, `TeamIdentifier=not set`, no Developer ID authority;
- absence of `get-task-allow`, secure timestamp, and notarization ticket;
- expected Gatekeeper rejection;
- arm64, Sparkle load command/runpath, helpers, and sandbox entitlements;
- exact appcast URL, length, versions, arm64 requirement, and EdDSA signature;
- output `APPLE_DISTRIBUTABLE=NO` and
  `SPARKLE_UPDATE_PUBLISHABLE=YES` only at the end.

Also assert the Developer ID validator still contains all original gates.

**Step 2: Run the focused tests and observe failure**

Expected: missing unsigned validator assertions fail.

**Step 3: Implement the validator**

Create a separate script rather than adding permissive branches to the signed
validator. Never accept an unsigned DMG in `validate_update_release.sh`.

**Step 4: Verify syntax and tests**

```bash
bash -n Scripts/validate_unsigned_update_release.sh
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/UpdateReleasePolicyTests
```

Expected: pass.

**Step 5: Commit**

```bash
git add Scripts/validate_unsigned_update_release.sh \
  MeetingNotesTests/UpdateReleasePolicyTests.swift
git commit -m "build(updates): validate unsigned Sparkle releases"
```

### Task 5: Add the isolated GitHub community publishing mode

**Files:**
- Modify: `.github/workflows/publish-update.yml`
- Modify: `MeetingNotesTests/UpdateReleasePolicyTests.swift`

**Step 1: Add failing workflow policy tests**

Require:

- `distribution_mode` choice with `developer-id` and `community-unsigned`;
- explicit `PUBLISH UNSIGNED stable VERSION (BUILD)` confirmation;
- community mode rejects Beta;
- Apple secrets and credential preparation run only for Developer ID mode;
- both modes require the existing Sparkle private-key secret;
- unsigned tag `vVERSION-unsigned-buildBUILD`, unique asset name, prerelease
  status, and Chinese warning text;
- the signed validator is selected only for Developer ID and the unsigned
  validator only for community mode;
- all validation occurs before Release/feed mutation;
- stable and Beta feeds remain isolated.

**Step 2: Run the focused tests and observe failure**

Expected: new mode assertions fail.

**Step 3: Implement the workflow path**

Keep the existing signed steps under explicit conditions. For unsigned mode,
build ad-hoc, rename the validated artifact, generate and verify the EdDSA
appcast, run the unsigned validator, publish a prerelease with a warning, then
update the stable feed.

**Step 4: Validate workflow syntax and focused tests**

Run `ruby`/`actionlint` YAML validation if available, `git diff --check`, and
the focused XCTest suite.

**Step 5: Commit**

```bash
git add .github/workflows/publish-update.yml \
  MeetingNotesTests/UpdateReleasePolicyTests.swift
git commit -m "ci(updates): publish free unsigned stable channel"
```

### Task 6: Audit and commit the pre-existing Beta 14-16 release changes

**Files:**
- Review every remaining modified/untracked file
- Expected existing paths include package tests, UI tests, release scripts,
  project metadata, and Beta acceptance evidence

**Step 1: Review all remaining diffs**

```bash
git status --short
git diff --stat
git diff --check
git diff
```

Classify each change. Stop if any file is unrelated or contradicts accepted
Beta 16 behavior.

**Step 2: Run the directly affected tests**

Run Sparkle/update policy tests and affected UI test compilation/execution.

**Step 3: Commit only reviewed existing changes**

Use one intentional commit message describing the Beta 14-16 packaging and
launch-regression evidence. Do not stage DMGs or DerivedData.

### Task 7: Build and validate the unsigned stable artifact locally

**Files:**
- Generated outside source tracking: `MeetingNotes-1.2.0-build16-unsigned.dmg`
- Generated outside source tracking: temporary signed appcast

**Step 1: Run static checks and builds**

```bash
git diff --check
bash -n Scripts/build_and_package.sh
bash -n Scripts/validate_update_release.sh
bash -n Scripts/validate_unsigned_update_release.sh
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS' build
```

**Step 2: Run focused and full tests**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/SparkleUpdateConfigurationTests \
  -only-testing:MeetingNotesTests/UpdateReleasePolicyTests
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test -only-testing:MeetingNotesTests
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test
```

Record exact exits and counts.

**Step 3: Build the Release package**

Run:

```bash
./Scripts/build_and_package.sh Release
```

Expected: exact stable identity, `PACKAGE_VALIDATION=PASS`,
`SIGNING_MODE=ad-hoc`, `PUBLISHABLE=NO`, `APPLE_DISTRIBUTABLE=NO`.

**Step 4: Generate and validate a temporary EdDSA appcast**

Use the existing private key through stdin, never a repository file. Run the
unsigned validator against the exact archive and appcast.

Expected: `SPARKLE_UPDATE_PUBLISHABLE=YES`.

**Step 5: Exercise a two-version unsigned chain**

Create isolated temporary old/new applications with build numbers below and at
16, the same embedded public key, ad-hoc signatures, and an EdDSA-signed local
feed. Verify Sparkle accepts exactly one newer result, the archive signature,
and the update bundle policy. Do not install over `/Applications/MeetingNotes.app`.

### Task 8: Push provenance and publish the GitHub seed

**Files:**
- Remote branch: `codex/formal-audio-beta-1.2.0`
- GitHub Release asset
- `gh-pages:updates/stable/appcast.xml`

**Step 1: Final source review**

Require a clean worktree, exact intended commits, and no DMG/model/cache files
tracked.

**Step 2: Push normally**

```bash
git push origin codex/formal-audio-beta-1.2.0
```

No force push.

**Step 3: Configure/verify the Sparkle secret**

If the matching secret is not already present, set
`SPARKLE_ED_PRIVATE_KEY` through `gh secret set` from a protected local source
without displaying it.

**Step 4: Dispatch the unsigned stable workflow**

Use version `1.2.0`, build `16`, community unsigned mode, and the exact manual
confirmation. Wait for completion and stop on any validation failure.

**Step 5: Verify public state**

Check:

- Release tag/title/prerelease/warning/asset hash;
- public HTTPS asset availability;
- stable appcast HTTPS availability and EdDSA signature;
- appcast version `16`, byte length, arm64 requirement, and download URL;
- Beta feed unchanged;
- no canonical `v1.2.0` tag created;
- no Developer ID/notarization claims.

### Task 9: Human seed installation gate

Ask the user to install the public build once using the documented manual
Gatekeeper approval path, launch it, and use “检查更新”. Because build 16 is the
latest feed item, the expected result is “已是最新版本”, not an update offer.
Record this as human evidence; do not fabricate it from automation.
