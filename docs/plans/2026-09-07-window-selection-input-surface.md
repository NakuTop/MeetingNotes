# Window selection input surface repair

**Goal:** Repair direct click selection while preserving the approved frosted overlay, one-click window screenshot, Escape cancellation, and Beta 23 audio behavior.

**Scope:** Existing performance worktree only. No project regeneration, production identity changes, permission changes, global input hooks, visible automation, capture of real screen pixels, installation, commit, push, or publication.

## Evidence and hypothesis

- User confirmed audio capture works. Screenshot overlay opens, initially no useful highlight; subsequent manual test can highlight another app, but clicking does not produce a screenshot.
- Read-only window metadata and SDK checks found eligible windows and matching dual-display coordinate spaces. Existing offscreen view geometry/hit-test checks pass. No new Beta crash was found.
- The highlighted region is an entirely transparent hole in a nonopaque, clear-background NSPanel. A view-level hitTest cannot protect an event that the window server routes through that hole. Activation loss then cancels the picker. Verify the rendered alpha invariant with the real drawing code, not a stub emitting a selected event. Actual window-server routing remains a manual gate unless observed through the read-only window-number query.

## Steps

1. Add offscreen bitmap regression tests in MeetingScreenshotWindowPickerTests.swift. Make the existing view internal for @testable access only; no behavior change yet. Require a nonzero, almost-clear input surface inside the highlight, intact outer dimming, and no cumulative darkening after repeated redraws.
2. Run RED via Scripts/test_in_background.sh with the screenshot picker suite. Only after a behavioral failure, fill the view's input surface before drawing the dimming hole and border. Use copy compositing to avoid accumulation. Keep selection identity, coordinate conversion, permissions, screenshot capture/encoding, and cancellation unchanged.
3. Run screenshot/capture/annotation focused tests, then full background units and an ordinary Debug build. Independent source review must distinguish offscreen regression evidence from actual packaged interaction.
4. If all checks pass, increment only Beta 23 to 24 in the existing three build references and version policy test; package locally, verify read-only mounted identity/signature/entitlements and DMG. Hand off for human direct-click/Escape/multiple-monitor acceptance. Do not install or launch the candidate automatically.

## Commands

Use the existing /tmp/MeetingNotes-BackgroundTests.audio22 derived data and pinned local SourcePackages cache with Scripts/test_in_background.sh. Focused suites: MeetingScreenshotWindowPickerTests, MeetingScreenshotCaptureTests, RecordingAnnotationViewModelTests. All interactive/UI tests remain NOT RUN.

Ordinary build: xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Debug -destination 'platform=macOS' -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build.

Packaging: env -u DEVELOPER_ID_APPLICATION -u NOTARY_KEYCHAIN_PROFILE nice -n 10 bash Scripts/build_and_package.sh Beta. Preserve the existing local signing identity and production 1.3.0 (18).

## Execution

- Apple's [window-number hit-testing documentation](https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:)) confirms transparent regions are skipped before view dispatch. A read-only probe during the user's overlay session found two overlay windows, but the window-server mouse target was not Beta. No input or real pixels were captured. This supports the routing defect; it does not establish the precise deactivation sequence of every reported click.
- RED: interior alpha was 0 versus required >= 0.01; repeated outside shading accumulated from 0.1608 to 0.7490. Moving/clearing test initially sampled the wrong bitmap Y coordinate; after correcting sampling to the common centerline, it independently failed for stale interior shading (0.1608) and accumulated clearing (0.2941). Logs are in /tmp/MeetingNotes-Screenshot24.60BSQF.
- Fix: real view paints alpha 0.02 across its bounds using copy compositing before the existing outside shade and accent border. This keeps the highlight nearly clear without a zero-alpha input hole. The class is internal solely for @testable access; no new public API, event hooks, or permission behavior.
- GREEN: screenshot picker 31, screenshot capture 15, annotation view model 9; **55 passed, 0 failed, exit 0**. The three added tests render only an unattached production view into an in-memory bitmap; no NSWindow or real desktop capture is used by those tests.
- Full background suite with Beta 24 configuration: **1373 passed, 0 failed, exit 0**. The two interactive floating-panel tests and all UI automation remain **NOT RUN**. Existing screenshot-completion Sendable/AppIntents and background-host system-service warnings remain; this is not a warning-free claim.
- Independent read-only review confirmed the transparent-hole defect and closed the narrow fix without new blockers. Selection identity checks, task cancellation, coordinates, screenshot encoding, and accepted audio production files are unchanged.
- Only Beta build references move 23 to 24. Production remains 1.3.0 (18). No project regeneration or resolved-package changes.
- Ordinary Debug build: **exit 0**, without the background test-host compilation flag. Beta packaging: **exit 0 / PACKAGE_VALIDATION=PASS**.
- Artifact: `MeetingNotes-1.3.1-beta-build24.dmg`, **9,740,104 bytes**, SHA256 `33972f797c5ac7d2f220a71c8c7bdda78064779b4cae47c440882f69642ceec2`. Independent `hdiutil verify`, read-only/no-autoopen mounted deep strict signature, Sparkle embedding, identity 1.3.1 (24), sandbox/audio-input/network-client entitlements and microphone/system-audio/screenshot privacy strings all passed. Real app has no `LSBackgroundOnly=true` or get-task-allow entitlement.
- Local self-signed certificate/designated requirement retained; **not notarized or published**. Installed production remains 1.3.0 (18); installed Beta was not replaced. Accepted audio source hashes and resolved-package SHA remain identical to the pre-fix baseline. HEAD remains `fa7f420deb5faf65b15998c085e41676d3c8d716`.
- Actual packaged single-click, Escape, and multi-monitor acceptance: **PENDING HUMAN**. No commit, push, PR update, publication, installation, or candidate launch.
