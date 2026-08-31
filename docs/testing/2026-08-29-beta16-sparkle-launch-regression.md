# Beta 1.2.0 (16) Sparkle standalone-launch regression

Date: 2026-08-29

## Incident and root cause

Beta 14 was rejected after macOS terminated the app before `main` with a dyld
error: `@rpath/Sparkle.framework/Versions/B/Sparkle` could not be found. The
framework was embedded, but the executable did not contain the app-framework
runpath `@executable_path/../Frameworks`.

An internal Beta 15 added the correct runpath but was also rejected before
delivery. Its ad-hoc main app and nested Sparkle code carried different ad-hoc
identities while hardened runtime library validation was enabled, so dyld
reported that the mapped process and framework had different Team IDs.

Beta 16 keeps the correct embedded-framework runpath. Local ad-hoc packages do
not enable hardened runtime, which avoids applying Team-ID library validation
to unrelated ad-hoc identities. Developer ID distribution remains hardened;
the publish validator requires the main app and every Sparkle framework/helper
to carry the same nonempty TeamIdentifier.

## Automated validation

- Sparkle configuration and update release policy suites: 20 passed, 0 failed.
- Final packaging-policy assertions after the signing guard was added: 2 passed,
  0 failed.
- Debug build: passed, exit 0.
- Full unit suite: 1,190 passed, 0 failed, exit 0.
- `git diff --check`: passed.
- `bash -n Scripts/build_and_package.sh`: passed.
- `bash -n Scripts/validate_update_release.sh`: passed.

The final whole-scheme attempt ran all 1,190 unit tests successfully, then the
UI runner failed during XCTest initialization with `Timed out while enabling
automation mode`; command exit was 65 and no UI test case started. An isolated
UI retry failed at the same initialization boundary. One final isolated retry
started the runner but remained before the first UI test for more than three
minutes; it was stopped with exit 130 without terminating any user app or
system service. Immediately before these configuration-only runpath/signing
changes, the complete scheme passed all 1,186 then-current unit tests and 12 UI
tests. No UI production or test source was changed by the Sparkle launch fix.

## Final package

- Filename: `MeetingNotes-1.2.0-beta-build16.dmg`.
- Size: 9,233,862 bytes.
- SHA-256:
  `7fa14d7e26f904578c0fafd4325320209023e34732c296c24c0c8de16d7b132f`.
- `hdiutil verify`: passed.
- Package validation: passed.
- Display name: `会议记录 Beta`.
- Bundle identifier: `com.shenminghao.MeetingNotes.beta`.
- Version/build: `1.2.0 (16)`.
- Architecture: arm64.
- Signing mode: ad hoc without hardened runtime.
- Notarization: skipped for the local ad-hoc package.
- Publishable: **NO**.

The final DMG was mounted read-only and its packaged executable was launched
directly, without Xcode or injected framework paths. The executable contained
`@executable_path/../Frameworks`, remained alive after three seconds, and its
launch log contained no dyld or Sparkle-load error. Only that tracked process
was terminated after the smoke check.

## Human packaged-app acceptance

Status: **PENDING HUMAN**

Beta 16 still requires the user to launch the copied app and exercise the
editing, Notion replacement, model preparation, meeting controls, and update
UI flows. This local ad-hoc package is for same-Mac testing only.

## Beta update-feed bootstrap

The first manual update check failed with Sparkle error 2001 because
`https://nakutop.github.io/MeetingNotes/updates/beta/appcast.xml` returned HTTP
404. The client configuration was correct; the planned `gh-pages` source had
not yet been bootstrapped.

The independent `gh-pages` branch was created at commit
`26f6507c9eda07424e4db92e24090bd63e512b01`. GitHub Pages is configured from
that branch's root with HTTPS enforced. The Beta path now serves HTTP 200 with
`application/xml`. Its bootstrap appcast deliberately contains zero `item`
and zero `enclosure` elements, so it cannot advertise or download the local
ad-hoc DMG. The exact Sparkle 2.9.2 parser used by MeetingNotes accepted both
the local XML and the live HTTPS response as an empty appcast; Sparkle maps
that state to no update available.

Interactive re-check in the installed app remains pending because the Mac was
locked during the final UI step. No lock-screen bypass was attempted.

## Remaining distribution gates

- Developer ID Application certificate: pending.
- Apple notarization and stapling: pending.
- Protected GitHub release secrets: pending configuration.
- Published Beta appcast and GitHub Release: not performed.
- Clean-Mac update installation and restart: pending.
- Push, PR update, and merge: not performed.
