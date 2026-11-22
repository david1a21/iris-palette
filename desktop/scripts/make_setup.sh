#!/usr/bin/env bash
# Iris 调色盘 · 生成 Windows 安装器（NSIS）
#   bash scripts/make_setup.sh            # 用现有 dist/win 打包
#   bash scripts/make_setup.sh --build    # 先重建 dist/win 再打包
# 依赖：dist/win 已存在（node scripts/build.js win）、makensis
#       NSIS_HOME 默认 /home/user/iris-release/tools/nsis
set -euo pipefail
cd "$(dirname "$0")/.."

NSIS_HOME="${NSIS_HOME:-/home/user/iris-release/tools/nsis}"
MAKENSIS="$NSIS_HOME/linux/makensis"
[ -x "$MAKENSIS" ] || { echo "缺少 makensis：$MAKENSIS（需先解出 electron-builder-binaries 的 nsis-3.0.4.2）" >&2; exit 1; }

if [ "${1:-}" = "--build" ]; then
  node scripts/build.js win
fi

[ -f "dist/win/Iris 调色盘.exe" ] || { echo "dist/win 里没有主程序，请先 node scripts/build.js win（或加 --build）" >&2; exit 1; }

# 版本号唯一来源：内嵌页面里的 IRIS_VERSION，页面换成新版这里自动跟着变
VER=$(grep -o "IRIS_VERSION='[^']*'" app/assets/index.html | head -1 | sed "s/.*'\(.*\)'/\1/")
[ -n "$VER" ] || { echo "从 app/assets/index.html 读不到 IRIS_VERSION" >&2; exit 1; }

OUT="release/Iris-Palette-Windows-x64-${VER}-Setup.exe"
mkdir -p release
rm -f "$OUT"

echo "    编译安装器：${VER}  (源 $(du -sh dist/win | cut -f1))"
"$MAKENSIS" -V2 \
  -DVERSION="$VER" \
  -DICONABS="$PWD/app/ui/icon.ico" \
  -DSRCDIR="$PWD/dist/win" \
  -DOUTFILE="$PWD/$OUT" \
  scripts/installer.nsi

[ -f "$OUT" ] || { echo "编译后没有产物：$OUT" >&2; exit 1; }
echo "    安装器：$(ls -lh "$OUT" | awk '{print $5}')  $OUT"
sha256sum "$OUT" | sed 's/^/    sha256 /'
