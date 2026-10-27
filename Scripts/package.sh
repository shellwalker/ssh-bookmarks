#!/usr/bin/env bash
# 把 build/SSH Bookmarks.app 打包为 dist/SSH-Bookmarks-<version>-<arch>.zip（可选 DMG）。
#   ARCH        默认 arm64，只用于文件名
#   MAKE_DMG=1  额外生成 DMG（hdiutil）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="build/SSH Bookmarks.app"
ARCH="${ARCH:-arm64}"
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found, run Scripts/build_app.sh first" >&2
  exit 1
fi
VERSION="$(cat build/VERSION 2>/dev/null || echo dev)"
BASENAME="SSH-Bookmarks-${VERSION}-${ARCH}"

rm -rf dist
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/${BASENAME}.zip"

if [[ "${MAKE_DMG:-0}" == "1" ]]; then
  STAGING="$(mktemp -d)"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "SSH Bookmarks" -srcfolder "$STAGING" -ov -format UDZO "dist/${BASENAME}.dmg"
  rm -rf "$STAGING"
fi

(cd dist && shasum -a 256 ./* > SHA256SUMS.txt)
ls -lh dist
