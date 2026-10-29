#!/bin/sh
# Installs Dynamic Notch:
#   1. builds the app into ~/Library/Application Support/DynamicNotch
#   2. adds its Claude Code hooks to ~/.claude/settings.json (backed up first, only when
#      that changes the file; Notchy's and Agent Away's hooks are left alone;
#      scripts/switch-from-notchy.sh removes Notchy's later)
#   3. links the `notch` command into ~/.local/bin
#   4. adds a login item (LaunchAgent) and (re)starts the app
# Re-running is safe: it replaces its own entries. Undo with uninstall.sh.
# --no-hooks skips step 2.
# Safe to run from a Dynamic Notch terminal tab: the restart closes that tab, and the
# rest of the output goes to install.log.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/common.sh"
APP="$DEST/DynamicNotch.app"
HOOK="$DEST/notch-hook.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOOKS=1
for arg in "$@"; do
    case "$arg" in
        --no-hooks) HOOKS=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

DN_FROM_INSTALL=1 sh "$HERE/scripts/build.sh"

# --- hooks -------------------------------------------------------------------
install -m 0755 "$HERE/hooks/notch-hook.sh" "$HOOK"
if [ "$HOOKS" = 1 ]; then
    mkdir -p "$HOME/.claude"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    /usr/bin/jq --arg cmd "/bin/sh \"$HOOK\"" -f "$HERE/scripts/hooks.jq" "$SETTINGS" > "$TMP"
    /usr/bin/jq -e . "$TMP" >/dev/null   # never write broken JSON
    # A rebuild usually changes nothing here: then no backup and no write.
    if /usr/bin/jq -e --slurpfile old "$SETTINGS" '. == $old[0]' "$TMP" >/dev/null; then
        echo "Hooks already in $SETTINGS"
    else
        backup_settings
        cat "$TMP" > "$SETTINGS"         # keep the file's inode and permissions
        echo "Hooks added to $SETTINGS (backup in $BACKUPS)"
    fi
fi

# --- notch command -------------------------------------------------------------
mkdir -p "$DEST/bin" "$HOME/.local/bin"
install -m 0755 "$HERE/bin/notch" "$DEST/bin/notch"
ln -sf "$DEST/bin/notch" "$HOME/.local/bin/notch"
echo "Linked ~/.local/bin/notch"

# --- login item ----------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/DynamicNotch</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

# Ask a running copy to quit the normal way, so open terminal sessions can ask first.
# If you cancel that, nothing is restarted.
if pgrep -x DynamicNotch >/dev/null 2>&1; then
    echo "Restarting Dynamic Notch."
    detach_from_notch install.log
    rc=0
    quit_app || rc=$?
    if [ $rc = 1 ]; then
        say_in_tab "Dynamic Notch is still running (quit was cancelled). The new build is in place; run this again to restart."
        exit 1
    fi
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x DynamicNotch 2>/dev/null || true
i=0
while pgrep -x DynamicNotch >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Login item installed and started ($LABEL)."
