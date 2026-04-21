# Releasing Meeting Reminder

How to cut a signed + notarized release and publish it on GitHub.

## TL;DR — cutting a release

```bash
# 1. Make sure main is clean and up to date
git switch main
git pull --rebase

# 2. Tag the release (version in tag drives MARKETING_VERSION)
git tag -a v2.1.0 -m "Release 2.1.0"
git push mine v2.1.0

# 3. Watch the CI build
gh run watch
```

GitHub Actions (`.github/workflows/release.yml`) then:

1. Imports the signing cert into an ephemeral keychain
2. Archives + signs + exports the `.app`
3. Submits to Apple's notary service (`xcrun notarytool submit --wait`)
4. Staples the notarization ticket
5. Builds a signed, stapled DMG
6. Creates a GitHub release with the DMG + SHA256 checksum + auto-generated changelog

Typical end-to-end runtime: **6–10 minutes** (notarization wait dominates).

---

## One-time setup

You need six GitHub secrets under
`adamswbrown/meeting-reminder` → **Settings → Secrets and variables → Actions**.

### 1. Export the signing cert

1. Keychain Access → find **Developer ID Application: Adam Brown (XXXXXXXXXX)**
2. Right-click → **Export…** → choose **Personal Information Exchange (.p12)**
3. Pick a strong password (this becomes `MACOS_CERTIFICATE_PWD`)
4. Base64-encode and copy to clipboard:

   ```bash
   base64 -i /path/to/cert.p12 | pbcopy
   ```

5. Paste into the `MACOS_CERTIFICATE` secret.

### 2. Generate an app-specific password for notarization

1. appleid.apple.com → **Sign-in & Security** → **App-specific passwords** → **Generate an app-specific password**
2. Label it `meeting-reminder CI`
3. Copy the password — this is `NOTARIZATION_PWD`

### 3. Find your Team ID

Either:

- Keychain Access → expand the cert name → read the 10 uppercase alphanumeric characters in parentheses
- developer.apple.com → **Membership** → **Team ID**

### 4. Create the secrets

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | Base64 of the `.p12` from step 1 |
| `MACOS_CERTIFICATE_PWD` | The `.p12` password you picked |
| `NOTARIZATION_APPLE_ID` | Your Apple ID email |
| `NOTARIZATION_PWD` | App-specific password from step 2 |
| `NOTARIZATION_TEAM_ID` | 10-char team ID from step 3 (optional — CI can auto-extract it from the cert) |
| `KEYCHAIN_PASSWORD` | Any random string (e.g. `openssl rand -base64 24`). CI uses it to create a disposable keychain per run. |

---

## Local test build

You can reproduce the CI build on your Mac:

```bash
# Create .env in the repo root (gitignored):
cat > .env <<'EOF'
SIGNING_IDENTITY="Developer ID Application: Adam Brown (XXXXXXXXXX)"
NOTARIZATION_APPLE_ID="you@example.com"
NOTARIZATION_PWD="abcd-efgh-ijkl-mnop"
NOTARIZATION_TEAM_ID="XXXXXXXXXX"
EOF

# Full signed + notarized build
scripts/build-release.sh 2.1.0

# Skip notarization for a quick signed-only test
SKIP_NOTARIZE=1 scripts/build-release.sh 2.1.0-test
```

Output: `dist/MeetingReminder-<version>.dmg` (+ `.dmg.sha256`).

`.env` is gitignored. Never commit it.

---

## Dry-run the workflow without tagging

Push the workflow, go to **Actions → Release → Run workflow** in the GitHub UI.
This builds + signs + DMGs without notarizing and uploads the result as a
workflow artifact (not a public release). Useful for sanity-checking the
pipeline after changes.

---

## Rotating the certificate

Developer ID Application certs expire every 5 years. When yours does:

1. developer.apple.com → **Certificates, Identifiers & Profiles** → create a new Developer ID Application cert
2. Download and install in Keychain Access
3. Redo steps 1–4 of the one-time setup above (export, base64, update `MACOS_CERTIFICATE` and `MACOS_CERTIFICATE_PWD`)
4. No other secrets need to change — the Apple ID and team ID stay the same

---

## Troubleshooting

### Notarization fails with "invalid signature"

Usually means hardened runtime isn't enabled or a nested framework isn't signed. Check:

```bash
codesign --verify --deep --strict --verbose=2 build/export/MeetingReminder.app
```

Hardened runtime was enabled in commit `18040af` — if someone disabled it in
the Xcode project settings, re-enable: Signing & Capabilities → Hardened Runtime.

### Notarization stuck on "In Progress"

Apple's notary service is occasionally slow. `notarytool submit --wait` will
happily sit there for 10+ minutes. The CI step has a `timeout-minutes: 30`
safety net. If that fires, re-run the job — the archive is cached and the
retry is usually fast.

### "No signing identity found"

The cert didn't import. Common causes:
- `MACOS_CERTIFICATE_PWD` doesn't match what you used when exporting the `.p12`
- `MACOS_CERTIFICATE` is base64 of a `.cer` (public only), not a `.p12` (private + public)
- You exported a "Development" cert, not "Developer ID Application"

Verify locally: `security find-identity -v -p codesigning` should list "Developer ID Application" for your team.

### CI fails with "Xcode_15.4.app: command not found"

GitHub rotated available Xcode versions. Update the `Select Xcode` step in
`.github/workflows/release.yml` to a version available in the
[runner image README](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-arm64-Readme.md).

### Users report "app is damaged and can't be opened"

This usually means the DMG wasn't stapled or the staple didn't apply. Check:

```bash
spctl -a -vvv -t install dist/MeetingReminder-2.1.0.dmg
```

Should return `source=Notarized Developer ID`. If it says `source=Unnotarized Developer ID`, stapling failed — re-run the release job.

### Versioning mistake

Tags drive everything — if you tag `v2.1.0` and then realize the code was wrong:

```bash
# Delete the remote tag
git push mine :refs/tags/v2.1.0
# Delete the GitHub release manually from the Releases page
# Fix the code, commit, re-tag with the same version
git tag -fa v2.1.0 -m "Release 2.1.0"
git push mine v2.1.0
```

The CI will re-run and overwrite the release. Avoid doing this if users may
have already downloaded the bad build — bump to `v2.1.1` instead.
