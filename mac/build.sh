#!/usr/bin/env bash
# 生成 Mac 版：dist/一键多开无痕浏览器.app 和 dist/一键多开无痕浏览器-v<版本>.dmg
# 需要：macOS + Xcode（或 Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
NAME="一键多开无痕浏览器"
DIST="$ROOT/dist"
APP="$DIST/$NAME.app"
# 最低支持 macOS 13；同时编译 Apple 芯片(arm64)和 Intel(x86_64)，合成通用版。
# 不写 -target 的话会按编译机的系统版本编译，旧系统就打不开。
MIN_MACOS=13.0

mkdir -p "$DIST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMPB="$(mktemp -d)"
trap 'rm -rf "$TMPB"' EXIT
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$ARCH-apple-macos$MIN_MACOS" main.swift -o "$TMPB/$ARCH"
done
lipo -create "$TMPB/arm64" "$TMPB/x86_64" -output "$APP/Contents/MacOS/WuhenDuokai"
# 图标：Assets.car 给新版 macOS（26 起），AppIcon.icns 给旧版；都由 assets/make_icons.sh 生成
cp AppIcon.icns Assets.car "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.wuhen.duokai</string>
  <key>CFBundleExecutable</key><string>WuhenDuokai</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string><string>x86_64</string></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# 本机自签（ad-hoc）。没有 Apple 开发者证书时，别人第一次打开需要「右键 → 打开」。
codesign --force --deep -s - "$APP"
codesign --verify --deep "$APP"

# DMG：打开后把 app 拖进「应用程序」
DMG="$DIST/$NAME-v$VERSION.dmg"
STAGE="$TMPB/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✅ $APP"
echo "✅ $DMG"
