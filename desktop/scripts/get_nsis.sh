#!/usr/bin/env bash
# 拉取 NSIS 3.0.4.2 工具链（Linux 版 makensis），供 make_setup.sh 出 Windows 安装器
#   bash scripts/get_nsis.sh            # 装到 $NSIS_HOME（默认 /home/user/iris-release/tools/nsis）
# 依赖：curl、7z/7za/7zz 任一（解 BCJ2 需要真 7-Zip，p7zip 会报 UnsupportedCompressionMethod）
set -euo pipefail
cd "$(dirname "$0")/.."

NSIS_HOME="${NSIS_HOME:-/home/user/iris-release/tools/nsis}"
[ -x "$NSIS_HOME/linux/makensis" ] && { echo "已存在：$NSIS_HOME/linux/makensis"; exit 0; }

SEVEN=$(command -v 7zz || command -v 7z || command -v 7za || true)
[ -n "$SEVEN" ] || { echo "缺少 7-Zip：装一个 7zz/7z 再来（p7zip 解不了 BCJ2 过滤）" >&2; exit 1; }

VER=3.0.4.2
URL="https://registry.npmmirror.com/-/binary/electron-builder-binaries/nsis-${VER}/nsis-${VER}.7z"
PKG=/tmp/nsis-${VER}.7z
echo "    下载 $URL"
curl -sL --retry 3 -o "$PKG" "$URL"
SZ=$(stat -c%s "$PKG")
[ "$SZ" -ge 1200000 ] || { echo "下载不完整（$SZ 字节），重试" >&2; exit 1; }
echo "    $SZ 字节，解压到 $NSIS_HOME"
mkdir -p "$NSIS_HOME" && "$SEVEN" x -y -o"$NSIS_HOME" "$PKG" >/dev/null
chmod +x "$NSIS_HOME/linux/makensis"
"$NSIS_HOME/linux/makensis" -version | sed 's/^/    makensis /'
