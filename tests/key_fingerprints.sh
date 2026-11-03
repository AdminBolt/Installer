#!/usr/bin/env bash
#
# AB-2280 review 1, point 3: the public keys install.sh writes to
# /etc/pki/rpm-gpg are the keys CI signs with. A wrong key there (the testing
# key pasted as the release key, an old key) makes every new server refuse
# every AdminBolt package, so CI compares the fingerprints with the repository
# variables before anything is merged or released.
#
#   RPM_SIGNING_FINGERPRINT=<40 hex> RPM_TESTING_SIGNING_FINGERPRINT=<40 hex> bash tests/key_fingerprints.sh
#
# While both keys are still the AB-2280 placeholder, install.sh stops before it
# writes any repository, so there is nothing to compare yet: a notice, exit 0.
# Otherwise each key must be one armored public key whose fingerprint is its
# variable; a missing variable, another key or one placeholder left fails.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}

heredoc() { # <delimiter>
    awk -v d="$1" '$0 ~ "<<.?" d ".?$" { on = 1; next } on && $0 == d { exit } on' "$INSTALL_SH"
}

work=$(mktemp -d)
trap 'GNUPGHOME="$work/gnupg" gpgconf --kill all >/dev/null 2>&1; rm -rf "$work"' EXIT
mkdir -m 700 "$work/gnupg"

heredoc ADMINBOLT_RELEASE_KEY >"$work/release.asc"
heredoc ADMINBOLT_TESTING_KEY >"$work/testing.asc"
placeholders=0
for k in release testing; do
    [[ -s "$work/$k.asc" ]] || { echo "::error::install.sh has no $k key heredoc"; exit 1; }
    grep -q 'AB-2280-PLACEHOLDER' "$work/$k.asc" && placeholders=$((placeholders + 1))
done
if ((placeholders == 2)); then
    echo "::notice::install.sh still carries the AB-2280 placeholders; it refuses to install until the real keys are in."
    exit 0
fi

bad=0
check() { # <kind> <file> <expected>
    local want got
    want=$(printf '%s' "$3" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if grep -q 'AB-2280-PLACEHOLDER' "$2"; then
        echo "::error::the $1 key in install.sh is still the placeholder, but the other key is real"
        bad=1
        return
    fi
    local n
    got=$(GNUPGHOME="$work/gnupg" gpg --batch --with-colons --show-keys "$2" 2>/dev/null | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')
    n=$(grep -c . <<<"$got")
    if [[ "$n" -ne 1 ]]; then
        echo "::error::the $1 key in install.sh must be exactly one public key (found $n)"
        bad=1
    elif [[ ! "$want" =~ ^[0-9A-F]{40}$ ]]; then
        echo "::error::the $1 key in install.sh is real, but its fingerprint variable is not set"
        bad=1
    elif [[ "$got" != "$want" ]]; then
        echo "::error::the $1 key in install.sh has fingerprint $got, but CI signs with ${want}"
        bad=1
    else
        echo "$1 key: $got"
    fi
}
check release "$work/release.asc" "${RPM_SIGNING_FINGERPRINT:-}"
check testing "$work/testing.asc" "${RPM_TESTING_SIGNING_FINGERPRINT:-}"
exit "$bad"
