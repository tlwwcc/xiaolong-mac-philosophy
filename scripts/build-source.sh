#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "This project requires macOS." >&2; exit 1; }
swift package resolve --only-use-versions-from-resolved-file
for product in aixlg-hotkeys aixlg-network-speed-status aixlg-sleep-status; do
  swift build --configuration debug --only-use-versions-from-resolved-file --product "$product"
done
echo "SOURCE_BUILD_PASS: main App, helpers, Youmu, Pijuan and Tinglan compiled; no App installed or launched."
