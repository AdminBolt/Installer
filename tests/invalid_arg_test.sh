#!/usr/bin/env bash
#
# Tests for invalid --source, --mariadb-version and --email values in
# install.sh (AB-2282): the value in the error message is cut to 40
# characters, anything unprintable is shown as "?", and escape sequences -
# raw or typed as text like \e[31m - are never interpreted. No network, no
# root: Stage 1 is replaced by a stub and install.sh is loaded with
# ADMINBOLT_INSTALL_SOURCE_ONLY=1.
#
# Needs bash 4+.
#   Linux:  bash tests/invalid_arg_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/invalid_arg_test.sh
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

# $1 flag name, $2 its value (written to a file, so no quoting of it here).
# Runs the real main up to the Stage 1 stub; stderr goes to $D/err.
run_flag() {
    D="$T/$1"
    rm -rf "$D"
    mkdir -p "$D"
    printf '%s' "$2" >"$D/value.arg"
    cat >"$D/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
REPORT_DIR="$D/spool"
REPORT_UNIT_DIR="$D/units"
REPORT_SENDER="$D/libexec/send"
REPORT_MARKER="$D/install-marker"
REPORT_EUID=0
stage_prerequisites() { echo REACHED-STAGE1; exit 0; }
main --no-telemetry "--$1=\$(cat "$D/value.arg")"
EOF
    (cd "$D" && "$BASH" child.sh >"$D/out" 2>"$D/err")
    RC=$?
    # The value as shown: everything after "Invalid --<flag>=" up to the
    # " (" that starts the hint. The colour codes of the ERROR: prefix sit
    # before it and are not part of the value.
    SHOWN=$(grep -a "Invalid --$1=" "$D/err" | head -n 1 | sed "s/^.*Invalid --$1=//; s/ (.*\$//")
}

for flag in source mariadb-version email; do
    echo "# --$flag"
    run_flag "$flag" $'x\e[31my'
    eq "--$flag with a raw ESC: refused, exit 1, install not started" "1 no" \
        "$RC $(grep -q REACHED-STAGE1 "$D/out" && echo yes || echo no)"
    eq "--$flag with a raw ESC: shown as '?'" 'x?[31my' "$SHOWN"
    check "--$flag with a raw ESC: no ESC byte in the shown value" bash -c '! grep -q $'"'"'\x1b'"'"' <<<"$1"' _ "$SHOWN"

    run_flag "$flag" 'x\e[31my'
    eq "--$flag with \\e[31m typed as text: refused, exit 1" 1 "$RC"
    eq "--$flag with \\e[31m typed as text: shown as typed" 'x\e[31my' "$SHOWN"

    run_flag "$flag" "$(printf 'x%.0s' {1..60})"
    eq "--$flag with 60 characters: refused, exit 1" 1 "$RC"
    eq "--$flag with 60 characters: 40 shown" 40 "${#SHOWN}"
done

echo
echo "# passed: $PASS, failed: $FAIL"
((FAIL == 0))
