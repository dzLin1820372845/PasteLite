#!/bin/bash
# 从 PasteLite.svg 重新生成应用图标 AppIcon.icns（改 logo 后跑一次即可）
# 依赖系统自带工具：qlmanage(SVG 光栅化) + sips(缩放) + iconutil(打包 icns)
set -euo pipefail
cd "$(dirname "$0")"

SRC="PasteLite.svg"
SET="AppIcon.iconset"
OUT="AppIcon.icns"

rm -rf "$SET" "$OUT" render
mkdir -p render "$SET"

# 光栅化 1024×1024 母版（保留 SVG 的透明通道与滤镜投影）
qlmanage -t -s 1024 -o render "$SRC" >/dev/null
MASTER="render/${SRC}.png"

gen() { sips -z "$2" "$2" "$MASTER" --out "$SET/icon_$1.png" >/dev/null; }
gen 16x16 16;    gen 16x16@2x 32
gen 32x32 32;    gen 32x32@2x 64
gen 128x128 128; gen 128x128@2x 256
gen 256x256 256; gen 256x256@2x 512
gen 512x512 512; gen 512x512@2x 1024

iconutil -c icns "$SET" -o "$OUT"
rm -rf render
echo "已生成 ${OUT}（源: ${SRC}，含 $(ls "$SET" | wc -l | tr -d ' ') 档尺寸）"
