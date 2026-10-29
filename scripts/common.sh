# Shared by install.sh, uninstall.sh and switch-from-notchy.sh; sourced, not run.

DEST="$HOME/Library/Application Support/DynamicNotch"
SETTINGS="$HOME/.claude/settings.json"
BACKUPS="$DEST/backups"
LABEL=local.dynamicnotch

# Copies ~/.claude/settings.json into backups/ before a script changes it. The first copy
# is kept for good as settings.json.original: your settings before Dynamic Notch touched
# them (taken from the oldest timestamped copy when an earlier version left some). Of the
# timestamped copies, the newest 10 stay and older ones go to the Trash.
backup_settings() {
    mkdir -p "$BACKUPS"
    if [ ! -e "$BACKUPS/settings.json.original" ]; then
        first=$(ls "$BACKUPS"/settings.json.[0-9]* 2>/dev/null | head -n 1)
        cp -p "${first:-$SETTINGS}" "$BACKUPS/settings.json.original"
    fi
    cp "$SETTINGS" "$BACKUPS/settings.json.$(date +%Y%m%d-%H%M%S)"
    # The names sort by time; the glob never matches the permanent copies.
    ls "$BACKUPS"/settings.json.[0-9]* | sort -r | tail -n +11 | while read -r f; do
        /usr/bin/trash "$f" || true
    done
}

# Quitting Dynamic Notch hangs up the shells in its terminal tabs and their running
# commands, which can be this script. So this ignores the hangup, and inside a Dynamic
# Notch tab sends the output from here on to $DEST/$1, as the tab closes; fd 3 stays on
# the tab for say_in_tab.
detach_from_notch() {
    trap '' HUP INT TERM PIPE
    [ "${TERM_PROGRAM:-}" = DynamicNotch ] || return 0
    mkdir -p "$DEST"
    DN_LOG="$DEST/$1"
    echo "Dynamic Notch asks before quitting, because this tab is running a command: choose Quit, and this tab closes. The rest is logged to $DN_LOG"
    exec 3>&2 </dev/null >>"$DN_LOG" 2>&1
    echo "--- $(date)"
}

# A message for you: on stderr, and also on the tab when detach_from_notch moved the
# output to a log (the tab is still open when the quit was cancelled).
say_in_tab() {
    echo "$*" >&2
    if [ -n "${DN_LOG:-}" ]; then echo "$*" >&3 || true; fi
}

# Asks a running copy to quit the normal way, so open terminal tabs can ask first and
# every feature saves its data, then waits up to 60 s for it to exit. Returns 0 once it
# is gone (or wasn't running), 1 when it is still running (the quit was cancelled), and
# 2 when it can't be asked (no bridge token or socket).
quit_app() {
    pgrep -x DynamicNotch >/dev/null 2>&1 || return 0
    token=$(cat "$DEST/bridge.token" 2>/dev/null || true)
    if [ -z "$token" ] || [ ! -S "$DEST/bridge.sock" ]; then return 2; fi
    printf '{"type":"app","token":"%s","command":"quit"}\n' "$token" | /usr/bin/nc -U -w 2 "$DEST/bridge.sock" >/dev/null 2>&1 || true
    i=0
    while pgrep -x DynamicNotch >/dev/null 2>&1 && [ $i -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
    if pgrep -x DynamicNotch >/dev/null 2>&1; then return 1; fi
}
