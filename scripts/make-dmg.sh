#!/usr/bin/env bash
# 把 dist/FreeRecord.app 打成可直接拖拽安装的 .dmg。
# 版本号从 App 的 Info.plist 读取，产物落在 dist/ 下（dist/ 已在 .gitignore 中）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-dist/FreeRecord.app}"
[[ -d "$APP" ]] || { echo "!! 找不到 $APP，请先执行 bash scripts/build.sh"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${OUT:-dist/FreeRecord-$VERSION.dmg}"
mkdir -p dist

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/payload"
cp -R "$APP" "$STAGE/payload/"
ln -s /Applications "$STAGE/payload/Applications"

echo "==> 生成 $OUT"
rm -f "$OUT"
hdiutil create -quiet \
  -volname "FreeRecord $VERSION" \
  -srcfolder "$STAGE/payload" \
  -format UDZO \
  "$OUT"

# dmg 本体也要签名。Developer ID 时需要带时间戳（公证要求）；其余 ad-hoc 即可。
if [[ "${CODESIGN_IDENTITY:-}" == Developer\ ID* ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$OUT"
else
  codesign --force --sign - "$OUT"
fi
echo "==> 完成：$OUT（$(du -h "$OUT" | cut -f1 | tr -d ' ')）"
