#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_NAME="FreeRecord"
APP_NAME="FreeRecord"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> 准备 MP3 编码器（macOS 自身编不出 MP3，只能内嵌 LAME）"
if [[ "${ALLOW_MISSING_MP3_ENCODER:-0}" == "1" ]]; then
  # 离线应急：允许出不带编码器的包，此时纯录音成品退回 .m4a
  bash scripts/build-mp3-encoder.sh || echo "!! 编码器构建失败，本次包没有 MP3 输出"
else
  bash scripts/build-mp3-encoder.sh
fi

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
# macOS 26 起系统不再给满幅图标加底板，运行时用它顶替 Dock 图标（见 AppMain）
cp Resources/AppIconModern.icns "$APP/Contents/Resources/AppIconModern.icns"
if [[ -x Vendor/bin/lame ]]; then
  # 纯录音要出 MP3：编码器随包分发，运行时的查找路径见 Mp3Exporter.encoderURL
  mkdir -p "$APP/Contents/Helpers"
  cp Vendor/bin/lame "$APP/Contents/Helpers/lame"
  cp Vendor/LICENSE.lame "$APP/Contents/Resources/LICENSE.lame"
fi
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
  if [[ -x "$APP/Contents/Helpers/lame" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/lame"
  fi
  codesign --force --options runtime --timestamp \
    --entitlements Resources/FreeRecord.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  if [[ -x "$APP/Contents/Helpers/lame" ]]; then
    # 嵌套可执行文件要先签，App 的签名才把它算进 seal 里
    codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/lame"
  fi
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi

lipo -info "$APP/Contents/MacOS/$BIN_NAME"
echo "==> 完成：$APP"
