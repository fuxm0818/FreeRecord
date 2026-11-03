#!/usr/bin/env bash
# 构建随 App 分发的 MP3 编码器：Vendor/bin/lame（arm64 + x86_64 通用二进制）。
#
# 为什么要有这一步：macOS 只提供 MP3 解码器，AVAssetWriter / AVAssetExportSession /
# ExtAudioFile 都写不出 .mp3，编码只能靠 LAME。
# 许可证：LAME 是 LGPL-2.0-or-later。我们把它编成独立可执行文件、通过管道调用，
# 不链接进主程序，因此 App 本体的 MIT 不受影响；随包附上 LAME 的许可证文本，
# 源码地址写在下面 LAME_URL。
set -euo pipefail
cd "$(dirname "$0")/.."

LAME_VERSION="3.100"
LAME_URL="https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz/download"
# 编译目标系统版本必须与 App 一致（Package.swift 的 platforms）
MIN_MACOS="12.0"
OUT_BIN="Vendor/bin/lame"
OUT_LICENSE="Vendor/LICENSE.lame"
CACHE_DIR="${HOME}/.cache/freerec"
TARBALL="${CACHE_DIR}/lame-${LAME_VERSION}.tar.gz"

if [[ -x "$OUT_BIN" && "${FORCE:-0}" != "1" ]]; then
  echo "==> 已存在 $OUT_BIN（FORCE=1 强制重建）"
  lipo -info "$OUT_BIN"
  exit 0
fi

# configure/make 的 CPU 探测按「本机」算：给不是本机的那一片显式指定 --host，
# 否则 x86_64 那一片会按 arm64 关掉 SSE 相关源文件，链接期报
# Undefined symbols: _init_xrpow_core_sse
NATIVE_ARCH="$(uname -m)"
host_triple() {
  case "$1" in
    arm64) echo "aarch64-apple-darwin22.6.0" ;;
    x86_64) echo "x86_64-apple-darwin22.6.0" ;;
    *) echo "" ;;
  esac
}

mkdir -p "$CACHE_DIR"
if [[ ! -f "$TARBALL" ]]; then
  echo "==> 下载 lame-${LAME_VERSION} 源码"
  curl -fL --retry 3 --max-time 300 -o "$TARBALL" "$LAME_URL"
fi
# 源码包必须可解且版本对得上，损坏的缓存会让下面报出莫名其妙的错
tar tzf "$TARBALL" >/dev/null

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar xzf "$TARBALL" -C "$WORK"
SRC="$WORK/lame-$LAME_VERSION"
[[ -d "$SRC" ]] || { echo "!! 源码包里没有 $SRC"; exit 1; }

for ARCH in arm64 x86_64; do
  echo "==> 编译 lame（$ARCH）"
  mkdir -p "$WORK/build-$ARCH"
  CONFIGURE_ARGS=("--disable-shared")
  if [[ "$ARCH" != "$NATIVE_ARCH" ]]; then
    CONFIGURE_ARGS+=("--host=$(host_triple "$ARCH")")
  fi
  (
    cd "$WORK/build-$ARCH"
    CFLAGS="-O3 -arch $ARCH -mmacosx-version-min=$MIN_MACOS" \
    LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS" \
      "$SRC/configure" "${CONFIGURE_ARGS[@]}" >/dev/null
    make "-j$(sysctl -n hw.ncpu)" >/dev/null
  )
  [[ -x "$WORK/build-$ARCH/frontend/lame" ]] || { echo "!! $ARCH 没编出 lame"; exit 1; }
done

mkdir -p "$(dirname "$OUT_BIN")"
lipo -create "$WORK/build-arm64/frontend/lame" "$WORK/build-x86_64/frontend/lame" -output "$OUT_BIN"
chmod +x "$OUT_BIN"
cp "$SRC/LICENSE" "$OUT_LICENSE"

# 只允许依赖系统库：多一条第三方 dylib，别人机器上就是「打开即闪退」
DEPS="$(otool -L "$OUT_BIN" | tail -n +2 | sed 's/^([^)]*)//' | sort -u)"
case "$DEPS" in
  *"/opt/homebrew/"*|*"/usr/local/"*)
    echo "!! lame 链接到了 Homebrew 的库，换到别的机器会缺库：$DEPS"
    exit 1
    ;;
esac

lipo -info "$OUT_BIN"
echo "==> 完成：$OUT_BIN + $OUT_LICENSE"
