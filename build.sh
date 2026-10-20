#!/bin/bash
# Builds Ord.app. Usage: ./build.sh [--install]
#   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). With a stable identity (e.g. an
#                  "Apple Development" certificate) macOS keeps permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

# Use an "Apple Development" certificate when there is one, so Accessibility and the other permissions
# survive rebuilds. An ad-hoc signature changes every build and macOS then forgets the permissions.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi

# One build per architecture, then one universal binary (works without Xcode, only the Command Line Tools).
for arch in arm64 x86_64; do
    swift build -c release --triple $arch-apple-macosx14.0 2>&1 | grep -E "error|warning: unre" || true
    [ -f .build/$arch-apple-macosx/release/Ord ] || { echo "build failed ($arch)"; exit 1; }
done
mkdir -p build
BIN=build/Ord-universal
lipo -create .build/arm64-apple-macosx/release/Ord .build/x86_64-apple-macosx/release/Ord -output "$BIN"

APP=build/Ord.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Ord.icns ] && cp Resources/Ord.icns "$APP/Contents/Resources/"
codesign --force --options runtime --entitlements Resources/Ord.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Ord 2>/dev/null && sleep 0.5 || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Ord.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Ord.app
    echo "installed ~/Applications/Ord.app"
fi
