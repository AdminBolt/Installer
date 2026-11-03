#!/usr/bin/env bash
#
# AB-2280 review 1, point 3: tests for tests/key_fingerprints.sh, the CI check
# that the public keys in install.sh are the keys CI signs with. Throwaway keys
# in a temporary directory; needs gpg, no network, no root.
#
#   bash tests/key_fingerprints_test.sh
# CHECK_SH=/path/to/key_fingerprints.sh tests another copy of the check.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK_SH=${CHECK_SH:-$HERE/key_fingerprints.sh}
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
export LC_ALL=C

T=$(mktemp -d)
trap 'GNUPGHOME="$T/gnupg" gpgconf --kill all >/dev/null 2>&1; rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }

mkdir -m 700 "$T/gnupg"
export GNUPGHOME="$T/gnupg"
for k in release testing other; do
    gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "AB-2280 throwaway $k <$k@example.invalid>" rsa3072 sign 1d 2>/dev/null
    gpg --batch --armor --export "$k@example.invalid" >"$T/$k.asc"
done
fpr() { gpg --batch --with-colons --list-keys "$1@example.invalid" | awk -F: '$1 == "fpr" { print $10; exit }'; }
REL=$(fpr release)
TST=$(fpr testing)
OTH=$(fpr other)

# install.sh with the given key files in place of the placeholders.
with_keys() {
    python3 -I - "$INSTALL_SH" "$1" "$2" "$3" <<'PY'
import sys
src, rel, tst, out = sys.argv[1:5]
s = open(src).read()
for marker, path in (("release", rel), ("testing", tst)):
    if path != "-":
        s = s.replace("AB-2280-PLACEHOLDER: paste the AdminBolt %s public key here.\n" % marker, open(path).read())
open(out, "w").write(s)
PY
}

run() { # <install.sh> <release fpr> <testing fpr>
    env INSTALL_SH="$1" RPM_SIGNING_FINGERPRINT="$2" RPM_TESTING_SIGNING_FINGERPRINT="$3" "$BASH" "$CHECK_SH" >"$T/out" 2>&1
}

[[ -f "$CHECK_SH" ]] || { nok "the check exists" "$CHECK_SH"; echo "# pass $PASS, fail $FAIL"; exit 1; }

with_keys "$T/release.asc" "$T/testing.asc" "$T/good.sh"
run "$T/good.sh" "$REL" "$TST" && ok "the right keys pass" || nok "the right keys pass" "$(tr '\n' ' ' <"$T/out")"
run "$T/good.sh" "$(tr "[:upper:]" "[:lower:]" <<<"$REL")" " $TST " && ok "fingerprints are compared without case and spaces" || nok "fingerprints are compared without case and spaces" "$(tr '\n' ' ' <"$T/out")"

with_keys "$T/testing.asc" "$T/testing.asc" "$T/swapped.sh"
run "$T/swapped.sh" "$REL" "$TST" && nok "the testing key in the release slot fails" \
    || { grep -q 'release' "$T/out" && ok "the testing key in the release slot fails" || nok "the failure names the release key" "$(tr '\n' ' ' <"$T/out")"; }

with_keys "$T/release.asc" "$T/other.asc" "$T/other.sh"
run "$T/other.sh" "$REL" "$TST" && nok "another key in the testing slot fails" \
    || { grep -q 'testing' "$T/out" && ok "another key in the testing slot fails" || nok "the failure names the testing key" "$(tr '\n' ' ' <"$T/out")"; }

run "$T/good.sh" "" "$TST" && nok "a real key without its fingerprint variable fails" || ok "a real key without its fingerprint variable fails"

with_keys "$T/release.asc" - "$T/half.sh"
run "$T/half.sh" "$REL" "$TST" && nok "one real key and one placeholder fail" || ok "one real key and one placeholder fail"

# Both placeholders: install.sh refuses to run, so there is nothing to compare yet.
cp "$INSTALL_SH" "$T/placeholder.sh"
if grep -q 'AB-2280-PLACEHOLDER: paste the AdminBolt release' "$T/placeholder.sh"; then
    run "$T/placeholder.sh" "" "" && grep -qi 'placeholder' "$T/out" \
        && ok "both placeholders pass with a notice" || nok "both placeholders pass with a notice" "$(tr '\n' ' ' <"$T/out")"
fi

echo "# pass $PASS, fail $FAIL"
exit "$FAIL"
