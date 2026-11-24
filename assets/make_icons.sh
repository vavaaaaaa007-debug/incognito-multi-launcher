#!/usr/bin/env bash
# 由 assets/icon.svg 生成：
#   mac/AppIcon.icns  旧版 macOS（13–15）用的图标
#   mac/Assets.car    新版 macOS（26 起）用的图标；没有它，系统会把图标放进一个白框里
#   win/app.ico       Windows 图标
# 只在改了图标设计时才需要运行（需要 macOS + Xcode）；生成的文件已经放在仓库里，打包时直接用。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

qlmanage -t -s 1024 -o "$T" icon.svg >/dev/null 2>&1
PNG="$T/icon.svg.png"
[ -f "$PNG" ] || { echo "SVG 渲染失败"; exit 1; }

# Mac：保留四周留白（符合 macOS 图标网格）
SET="$T/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$PNG" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$PNG" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/mac/AppIcon.icns"

# 新版 macOS：Icon Composer 格式（.icon），图层是满版（无留白、无圆角）的图，圆角和玻璃效果由系统加。
# 用 actool 编译成 Assets.car。
sed -e 's/viewBox="0 0 1024 1024"/viewBox="100 100 824 824"/' -e 's/rx="185"/rx="0"/' icon.svg > "$T/full.svg"
qlmanage -t -s 1024 -o "$T" "$T/full.svg" >/dev/null 2>&1
mkdir -p "$T/AppIcon.icon/Assets" "$T/car"
cp "$T/full.svg.png" "$T/AppIcon.icon/Assets/fg.png"
cat > "$T/AppIcon.icon/icon.json" <<'JSON'
{
  "groups" : [ { "layers" : [ { "image-name" : "fg.png", "name" : "fg" } ] } ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON
xcrun actool "$T/AppIcon.icon" --compile "$T/car" --platform macosx --minimum-deployment-target 13.0 \
  --app-icon AppIcon --output-partial-info-plist "$T/car/partial.plist" >/dev/null
cp "$T/car/Assets.car" "$ROOT/mac/Assets.car"

# Windows：去掉大部分留白，图标填满格子（Windows 图标的习惯）
sips --cropToHeightWidth 848 848 "$PNG" --out "$T/win.png" >/dev/null
for s in 16 20 24 32 40 48 64 128 256; do sips -z $s $s "$T/win.png" --out "$T/w$s.png" >/dev/null; done
python3 -I - "$ROOT/win/app.ico" "$T" <<'EOF'
import struct, sys, pathlib
out, d = sys.argv[1], pathlib.Path(sys.argv[2])
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
imgs = [(d / f"w{s}.png").read_bytes() for s in sizes]
# ICO 文件：文件头 + 每个尺寸一条目录 + PNG 数据（Windows Vista 起支持 PNG 格式的图标）
head = struct.pack("<HHH", 0, 1, len(sizes))
off = 6 + 16 * len(sizes)
dirs, data = b"", b""
for s, img in zip(sizes, imgs):
    dirs += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(img), off + len(data))
    data += img
pathlib.Path(out).write_bytes(head + dirs + data)
EOF
echo "✅ $ROOT/mac/AppIcon.icns"
echo "✅ $ROOT/mac/Assets.car"
echo "✅ $ROOT/win/app.ico"
