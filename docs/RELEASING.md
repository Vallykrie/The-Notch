# Releasing

## How it works

`.github/workflows/release.yml` fires on any `v*` tag. It runs
[`scripts/build-release.sh`](../scripts/build-release.sh), which:

1. Archives a universal (`arm64` + `x86_64`) Release build, unsigned.
2. Builds `notch-hook` for both architectures and `lipo`s them into one binary, replacing the
   arm64-only copy checked into `The Notch/Resources/Hooks/`. Without this an Intel Mac gets an
   app that runs but whose agent hooks do not.
3. Signs the nested hook first, then the bundle. Nested code must be signed before the outer
   bundle or the outer signature seals a stale hash. The bundle is signed with
   `The Notch/The Notch.entitlements`, whose `automation.apple-events` entitlement the hardened
   runtime requires before it lets Now Playing and jump-back send Apple Events.
4. Packages a DMG with an `/Applications` symlink.
5. Notarises and staples, if credentials are present.
6. Writes a SHA-256 next to the DMG.

Then the workflow publishes the DMG and its checksum to GitHub Releases. A `-` anywhere in the
version (`1.0.0-beta.1`) marks it as a prerelease.

## Cutting a release

```bash
git tag -a v1.0.0-beta.2 -m "The Notch 1.0.0-beta.2" && git push origin v1.0.0-beta.2
```

The tag is the source of truth for the version — it overrides `MARKETING_VERSION` on the build
command line. `CURRENT_PROJECT_VERSION` becomes the commit count, so it always increases.

To build a DMG without publishing anything, run the workflow manually from the Actions tab
(`workflow_dispatch`) and take the artifact. Locally:

```bash
scripts/build-release.sh 1.0.0-beta.2
```

## Signing and notarisation

Until the secrets below exist, builds are **ad-hoc signed**: they install and run, but Gatekeeper
blocks the first launch and testers have to right-click → Open. The release notes say so
automatically, and stop saying so once the build is signed.

### 1. Get a Developer ID Application certificate

An *Apple Development* certificate is not enough — distribution outside the App Store needs a
*Developer ID Application* certificate. Easiest path:

**Xcode → Settings → Accounts →** select the team **→ Manage Certificates → + → Developer ID
Application.**

Confirm it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Export it as a `.p12`

**Keychain Access → My Certificates**, right-click the *Developer ID Application* certificate →
**Export** → `.p12`, and set an export password. Then:

```bash
base64 -i /path/to/cert.p12 | pbcopy
```

### 3. Create an App Store Connect API key for notarytool

**App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys →
Generate API Key**, with the **Developer** role. Download the `AuthKey_XXXXXXXXXX.p8` — Apple
serves it once. Note the **Key ID** and the **Issuer ID** on that page.

```bash
base64 -i /path/to/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

### 4. Add the repository secrets

Run these yourself — they carry credentials.

```bash
gh secret set MACOS_CERTIFICATE < <(base64 -i /path/to/cert.p12)
gh secret set MACOS_CERTIFICATE_PASSWORD
gh secret set MACOS_SIGN_IDENTITY   # "Developer ID Application: Your Name (TEAMID)"
gh secret set NOTARY_KEY < <(base64 -i /path/to/AuthKey_XXXXXXXXXX.p8)
gh secret set NOTARY_KEY_ID         # the 10-character Key ID
gh secret set NOTARY_ISSUER_ID      # the UUID Issuer ID
```

The exact `MACOS_SIGN_IDENTITY` string is the quoted name from `security find-identity`.

Nothing else changes: the next tag produces a signed, notarised, stapled DMG that opens with a
double-click. Delete any secret to fall back to ad-hoc.

### Signing a local build

```bash
xcrun notarytool store-credentials notch-notary \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id KEYID --issuer ISSUERID

CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE=notch-notary \
scripts/build-release.sh 1.0.0-beta.2
```

## Verifying a build

```bash
hdiutil attach dist/The-Notch-<version>.dmg
codesign -dv --verbose=4 "/Volumes/The Notch/The Notch.app"
spctl --assess --type execute -vv "/Volumes/The Notch/The Notch.app"   # "accepted" once notarised
lipo -info "/Volumes/The Notch/The Notch.app/Contents/MacOS/The Notch" # x86_64 arm64
```

## Distribution repos

| Repo | Holds |
| --- | --- |
| `Vallykrie/The-Notch` | source, and the release DMGs |
| [`Vallykrie/homebrew-tap`](https://github.com/Vallykrie/homebrew-tap) | `Casks/the-notch.rb` |

`Vallykrie/the-notch-releases` is retired. It mirrored DMGs while the source repo was private;
it still holds beta.1 and beta.2 but receives nothing new.

### One-time token setup

The cask bump needs a token that can write to `homebrew-tap`; the built-in `GITHUB_TOKEN` is
scoped to this repository only. Create a fine-grained PAT with **Contents: read and write** on
`homebrew-tap` only, then:

```bash
gh secret set RELEASE_REPO_TOKEN --repo Vallykrie/The-Notch
```

Until that secret exists, tagging still builds and publishes the release; the workflow logs a
warning and skips the cask bump, so update `version` and `sha256` in the cask by hand.

### The cask

`version` and `sha256` are rewritten by the workflow; everything else is hand-maintained. To
change the cask itself, edit it in the tap repo.

```bash
brew install --cask vallykrie/tap/the-notch
```

Until the app is notarised, Homebrew still quarantines it and Gatekeeper blocks the first launch.
Homebrew 6 removed the `--no-quarantine` flag, so the fix is:

```bash
xattr -dr com.apple.quarantine "/Applications/The Notch.app"
```

The cask says this in its caveats. Notarising removes the problem entirely; nothing about the cask
needs to change when that happens.

## Still to build

- Sparkle appcast for in-app updates (needs a signed build first).
