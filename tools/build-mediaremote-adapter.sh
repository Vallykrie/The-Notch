#!/bin/bash
# Builds the vendored MediaRemoteAdapter into the app bundle. Runs as an Xcode Run Script phase.
#
#   Contents/Frameworks/MediaRemoteAdapter.framework   loaded by /usr/bin/perl, never linked
#   Contents/Helpers/MediaRemoteAdapterTestClient      used only by the adapter's `test` command
#   Contents/Resources/mediaremote-adapter.pl          the entry point perl runs
#
# Mirrors the sources and flags in Vendor/MediaRemoteAdapter/CMakeLists.txt.
set -euo pipefail

SRC="${SRCROOT}/Vendor/MediaRemoteAdapter"
APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents"
FW="${APP}/Frameworks/MediaRemoteAdapter.framework"
HELPERS="${APP}/Helpers"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

ARCH_FLAGS=()
for arch in ${ARCHS}; do ARCH_FLAGS+=(-arch "$arch"); done

SOURCES=(
  src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m
  src/adapter/now_playing.m src/adapter/repeat.m src/adapter/seek.m src/adapter/send.m
  src/adapter/shuffle.m src/adapter/speed.m src/adapter/stream.m src/adapter/test.m
  src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m
)

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources" "$HELPERS"

cd "$SRC"
xcrun clang -dynamiclib "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MIN_OS" \
  -fobjc-arc -fvisibility=default -O2 \
  -I include -I src \
  -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  "${SOURCES[@]}" -o "$FW/Versions/A/MediaRemoteAdapter"

xcrun clang "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MIN_OS" -fobjc-arc -O2 \
  -I src/test -framework Foundation -framework MediaPlayer \
  src/test/main.m src/test/NowPlayingTest.m -o "$HELPERS/MediaRemoteAdapterTestClient"

cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER}.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"

cp "$SRC/bin/mediaremote-adapter.pl" "${APP}/Resources/mediaremote-adapter.pl"

# Sign with the app's identity so a Developer ID build notarises; ad-hoc when signing is off.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime); fi
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Developer ID"* ]]; then SIGN_FLAGS+=(--timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$HELPERS/MediaRemoteAdapterTestClient"
codesign "${SIGN_FLAGS[@]}" "$FW"
