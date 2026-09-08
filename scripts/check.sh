#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --find xcodebuild >/dev/null || { echo "Full Xcode is required to run XCTest; build-source.sh can compile with compatible Command Line Tools." >&2; exit 1; }
"$ROOT/scripts/build-source.sh"
swift test --package-path "$ROOT" --only-use-versions-from-resolved-file
swift test --package-path "$ROOT/Platform"
echo "SOURCE_CHECK_PASS: compiled products and independent tests; no installed-app claim."
