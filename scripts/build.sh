#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_NAME="FreeRecord"
APP_NAME="FreeRecord"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> 准备 MP3 编码器（macOS 自身编不出 MP3，只能内嵌 LAME）"
NEED_MP3_ENCODER=1
if [[ "${ALLOW_MISSING_MP3_ENCODER:-0}" == "1" ]]; then
  # 离线应急：允许出不带编码器的包，此时纯录音成品退回 .m4a
  NEED_MP3_ENCODER=0
  bash scripts/build-mp3-encoder.sh || echo "!! 编码器构建失败，本次包没有 MP3 输出"
else
  bash scripts/build-mp3-encoder.sh
fi
# 脚本内部的失败可能被 EXIT trap 吃成 0，所以只认产物本身：
# 少了这个文件还继续打包，发出去的包就是「点了录音只出 .m4a」而没人会告诉你
if [[ "$NEED_MP3_ENCODER" == "1" ]]; then
  [[ -x Vendor/bin/lame ]] || { echo "!! Vendor/bin/lame 没生成，终止出包（离线应急用 ALLOW_MISSING_MP3_ENCODER=1）"; exit 1; }
  [[ -f Vendor/LICENSE.lame ]] || { echo "!! Vendor/LICENSE.lame 没生成，LGPL 要求随包附许可文本"; exit 1; }
  ARCHES="$(lipo -archs Vendor/bin/lame)"
  case " $ARCHES " in *" arm64 "*) ;; *) echo "!! Vendor/bin/lame 缺 arm64（实际：${ARCHES}）"; exit 1 ;; esac
  case " $ARCHES " in *" x86_64 "*) ;; *) echo "!! Vendor/bin/lame 缺 x86_64，Intel Mac 会闪退（实际：${ARCHES}）"; exit 1 ;; esac
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
# App 名称/权限文案按系统语言取值：英文系统读 en.lproj，中文系统读 zh-Hans.lproj。
# 少了这两个目录，Finder、Dock 和「系统设置 → 隐私与安全性」列表里会固定显示 App-Info.plist 里的中文值。
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
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
# 最后一道闸：产物里没有编码器就发出去，用户只会发现「录音出的是 .m4a」
if [[ "$NEED_MP3_ENCODER" == "1" ]]; then
  [[ -x "$APP/Contents/Helpers/lame" ]] || { echo "!! ${APP} 里没有 Helpers/lame，这个包出不了 MP3"; exit 1; }
  echo "==> MP3 编码器：$(lipo -archs "$APP/Contents/Helpers/lame")"
else
  echo "==> 本次包不含 MP3 编码器（纯录音会退回 .m4a）"
fi
echo "==> 完成：$APP"
