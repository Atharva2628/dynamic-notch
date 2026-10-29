# Removes Dynamic Notch's Claude Code hooks from a settings object. Other hooks are left
# exactly as they are; a group or event list is removed only when dropping ours empties it.
#   jq -f hooks-remove.jq settings.json

def ours: type == "object" and ((.command // "") | tostring | contains("DynamicNotch/notch-hook.sh"));

# A group's hook entries; nothing for anything malformed, which is then left alone.
def entries: if type == "object" and (.hooks | type) == "array" then .hooks[] else empty end;

def strip: map(if any(entries; ours) then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0) else . end);

def touched: type == "array" and any(.[]; any(entries; ours));

if (.hooks | type) == "object" and any(.hooks[]; touched) then
    .hooks |= with_entries(if .value | touched then (.value |= strip) | select(.value | length > 0) else . end)
    | if .hooks == {} then del(.hooks) else . end
else . end
