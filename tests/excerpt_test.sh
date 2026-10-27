#!/usr/bin/env bash
#
# Tests for the full install log and the redaction of error excerpts in
# install.sh (AB-2233). No network, no root: install.sh is loaded with
# ADMINBOLT_INSTALL_SOURCE_ONLY=1 and every path points into a temporary
# directory. The flow of the excerpts through install_finished is tested in
# tests/telemetry_test.sh ("error excerpts of failed steps").
#
# Needs bash 4+, GNU coreutils, gawk and jq.
#   bash tests/excerpt_test.sh
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
INSTALL_SH=$(cd "$(dirname "$INSTALL_SH")" && pwd)/$(basename "$INSTALL_SH")

if ((BASH_VERSINFO[0] < 4)); then echo "bash 4 or newer required" >&2; exit 2; fi
for c in gawk jq; do command -v "$c" >/dev/null 2>&1 || { echo "$c required" >&2; exit 2; }; done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else nok "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else nok "$1" "missing '$2' in: $3"; fi; }
hasnt() { if grep -qiF -- "$2" <<<"$3"; then nok "$1" "still has '$2' in: $3"; else ok "$1"; fi; }

ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
set +e
trap 'rm -rf "$T"' EXIT
trap - INT TERM HUP

# The private values of a made-up server.
PRIV="$T/private"
printf 'host srv7.customer-host.net\nhost srv7x\nemail owner@customer-mail.org\nhost customer-mail.org\nkey ABLT-9F3A-77B2-C0DE\n' >"$PRIV"
redact() { _report_redact "$PRIV"; }

# ---------------------------------------------------------------------------
echo "# redaction of real error output"
# ---------------------------------------------------------------------------
out=$(redact <<'EOF'
Errors during downloading metadata for repository 'bolt':
  - Curl error (7): Couldn't connect to server for https://mirror.adminbolt.com/pulp/content/stable/rhel/9/x86_64/repodata/repomd.xml [Failed to connect to mirror.adminbolt.com port 443 after 2 ms: Connection refused]
  - Curl error (6): Couldn't resolve host name for http://203.0.113.80/almalinux/9/BaseOS/x86_64/os/repodata/repomd.xml [Could not resolve host: 203.0.113.80]
Error: Failed to download metadata for repo 'bolt': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried
EOF
)
has "dnf mirror: the error stays" "All mirrors were tried" "$out"
has "dnf mirror: the public mirror stays" "https://mirror.adminbolt.com/pulp/content/stable/rhel/9/x86_64/repodata/repomd.xml" "$out"
has "dnf mirror: the address of a private mirror goes" "for http://<ip>/almalinux/9/BaseOS" "$out"

out=$(redact <<'EOF'
Error:
 Problem: problem with installed package curl-minimal-7.76.1-29.el9_4.x86_64
  - package curl-7.76.1-29.el9_4.x86_64 from baseos conflicts with curl-minimal provided by curl-minimal-7.76.1-29.el9_4.x86_64
(try to add '--allowerasing' to command line to replace conflicting packages or '--skip-broken' to skip uninstallable packages)
EOF
)
has "dnf conflict: package versions untouched" "package curl-7.76.1-29.el9_4.x86_64 from baseos conflicts with curl-minimal provided by curl-minimal-7.76.1-29.el9_4.x86_64" "$out"
has "dnf conflict: the hint stays" "--allowerasing" "$out"

out=$(redact <<'EOF'
Job for mariadb.service failed because the control process exited with error code.
See "systemctl status mariadb.service" and "journalctl -xeu mariadb.service" for details.
Oct 23 14:30:01 srv7 mariadbd[5121]: 2026-10-23 14:30:01 0 [ERROR] Can't start server: Bind on TCP/IP port. Got error: 98: Address already in use
Oct 23 14:30:01 srv7.customer-host.net systemd[1]: mariadb.service: Failed with result 'exit-code'.
EOF
)
has "systemd: the error stays" "Address already in use" "$out"
has "systemd: times stay" "2026-10-23 14:30:01 0 [ERROR]" "$out"
has "systemd: the syslog host goes" "Oct 23 14:30:01 <host> mariadbd[5121]" "$out"
has "systemd: the full host name goes" "Oct 23 14:30:01 <host> systemd[1]" "$out"

out=$(redact <<'EOF'
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)
mysql -uroot -pS3cr3tPw! -h 203.0.113.9 -e 'SELECT 1'
ERROR 2002 (HY000): Can't connect to server on '2001:db8:85a3::8a2e:370:7334' (115)
GRANT ALL ON *.* TO 'bolt'@'%' IDENTIFIED BY 'x'; password=Tr0ub4dor
EOF
)
has "MariaDB: the error code stays" "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)" "$out"
has "MariaDB: mysql -p password goes" "mysql -uroot -p<secret> -h <ip>" "$out"
has "MariaDB: IPv6 goes" "on '<ip>' (115)" "$out"
hasnt "MariaDB: no password left" "S3cr3tPw" "$out"
hasnt "MariaDB: password= value goes" "Tr0ub4dor" "$out"

out=$(redact <<'EOF'
In Connection.php line 825:
  SQLSTATE[HY000] [2002] Connection refused (Connection: mysql, SQL: select * from "settings" where "key" = mail_hostname)
  Illuminate\Database\Connectors\Connector::createPdoConnection(): could not reach srv7.customer-host.net as owner@customer-mail.org
  /usr/local/bolt/web/vendor/laravel/framework/src/Illuminate/Database/Connectors/Connector.php:66
Licence ABLT-9F3A-77B2-C0DE is not valid for srv7x; APP_KEY=base64:q1w2E3r4T5y6U7i8O9p0A1s2D3f4G5h6J7k8L9z0X1c=
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl
Panel: https://203.0.113.9:8443/sso/login?token=a1b2c3d4e5f60718293a4b5c6d7e8f90
EOF
)
has "bolt-cli: the exception stays" "SQLSTATE[HY000] [2002] Connection refused" "$out"
has "bolt-cli: class and method stay" "Illuminate\\Database\\Connectors\\Connector::createPdoConnection()" "$out"
has "bolt-cli: the vendor path stays" "/usr/local/bolt/web/vendor/laravel/framework/src/Illuminate/Database/Connectors/Connector.php:66" "$out"
has "bolt-cli: host and e-mail go" "could not reach <host> as <email>" "$out"
has "bolt-cli: licence key and short host name go" "Licence <secret> is not valid for <host>;" "$out"
has "bolt-cli: APP_KEY goes" "APP_KEY=<secret>" "$out"
has "bolt-cli: Authorization goes" "Authorization: <secret>" "$out"
has "bolt-cli: token in a URL goes" "https://<ip>:8443/sso/login?token=<secret>" "$out"

out=$(redact <<'EOF'
ERROR: Port 8443 is already in use by another service. Please free it before running this installer.
Current listener:
tcp   LISTEN 0      511    0.0.0.0:8443   0.0.0.0:*    users:(("nginx",pid=812,fd=6))
tcp   LISTEN 0      511       [::]:8443      [::]:*    users:(("nginx",pid=812,fd=7))
EOF
)
has "port 8443: the listener stays" 'users:(("nginx",pid=812,fd=6))' "$out"
has "port 8443: addresses go" "<ip>:8443   <ip>:*" "$out"
has "port 8443: IPv6 any goes" "[<ip>]:8443" "$out"

out=$(redact <<'EOF'
QyNTUxOQAAACBkZXZpY2UtYm9vdHN0cmFwLWtleS1mb3ItdGVzdGluZy1vbmx5
-----END OPENSSH PRIVATE KEY-----
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA1
-----END RSA PRIVATE KEY-----
curl https://deploy:tok3nValue@git.example.net/repo.git
fe80::1%eth0 ::ffff:192.0.2.1 addr:2001:db8::2 http://[2001:db8::3]:8443/ 2001:0db8:0000:0000:0000:ff00:0042:8329
mail OWNER@Customer-Mail.org, mail for root@srv7.customer-host.net
Static hostname: web01
EOF
)
eq "key block, also one cut at the top" "<secret>|<secret>|<secret>|<secret>|<secret>" "$(head -n 5 <<<"$out" | paste -sd'|')"
has "URL credentials go" "curl https://<secret>@git.example.net/repo.git" "$out"
has "every IPv6 form goes" "<ip> <ip> addr:<ip> http://[<ip>]:8443/ <ip>" "$out"
has "e-mail in another case goes" "mail <email>, mail for <email>" "$out"
has "hostname field goes" "Static hostname: <host>" "$out"

in='14:30:01 MariaDB 10.11.6 v1.2.3.4 1.2.3.4.5 Foo::bar std::string 52:54:00:12:34:56 tests passed: 3 self::add() srv7xyz nginx.conf install.sh "key": "mail_hostname"'
eq "times, versions, PHP calls, MACs, other names stay" "$in" "$(redact <<<"$in")"
eq "IPv4 with a port and at the end of a sentence" "connect to <ip>:443 failed; seen from <ip>." "$(redact <<<'connect to 192.0.2.10:443 failed; seen from 192.0.2.11.')"
eq "a second pass changes nothing" "$out" "$(redact <<<"$out")"

# The receiver (bolt-ai-hub, installevents/redact.go) runs the same rules:
# both test the same vectors. HUB_REDACTION_VECTORS=/path/to/its copy also
# checks that the two files are still identical.
VECTORS="$HERE/redaction-vectors.tsv"
: >"$T/nopriv"
bad=0 nvec=0
while IFS=$'\t' read -r vin vwant; do
    [[ "$vin" == \#* || -z "$vin" ]] && continue
    nvec=$((nvec + 1))
    vgot=$(_report_redact "$T/nopriv" <<<"$vin")
    [[ "$vgot" == "$vwant" ]] || { bad=$((bad + 1)); echo "# vector: $vin -> $vgot (want $vwant)"; }
done <"$VECTORS"
eq "shared redaction vectors ($nvec) give the receiver's result" 0 "$bad"
if [[ -n "${HUB_REDACTION_VECTORS:-}" ]]; then
    check "shared vectors identical to the receiver's copy" cmp -s "$VECTORS" "$HUB_REDACTION_VECTORS"
fi

# Without gawk the redaction fails, so the caller sends no output.
_report_redact_nogawk=$(PATH="$T/empty" _report_redact "$PRIV" <<<"x" 2>/dev/null; echo "rc=$?")
eq "no gawk: redaction refuses" "rc=1" "$_report_redact_nogawk"

# ---------------------------------------------------------------------------
echo "# private values of this server"
# ---------------------------------------------------------------------------
ADMIN_EMAIL="Jan.Kowalski@Example-Corp.pl"
REPORT_PANEL_DB="$T/no-db"
vals=$(_report_private_values)
has "this host's name" "host $(uname -n | tr 'A-Z' 'a-z')" "$vals"
has "the --email address" "email Jan.Kowalski@Example-Corp.pl" "$vals"
has "the --email domain" "host example-corp.pl" "$vals"
has "the --email address URL-encoded" "email Jan.Kowalski%40Example-Corp.pl" "$vals"
hasnt "no generic names" "host localhost" "$vals"
mkdir -p "$T/bin"
printf '#!/bin/bash\n[[ "$1" == -r && "$3" == "%s" ]] && echo "key ABLT-1111-2222"\n' "$T/db" >"$T/bin/bolt-php"
chmod +x "$T/bin/bolt-php"
: >"$T/db"
REPORT_PANEL_DB="$T/db"
vals=$(PATH="$T/bin:$PATH" _report_private_values)
has "licence key read from the panel database" "key ABLT-1111-2222" "$vals"
ADMIN_EMAIL=""

# ---------------------------------------------------------------------------
echo "# cleaning and cutting an excerpt"
# ---------------------------------------------------------------------------
printf 'first\n\033[0;31mred\033[0m line\r\nprogress 10%%\rprogress 100%%\nbinary \001\002 caf\xc3\xa9\n\n\n' >"$T/step"
eq "colour codes, carriage returns and non-ASCII cleaned, empty end dropped" $'first\nred line\nprogress 100%\nbinary ?? cafe' "$(_report_excerpt_clean "$T/step" | _report_excerpt_cut 2048)"
printf 'Installing MariaDB 11.4\n  0/28 [\xe2\x96\x91\xe2\x96\x91]   0%%\n 14/28 [\xe2\x96\x93\xe2\x96\x91]  50%%\n 28/28 [\xe2\x96\x93\xe2\x96\x93] 100%%\n\xe2\x9c\x97 MariaDB installation failed\n' >"$T/bar"
eq "a progress bar keeps its last state, one ? per character" $'Installing MariaDB 11.4\n 28/28 [??] 100%\n? MariaDB installation failed' "$(_report_excerpt_clean "$T/bar")"
seq 1 100 | sed 's/^/l/' >"$T/many"
eq "only the last 40 lines" "40 l61 l100" "$(_report_excerpt_cut 2048 <"$T/many" | awk 'NR==1{f=$0} END{print NR, f, $0}')"
eq "byte limit: oldest lines go" "l97"$'\n'"l98"$'\n'"l99"$'\n'"l100" "$(_report_excerpt_cut 16 <"$T/many")"
eq "one line over the step limit keeps its end" "$(printf 'b%.0s' $(seq 1 2048))" "$(printf '%s%s\n' "$(printf 'a%.0s' $(seq 1 100))" "$(printf 'b%.0s' $(seq 1 2048))" | _report_excerpt_cut 2048)"
head -c 1048576 /dev/zero | tr '\0' 'a' >"$T/huge"; printf ' 192.0.2.1 final\n' >>"$T/huge"
t0=$(date +%s%N)
huge=$(_report_excerpt_clean "$T/huge" | _report_redact "$PRIV")
ms=$((($(date +%s%N) - t0) / 1000000))
check "a 1 MB line is redacted quickly (${ms} ms), its end kept" bash -c '[[ "$1" -lt 2000 && "$2" == *" <ip> final" ]]' _ "$ms" "$huge"
eq "a line that misses only the rest of the budget is left out" "" "$(printf 'abcdef\n' | _report_excerpt_cut 3)"

# ---------------------------------------------------------------------------
echo "# full install log"
# ---------------------------------------------------------------------------
log_child() {
    # $1 = name, $2 = body; runs install_log_start with INSTALL_LOG in $T/$1.
    D="$T/$1"; mkdir -p "$D"
    cat >"$D/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
INSTALL_LOG="$D/bolt-install.log"
REPORT_UUID_FILE="$D/no-uuid"
REPORT_EUID=\${TEST_EUID:-0}
trap 'install_log_stop' EXIT
$2
EOF
}
log_child plain '
install_log_start
echo -e "\033[0;32mSUCCESS:\033[0m step one"
echo "to stderr" >&2
printf "progress 1%%\rprogress 100%%\n"
exit 3'
(cd "$D" && bash child.sh >"$D/term" 2>&1); rc=$?
eq "exit code unchanged" 3 "$rc"
eq "terminal gets the same bytes" "$(printf '\033[0;32mSUCCESS:\033[0m step one\nto stderr\nprogress 1%%\rprogress 100%%\n')" "$(cat "$D/term")"
eq "log is root only (0600)" 600 "$(stat -c %a "$D/bolt-install.log")"
check "header with the install ID and the start time" grep -qE '^===== AdminBolt install, install ID [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}, started [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} UTC =====$' "$D/bolt-install.log"
check "every line has a UTC time" bash -c '[[ $(grep -v "^=====\|^$" "$1" | grep -cvE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ") == 0 ]]' _ "$D/bolt-install.log"
check "colour codes removed" bash -c '! grep -q $'"'"'\033'"'"' "$1"' _ "$D/bolt-install.log"
check "stdout and stderr both in it" bash -c 'grep -q "Z SUCCESS: step one$" "$1" && grep -q "Z to stderr$" "$1" && grep -q "Z progress 100%$" "$1"' _ "$D/bolt-install.log"
(cd "$D" && bash child.sh >/dev/null 2>&1)
eq "a rerun appends after its own header" 2 "$(grep -c '^===== AdminBolt install' "$D/bolt-install.log")"

log_child apart '
install_log_start
echo out-line
echo err-line >&2
exit 0'
(cd "$D" && bash child.sh >"$D/out" 2>"$D/err"); rc=$?
check "stdout and stderr apart: each on its own stream" bash -c 'grep -qx out-line "$1/out" && grep -qx err-line "$1/err" && ! grep -q err "$1/out"' _ "$D"
check "stdout and stderr apart: both logged" bash -c 'grep -q "Z out-line$" "$1" && grep -q "Z err-line$" "$1"' _ "$D/bolt-install.log"

log_child off '
REPORT_NO_TELEMETRY=1
install_log_start
echo "nothing sent"'
(cd "$D" && bash child.sh >/dev/null 2>&1)
check "--no-telemetry: the log is still written" grep -q 'Z nothing sent$' "$D/bolt-install.log"
check "--no-telemetry: no install ID made" grep -q 'install ID none (install report off)' "$D/bolt-install.log"

log_child notroot '
install_log_start
echo hi'
(cd "$D" && TEST_EUID=1000 bash child.sh >/dev/null 2>&1)
check "not root: no log" test ! -e "$D/bolt-install.log"

log_child symlink '
install_log_start
echo hi'
ln -s "$T/elsewhere" "$D/bolt-install.log"
(cd "$D" && bash child.sh >"$D/term" 2>&1)
check "a symlink at the log path is not followed" test ! -e "$T/elsewhere"
eq "a symlink at the log path: the install still prints" hi "$(cat "$D/term")"

log_child loose '
install_log_start
echo hi'
(umask 022; : >"$D/bolt-install.log")
chmod 0644 "$D/bolt-install.log"
(cd "$D" && bash child.sh >/dev/null 2>&1)
eq "an existing log is made root only" 600 "$(stat -c %a "$D/bolt-install.log")"

# Ctrl+C reaches the whole process group; the log goes on while dnf (here a
# command that ignores INT) finishes, as the install did before.
log_child interrupt '
install_log_start
echo before
( trap "" INT; sleep 1; echo after-int )
echo end'
(cd "$D" && setsid bash child.sh >"$D/term" 2>&1 & echo $! >"$D/pid"; sleep 0.5; kill -INT -- -"$(cat "$D/pid")"; wait) 2>/dev/null
check "Ctrl+C: output after it still on the terminal" grep -qx after-int "$D/term"
check "Ctrl+C: and in the log" grep -q 'Z after-int$' "$D/bolt-install.log"

# The step's output goes through one more tee than the installer's own
# messages; ending the capture waits for it, so the order stays.
log_child order '
install_log_start
REPORT_MODE=memory
_report_capture_init
for i in $(seq 1 20); do
    report_step_start check_os
    printf "step-%s\n" "$i" >&2
    report_exit_code 1
    echo "msg-$i"
done
exit 0'
(cd "$D" && bash child.sh >"$D/term" 2>&1)
eq "terminal order kept: each step's output before the message after it" "$(for i in $(seq 1 20); do printf 'step-%s\nmsg-%s\n' "$i" "$i"; done)" "$(cat "$D/term")"

# A job started during the install must not keep a reader of the
# installer's output waiting: no copy of stdout is left open for it.
log_child jobs '
install_log_start
REPORT_MODE=memory
_report_capture_init
( sleep 3 ) </dev/null >/dev/null 2>&1 &
report_step_start check_os
( _report_close_saved_fds; sleep 3 ) </dev/null >/dev/null 2>&1 &
echo done
exit 0'
t0=$(date +%s%N)
(cd "$D" && bash child.sh | cat >/dev/null)
ms=$((($(date +%s%N) - t0) / 1000000))
check "a background job does not hold the output pipe (${ms} ms)" test "$ms" -lt 1500

echo
echo "# passed: $PASS, failed: $FAIL"
((FAIL == 0))
