#!/usr/bin/env bash
#
# Tests for --ssh-key in install.sh (AB-2106): reading and checking the key,
# adding it to root's authorized_keys, and turning SSH password login off only
# when it is safe. Uses the real ssh-keygen and `sshd -t` / `sshd -T`, so it
# changes /etc/ssh/sshd_config.d: run it only in a throwaway AlmaLinux 9 or
# Rocky Linux 9 container, never on a real server. curl, systemctl and
# journalctl are fakes, the terminal is a file; install.sh is loaded with
# ADMINBOLT_INSTALL_SOURCE_ONLY=1 and runs under its own set -e.
#
#   docker run --rm -v "$PWD":/src:ro almalinux:9 bash -c \
#     'dnf -y -q install openssh-server >/dev/null && ssh-keygen -A && ADMINBOLT_SSH_KEY_TEST=1 bash /src/tests/ssh_key_test.sh'
#
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}

if [[ "${ADMINBOLT_SSH_KEY_TEST:-}" != 1 || "$EUID" -ne 0 || ! -d /etc/ssh/sshd_config.d ]] || ! command -v sshd >/dev/null; then
    echo "Run as root in a throwaway container with openssh-server and ADMINBOLT_SSH_KEY_TEST=1 (see the header)" >&2
    exit 2
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
DROP_IN_DIR=/etc/ssh/sshd_config.d
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
cat "$FAKE/curl_body" 2>/dev/null
exit "$(cat "$FAKE/curl_rc" 2>/dev/null || echo 0)"
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE/systemctl.log"
exit "$(cat "$FAKE/systemctl_rc" 2>/dev/null || echo 0)"
EOF
cat >"$T/bin/journalctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE/journalctl.args"
cat "$FAKE/auth.log" 2>/dev/null
EOF
chmod +x "$T/bin/"*

ssh-keygen -q -t ed25519 -N '' -C k1 -f "$T/k1" && ssh-keygen -q -t ed25519 -N '' -C k2 -f "$T/k2" && ssh-keygen -q -t ed25519 -N '' -C k3 -f "$T/k3"
K1=$(cat "$T/k1.pub") K2=$(cat "$T/k2.pub")
FP1=$(ssh-keygen -l -E sha256 -f "$T/k1.pub" | awk '{print $2}')
FP3=$(ssh-keygen -l -E sha256 -f "$T/k3.pub" | awk '{print $2}')
DROP_IN=$DROP_IN_DIR/00-adminbolt-ssh-key-only.conf

PASS=0 FAIL=0
check() {
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name"; fi
}
eq() { check "$1 (expected '$2', got '$3')" test "$2" == "$3"; }

# A fresh case: own fake dir and authorized_keys, no test drop-ins left behind.
# $1 = name, $2 = script run with install.sh loaded. Sets RC; output in $FAKE/out.
run_case() {
    FAKE="$T/$1"
    mkdir -p "$FAKE/root/.ssh"
    [[ -e "$FAKE/no-tty" ]] || touch "$FAKE/tty"
    rm -f "$DROP_IN_DIR"/00-a.conf "$DROP_IN_DIR"/50-test.conf "$DROP_IN"
    cat >"$FAKE/case.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
ROOT_AUTHORIZED_KEYS="$FAKE/root/.ssh/authorized_keys"
SSH_KEY_LOGIN_WAIT=20
SSH_KEY_TTY="$FAKE/tty"
$2
EOF
    (export FAKE; PATH="$T/bin:$PATH" bash "$FAKE/case.sh" >"$FAKE/out" 2>&1 </dev/null)
    RC=$?
}
out_has() { grep -qF -- "$1" "$FAKE/out"; }
not_out_has() { ! out_has "$1"; }
sshd_root() { sshd -T -C "user=root,host=$1,addr=$1" | awk -v k="$2" '$1 == k {print $2; exit}'; }

# ---- reading --ssh-key ----
run_case load-literal "SSH_KEY_ARG='$K1'; ssh_key_load && printf '%s|%s' \"\$SSH_KEYS\" \"\$SSH_KEY_FPS\""
eq "literal key accepted" 0 "$RC"
check "literal key kept and fingerprinted" out_has "$K1"$'\n'"|$FP1"

run_case load-garbage "SSH_KEY_ARG='hello world'; ssh_key_load"
eq "garbage refused" 1 "$RC"
check "garbage named in the error" out_has "not an SSH public key: hello world"

run_case load-options "SSH_KEY_ARG='command=\"/bin/sh\" $K1'; ssh_key_load"
eq "key with authorized_keys options refused" 1 "$RC"

run_case load-bad-blob "SSH_KEY_ARG='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIbroken'; ssh_key_load"
eq "key with a broken blob refused" 1 "$RC"

run_case load-http "SSH_KEY_ARG='http://example.com/keys'; ssh_key_load"
eq "http URL refused" 1 "$RC"
check "http refusal says what is accepted" out_has "public key or an https:// URL"

mkdir -p "$T/load-url"
printf '# keys\n\n%s\r\n  %s  \n' "$K1" "$K2" >"$T/load-url/curl_body"
run_case load-url "SSH_KEY_ARG='https://example.com/keys'; ssh_key_load && grep -c . <<<\"\$SSH_KEYS\" && grep -cF -e '$K1' -e '$K2' <<<\"\$SSH_KEYS\""
eq "URL with two keys, a comment, CRLF and spaces accepted" 0 "$RC"
check "both keys read from the URL" test "$(tr -d '\r' <"$FAKE/out")" == $'2\n2'

echo 22 >"$T/load-url/curl_rc"
run_case load-url "SSH_KEY_ARG='https://example.com/keys'; ssh_key_load"
eq "failed download refused" 1 "$RC"
check "failed download named" out_has "Could not download the SSH key"

run_case load-empty "SSH_KEY_ARG='# only a comment'; ssh_key_load"
eq "no key at all refused" 1 "$RC"

# ---- adding the key ----
run_case install-new "SSH_KEY_ARG='$K1'; ssh_key_load && ssh_key_install"
eq "key installed" 0 "$RC"
eq "authorized_keys holds the key" "$K1" "$(cat "$FAKE/root/.ssh/authorized_keys")"
eq ".ssh is 700" 700 "$(stat -c %a "$FAKE/root/.ssh")"
eq "authorized_keys is 600" 600 "$(stat -c %a "$FAKE/root/.ssh/authorized_keys")"

mkdir -p "$T/install-commented/root/.ssh"; printf '# %s\n' "$K1" >"$T/install-commented/root/.ssh/authorized_keys"
run_case install-commented "SSH_KEY_ARG='$K1'; ssh_key_load && ssh_key_install"
check "commented-out copy does not count: key added" out_has "(1 added)"

mkdir -p "$T/install-keep/root/.ssh"
printf 'from="10.0.0.1" %s' "$K2" >"$T/install-keep/root/.ssh/authorized_keys"
run_case install-keep "SSH_KEY_ARG='$K1'\$'\\n''$K2'; ssh_key_load && ssh_key_install && ssh_key_install"
eq "install over an existing file" 0 "$RC"
eq "existing lines kept, plain lines added on their own lines, nothing doubled" "from=\"10.0.0.1\" $K2"$'\n'"$K1"$'\n'"$K2" "$(cat "$FAKE/root/.ssh/authorized_keys")"
check "second run adds nothing" out_has "(0 added)"

run_case install-none "ssh_key_install; ssh_password_login_off"
eq "no --ssh-key: no-op" 0 "$RC"
check "no --ssh-key: authorized_keys untouched" test ! -e "$FAKE/root/.ssh/authorized_keys"
check "no --ssh-key: no drop-in" test ! -e "$DROP_IN"
check "no --ssh-key: sshd not reloaded" test ! -e "$FAKE/systemctl.log"
check "no --ssh-key: log not read" test ! -e "$FAKE/journalctl.args"

# ---- turning password login off ----
OFF="SSH_KEY_ARG='$K1'; ssh_key_load && ssh_key_install && ssh_password_login_off; echo -e \"NOTE=\$SSH_PASSWORD_NOTE\""

mkdir -p "$T/off-ok"; echo "Accepted publickey for root from 203.0.113.5 port 50022 ssh2: ED25519 $FP1" >"$T/off-ok/auth.log"
run_case off-ok "$OFF"
eq "password off: runs" 0 "$RC"
check "password off: drop-in written" test -f "$DROP_IN"
eq "password off: sshd -T for the client" no "$(sshd_root 203.0.113.5 passwordauthentication)"
eq "keyboard-interactive off too" no "$(sshd_root 203.0.113.5 kbdinteractiveauthentication)"
eq "key login still on" yes "$(sshd_root 203.0.113.5 pubkeyauthentication)"
eq "sshd reloaded once" "reload sshd" "$(cat "$FAKE/systemctl.log")"
check "only sign-ins from now on are read" grep -qE -- '--since @[0-9]{10}' "$FAKE/journalctl.args"
eq "other users keep password login" yes "$(sshd -T -C user=nobody,host=203.0.113.5,addr=203.0.113.5 | awk '$1 == "passwordauthentication" {print $2}')"
check "seen sign-in reported" out_has "Sign-in with your key seen from 203.0.113.5"
check "password off: says so" out_has "SSH password login for root turned off"
check "password off: undo command shown" out_has "rm $DROP_IN && systemctl reload sshd"
rm -f "$DROP_IN"

run_case off-no-login "$OFF"
check "no sign-in seen: no drop-in" test ! -e "$DROP_IN"
check "no sign-in seen: reason given" out_has "SSH password login for root left on: no sign-in with the key was seen"
check "kept note shows a working command" out_has "printf 'Match User root\\n    PasswordAuthentication no\\n    KbdInteractiveAuthentication no\\n' > $DROP_IN && sshd -t && systemctl reload sshd"
check "terminal asked for a sign-in" out_has "From a new terminal, sign in with your key"

mkdir -p "$T/off-no-tty"; touch "$T/off-no-tty/no-tty"; cp "$T/off-ok/auth.log" "$T/off-no-tty/"
run_case off-no-tty "$OFF"
check "no terminal: password login kept even with a logged sign-in" test ! -e "$DROP_IN"
check "no terminal: nothing asked" not_out_has "From a new terminal"

mkdir -p "$T/off-forged"; echo "Invalid user Accepted publickey for root from 198.51.100.9 port 1 ssh2: ED25519 $FP1 from 198.51.100.9 port 4242" >"$T/off-forged/auth.log"
echo "Accepted publickey for root from 198.51.100.9 port 1 ssh2: ED25519 $FP1 [preauth]" >>"$T/off-forged/auth.log"
run_case off-forged "$OFF"
check "forged log lines do not count" test ! -e "$DROP_IN"

mkdir -p "$T/off-restricted"; cp "$T/off-ok/auth.log" "$T/off-restricted/"
mkdir -p "$T/off-restricted/root/.ssh"
printf 'no-pty,command="echo use the almalinux user;exit 142" %s\n' "$K1" >"$T/off-restricted/root/.ssh/authorized_keys"
run_case off-restricted "$OFF"
check "key also listed with command=: no drop-in" test ! -e "$DROP_IN"
check "key also listed with command=: reason given" out_has "also lists the key with restrictions"

# sshd reads root's keys from a second file first; there the key has a forced command.
mkdir -p "$T/keys"; printf 'command="/bin/false" %s\n' "$K1" >"$T/keys/root"
printf 'AuthorizedKeysFile %s/keys/%%u .ssh/authorized_keys\n' "$T" >"$T/other-file.conf"
mkdir -p "$T/off-other-file"; cp "$T/off-ok/auth.log" "$T/off-other-file/"
run_case off-other-file "cp '$T/other-file.conf' $DROP_IN_DIR/00-a.conf; $OFF"
check "key with command= in another AuthorizedKeysFile: no drop-in" test ! -e "$DROP_IN"
check "key with command= in another AuthorizedKeysFile: file named" out_has "$T/keys/root also lists the key with restrictions"

mkdir -p /root/.ssh; printf 'no-pty %s\n' "$K1" >/root/.ssh/ab2106_test_keys
mkdir -p "$T/off-other-home"; cp "$T/off-ok/auth.log" "$T/off-other-home/"
run_case off-other-home "printf 'AuthorizedKeysFile .ssh/authorized_keys %%h/.ssh/ab2106_test_keys\n' >$DROP_IN_DIR/00-a.conf; $OFF"
check "key with no-pty in %h file: no drop-in" test ! -e "$DROP_IN"
check "key with no-pty in %h file: file named" out_has "/root/.ssh/ab2106_test_keys also lists the key"

printf 'restrict %s\n' "$K2" >/root/.ssh/ab2106_test_keys
mkdir -p "$T/off-other-key-restricted"; cp "$T/off-ok/auth.log" "$T/off-other-key-restricted/"
run_case off-other-key-restricted "printf 'AuthorizedKeysFile .ssh/authorized_keys %%h/.ssh/ab2106_test_keys\n' >$DROP_IN_DIR/00-a.conf; $OFF"
check "another key restricted in the second file: password off" test -f "$DROP_IN"
rm -f "$DROP_IN" /root/.ssh/ab2106_test_keys

mkdir -p "$T/off-keys-command"; cp "$T/off-ok/auth.log" "$T/off-keys-command/"
run_case off-keys-command "printf 'AuthorizedKeysCommand /bin/true\nAuthorizedKeysCommandUser nobody\n' >$DROP_IN_DIR/00-a.conf; $OFF"
check "keys from AuthorizedKeysCommand: no drop-in" test ! -e "$DROP_IN"
check "keys from AuthorizedKeysCommand: reason given" out_has "AuthorizedKeysCommand /bin/true"

mkdir -p "$T/off-already-off"
run_case off-already-off "printf 'PasswordAuthentication no\n' >$DROP_IN_DIR/00-a.conf; $OFF"
check "already off elsewhere: note does not claim it is on" out_has "sshd already has it off"
check "already off elsewhere: no 'left ON'" not_out_has "left ON"
check "no sign-in seen: sshd not reloaded" test ! -e "$FAKE/systemctl.log"

mkdir -p "$T/off-other-key"; echo "Accepted publickey for root from 203.0.113.5 port 1 ssh2: ED25519 $FP3" >"$T/off-other-key/auth.log"
run_case off-other-key "$OFF"
check "sign-in with another key does not count" test ! -e "$DROP_IN"

mkdir -p "$T/off-other-user"; echo "Accepted publickey for alma from 203.0.113.5 port 1 ssh2: ED25519 $FP1" >"$T/off-other-user/auth.log"
run_case off-other-user "$OFF"
check "sign-in as another user does not count" test ! -e "$DROP_IN"

mkdir -p "$T/off-key-gone"; echo "Accepted publickey for root from 203.0.113.5 port 1 ssh2: ED25519 $FP1" >"$T/off-key-gone/auth.log"
run_case off-key-gone "SSH_KEY_ARG='$K1'; ssh_key_load && ssh_key_install && : >\"\$ROOT_AUTHORIZED_KEYS\" && ssh_password_login_off"
check "key gone: no drop-in" test ! -e "$DROP_IN"
check "key gone: reason given" out_has "the key is no longer in"

mkdir -p "$T/off-no-root"; cp "$T/off-key-gone/auth.log" "$T/off-no-root/"
printf 'PermitRootLogin no\n' >"$T/no-root.conf"
run_case off-no-root "cp '$T/no-root.conf' $DROP_IN_DIR/00-a.conf; $OFF"
check "root login off: no drop-in" test ! -e "$DROP_IN"
check "root login off: reason given" out_has "root login over SSH is not allowed (PermitRootLogin no)"

mkdir -p "$T/off-match-addr"; cp "$T/off-key-gone/auth.log" "$T/off-match-addr/"
printf 'Match Address 203.0.113.0/24\n    PubkeyAuthentication no\n' >"$T/match.conf"
run_case off-match-addr "cp '$T/match.conf' $DROP_IN_DIR/50-test.conf; $OFF"
check "key login off for the client's address: no drop-in" test ! -e "$DROP_IN"
check "key login off for the client's address: reason names the address" out_has "(for 203.0.113.5)"

mkdir -p "$T/off-overridden"; cp "$T/off-key-gone/auth.log" "$T/off-overridden/"
run_case off-overridden "printf 'Match User root\n    PasswordAuthentication yes\n' >$DROP_IN_DIR/00-a.conf; $OFF"
check "earlier Match block for root wins: ours removed" test ! -e "$DROP_IN"
check "earlier Match block for root wins: reason given" out_has "another sshd setting overrides"
check "earlier Match block for root wins: sshd not reloaded" test ! -e "$FAKE/systemctl.log"

mkdir -p "$T/off-restore"; cp "$T/off-key-gone/auth.log" "$T/off-restore/"
run_case off-restore "printf '# mine\n' >$DROP_IN; printf 'Match User root\n    PasswordAuthentication yes\n' >$DROP_IN_DIR/00-a.conf; $OFF"
eq "previous drop-in put back as it was" "# mine" "$(cat "$DROP_IN" 2>/dev/null)"
check "no leftover temp or backup files" test -z "$(find "$DROP_IN_DIR" -name '00-adminbolt-ssh-key-only.conf.*')"
rm -f "$DROP_IN"

mkdir -p "$T/off-reload-fails"; cp "$T/off-key-gone/auth.log" "$T/off-reload-fails/"; echo 1 >"$T/off-reload-fails/systemctl_rc"
run_case off-reload-fails "$OFF"
eq "failed reload: runs" 0 "$RC"
check "failed reload: drop-in removed" test ! -e "$DROP_IN"
eq "failed reload: reload tried again after removing it" $'reload sshd\nreload sshd' "$(cat "$FAKE/systemctl.log")"
check "failed reload: reason given" out_has "sshd did not reload"

# ---- the option itself ----
run_case opt-empty "ADMINBOLT_INSTALL_SOURCE_ONLY=0 main --ssh-key="
eq "--ssh-key= with no value stops the installer" 1 "$RC"
check "--ssh-key= with no value: says why" out_has "--ssh-key= needs a public key"

rm -f "$DROP_IN_DIR"/00-a.conf "$DROP_IN_DIR"/50-test.conf "$DROP_IN"
echo "ssh_key_test: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
