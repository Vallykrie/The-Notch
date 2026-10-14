#!/bin/bash
#
# Build a distributable The Notch.dmg.
#
# Everything is archived unsigned and then signed here by hand, so the local and CI
# paths are the same code. Signing is opt-in through the environment:
#
#   CODESIGN_IDENTITY   Developer ID Application identity. Unset -> ad-hoc signature,
#                       which produces a working but unnotarised app that Gatekeeper
#                       will quarantine on first launch.
#   NOTARY_KEYCHAIN_PROFILE
#                       `notarytool store-credentials` profile name. Requires
#                       CODESIGN_IDENTITY; unset -> the DMG is not notarised.
#
# Usage: scripts/build-release.sh [version]
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="The Notch"
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
STAGE="$BUILD_DIR/dmg"
DIST="$ROOT/dist"

# The tag drives the version. Falling back to the project's own MARKETING_VERSION keeps
# a bare local invocation working.
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(xcodebuild -project "$APP_NAME.xcodeproj" -target "$APP_NAME" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
fi
VERSION="${VERSION#v}"
: "${VERSION:?could not determine a version}"

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
DMG="$DIST/The-Notch-$VERSION.dmg"

echo "==> Building $APP_NAME $VERSION (build $BUILD_NUMBER)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST"

# --- 1. Archive, universal, unsigned -----------------------------------------------
echo "==> Archiving (arm64 + x86_64)"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  | (command -v xcbeautify >/dev/null && xcbeautify || cat)

APP="$STAGE/$APP_NAME.app"
mkdir -p "$STAGE"
cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

# --- 2. Swap in a universal notch-hook ---------------------------------------------
# The copy checked into Resources/Hooks is arm64-only; an Intel Mac needs the fat one.
echo "==> Building universal notch-hook"
HOOK_TMP="$BUILD_DIR/hook"
mkdir -p "$HOOK_TMP"
for arch in arm64 amd64; do
  (cd tools/notch-hook && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" \
    go build -trimpath -ldflags "-s -w" -o "$HOOK_TMP/notch-hook-$arch" .)
done
lipo -create -output "$HOOK_TMP/notch-hook" \
  "$HOOK_TMP/notch-hook-arm64" "$HOOK_TMP/notch-hook-amd64"
cp "$HOOK_TMP/notch-hook" "$APP/Contents/Resources/notch-hook"
chmod +x "$APP/Contents/Resources/notch-hook"
lipo -info "$APP/Contents/Resources/notch-hook"
lipo -info "$APP/Contents/MacOS/$APP_NAME"

# --- 3. Sign ------------------------------------------------------------------------
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing with: $IDENTITY (hardened runtime, secure timestamp)"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
else
  echo "==> No CODESIGN_IDENTITY; signing ad-hoc (not notarisable)"
  SIGN_ARGS=(--force --sign -)
fi

# Nested code first, then the bundle, or the outer signature seals a stale hash.
# Entitlements go on the bundle only. The archive above is built with them stripped, and
# under the hardened runtime an app without `automation.apple-events` is refused every Apple
# Event without a prompt — Now Playing and jump-back both talk to other apps through
# `osascript`, which is attributed to this app.
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/notch-hook"

# Sparkle ships its own helpers (the installer, the downloader and the Updater app). The
# archive leaves them unsigned, so they are signed here innermost first, then the framework,
# with no entitlements: the app is not sandboxed, so the helpers need none. `--deep` is not
# used, because it re-signs each nested bundle with the outer bundle's entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE" ]]; then
  echo "==> Signing Sparkle's helpers"
  for helper in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [[ -e "$helper" ]] && codesign "${SIGN_ARGS[@]}" "$helper"
  done
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi

codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/$APP_NAME/$APP_NAME.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 4. Package as a DMG -------------------------------------------------------------
echo "==> Building DMG"
ln -sf /Applications "$STAGE/Applications"

# Whether "$DMG" is a disk image notarytool will accept: a UDIF image ends in a 512-byte
# trailer that starts with "koly", and `hdiutil verify` checks the image's own checksums.
# The beta.15 release failed because hdiutil exited 0 having written a file that was neither,
# and nothing noticed until notarytool refused it.
dmg_is_valid() {
  [[ -s "$DMG" ]] || return 1
  [[ "$(tail -c 512 "$DMG" | head -c 4)" == "koly" ]] || return 1
  hdiutil verify "$DMG" >/dev/null 2>&1
}

for attempt in 1 2 3; do
  rm -f "$DMG"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG" >/dev/null && dmg_is_valid && break
  echo "    attempt $attempt produced no valid disk image" >&2
  if [[ $attempt -eq 3 ]]; then
    echo "error: hdiutil could not build a valid DMG in three attempts" >&2
    exit 1
  fi
  sleep $((attempt * 5))
done

# --- 5. Notarise and staple ----------------------------------------------------------
if [[ -n "$IDENTITY" ]]; then
  codesign "${SIGN_ARGS[@]}" "$DMG"
  # Signing writes into the image, so it is checked again before Apple sees it.
  if ! dmg_is_valid; then
    echo "error: the DMG is no longer a valid disk image after signing" >&2
    exit 1
  fi
fi

PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
if [[ -n "$IDENTITY" && -n "$PROFILE" ]]; then
  echo "==> Notarising (this waits on Apple)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

  # Stapling and validating both fetch the ticket from Apple's CloudKit endpoint, which drops
  # connections now and then ("The network connection was lost", exit 68). The submission has
  # already succeeded by this point, so a dropped lookup is worth retrying rather than failing
  # the whole release.
  retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
      "$@" && return 0
      echo "    attempt $attempt failed: $*" >&2
      [[ $attempt -lt 5 ]] && sleep $((attempt * 10))
    done
    return 1
  }
  retry xcrun stapler staple "$DMG"
  retry xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
else
  echo "==> Skipping notarisation (needs CODESIGN_IDENTITY and NOTARY_KEYCHAIN_PROFILE)"
fi

# --- 6. Checksum ---------------------------------------------------------------------
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo
echo "==> Done: $DMG"
cat "$DMG.sha256"
