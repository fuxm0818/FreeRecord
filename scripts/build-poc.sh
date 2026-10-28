#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_NAME="FreeRecordPOC"
APP_NAME="FreeRecordPOC"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> 构建 arm64"
swift build -c release --arch arm64 --product "$BIN_NAME"
ARM_BIN="$(swift build -c release --arch arm64 --show-bin-path)/$BIN_NAME"

echo "==> 构建 x86_64（给 2015 款 Intel Mac）"
swift build -c release --arch x86_64 --product "$BIN_NAME" --scratch-path .build-x86
X86_BIN="$(swift build -c release --arch x86_64 --product "$BIN_NAME" --scratch-path .build-x86 --show-bin-path)/$BIN_NAME"

echo "==> 打包 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/POC-Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

lipo -info "$APP/Contents/MacOS/$BIN_NAME"
echo "==> 完成：$APP"
