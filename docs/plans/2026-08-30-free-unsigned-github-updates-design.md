# Free Unsigned GitHub Updates Design

**Date:** 2026-08-30

## Goal

Publish MeetingNotes through GitHub without an Apple Developer Program
subscription while preserving an authenticated Sparkle update chain. The first
installation remains a manual Gatekeeper exception; later versions can be
downloaded and installed from inside the application.

## Product Identity

The first stable seed is:

- Display name: `会议记录`
- Bundle identifier: `com.shenminghao.MeetingNotes`
- Marketing version: `1.2.0`
- Build version: `16`
- Update channel: `stable`
- Feed: `https://nakutop.github.io/MeetingNotes/updates/stable/appcast.xml`

Build 16 does not update to itself. It establishes the updater and embedded
public key; later stable builds must use a strictly greater `CFBundleVersion`.

## Trust Model

The free channel intentionally does not claim Apple distribution trust:

- The application is ad-hoc code signed so its nested code and entitlements are
  sealed consistently.
- The DMG and application are not Developer ID signed or notarized.
- Gatekeeper rejection is expected on first installation. Release notes must
  explain the manual right-click/System Settings approval step.
- Every published archive is signed with Sparkle EdDSA. The public key remains
  embedded in the application; the matching private seed is stored only as a
  protected GitHub Actions secret.
- HTTPS protects transport and EdDSA authenticates the exact update archive.
- Losing the EdDSA private key breaks the unsigned update chain. The workflow
  must never generate or rotate a replacement key implicitly.

Before public release, update Sparkle from 2.9.2 to 2.9.6 so the seed does not
ship with updater defects already fixed upstream.

## Publishing Modes

Keep the existing fail-closed Developer ID workflow intact. Add an explicit
`community-unsigned` mode rather than weakening its checks.

The community mode:

1. Requires a manual confirmation string that contains `UNSIGNED`.
2. Accepts only the stable channel for this initial release.
3. Requires the existing Sparkle private key secret and no Apple credentials.
4. Builds Release with ad-hoc signing.
5. Validates the app, DMG, identity, framework embedding, entitlements, and
   EdDSA archive signature before any GitHub mutation.
6. Requires `get-task-allow` to be absent.
7. Requires Developer ID, secure timestamp, and notarization ticket to be
   absent, and records `APPLE_DISTRIBUTABLE=NO`.
8. Records `SPARKLE_UPDATE_PUBLISHABLE=YES` only after all unsigned-channel
   checks pass.

The Developer ID mode continues to require Apple credentials, notarization,
stapling, hardened runtime, matching Team ID, and `PUBLISHABLE=YES`.

## GitHub Representation

Publish the first free seed as:

- Tag: `v1.2.0-unsigned-build16`
- Asset: `MeetingNotes-1.2.0-build16-unsigned.dmg`
- GitHub state: prerelease
- Feed item: stable appcast entry with Sparkle version `16`

The release title and notes visibly say `未签名 / 未公证`. The unsigned tag does
not consume `v1.2.0`, leaving that canonical tag available for a future Apple
Developer ID release.

GitHub Release creation and `gh-pages` feed publication occur only after local
and CI validation. If Release creation succeeds but feed publication fails, the
workflow reports the partial state and does not create a second tag or release.

## Source Provenance

The published artifact must be built from a pushed commit. Existing uncommitted
Beta 14-16 packaging/test changes are reviewed and committed deliberately before
publication. The Release version/build values are persisted in `project.yml`,
`project.pbxproj`, and the packaging validator so CI does not depend on local
command-line overrides.

No release may be created from an uncommitted local DMG whose source does not
match the release tag.

## Validation

Validation includes:

- Release and Debug compilation.
- Focused updater and release-policy tests.
- Full MeetingNotes unit suite and whole scheme when the environment permits.
- Package identity, arm64 architecture, privacy string, Sparkle embedding, and
  framework runpath.
- Deep strict ad-hoc code-signature verification and exact entitlements.
- Expected absence of Apple Developer ID, notarization, and stapling.
- EdDSA public/private key match without printing the private key.
- EdDSA verification of the exact DMG bytes referenced by the appcast.
- Appcast version, length, URL, channel, and hardware requirements.
- A deterministic two-version unsigned update-chain test before publishing.
- Post-publication HTTPS checks for the Release asset and stable appcast.

The public Release remains blocked if the existing private EdDSA key cannot be
proved to match the public key embedded in build 16.
