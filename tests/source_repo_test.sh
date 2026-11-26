#!/usr/bin/env bash
#
# Tests for the --source channel to repository mapping (AB-2614): stable is
# production, which is published to pulp/content/adminbolt/ (the tree the
# default bolt-repo RPM points at), not to pulp/content/stable/, a tree
# retired in June 2026 that only has bolt-panel 1.0.x. staging and testing
# keep their own trees; any other value is refused before anything is
# installed. No network, no root: install.sh is loaded with
# ADMINBOLT_INSTALL_SOURCE_ONLY=1, the repository file is written into a
# temporary directory and Stage 1 is replaced by a stub.
#
# Needs bash 4+.
#   Linux:  bash tests/source_repo_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/source_repo_test.sh
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
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }

MIRROR='https://mirror.adminbolt.com/pulp/content'

# Writes the repository file for --source=$1 into $T/$1/bolt.repo with the
# installer's own function; RC is its exit code.
write_repos() {
    D="$T/$1"
    rm -rf "$D"
    mkdir -p "$D"
    (
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        BOLT_REPO_FILE="$D/bolt.repo"
        REPORT_MODE=off
        install_bolt_repos_from_source "$1"
    ) >"$D/out" 2>"$D/err"
    RC=$?
}

baseurls() { sed -n 's/^baseurl = //p' "$1" | paste -sd' ' -; }

# 1. Each channel's baseurls, for bolt and bolt-noarch.
for case in 'stable adminbolt' 'staging staging' 'testing testing'; do
    read -r channel segment <<<"$case"
    write_repos "$channel"
    eq "--source=$channel: written" 0 "$RC"
    # shellcheck disable=SC2016
    eq "--source=$channel: bolt and bolt-noarch under pulp/content/$segment" \
        "$MIRROR/$segment/rhel/\$releasever/\$basearch $MIRROR/$segment/rhel/\$releasever/noarch" \
        "$(baseurls "$D/bolt.repo")"
done

# 2. stable never lands on the retired tree.
write_repos stable
if grep -q 'pulp/content/stable' "$D/bolt.repo"; then nok "--source=stable: no pulp/content/stable in the repository file" "$(grep baseurl "$D/bolt.repo")"; else ok "--source=stable: no pulp/content/stable in the repository file"; fi
if grep -q 'source=stable, pulp/content/adminbolt' "$D/out"; then ok "--source=stable: the log names the tree"; else nok "--source=stable: the log names the tree" "$(cat "$D/out")"; fi

# 3. A value that is not a channel (the path segment itself included) writes
# nothing and stops.
for bad in adminbolt hotfix nope; do
    write_repos "$bad"
    eq "install_bolt_repos_from_source $bad: exit 1" 1 "$RC"
    if [[ -e "$D/bolt.repo" ]]; then nok "install_bolt_repos_from_source $bad: no repository file"; else ok "install_bolt_repos_from_source $bad: no repository file"; fi
done

# 4. main: the accepted values stay stable, staging and testing; anything else
# is refused before Stage 1 with the list of valid values.
run_main() {
    D="$T/main-$1"
    rm -rf "$D"
    mkdir -p "$D"
    cat >"$D/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
REPORT_DIR="$D/spool"
REPORT_UNIT_DIR="$D/units"
REPORT_SENDER="$D/libexec/send"
REPORT_MARKER="$D/install-marker"
REPORT_EUID=0
stage_prerequisites() { echo REACHED-STAGE1; exit 0; }
main --no-telemetry "--source=$1"
EOF
    (cd "$D" && "$BASH" child.sh >"$D/out" 2>"$D/err")
    RC=$?
}
for good in stable staging testing; do
    run_main "$good"
    eq "main --source=$good: accepted" "0 yes" "$RC $(grep -q REACHED-STAGE1 "$D/out" && echo yes || echo no)"
done
for bad in adminbolt production; do
    run_main "$bad"
    eq "main --source=$bad: refused before Stage 1" "1 no" "$RC $(grep -q REACHED-STAGE1 "$D/out" && echo yes || echo no)"
    if grep -q "Invalid --source=$bad (allowed: stable, staging, testing)" "$D/err"; then ok "main --source=$bad: names the valid values"; else nok "main --source=$bad: names the valid values" "$(cat "$D/err")"; fi
done

# 5. The help text says stable is production.
help=$(ADMINBOLT_INSTALL_SOURCE_ONLY=1 "$BASH" -c '. "$1"; print_usage' _ "$INSTALL_SH" 2>&1)
if grep -q 'stable is production' <<<"$help"; then ok "--help: stable is production"; else nok "--help: stable is production"; fi

echo "# $PASS passed, $FAIL failed"
((FAIL == 0))
