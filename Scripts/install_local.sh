#!/usr/bin/env bash
# Local-build install: skip GitHub Actions / release cycle. ~5 min cold, ~1 min warm.
#
# What this does:
#   1. Single-arch release build for the host machine (no x86_64 if you're on arm64)
#   2. Keep .build/ so SPM does an incremental compile
#   3. Stop any running CodexBar
#   4. Replace /Applications/CodexBar.app and strip quarantine
#   5. Relaunch
#
# Designed for the daily edit→try loop. For shipping a real release, push a
# v* tag and let .github/workflows/my-release.yml build universal + publish.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

HOST_ARCH=$(uname -m)
export ARCHES="${ARCHES:-$HOST_ARCH}"
# Match the release workflow: ad-hoc signing, no Apple Developer ID required.
# (Upstream's package_app.sh defaults to "Developer ID Application: Peter
# Steinberger" which only exists on his machine. Override per env if you have
# your own signing identity.)
export CODEXBAR_SIGNING="${CODEXBAR_SIGNING:-adhoc}"
unset CODEXBAR_FORCE_CLEAN

echo "==> Building (arch=$ARCHES, incremental, signing=$CODEXBAR_SIGNING)"
./Scripts/package_app.sh release

APP_SRC="$ROOT/CodexBar.app"
APP_DST="/Applications/CodexBar.app"

if [[ ! -d "$APP_SRC" ]]; then
  echo "ERROR: build did not produce $APP_SRC" >&2
  exit 1
fi

echo "==> Stopping running CodexBar (if any)"
osascript -e 'quit app "CodexBar"' >/dev/null 2>&1 || true
pkill -x CodexBar 2>/dev/null || true
pkill -f "CodexBar.app/Contents/MacOS" 2>/dev/null || true
# Give the menu bar process time to release file handles before we overwrite.
for _ in 1 2 3 4 5; do
  if pgrep -f "CodexBar.app/Contents/MacOS" >/dev/null 2>&1; then
    sleep 0.5
  else
    break
  fi
done

echo "==> Installing to $APP_DST"
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

echo "==> Launching"
open "$APP_DST"
sleep 1
if pgrep -f "CodexBar.app/Contents/MacOS" >/dev/null 2>&1; then
  echo "==> Done. CodexBar is running."
else
  echo "WARN: CodexBar process not detected after open; check Console.app." >&2
  exit 1
fi
