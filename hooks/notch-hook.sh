#!/bin/sh
# Dynamic Notch hook for Claude Code. Forwards one hook event to the app over its local
# socket: the event name is $1, the hook input arrives on stdin. Registered for 9 events
# by scripts/hooks.jq.
#
# Fire-and-forget, except a PermissionRequest, which waits up to 110 s for the answer
# from the notch and prints it for Claude Code. No answer means Claude Code shows its own
# prompt. ALWAYS exits 0: the app being closed or restarting must never surface as a
# hook error in a session.
#
# Message (one line): {"type":"hook","token":T,"event":E,"pid":P,"wait":W,"payload":<stdin>}

D="$HOME/Library/Application Support/DynamicNotch"
S="$D/bridge.sock"
E=${1:-}

# Read stdin fully (closing it early can surface as a hook error), on one line: the app
# reads one line per message, and JSON has raw newlines only as whitespace.
IN=$(/usr/bin/tr '\r\n' '  ')

case $E in "" | *[!A-Za-z]*) exit 0 ;; esac
[ -S "$S" ] || exit 0
T=$(/bin/cat "$D/bridge.token" 2>/dev/null) || exit 0
case $T in "" | *[!0-9a-f]*) exit 0 ;; esac
case $IN in "{"*) ;; *) IN='{}' ;; esac

# Wait for an answer only when Notchy surely isn't running (pgrep exits 1): its own hook
# would answer too. The waiting client is Perl, not nc: nc shuts down its sending side
# when its input ends, which the app would take for Claude Code cancelling the request.
W=false
if [ "$E" = PermissionRequest ] && [ -x /usr/bin/perl ]; then
    /usr/bin/pgrep -xq Notchy
    [ $? -eq 1 ] && W=true
fi
M=$(printf '{"type":"hook","token":"%s","event":"%s","pid":%d,"wait":%s,"payload":%s}' \
    "$T" "$E" "$PPID" "$W" "$IN")

if [ $W = true ]; then
    # exec, so Claude Code cancelling the hook kills the client itself and the app sees
    # the connection close.
    exec /usr/bin/perl -e '
        use IO::Socket::UNIX;
        $SIG{PIPE} = "IGNORE";
        $SIG{$_} = sub { exit 0 } for qw(ALRM TERM INT HUP);
        alarm 110;
        eval {
            my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $ARGV[0]) or exit 0;
            my $m = do { local $/; <STDIN> };
            print $s $m;
            my $r = <$s>;
            print $r if defined $r && $r =~ /^\{/;
        };
        exit 0;
    ' "$S" <<EOF
$M
EOF
fi

printf '%s\n' "$M" | /usr/bin/nc -U -w 1 "$S" >/dev/null 2>&1
exit 0
