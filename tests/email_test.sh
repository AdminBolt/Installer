#!/usr/bin/env bash
#
# Tests for --email in install.sh (AB-2211): the address is checked before
# anything is installed and reaches bolt-cli as one argument, never as shell
# code. No network, no root: bolt-cli is a fake on PATH that records its
# arguments, Stage 1 is replaced by a stub, and install.sh is loaded with
# ADMINBOLT_INSTALL_SOURCE_ONLY=1.
#
# Needs bash 4+.
#   Linux:  bash tests/email_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/email_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
INSTALL_SH=$(cd "$(dirname "$INSTALL_SH")" && pwd)/$(basename "$INSTALL_SH")

if ((BASH_VERSINFO[0] < 4)); then echo "bash 4 or newer required (this is $BASH_VERSION)" >&2; exit 2; fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export LC_ALL=C

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else nok "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }

# Fake bolt-cli: one argument per line in $FAKE_DIR/args, exit code from $FAKE_DIR/rc.
mkdir -p "$T/bin"
cat >"$T/bin/bolt-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_DIR/args"
exit "$(cat "$FAKE_DIR/rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/bolt-cli"

# $1 name, $2 the address (written to a file, so no quoting of it here),
# $3 code to run after install.sh is loaded. The child runs in its own
# directory: a payload that writes "pwned" lands there.
child() {
    D="$T/$1"
    rm -rf "$D"
    mkdir -p "$D/fake"
    printf '%s' "$2" >"$D/email.arg"
    cat >"$D/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
REPORT_DIR="$D/spool"
REPORT_UNIT_DIR="$D/units"
REPORT_SENDER="$D/libexec/send"
REPORT_MARKER="$D/install-marker"
REPORT_EUID=0
EMAIL=\$(cat "$D/email.arg")
$3
EOF
    (cd "$D" && FAKE_DIR="$D/fake" PATH="$T/bin:$PATH" "$BASH" child.sh >"$D/out" 2>&1)
    RC=$?
}
args() { paste -sd'|' "$D/fake/args" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "# --email checked before anything is installed"
# ---------------------------------------------------------------------------
parse() { # $1 name, $2 address: runs the real main up to the Stage 1 stub
    child "$1" "$2" 'stage_prerequisites() { echo REACHED-STAGE1; exit 0; }
main --no-telemetry "--email=$EMAIL"'
}
refused() { # $1 label, $2 address
    parse refused "$2"
    eq "$1: refused, exit 1, install not started" "1 yes no" \
        "$RC $(grep -q 'Invalid --email' "$D/out" && echo yes || echo no) $(grep -q REACHED-STAGE1 "$D/out" && echo yes || echo no)"
    check "$1: nothing executed" test ! -e "$D/pwned"
    check "$1: bolt-cli not called" test ! -e "$D/fake/args"
    check "$1: no install marker" test ! -e "$D/install-marker"
}
refused '$(...)' 'x$(touch${IFS}pwned)@a.b'
refused 'backticks' 'x`touch${IFS}pwned`@a.b'
refused ';' 'a@b.com;touch${IFS}pwned'
refused 'bare $' 'a$b@example.com'
refused 'double quote' 'a"b@example.com'
refused 'space' 'a b@example.com'
refused 'tab' $'a\tb@example.com'
refused 'newline' $'a@example.com\ntouch pwned'
refused 'control character' $'a\x01b@example.com'
refused 'second @' 'a@b@example.com'
parse shown $'x$(id)\e[31m@a.b'
check "refusal says what is not allowed" grep -qF 'expected name@domain.tld; no spaces, ", $, `, ; or control characters' "$D/out"
check "refusal shows the value with control characters as '?'" grep -qF 'Invalid --email=x$(id)?[31m@a.b ' "$D/out"

accepted() { # $1 label, $2 address
    parse accepted "$2"
    eq "$1: accepted, install goes on" "0 no yes" \
        "$RC $(grep -q 'Invalid --email' "$D/out" && echo yes || echo no) $(grep -q REACHED-STAGE1 "$D/out" && echo yes || echo no)"
}
accepted 'plain address' 'first.last+tag@mail-1.example.co.uk'
accepted 'apostrophe' "o'brien@example.com"
accepted '& | and the other RFC characters' 'a!#%&*/=?^_{|}~-z@example.com'

# ---------------------------------------------------------------------------
echo "# trial request: the address is one argument to bolt-cli, no eval"
# ---------------------------------------------------------------------------
# ADMIN_EMAIL is set directly, past the check: even an address the check
# would refuse must not run as code here.
trial() { # $1 name, $2 address
    child "$1" "$2" 'set -e
eval "orig_$(declare -f run_or_warn)"
run_or_warn() { echo USED-RUN-OR-WARN; orig_run_or_warn "$@"; }
ADMIN_EMAIL=$EMAIL
TRIAL_LICENCE_OK=0
request_trial_licence
echo "ok=$TRIAL_LICENCE_OK"'
}
for addr in 'first.last+tag@mail-1.example.co.uk' "o'brien@example.com" 'x$(touch${IFS}pwned)@a.b' 'x`touch${IFS}pwned`@a.b' 'a;touch${IFS}pwned@a.b' "x'\$(touch\${IFS}pwned)'\"@a.b" 'a|touch${IFS}pwned&@a.b'; do
    trial trial "$addr"
    eq "$addr: bolt-cli gets it unchanged as one argument" "request-trial-license|--email=$addr" "$(args)"
    check "$addr: nothing executed" test ! -e "$D/pwned"
    eq "$addr: exactly two arguments" 2 "$(wc -l <"$D/fake/args" | tr -d " ")"
    check "$addr: not run through run_or_warn (eval)" bash -c '! grep -q USED-RUN-OR-WARN "$1"' _ "$D/out"
    check "$addr: TRIAL_LICENCE_OK=1, completed" grep -q 'ok=1' "$D/out"
done
trial trial_out 'a@example.com'
check "same messages as before: step name and completed" bash -c 'grep -q "INFO:.*Request trial licence$" "$1" && grep -q "SUCCESS:.*Request trial licence completed" "$1"' _ "$D/out"
child trial_refused 'a@example.com' 'set -e
ADMIN_EMAIL=$EMAIL
TRIAL_LICENCE_OK=0
echo 1 >"$FAKE_DIR/rc"
request_trial_licence
echo "ok=$TRIAL_LICENCE_OK after"'
eq "refused request: warning, TRIAL_LICENCE_OK=0, the script goes on under set -e" "0 yes yes" \
    "$RC $(grep -q 'WARNING:.*Request trial licence failed (continuing)' "$D/out" && echo yes || echo no) $(grep -q 'ok=0 after' "$D/out" && echo yes || echo no)"

echo
echo "# passed: $PASS, failed: $FAIL"
((FAIL == 0))
