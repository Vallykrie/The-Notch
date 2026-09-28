#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DIST_DIR="$SCRIPT_DIR/dist"
mkdir -p "$DIST_DIR"

for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64 freebsd/arm64 freebsd/amd64; do
    os=${target%/*}
    arch=${target#*/}
    output="$DIST_DIR/notch-hook-$os-$arch"
    printf 'building %s/%s -> %s\n' "$os" "$arch" "$output"
    (cd "$SCRIPT_DIR" && CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -o "$output" .)
done
