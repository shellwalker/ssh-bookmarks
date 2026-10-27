#!/usr/bin/env bash
# 用 SwiftPM 构建 release 二进制，并组装成 build/SSH Bookmarks.app。
#
# 环境变量（均可选）：
#   VERSION        CFBundleShortVersionString，默认取 git tag（去掉前缀 v），否则用 Info.plist 中的值
#   BUILD_NUMBER   CFBundleVersion，默认 git 提交数
#   ARCH           arm64（默认）| x86_64 | universal
#   SIGN_IDENTITY  codesign 身份（如 "Developer ID Application: ..."）；为空则 ad-hoc 签名
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SSH Bookmarks"
PRODUCT="SSHBookmarks"
ARCH="${ARCH:-arm64}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
PLIST_BUDDY=/usr/libexec/PlistBuddy

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: build_app.sh must run on macOS" >&2
  exit 1
fi

case "$ARCH" in
  arm64 | x86_64) ARCH_FLAGS=(--arch "$ARCH") ;;
  universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
  *)
    echo "error: unsupported ARCH=$ARCH" >&2
    exit 1
    ;;
esac

echo "==> swift build (release, $ARCH)"
swift build -c release --product "$PRODUCT" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --product "$PRODUCT" "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
for lproj in "$ROOT"/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  "$PLIST_BUDDY" -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" || true
fi

# 版本号
if [[ -z "${VERSION:-}" ]]; then
  if TAG="$(git describe --tags --exact-match 2>/dev/null)"; then
    VERSION="${TAG#v}"
  else
    VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
  fi
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
for strings in "$APP"/Contents/Resources/*.lproj/*.strings; do
  plutil -lint "$strings"
done

echo "==> codesign"
ENTITLEMENTS="$ROOT/Resources/SSHBookmarks.entitlements"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
else
  echo "    SIGN_IDENTITY not set, using ad-hoc signature"
  codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "$VERSION" > "$BUILD_DIR/VERSION"
echo "==> built $APP (version $VERSION, build $BUILD_NUMBER)"
