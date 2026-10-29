#!/bin/sh
# Switch day: swaps Notchy's hook entries in ~/.claude/settings.json for Dynamic Notch's
# in one write (backed up first, and the settings from before the switch kept for good
# as settings.json.before-switch), so only Dynamic Notch answers Claude Code's permission
# requests and there is never a moment with no hooks. Adds Dynamic Notch's hooks even if
# install.sh ran with --no-hooks. Doesn't touch Notchy itself: quit it, turn off its
# launch at login, then move Notchy.app to the Trash.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/common.sh"
HOOK="$DEST/notch-hook.sh"

[ -f "$HOOK" ] || { echo "Dynamic Notch isn't installed; run scripts/install.sh first." >&2; exit 1; }
if [ ! -f "$SETTINGS" ] || ! grep -q "Notchy/agent-hook.sh" "$SETTINGS"; then
    echo "No Notchy hooks in $SETTINGS; nothing to do."
    exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# hooks.jq drops any earlier copy of ours first, so this is safe when they're already in.
/usr/bin/jq --arg cmd "/bin/sh \"$HOOK\"" -f "$HERE/scripts/hooks.jq" "$SETTINGS" > "$T/added.json"
/usr/bin/jq -f "$HERE/scripts/notchy-hooks-remove.jq" "$T/added.json" > "$T/settings.json"
/usr/bin/jq -e . "$T/settings.json" >/dev/null   # never write broken JSON
backup_settings
[ -e "$BACKUPS/settings.json.before-switch" ] || cp -p "$SETTINGS" "$BACKUPS/settings.json.before-switch"
cat "$T/settings.json" > "$SETTINGS"             # keep the file's inode and permissions
echo "Dynamic Notch now handles Claude Code's hooks; Notchy's are removed from $SETTINGS (backup in $BACKUPS)."
echo "Next: quit Notchy, turn off its launch at login, and move /Applications/Notchy.app to the Trash."
