#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_NAME="FreeRecord"
APP_NAME="FreeRecord"
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
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# TCC 授权按代码签名身份记账：ad-hoc 每次构建 cdhash 都变，授权就失效。
# 优先用 keychain 里的稳定身份（CODESIGN_IDENTITY 或 "FreeRec Dev"），权限可在多次构建间保留。
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"FreeRec Dev"'; then
  SIGN_IDENTITY="FreeRec Dev"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> 签名：ad-hoc（每次构建都会让屏幕录制授权失效）"
else
  echo "==> 签名：$SIGN_IDENTITY"
fi
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
  # 只有 Developer ID 才需要公证：hardened runtime + 安全时间戳 + 显式 entitlements。
  # 本地 ad-hoc / 自签名不启用 hardened runtime，方便用 lldb attach 调试。
  codesign --force --options runtime --timestamp \
    --entitlements Resources/FreeRecord.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi

lipo -info "$APP/Contents/MacOS/$BIN_NAME"
echo "==> 完成：$APP"
