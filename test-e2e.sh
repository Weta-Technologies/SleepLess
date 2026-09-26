#!/bin/bash
# ./test-e2e.sh [dir] — every user-facing function end to end (E2E.swift), on a throwaway copy of build/SleepLess.app:
# its own bundle id (io.github.cyborgfingers.sleepless.e2e — so the installed SleepLess, its settings, its helper, its
# login item and its notification permission are never involved), no URL-scheme registration, ad-hoc signed. Inside,
# the Mac is behind FakeHardware (Hardware.swift): no brightness, keyboard light, charging light, helper, pmset, login
# item or notification permission is ever touched, and the update feed is a stub that never downloads. The only real
# effects are the copy's own sleep assertions (gone when it exits — checked below) and its own hot key.
# Prints one row per function and exits 0 only when every row passed. The copy and its settings domain go afterwards.
set -euo pipefail
cd "$(dirname "$0")"
APP=SleepLess
ID=io.github.cyborgfingers.sleepless.e2e
[[ -n "${SKIP_BUILD:-}" ]] || ./build.sh >/dev/null
# The copy drops the URL scheme (so it never answers the real one); the build itself must still declare it.
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "build/$APP.app/Contents/Info.plist") == sleepless ]] \
  || { echo "FAIL: build/$APP.app doesn't register sleepless://"; exit 1; }
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT"
T=$(mktemp -d)
cleanup() { rm -r "$T"; defaults delete "$ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cp -R "build/$APP.app" "$T/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Delete :CFBundleURLTypes" "$T/$APP.app/Contents/Info.plist"
codesign --force --sign - --options runtime "$T/$APP.app" 2>/dev/null
"$T/$APP.app/Contents/MacOS/$APP" --e2e "$OUT" &
PID=$!
status=0
wait $PID || status=$?
sleep 1
if pmset -g assertions | grep -q "pid $PID("; then echo "FAIL: the copy left a sleep assertion behind"; status=1; else echo "ok   no sleep assertion left behind (pid $PID)"; fi
exit $status
