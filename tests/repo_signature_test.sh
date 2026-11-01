#!/usr/bin/env bash
#
# Tests for the package signature and mirror certificate checks the installer
# sets up (AB-2280). No network, no root: curl, rpm, rpmkeys and dnf are
# replaced by fakes on PATH, every path points into a temporary directory, and
# install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install
# itself never runs.
#
#   Linux:  bash tests/repo_signature_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/repo_signature_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
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
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }

FAKE_KEY=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nthrowaway test key\n-----END PGP PUBLIC KEY BLOCK-----'

# Fakes: every call is logged; rpmkeys answers $FAKE_DIR/rpmkeys_rc; curl
# writes a dummy file where -o points.
mkdir -p "$T/bin"
for tool in rpm dnf yum; do
    cat >"$T/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >>"\$FAKE_DIR/calls"
exit 0
EOF
done
cat >"$T/bin/rpmkeys" <<'EOF'
#!/usr/bin/env bash
echo "rpmkeys $*" >>"$FAKE_DIR/calls"
exit "$(cat "$FAKE_DIR/rpmkeys_rc" 2>/dev/null || echo 0)"
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_DIR/calls"
prev=""
for a in "$@"; do [[ "$prev" == -o ]] && echo rpm >"$a"; prev="$a"; done
exit 0
EOF
chmod +x "$T/bin/"*

# Runs one snippet with install.sh loaded, paths in a fresh directory. Keys are
# the placeholder unless WITH_KEYS=1. Prints the snippet's exit code last.
run() {
    local dir; dir=$(mktemp -d "$T/run.XXXX")
    (
        export FAKE_DIR="$dir" PATH="$T/bin:$PATH"
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        set +e
        BOLT_REPO_FILE="$dir/bolt.repo"
        ADMINBOLT_RPM_KEY_DIR="$dir/rpm-gpg"
        report_fail() { echo "report_fail $*" >>"$FAKE_DIR/calls"; }
        if [[ "${WITH_KEYS:-0}" == 1 ]]; then
            adminbolt_release_key() { printf '%s\n' "$FAKE_KEY"; }
            adminbolt_testing_key() { printf '%s\n' "$FAKE_KEY"; }
        fi
        eval "$1"
    ) >"$dir/out" 2>&1
    echo "$dir"
}

section() { awk -v s="[$2]" '$0 == s { on = 1; next } /^\[/ { on = 0 } on' "$1"; }
RELEASE_LINE='gpgkey = file://%s/rpm-gpg/RPM-GPG-KEY-adminbolt'

echo "# repository file written for --source (criterion 2)"
for tier in stable staging testing; do
    d=$(run "install_bolt_repos_from_source $tier")
    f="$d/bolt.repo"
    for s in bolt bolt-noarch; do
        body=$(section "$f" "$s")
        grep -qx 'gpgcheck = 1' <<<"$body" && ok "$tier [$s] gpgcheck = 1" || nok "$tier [$s] gpgcheck = 1" "$(tr '\n' ' ' <<<"$body")"
        grep -qx 'sslverify = 1' <<<"$body" && ok "$tier [$s] sslverify = 1" || nok "$tier [$s] sslverify = 1"
        want=$(printf "$RELEASE_LINE" "$d")
        [[ "$tier" == testing ]] && want+=" file://$d/rpm-gpg/RPM-GPG-KEY-adminbolt-testing"
        grep -qxF "$want" <<<"$body" && ok "$tier [$s] gpgkey names the right keys" || nok "$tier [$s] gpgkey names the right keys" "$(grep gpgkey <<<"$body")"
    done
    grep -qE '^(gpgcheck|sslverify)[[:space:]]*=[[:space:]]*0' "$f" && nok "$tier: no check turned off" || ok "$tier: no check turned off"
done

echo "# keys before repositories"
d=$(run 'install_repo_rhel 9; echo "rc=$?"')
grep -q 'carries no AdminBolt package key' "$d/out" && ok "placeholder key: the install stops with a reason" || nok "placeholder key: the install stops with a reason" "$(tail -3 "$d/out" | tr '\n' ' ')"
check "placeholder key: nothing downloaded" bash -c "! grep -q '^curl' '$d/calls' 2>/dev/null"
check "placeholder key: no repository file" test ! -e "$d/bolt.repo"
check "placeholder key: reported as a repo_setup failure" grep -q 'report_fail repo_setup' "$d/calls"

d=$(WITH_KEYS=1 run 'BOLT_SOURCE=testing; install_repo_rhel 9')
check "--source=testing: release key written" test -s "$d/rpm-gpg/RPM-GPG-KEY-adminbolt"
check "--source=testing: testing key written" test -s "$d/rpm-gpg/RPM-GPG-KEY-adminbolt-testing"
check "--source=testing: keys imported into rpm" grep -q "^rpm --import $d/rpm-gpg/RPM-GPG-KEY-adminbolt$" "$d/calls"
check "--source=testing: repository written after the keys" test -s "$d/bolt.repo"

d=$(WITH_KEYS=1 run 'BOLT_SOURCE=stable; install_repo_rhel 9')
check "--source=stable: no testing key" test ! -e "$d/rpm-gpg/RPM-GPG-KEY-adminbolt-testing"

echo "# default path: the bolt-repo package is verified before it is installed"
d=$(WITH_KEYS=1 run 'BOLT_SOURCE=""; install_repo_rhel 9')
check "certificate checked on download (no -k)" bash -c "grep '^curl' '$d/calls' | grep -q 'bolt-repo-' && ! grep '^curl' '$d/calls' | grep -qE ' -[A-Za-z]*k( |$)'"
check "signature checked with _pkgverify_level all" grep -qE "^rpmkeys --dbpath [^ ]+ --checksig --define _pkgverify_level all /tmp/bolt-repo-9.rpm" "$d/calls"
db=$(sed -nE 's#^rpmkeys --dbpath ([^ ]+) --checksig .*#\1#p' "$d/calls" | head -1)
check "checked in its own rpm database, not the system keyring" bash -c "[[ -n '$db' ]] && grep -q '^rpm --dbpath $db --initdb' '$d/calls'"
check "that database holds the release key only" bash -c "[[ \$(grep -c '^rpmkeys --dbpath $db --import' '$d/calls') -eq 1 ]] && grep -q '^rpmkeys --dbpath $db --import $d/rpm-gpg/RPM-GPG-KEY-adminbolt\$' '$d/calls'"
check "no signature check against the system keyring" bash -c "! grep -qE '^rpmkeys --checksig' '$d/calls'"
check "the throwaway database is removed" bash -c "[[ -n '$db' && ! -e '$db' ]]"
check "signed package installed" grep -q '^dnf install -y /tmp/bolt-repo-9.rpm' "$d/calls"
key_line=$(grep -n '^rpm --import' "$d/calls" | head -1 | cut -d: -f1)
dl_line=$(grep -n '^curl' "$d/calls" | head -1 | cut -d: -f1)
[[ -n "$key_line" && -n "$dl_line" && "$key_line" -lt "$dl_line" ]] && ok "key imported before the download" || nok "key imported before the download"

d=$(run 'echo 1 >"$FAKE_DIR/rpmkeys_rc"; BOLT_SOURCE=""; adminbolt_release_key() { printf "%s\n" "$FAKE_KEY"; }; install_repo_rhel 9')
check "unsigned or foreign-key repository package: refused" grep -q 'not signed with the AdminBolt key' "$d/out"
check "unsigned or foreign-key repository package: not installed" bash -c "! grep -qE '^(dnf|yum) install|^rpm -ivh' '$d/calls'"
check "unsigned or foreign-key repository package: reported" grep -q 'report_fail repo_setup repo_download_failed' "$d/calls"

echo "# no insecure option in install.sh (criterion 6)"
# gpgcheck/sslverify off, --nogpgcheck, --insecure, and curl's -k in any short
# option cluster. The one allowed curl -k is the loopback readiness probe of the
# server's own panel ("$REPORT_PANEL_URL", https://127.0.0.1:8443/).
forbidden() {
    grep -nE -e '(gpgcheck|sslverify|repo_gpgcheck)[[:space:]]*=[[:space:]]*(0|false|no|off)\b' \
        -e '--nogpgcheck' -e '--insecure' \
        -e 'curl([[:space:]]+[^|;&]*)?[[:space:]]-[A-Za-z]*k' "$1" | grep -v '"\$REPORT_PANEL_URL"'
}
if hits=$(forbidden "$INSTALL_SH"); then nok "install.sh turns no check off" "$(tr '\n' ' ' <<<"$hits")"; else ok "install.sh turns no check off"; fi
grep -q '^REPORT_PANEL_URL="https://127.0.0.1:8443/"$' "$INSTALL_SH" && ok "the allowed probe is loopback only" || nok "the allowed probe is loopback only"
probe="$T/probe"
for bad in 'gpgcheck = 0' 'sslverify = 0' 'dnf install --nogpgcheck x' 'curl --insecure -o a b' 'curl -f -L -k -o "$t" "$u"' 'curl -fsSLk "$u"'; do
    printf '%s\n' "$bad" >"$probe"
    forbidden "$probe" >/dev/null && ok "the check catches: $bad" || nok "the check catches: $bad"
done

echo "# pass $PASS, fail $FAIL"
exit "$FAIL"
