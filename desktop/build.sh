#!/usr/bin/env bash
# Iris 调色盘 · 三端构建（Linux 上可一次性产出 Windows / Linux / macOS 目录与发布包）
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d node_modules ]; then
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
    npm install --no-audit --no-fund
fi

# 运行时缓存（缺失才下载）
mkdir -p .cache
for t in win32-x64 linux-x64 darwin-arm64; do
  f=".cache/electron-$t.zip"
  [ -f "$f" ] || curl -sL -o "$f" "https://npmmirror.com/mirrors/electron/31.7.7/electron-v31.7.7-$t.zip"
done

node scripts/build.js all
python3 scripts/pack_release.py
echo "完成：release/"
