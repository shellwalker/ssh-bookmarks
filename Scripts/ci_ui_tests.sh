#!/usr/bin/env bash
# 构建 .app，生成 UI 测试工程，跑 XCUITest。截图写到 build/ui-screenshots。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> installing XcodeGen 2.42.0"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/xcodegen.zip" \
    https://github.com/yonaskolb/XcodeGen/releases/download/2.42.0/xcodegen.zip
  unzip -q "$TMP/xcodegen.zip" -d "$TMP"
  BIN="$(find "$TMP" -type f -name xcodegen | head -n 1)"
  if [[ -z "$BIN" ]]; then
    echo "xcodegen binary not found in the release archive" >&2
    exit 1
  fi
  install_dir="/usr/local"
  sudo mkdir -p "$install_dir/bin" "$install_dir/share"
  sudo cp "$BIN" "$install_dir/bin/xcodegen"
  sudo chmod 755 "$install_dir/bin/xcodegen"
  share="$(find "$TMP" -type d -name xcodegen -path '*/share/*' | head -n 1 || true)"
  if [[ -n "$share" ]]; then
    sudo rm -rf "$install_dir/share/xcodegen"
    sudo cp -R "$share" "$install_dir/share/xcodegen"
  fi
fi

echo "==> build app"
ARCH="${ARCH:-arm64}" Scripts/build_app.sh

rm -rf "$ROOT/build/ui-screenshots" "$ROOT/build/ui-results.xcresult" "$ROOT/build/ui-derived" \
  "$ROOT/MenuSSHUI.xcodeproj"
mkdir -p "$ROOT/build/ui-screenshots"

echo "==> generate Xcode project"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

echo "==> XCUITest"
export MENUSH_SCREENSHOT_DIR="$ROOT/build/ui-screenshots"
set +e
xcodebuild test \
  -project "$ROOT/MenuSSHUI.xcodeproj" \
  -scheme MenuSSHUI \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT/build/ui-derived" \
  -resultBundlePath "$ROOT/build/ui-results.xcresult" \
  CODE_SIGNING_ALLOWED=NO
status=$?
set -e
exit "$status"
