#!/usr/bin/env bash
# scripts/test-ios.sh
#
# Unit-tests the PortaCore Swift package, then compiles the Porta iOS app
# for the Simulator to catch regressions in the app target. Does not launch
# the Simulator UI — this is a build-and-unit-tests smoke, safe to wire
# into CI or run before a commit.
#
# Usage:
#   ./scripts/test-ios.sh               # tests + iOS Simulator build
#   BUILD_ONLY=1 ./scripts/test-ios.sh  # skip swift test, just compile

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
log()  { printf '%s %s\n' "$(_color '36' "[$(date +%H:%M:%S)]")" "$*"; }
ok()   { printf '%s %s\n' "$(_color '32' "[ ok ]")" "$*"; }
fail() { printf '%s %s\n' "$(_color '31' "[fail]")" "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "xcodebuild not installed"
command -v swift      >/dev/null || fail "swift not installed"

if [[ -z "${BUILD_ONLY:-}" ]]; then
  log "running PortaCore unit tests"
  (cd "$ROOT/ios/PortaCore" && swift test 2>&1) | tail -30
  ok "PortaCore tests passed"
fi

log "building Porta iOS app for the Simulator"
xcodebuild \
  -project "$ROOT/ios/Porta.xcodeproj" \
  -scheme Porta \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build 2>&1 | tail -20 | grep -E "error:|warning:|BUILD" || true

# xcodebuild pipes into tail+grep, so re-derive success from the exit of the
# *next* invocation — a no-op that just checks the derived data has objects.
if ! xcodebuild \
    -project "$ROOT/ios/Porta.xcodeproj" \
    -scheme Porta \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    -quiet build >/dev/null 2>&1; then
  fail "iOS build failed — re-run without -quiet for full log"
fi

ok "iOS Simulator build succeeded"
