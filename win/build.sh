#!/usr/bin/env bash
# 生成 Windows 版（图标已编进 exe）：dist/一键多开无痕浏览器-v<版本>-安装包.exe 和 dist/一键多开无痕浏览器-v<版本>-Windows免安装版.zip
# 在 macOS 或 Linux 上交叉编译，不需要 Windows。需要：Go、NSIS(makensis)、mingw-w64(windres)、python3
#   macOS: brew install go makensis      Ubuntu: sudo apt-get install -y nsis（Go 另装）
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
NAME="一键多开无痕浏览器"
DIST="$ROOT/dist"
mkdir -p "$DIST"
[ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH"
# makensis 读中文脚本需要 UTF-8 语言环境（macOS 用 en_US.UTF-8，Linux 用 C.UTF-8）
if [ "$(uname)" = Darwin ]; then export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8; else export LC_ALL=C.UTF-8 LANG=C.UTF-8; fi

# 图标和系统清单编进 exe：windres 把 app.rc 编成 .syso，go build 自动链接
#   macOS: brew install mingw-w64      Ubuntu: sudo apt-get install -y binutils-mingw-w64-x86-64
WINDRES="$(command -v x86_64-w64-mingw32-windres || true)"
[ -n "$WINDRES" ] || { echo "缺少 x86_64-w64-mingw32-windres，请先安装 mingw-w64"; exit 1; }
"$WINDRES" -O coff -F pe-x86-64 -i app.rc -o rsrc_windows_amd64.syso
trap 'rm -f WuhenDuokai.exe rsrc_windows_amd64.syso' EXIT
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-H windowsgui -s -w" -o WuhenDuokai.exe .

makensis -INPUTCHARSET UTF8 -V2 -DVERSION="$VERSION" installer.nsi

# 免安装版 zip（用 python 写，保证中文文件名在 Windows 上不乱码）
ZIP="$DIST/$NAME-v$VERSION-Windows免安装版.zip"
rm -f "$ZIP"
python3 -I - "$ZIP" "$NAME" WuhenDuokai.exe <<'EOF'
import sys, zipfile
out, folder, *files = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f, f"{folder}/{f}")
EOF
echo "✅ $DIST/$NAME-v$VERSION-安装包.exe"
echo "✅ $ZIP"
