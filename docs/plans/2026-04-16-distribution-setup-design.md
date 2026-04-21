# Distribution Setup — Design Document

**Date:** 2026-04-16
**Author:** Adam Brown (with Claude)
**Status:** Approved — ready for implementation planning

## Goal

Turn the Meeting Reminder app into something anyone can download from GitHub
and run on their Mac, with a clean install experience (no Gatekeeper warnings,
no `xattr -cr` workarounds), buildable reproducibly from another Mac, and
releasable via a tag push.

## Constraints

- macOS-only target (Swift + SwiftUI, macOS 13+)
- Sandbox disabled (required to spawn the `minutes` CLI) — disqualifies App Store
- No SwiftPM package dependencies (preserve the existing promise)
- Two git remotes: `mine` (adamswbrown, push target) and `origin` (nilBora, fetch only)
- MIT licensed (compatible with upstream `nilBora/meeting-reminder`, which is also MIT)

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Code signing | Developer ID + notarization | Adam has a paid Apple Developer account; produces clean install UX with zero Gatekeeper friction |
| Build system | GitHub Actions on `macos-14` | Reproducible, no single-machine dependency; ~6-10 min per release |
| Distribution format | DMG only | Familiar Mac install UX; `hdiutil`-based (no npm/Node dep) |
| Auto-update | None (for now) | Keeps zero-dep promise; can revisit when user base grows |
| License | MIT | Matches upstream; maximum permissiveness for tinkerers |
| Version source | Git tag (`v*.*.*`) | Single source of truth; CI parses tag → `MARKETING_VERSION` |

## What gets added

```
.github/
└── workflows/
    └── release.yml              # CI: build → sign → notarize → DMG → release

scripts/
├── build-release.sh             # Local reproduction of CI build
├── create-dmg.sh                # hdiutil-based DMG assembly
└── notarize.sh                  # xcrun notarytool wrapper

docs/
└── RELEASING.md                 # Secrets setup, rotation, troubleshooting

README.md                         # Rewrite: user-first install flow + build instructions
LICENSE                           # MIT
```

**No existing Swift source or Xcode project settings change.** The entitlements
file stays as-is (sandbox disabled, hardened runtime enabled — per commit
`18040af`, hardened runtime is already in place, which is a notarization prereq).

## GitHub secrets (one-time setup)

Six secrets, all stored in `adamswbrown/meeting-reminder` → Settings → Secrets:

| Secret | Source |
|---|---|
| `MACOS_CERTIFICATE` | base64 of exported `.p12` (Developer ID Application cert) |
| `MACOS_CERTIFICATE_PWD` | password set when exporting the `.p12` |
| `NOTARIZATION_APPLE_ID` | Apple ID email |
| `NOTARIZATION_PWD` | app-specific password from appleid.apple.com |
| `NOTARIZATION_TEAM_ID` | 10-char team ID from developer.apple.com → Membership |
| `KEYCHAIN_PASSWORD` | random string; CI uses it to create an ephemeral keychain per run |

Notarization uses `app-specific password` (not App Store Connect API keys) —
simpler, and `notarytool` accepts both. API keys can be added later if this
gets shared with other maintainers.

## Release workflow (release.yml)

**Triggers:**
- Push of a git tag matching `v*.*.*` (e.g. `v2.1.0`)
- Manual `workflow_dispatch` (for dry-runs)

**Runs on:** `macos-14` (Apple Silicon, Xcode 15+ preinstalled)

**Steps:**

1. **Checkout** — `fetch-depth: 0` so tag message is readable
2. **Parse version** — `${GITHUB_REF_NAME#v}` → `$VERSION` (e.g. `2.1.0`)
3. **Import cert** into ephemeral keychain
   - `base64 -d` the `MACOS_CERTIFICATE` secret → `cert.p12`
   - `security create-keychain` + `import` + `set-key-partition-list`
4. **xcodebuild archive**
   - `CODE_SIGN_STYLE=Manual`
   - `CODE_SIGN_IDENTITY="Developer ID Application: Adam Brown (TEAMID)"`
   - `MARKETING_VERSION=$VERSION`
   - `CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER`
   - `OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"`
5. **Export** `.app` from archive via `ExportOptions.plist` (`method=developer-id`)
6. **Notarize**
   - `ditto -c -k --keepParent MeetingReminder.app notarize.zip`
   - `xcrun notarytool submit notarize.zip --wait --apple-id ... --password ... --team-id ...`
   - `xcrun stapler staple MeetingReminder.app`
7. **Build DMG** — `scripts/create-dmg.sh`
   - `hdiutil create` with layout: `.app` + symlink to `/Applications`
   - Sign the DMG: `codesign --sign "$IDENTITY" --timestamp ...`
   - Staple the DMG: `xcrun stapler staple`
8. **Create GitHub release** — `softprops/action-gh-release@v1`
   - Attach `MeetingReminder-$VERSION.dmg` + `MeetingReminder-$VERSION.dmg.sha256`
   - Body: tag message + auto-generated changelog since previous tag
9. **Cleanup** — `security delete-keychain` (always runs, even on failure)

**Typical runtime:** 6-10 minutes (notarization wait dominates).

## User-facing README structure

Rewrite `README.md` with a user-first layout:

**Above the fold:**
- One-sentence description
- Download latest DMG link (→ Releases page)
- 5-step install flow (download → open DMG → drag to Applications → launch → grant calendar permission)
- Optional: install `minutes` CLI for transcription

**Middle:**
- Feature highlights (3 bullets)
- Screenshots (optional, hold off until Minutes UX stabilizes)

**Bottom (collapsed `<details>`):**
- Build from source (Xcode 15+, `xcodebuild ...`)
- Contributing
- Link to `docs/ADHD-FEATURES-ROADMAP.md`

**Deliberately not in the README:**
- The `origin` remote (nilBora upstream) — internal plumbing
- "Coming soon" teasers
- Developer ID / signing internals (→ `docs/RELEASING.md`)

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Apple rejects notarization | CI fails, no release artifact. Fix locally, re-tag |
| GitHub bumps default Xcode and breaks build | Pin Xcode version in workflow: `sudo xcode-select -s /Applications/Xcode_15.4.app` |
| Cert expires | `docs/RELEASING.md` has rotation checklist (2-min job) |
| User download without internet | Solved by `stapler staple` — ticket is embedded, no phone-home needed |
| Entitlements drift between Debug/Release | Single `.entitlements` file used for both; sandbox stays disabled in Release |

## Out of scope (deliberately)

- Auto-update (Sparkle)
- Homebrew cask (can add later as separate PR)
- Windows / Linux builds
- App Store submission (blocked by disabled sandbox)
- App Store Connect API keys for notarization (app-specific password is sufficient)
- Signing the `minutes` CLI (users install via Homebrew; out of our control)

## Open questions (none)

All design decisions resolved during brainstorming.

## Next step

Create implementation plan with concrete tasks and verification steps for each file to add.
