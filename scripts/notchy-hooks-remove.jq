# Removes Notchy's Claude Code hooks (its agent-hook.sh) from a settings object, for the
# day Dynamic Notch takes over. Other hooks are left exactly as they are; a group or
# event list is removed only when dropping Notchy's entries empties it.
#   jq -f notchy-hooks-remove.jq settings.json

def notchy: type == "object" and ((.command // "") | tostring | contains("Notchy/agent-hook.sh"));

# A group's hook entries; nothing for anything malformed, which is then left alone.
def entries: if type == "object" and (.hooks | type) == "array" then .hooks[] else empty end;

def strip: map(if any(entries; notchy) then (.hooks |= map(select(notchy | not))) | select(.hooks | length > 0) else . end);

def touched: type == "array" and any(.[]; any(entries; notchy));

if (.hooks | type) == "object" and any(.hooks[]; touched) then
    .hooks |= with_entries(if .value | touched then (.value |= strip) | select(.value | length > 0) else . end)
    | if .hooks == {} then del(.hooks) else . end
else . end
