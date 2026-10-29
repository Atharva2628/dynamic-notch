# Adds Dynamic Notch's Claude Code hooks to a settings object: one entry per event, after
# dropping any earlier copy of ours, so running it twice changes nothing. Other hooks
# (Notchy's, Agent Away's) are left exactly as they are.
#   jq --arg cmd '/bin/sh "/path/to/notch-hook.sh"' -f hooks.jq settings.json

def ours: type == "object" and ((.command // "") | tostring | contains("DynamicNotch/notch-hook.sh"));

# A group's hook entries; nothing for anything malformed, which is then left alone.
def entries: if type == "object" and (.hooks | type) == "array" then .hooks[] else empty end;

# Drops our entries from one event's groups; a group is removed only when that empties it.
def strip: map(if any(entries; ours) then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0) else . end);

def touched: type == "array" and any(.[]; any(entries; ours));

# PostToolUseFailure too: a request answered in Claude Code's own dialog whose tool then
# fails must still leave the notch.
def events: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
             "PostToolUseFailure", "Stop", "Notification", "PermissionRequest"];

# Permission requests wait up to 110 s for an answer from the notch; the rest are instant.
def entry($event): {hooks: [{type: "command", command: "\($cmd) \($event)",
                             timeout: (if $event == "PermissionRequest" then 120 else 10 end)}]};

.hooks |= ((. // {}) | with_entries(if .value | touched then (.value |= strip) | select(.value | length > 0) else . end))
| reduce events[] as $e (.; .hooks[$e] += [entry($e)])
