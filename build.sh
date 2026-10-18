#!/bin/bash
# 构建 PasteLite Universal Release：SwiftPM release → .app → ad-hoc 签名 → DMG。
set -euo pipefail

cd "$(dirname "$0")"

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "错误: 未找到 /Applications/Xcode.app，工具链不可用" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUILD_ROOT=".build/release-universal"
APP="build/PasteLite.app"
DIST="dist"
DMG_NAME="PasteLite-${VERSION}-macOS-universal.dmg"

rm -rf "$BUILD_ROOT" "$APP" "$DIST"
mkdir -p "$BUILD_ROOT" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

build_arch() {
  local arch="$1"
  local scratch="$BUILD_ROOT/$arch"
  swift build \
    -c release \
    --triple "${arch}-apple-macosx13.0" \
    --scratch-path "$scratch"

  find "$scratch" -type f -path '*/Products/Release/PasteLite' -print -quit
}

ARM64_BINARY=$(build_arch arm64 | tail -n 1)
X86_64_BINARY=$(build_arch x86_64 | tail -n 1)

if [ ! -f "$ARM64_BINARY" ] || [ ! -f "$X86_64_BINARY" ]; then
  echo "错误: Universal 构建未找到两个架构的 Release 二进制" >&2
  exit 1
fi

lipo "$ARM64_BINARY" "$X86_64_BINARY" -create -output "$APP/Contents/MacOS/PasteLite"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Branding/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Branding/PasteLiteTemplate.png "$APP/Contents/Resources/PasteLiteTemplate.png"
codesign --force --sign - "$APP"

DMG_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/pastelite-dmg.XXXXXX")
trap 'rm -rf "$DMG_STAGING"' EXIT
cp -R "$APP" "$DMG_STAGING/PasteLite.app"
cp docs/安装说明.txt "$DMG_STAGING/安装说明.txt"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -volname "PasteLite ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DIST/$DMG_NAME"

echo "构建完成: $APP"
echo "安装包完成: $DIST/$DMG_NAME"
