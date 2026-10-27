#!/usr/bin/env bash
# 公证 dist/ 下的 zip 并给 build/SSH Bookmarks.app 盖章，然后重新打包。
# 需要 Developer ID 签名；需要环境变量 APPLE_ID、APPLE_TEAM_ID、APPLE_APP_PASSWORD（App 专用密码）。
# 任一缺失则跳过（不报错），方便在没有证书时运行 CI。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "notarize: credentials not set, skipping"
  exit 0
fi

ZIPS=(dist/*.zip)
ZIP="${ZIPS[0]}"
if [[ ! -f "$ZIP" ]]; then
  echo "error: no zip in dist/, run Scripts/package.sh first" >&2
  exit 1
fi
echo "==> notarizing $ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait
xcrun stapler staple "build/SSH Bookmarks.app"
xcrun stapler validate "build/SSH Bookmarks.app"

# 盖章后重新打 zip，让离线首次打开也能通过 Gatekeeper。
"$ROOT/Scripts/package.sh"
