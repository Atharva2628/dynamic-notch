#!/bin/sh
# Removes Dynamic Notch's Claude Code hooks (settings backed up first), the `notch` link
# and the login item, then quits the app the normal way (open terminal tabs ask first,
# and every feature saves its data) and moves it to the Trash.
# Keeps settings, data and backups in ~/Library/Application Support/DynamicNotch.
# Safe to run from a Dynamic Notch terminal tab: quitting closes that tab, and the rest
# of the output goes to uninstall.log.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/common.sh"
APP="$DEST/DynamicNotch.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$SETTINGS" ] && grep -q "DynamicNotch/notch-hook.sh" "$SETTINGS"; then
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    /usr/bin/jq -f "$HERE/scripts/hooks-remove.jq" "$SETTINGS" > "$TMP"
    /usr/bin/jq -e . "$TMP" >/dev/null
    backup_settings
    cat "$TMP" > "$SETTINGS"
    echo "Hooks removed from $SETTINGS (backup in $BACKUPS)"
fi

if [ -L "$HOME/.local/bin/notch" ]; then /usr/bin/trash "$HOME/.local/bin/notch"; fi
# Without the plist nothing starts the app at login again, and a clean quit (exit 0)
# isn't restarted: KeepAlive only covers crashes.
if [ -f "$PLIST" ]; then /usr/bin/trash "$PLIST"; fi

if pgrep -x DynamicNotch >/dev/null 2>&1; then
    echo "Quitting Dynamic Notch."
    detach_from_notch uninstall.log
    rc=0
    quit_app || rc=$?
    if [ $rc = 1 ]; then
        say_in_tab "Dynamic Notch is still running (quit was cancelled). Its hooks, the notch command and the login item are removed; quit it from its menu bar icon, then run this again to move the app to the Trash."
        exit 1
    fi
    # No bridge to ask through: stop it the hard way.
    if [ $rc = 2 ]; then pkill -x DynamicNotch 2>/dev/null || true; fi
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
i=0
while pgrep -x DynamicNotch >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

if [ -d "$APP" ]; then /usr/bin/trash "$APP"; fi
echo "Removed. Settings, data and backups are still in $DEST"
