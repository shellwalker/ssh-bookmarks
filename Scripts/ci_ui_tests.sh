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
  "$ROOT/SSHBookmarksUI.xcodeproj" /tmp/menush-ui-screenshots
mkdir -p "$ROOT/build/ui-screenshots"

echo "==> generate Xcode project"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

SCHEME="$(find "$ROOT/SSHBookmarksUI.xcodeproj" -name 'SSHBookmarksUI.xcscheme' | head -n 1)"
if [[ -z "$SCHEME" ]]; then
  echo "missing SSHBookmarksUI.xcscheme" >&2
  exit 1
fi
python3 - "$SCHEME" "$ROOT/build/ui-screenshots" <<'PY'
import re
import sys
from pathlib import Path

path, value = sys.argv[1], sys.argv[2]
text = Path(path).read_text()
text, flag_count = re.subn(
    r'(<TestAction\b[^>]*\bshouldUseLaunchSchemeArgsEnv\s*=\s*")[^"]*"',
    r'\1NO"',
    text,
    count=1,
    flags=re.S,
)
if flag_count != 1:
    raise SystemExit("scheme has no TestAction shouldUseLaunchSchemeArgsEnv")

value_pattern = re.compile(
    r'(<EnvironmentVariable\b[^>]*\bkey\s*=\s*"MENUSH_SCREENSHOT_DIR"[^>]*\bvalue\s*=\s*")[^"]*"',
    re.S,
)
text, value_count = value_pattern.subn(rf'\1{value}"', text, count=1)
if value_count != 1:
    block = (
        "      <EnvironmentVariables>\n"
        f'         <EnvironmentVariable key="MENUSH_SCREENSHOT_DIR" value="{value}" isEnabled="YES"/>\n'
        "      </EnvironmentVariables>\n"
    )
    if "<Testables>" not in text:
        raise SystemExit("scheme has no Testables")
    text = text.replace("<Testables>", block + "      <Testables>", 1)
if "MENUSH_SCREENSHOT_DIR" not in text or value not in text:
    raise SystemExit("could not set MENUSH_SCREENSHOT_DIR in the scheme")
Path(path).write_text(text)
print("screenshot directory:", value)
PY

echo "==> XCUITest"
export MENUSH_SCREENSHOT_DIR="$ROOT/build/ui-screenshots"
set +e
xcodebuild test \
  -project "$ROOT/SSHBookmarksUI.xcodeproj" \
  -scheme SSHBookmarksUI \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT/build/ui-derived" \
  -resultBundlePath "$ROOT/build/ui-results.xcresult" \
  CODE_SIGNING_ALLOWED=NO
status=$?
set -e
if [[ -d /tmp/menush-ui-screenshots ]]; then
  cp -R /tmp/menush-ui-screenshots/. "$ROOT/build/ui-screenshots/"
fi
exit "$status"
