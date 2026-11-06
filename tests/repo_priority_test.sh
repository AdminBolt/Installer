#!/usr/bin/env bash
#
# Tests for the bolt.repo priorities install.sh sets on the default path,
# after the bolt-repo RPM is installed (AB-1407). No network, no root:
# install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 and only
# rank_bolt_repos is called, on files in a temporary directory.
#
#   Linux:  bash tests/repo_priority_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/repo_priority_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
# shellcheck disable=SC2329,SC2012,SC2016
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

# A bolt.repo in the given layout: one "priority = N" per section, in the
# order bolt-cdn, bolt-noarch-cdn, bolt, bolt-noarch.
write_repo() {
    local file=$1; shift
    local sections=(bolt-cdn bolt-noarch-cdn bolt bolt-noarch) i=0
    {
        echo "# Name:  Adminbolt RHEL"
        echo "# URL: http://www.adminbolt.com/"
        for prio in "$@"; do
            echo
            echo "[${sections[$i]}]"
            echo "name = Adminbolt RHEL - \$releasever - ${sections[$i]}"
            echo "baseurl = https://mirror.adminbolt.com/pulp/content/adminbolt/rhel/\$releasever/\$basearch"
            echo "enabled = 1"
            echo "gpgcheck = 0"
            echo "priority = $prio"
            echo "sslverify = 0"
            i=$((i + 1))
        done
    } >"$file"
}

# Runs rank_bolt_repos on the file in a subshell with install.sh sourced.
rank() {
    (
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        rank_bolt_repos "$1"
    ) >/dev/null 2>&1
}

priorities() { sed -n 's/^priority = //p' "$1" | paste -sd' ' -; }

# 1. bolt-repo 1.0.7 (100 to 400) gets the agent's values.
mkdir -p "$T/old"
write_repo "$T/old/bolt.repo" 100 200 300 400
rank "$T/old/bolt.repo"
eq "1.0.7 layout: priorities lowered to 10 20 30 40" "10 20 30 40" "$(priorities "$T/old/bolt.repo")"
write_repo "$T/old/expected.repo" 10 20 30 40
if cmp -s "$T/old/expected.repo" "$T/old/bolt.repo"; then ok "1.0.7 layout: only the priority lines change"; else nok "1.0.7 layout: only the priority lines change" "$(diff "$T/old/expected.repo" "$T/old/bolt.repo")"; fi
eq "1.0.7 layout: file mode 0644" "644" "$(stat -c %a "$T/old/bolt.repo" 2>/dev/null || stat -f %Lp "$T/old/bolt.repo")"
eq "1.0.7 layout: no temporary file left" "bolt.repo expected.repo" "$(cd "$T/old" && ls -A | paste -sd' ' -)"

# 2. bolt-repo 1.0.8 (10 to 40) stays byte-identical and is not rewritten.
mkdir -p "$T/new"
write_repo "$T/new/bolt.repo" 10 20 30 40
cp -p "$T/new/bolt.repo" "$T/new/before.repo"
inode_before=$(ls -i "$T/new/bolt.repo" | awk '{print $1}')
rank "$T/new/bolt.repo"
if cmp -s "$T/new/before.repo" "$T/new/bolt.repo"; then ok "1.0.8 layout: byte-identical"; else nok "1.0.8 layout: byte-identical" "$(diff "$T/new/before.repo" "$T/new/bolt.repo")"; fi
eq "1.0.8 layout: file not replaced" "$inode_before" "$(ls -i "$T/new/bolt.repo" | awk '{print $1}')"

# 3. Another bolt* section gets 50; a non-bolt section keeps its priority.
mkdir -p "$T/extra"
write_repo "$T/extra/bolt.repo" 100 200 300 400
printf '\n[bolt-extra]\nname = extra\npriority = 500\n\n[epel-local]\nname = other\npriority = 120\n' >>"$T/extra/bolt.repo"
rank "$T/extra/bolt.repo"
eq "other bolt* section: priority 50, non-bolt section untouched" "10 20 30 40 50 120" "$(priorities "$T/extra/bolt.repo")"

# 4. No bolt.repo (the RPM did not write one): nothing happens, no error.
mkdir -p "$T/none"
if rank "$T/none/bolt.repo"; then ok "missing bolt.repo: returns 0"; else nok "missing bolt.repo: returns 0"; fi
eq "missing bolt.repo: nothing created" "" "$(ls -A "$T/none")"

# 5. The default path calls it right after installing the bolt-repo RPM.
body=$(sed -n '/^install_repo_rhel() {/,/^}/p' "$INSTALL_SH")
if grep -q 'rank_bolt_repos "\$BOLT_REPO_FILE"' <<<"$body"; then ok "install_repo_rhel ranks the repositories on the default path"; else nok "install_repo_rhel ranks the repositories on the default path"; fi

echo "# $PASS passed, $FAIL failed"
((FAIL == 0))
