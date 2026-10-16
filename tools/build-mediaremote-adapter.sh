#!/bin/bash
# Builds the vendored MediaRemoteAdapter into the app bundle. Runs as an Xcode Run Script phase.
#
#   Contents/Frameworks/MediaRemoteAdapter.framework   loaded by /usr/bin/perl, never linked
#   Contents/Helpers/MediaRemoteAdapterTestClient      used only by the adapter's `test` command
#   Contents/Resources/mediaremote-adapter.pl          the entry point perl runs
#
# Mirrors the sources and flags in Vendor/MediaRemoteAdapter/CMakeLists.txt.
#
# Runs inside Xcode's user-script sandbox: it may only read the files listed in
# tools/mediaremote-adapter-inputs.xcfilelist and write the outputs declared on the phase. Add a
# source upstream and it must be added to both. Nothing here is signed: the linker ad-hoc signs
# each binary, which is all a development build needs, and scripts/build-release.sh signs both
# with the Developer ID before the app.
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

mkdir -p "$FW/Versions/A/Resources" "$HELPERS"

# Compile into a private temp folder, then copy each finished binary into the bundle. A
# universal build ends in `lipo`, which writes a `<output>.lipo` scratch file beside its
# output; the sandbox refuses that inside the bundle, where only declared outputs may be
# written, but allows the temp folder.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mediaremote-adapter.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cd "$SRC"
xcrun clang -dynamiclib "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MIN_OS" \
  -fobjc-arc -fvisibility=default -O2 \
  -I include -I src \
  -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  "${SOURCES[@]}" -o "$WORK/MediaRemoteAdapter"

# Upstream sizes a stack buffer with a `const int`; clang folds it and warns. Unmodified source.
xcrun clang "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MIN_OS" -fobjc-arc -O2 -Wno-gnu-folding-constant \
  -I src/test -framework Foundation -framework MediaPlayer \
  src/test/main.m src/test/NowPlayingTest.m -o "$WORK/MediaRemoteAdapterTestClient"

cp "$WORK/MediaRemoteAdapter" "$FW/Versions/A/MediaRemoteAdapter"
cp "$WORK/MediaRemoteAdapterTestClient" "$HELPERS/MediaRemoteAdapterTestClient"

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
