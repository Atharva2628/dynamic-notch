#!/bin/sh
# Compiles Dynamic Notch into ~/Library/Application Support/DynamicNotch (kept out of the
# iCloud-synced Desktop so the app is never evicted). Needs only the Command Line Tools.
# All build caches go to a temp dir that is deleted afterwards.
# Signs with the "Dynamic Notch Dev" certificate when it exists, so macOS keeps granted
# permissions across rebuilds; otherwise signs ad-hoc.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/Library/Application Support/DynamicNotch"
APP="$DEST/DynamicNotch.app"
IDENTITY="Dynamic Notch Dev"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Everything SwiftPM writes (temp files, locks, caches, config) stays inside $TMP.
mkdir "$TMP/tmp"
TMPDIR="$TMP/tmp/" swift build -c release --quiet --package-path "$HERE" \
    --scratch-path "$TMP/build" --manifest-cache local \
    --cache-path "$TMP/cache" --config-path "$TMP/config" --security-path "$TMP/security"

NEW="$TMP/DynamicNotch.app"
mkdir -p "$NEW/Contents/MacOS"
cp "$TMP/build/release/DynamicNotch" "$NEW/Contents/MacOS/DynamicNotch"
cp "$HERE/src/Info.plist" "$NEW/Contents/Info.plist"

# Reads macOS's Now Playing for apps other than Spotify and Music; Apple's perl runs it
# (see src/Features/NowPlaying/NowPlayingSystem.swift).
mkdir -p "$NEW/Contents/Frameworks"
TMPDIR="$TMP/tmp/" clang -dynamiclib -fobjc-arc -O2 -Wall -mmacosx-version-min=26.0 -framework Foundation \
    -o "$NEW/Contents/Frameworks/NowPlayingHelper.dylib" "$HERE/helpers/NowPlayingHelper.m"

SIGN=-
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    SIGN=$IDENTITY
fi
/usr/bin/codesign --force --sign "$SIGN" "$NEW/Contents/Frameworks/NowPlayingHelper.dylib"
/usr/bin/codesign --force --sign "$SIGN" "$NEW"

# Swap the new build in; the old one is deleted with the temp dir.
mkdir -p "$DEST"
if [ -d "$APP" ]; then mv "$APP" "$TMP/old.app"; fi
mv "$NEW" "$APP"
printf '%s\n' "$HERE" > "$DEST/source-dir"

if [ "$SIGN" = - ]; then SIGNED=ad-hoc; else SIGNED=$SIGN; fi
echo "Built $APP ($(du -sh "$APP" | cut -f1), signed $SIGNED)"

# A copy already running keeps the old build until it restarts. install.sh restarts it.
if [ -z "${DN_FROM_INSTALL:-}" ] && pgrep -x DynamicNotch >/dev/null 2>&1; then
    echo "Note: Dynamic Notch is still running the previous build. Run scripts/install.sh, or quit it from the menu bar and open the app again."
fi
