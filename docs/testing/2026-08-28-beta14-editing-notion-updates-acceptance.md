# Beta 1.2.0 (14) editing, Notion, and updates acceptance

Date: 2026-08-28

## Rejected package

Status: **REJECTED — DO NOT INSTALL OR TEST**

The packaged app terminates at launch because its executable links Sparkle as
`@rpath/Sparkle.framework/Versions/B/Sparkle` but does not contain
`@executable_path/../Frameworks` in `LC_RPATH`. Xcode-hosted validation did not
expose this standalone distribution failure because the test environment
supplied additional framework search paths. Beta 16 supersedes this package.

This record covers the local release candidate that adds in-place meeting
editing, explicit whole-page Notion replacement, and signed Sparkle update
infrastructure. It does not claim Developer ID distribution, notarization, a
published appcast, or human packaged-app acceptance.

## Automated validation

- Pre-version focused suites: 429 passed, 0 failed, exit 0.
- Debug build: passed, exit 0.
- Full unit suite: 1,186 passed, 0 failed, exit 0.
- Final whole scheme after UI contract corrections:
  - MeetingNotesTests: 1,186 passed, 0 failed.
  - MeetingNotesUITests: 12 passed, 0 failed.
  - Command exit: 0.
- Update release policy suite after publishability-order regression fix:
  10 passed, 0 failed, exit 0.
- `git diff --check`: passed.
- `bash -n Scripts/build_and_package.sh`: passed.
- `bash -n Scripts/validate_update_release.sh`: passed.

The first whole-scheme attempt was blocked before UI execution by macOS
LocalAuthentication reporting that system authentication was already running.
After that environment collision cleared, UI execution exposed two outdated UI
test contracts: editable document text was still queried as `StaticText`, and
the legacy partial-archive fixture still expected the old per-document Notion
label. Those test expectations were corrected without changing production UI
or Notion behavior, and the final complete scheme passed.

## Package

- Filename: `MeetingNotes-1.2.0-beta-build14.dmg`
- Size: 9,233,578 bytes.
- SHA-256:
  `06fec0b7bee381cbf1199d7a608af637d7755bf8bcca81db4551bcd2b5609d1a`
- `hdiutil verify`: passed.
- Package validation: passed.
- Architecture: arm64.
- Display name: `会议记录 Beta`.
- Bundle identifier: `com.shenminghao.MeetingNotes.beta`.
- Version/build: `1.2.0 (14)`.
- Microphone privacy string: `用于录制并转录会议中的麦克风声音。`
- Sandbox, audio input, and network client entitlements: present.
- Embedded Sparkle framework and helpers: strict code-sign verification passed.
- Feed: Beta channel only.
- Signing mode: ad hoc.
- Notarization: skipped for the ad-hoc local package.
- Publishable: **NO**.

The package is rejected and must not be used for local acceptance, published
to the Sparkle feed, or represented as a clean-Mac distribution artifact.

## Human packaged-app acceptance

Status: **NOT PERFORMED — PACKAGE REJECTED AT LAUNCH**

The following checks moved to the replacement Beta package:

- live transcript edits auto-save and survive meeting finalization and restart;
- summary and full-minutes edits auto-save and survive ordinary app actions;
- exact replacement affects only the current meeting;
- explicit Notion sync replaces the app-managed page content without permanent
  duplication;
- the original native translucent interface remains visually intact;
- model preparation still gates meeting creation without losing stop controls;
- protected meeting or sync activity prevents update installation;
- the Beta update channel does not consume the stable feed.

The complete idle update/restart path remains pending a Developer ID signed,
notarized second build and a deliberately published Beta appcast.

## Remaining distribution gates

- Developer ID Application certificate: pending.
- Apple notarization and stapling: pending.
- Protected GitHub release secrets: pending configuration.
- Published Beta appcast and GitHub Release: not performed.
- Clean-Mac update installation and restart: pending.
- Push, PR update, and merge: not performed.
