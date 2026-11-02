#!/usr/bin/env bash
#
# Tests for installing bolt-agent again after its %post failed, and for what
# counts as a finished agent setup. No network, no root: rpm, dnf and
# systemctl (and, in single cases, tee and df) are replaced by fakes on PATH,
# and install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install
# itself never runs; only install_bolt_agent_and_check_post (and
# check_agent_setup_at_end) is called.
#
#   Linux:  bash tests/agent_post_rerun_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/agent_post_rerun_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
# The stubs and the AGENT_* paths are read by the sourced install.sh, and PATH
# is changed on purpose inside the subshell only.
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
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else nok "$1" "'$2' not in output"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then nok "$1" "'$2' in output"; else ok "$1"; fi; }

# Fakes, driven by files in $FAKE_DIR:
#   installed             - present: rpm -q bolt-agent succeeds
#   active                - present: systemctl is-active bolt-agent succeeds
#   dnf.<subcommand>      - output of that dnf call (exit code in dnf.<subcommand>.rc)
#   dnf.<subcommand>.post - what that call's %post and %posttrans leave behind,
#                           one of the fake-post modes below
# dnf records each call in dnf.log, one per line.
mkdir -p "$T/bin" "$T/badtee" "$T/fulldisk"
cat >"$T/bin/rpm" <<'EOF'
#!/usr/bin/env bash
[[ -e "$FAKE_DIR/installed" ]] && { echo "bolt-agent-1.32.23-1.x86_64"; exit 0; }
echo "package bolt-agent is not installed"
exit 1
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == is-active && -e "$FAKE_DIR/active" ]] && exit 0
exit 3
EOF
cat >"$T/bin/dnf" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/dnf.log"
cat "$FAKE_DIR/dnf.$1" 2>/dev/null
[[ -e "$FAKE_DIR/dnf.$1.post" ]] && fake-post "$(cat "$FAKE_DIR/dnf.$1.post")"
exit "$(cat "$FAKE_DIR/dnf.$1.rc" 2>/dev/null || echo 0)"
EOF
# What the agent's %post does to agent.conf: writes it only when there is
# none (an existing one is kept), then the certificate and the service.
#   clean      - a finished %post: HTTPS on, certificate files, agent running
#   https-off  - %post went on past a failed certificate step (a full disk):
#                HTTPS off, no certificate files, agent running
#   no-service - files as clean, but the agent does not come up
cat >"$T/bin/fake-post" <<'EOF'
#!/usr/bin/env bash
mode=$1 conf="$FAKE_DIR/etc/agent.conf" https=true
[[ "$mode" == https-off ]] && https=false
mkdir -p "$FAKE_DIR/etc" "$FAKE_DIR/ssl"
if [[ ! -e "$conf" ]]; then
    printf '[server]\nport=3030\nhttps_enabled=%s\nhttps_cert_path=%s\nhttps_key_path=%s\nhttps_ca_path=%s\n\n[security]\ntoken=fresh-token\n' \
        "$https" "$FAKE_DIR/ssl/cert.pem" "$FAKE_DIR/ssl/privkey.pem" "$FAKE_DIR/ssl/fullchain.pem" >"$conf"
fi
if [[ "$mode" != https-off ]]; then
    for f in cert privkey fullchain; do echo pem >"$FAKE_DIR/ssl/$f.pem"; done
fi
if [[ "$mode" == no-service ]]; then rm -f "$FAKE_DIR/active"; else touch "$FAKE_DIR/active"; fi
EOF
# tee that cannot write its copy (a full disk): passes the input through,
# leaves the file empty and exits 1, as GNU tee does on ENOSPC.
cat >"$T/badtee/tee" <<'EOF'
#!/usr/bin/env bash
: >"$1" 2>/dev/null
cat
echo "tee: $1: No space left on device" >&2
exit 1
EOF
# df on a full disk.
cat >"$T/fulldisk/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/loop0 51200 51200 0 100% /"
EOF
chmod +x "$T/bin/"* "$T/badtee/tee" "$T/fulldisk/df"

POST_FAILED='warning: %post(bolt-agent-1.32.23-1.x86_64) scriptlet failed, exit status 1'

# new_case NAME: a fresh fake dir in $D (agent.conf, certificates and the
# marker live inside it); EXTRA_PATH is reset.
new_case() { D="$T/$1"; mkdir -p "$D"; EXTRA_PATH=""; }
# A finished setup already on disk (agent.conf, certificates; not the service).
finished_setup() { FAKE_DIR="$D" "$T/bin/fake-post" clean; rm -f "$D/active"; }
marker() { [[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no; }

# run_case [FUNCTION]: calls install_bolt_agent_and_check_post (or FUNCTION)
# against $D; leaves the output in $OUT and the exit code in $RC.
run_case() {
    local fn="${1:-install_bolt_agent_and_check_post}"
    (
        export FAKE_DIR="$D" PATH="${EXTRA_PATH:+$EXTRA_PATH:}$T/bin:$PATH"
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        report_step_start() { :; }
        report_step_result() { :; }
        report_fail() { :; }
        AGENT_POST_FAILED_MARKER="${MARKER_OVERRIDE:-$D/state/agent-post-failed}"
        AGENT_CONF="$D/etc/agent.conf"
        AGENT_CONF_BACKUP_DIR="${BACKUP_OVERRIDE:-$D/backup}"
        AGENT_ACTIVE_WAIT_SECONDS=0
        "$fn"
    ) >"$D/out" 2>&1
    RC=$?
    OUT=$(cat "$D/out")
}
dnf_calls() { cut -d' ' -f1 "$D/dnf.log" 2>/dev/null | paste -sd' ' -; }

# 1. %post failed earlier and %posttrans started the agent anyway: the
#    marker alone makes the installer install bolt-agent again.
new_case marker-active
touch "$D/installed" "$D/active"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
echo clean >"$D/dnf.reinstall.post"
run_case
eq "marker + running agent: exit 0" 0 "$RC"
hasnt "marker + running agent: not reported as already installed" "bolt-agent already installed" "$OUT"
eq "marker + running agent: bolt-agent reinstalled" "reinstall" "$(dnf_calls)"
eq "marker + running agent: marker removed after a clean %post" no "$(marker)"

# 2. Installed, no marker, agent not running (the case the ticket describes).
new_case no-marker-inactive
touch "$D/installed"; finished_setup
echo clean >"$D/dnf.reinstall.post"
run_case
eq "agent not running: exit 0" 0 "$RC"
hasnt "agent not running: not reported as already installed" "bolt-agent already installed" "$OUT"
eq "agent not running: bolt-agent reinstalled" "reinstall" "$(dnf_calls)"

# 3. The %post fails again on the rerun: same message, non-zero exit, the
#    marker stays for the next run.
new_case post-fails-again
touch "$D/installed" "$D/active"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
echo "$POST_FAILED" >"$D/dnf.reinstall"
run_case
eq "%post fails again: exit 1" 1 "$RC"
has "%post fails again: the %post message" "post-install script (%post) failed" "$OUT"
has "%post fails again: the advice is a rerun the installer finishes" "rerun this installer; it retries the agent install" "$OUT"
eq "%post fails again: marker kept" yes "$(marker)"

# 4. A normal rerun: installed, set up, running, no marker - nothing is reinstalled.
new_case healthy
touch "$D/installed"; finished_setup; touch "$D/active"
run_case
eq "healthy agent: exit 0" 0 "$RC"
has "healthy agent: reported as already installed" "bolt-agent already installed" "$OUT"
eq "healthy agent: no dnf call" "" "$(dnf_calls)"

# 5. %post failed and the installed version left the repository: upgrade to
#    the newer one, which runs %post too.
new_case not-available
touch "$D/installed"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
echo "Installed package bolt-agent-1.32.23-1.x86_64 (from bolt) not available." >"$D/dnf.reinstall"
echo 1 >"$D/dnf.reinstall.rc"
echo clean >"$D/dnf.upgrade.post"
run_case
eq "version gone from the repository: exit 0" 0 "$RC"
eq "version gone from the repository: reinstall, then upgrade" "reinstall upgrade" "$(dnf_calls)"

# 5b. Only stopped (no marker, setup on disk complete) and the version is not
#     in the repository: no upgrade, a warning, and the install goes on as before.
new_case stopped-not-available
touch "$D/installed"; finished_setup
echo "Installed package bolt-agent-1.32.23-1.x86_64 (from bolt) not available." >"$D/dnf.reinstall"
echo 1 >"$D/dnf.reinstall.rc"
run_case
eq "stopped agent, version gone: exit 0 (continues)" 0 "$RC"
eq "stopped agent, version gone: reinstall only, no upgrade" "reinstall" "$(dnf_calls)"
has "stopped agent, version gone: warns" "keeping the installed version (continuing)" "$OUT"
eq "stopped agent, version gone: no marker" no "$(marker)"

# 5c. Only stopped and the reinstall fails for another reason: same.
new_case stopped-reinstall-fails
touch "$D/installed"; finished_setup
echo "Error: Failed to download metadata for repo 'bolt'" >"$D/dnf.reinstall"
echo 1 >"$D/dnf.reinstall.rc"
run_case
eq "stopped agent, reinstall error: exit 0 (continues)" 0 "$RC"
eq "stopped agent, reinstall error: reinstall only" "reinstall" "$(dnf_calls)"

# 6. ... and no newer one either (a newer testing or PR build is installed):
#    stop with advice that ends in a rerun, not a false ok.
new_case nothing-newer
touch "$D/installed"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
echo "Installed package bolt-agent-1.32.23-1.x86_64 (from bolt) not available." >"$D/dnf.reinstall"
echo 1 >"$D/dnf.reinstall.rc"
echo "Nothing to do." >"$D/dnf.upgrade"
run_case
eq "no version to install: exit 1" 1 "$RC"
has "no version to install: says why" "the installed version is not in the repository" "$OUT"
has "no version to install: advice is a rerun the installer finishes" "Rerun this installer with the --source" "$OUT"
has "no version to install: the rerun retries the agent install" "it retries the agent install" "$OUT"
hasnt "no version to install: no manual dnf reinstall advice" "dnf reinstall" "$OUT"
hasnt "no version to install: no dnf remove advice (bolt-panel requires bolt-agent)" "dnf remove" "$OUT"
eq "no version to install: marker kept" yes "$(marker)"

# 7. First install with a failed %post: the marker is written.
new_case first-install-fails
echo "$POST_FAILED" >"$D/dnf.install"
run_case
eq "first install, %post failed: exit 1" 1 "$RC"
eq "first install, %post failed: plain install" "install" "$(dnf_calls)"
eq "first install, %post failed: marker written" yes "$(marker)"

# 8. First install, clean: no marker, plain install.
new_case first-install-ok
echo clean >"$D/dnf.install.post"
run_case
eq "first install, clean: exit 0" 0 "$RC"
eq "first install, clean: plain install" "install" "$(dnf_calls)"
eq "first install, clean: no marker" no "$(marker)"
has "first install, clean: reported installed" "bolt-agent installed" "$OUT"

# 9. Marker present, the reinstall hits a full disk that %post reports as a
#    warning only: dnf exits 0 and prints no failed %post, but HTTPS is off
#    and the certificate is missing. Not proof of a finished setup: the
#    marker stays and the install stops.
new_case marker-enospc-quiet
touch "$D/installed" "$D/active"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
echo https-off >"$D/dnf.reinstall.post"
run_case
eq "marker, quiet full-disk %post: exit 1" 1 "$RC"
eq "marker, quiet full-disk %post: marker kept" yes "$(marker)"
hasnt "marker, quiet full-disk %post: no success" "SUCCESS: bolt-agent installed" "$OUT"
has "marker, quiet full-disk %post: says the setup did not finish" "bolt-agent's setup did not finish" "$OUT"
has "marker, quiet full-disk %post: names HTTPS off" "HTTPS is off in $D/etc/agent.conf" "$OUT"
has "marker, quiet full-disk %post: names the missing certificate" "the certificate file $D/ssl/cert.pem is missing or empty" "$OUT"

# 10. Marker present, dnf exits 0 with no message and nothing set up at all.
new_case marker-nothing-written
touch "$D/installed" "$D/active"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
run_case
eq "marker, nothing written: exit 1" 1 "$RC"
eq "marker, nothing written: marker kept" yes "$(marker)"
has "marker, nothing written: names agent.conf" "$D/etc/agent.conf is missing" "$OUT"

# 11. The copy of dnf's output cannot be written (full disk): the failure
#     message could be in the lost part, so a clean end state is not enough.
new_case log-copy-lost
echo "$POST_FAILED" >"$D/dnf.install"
echo clean >"$D/dnf.install.post"
EXTRA_PATH="$T/badtee"
run_case
eq "output copy lost: exit 1" 1 "$RC"
eq "output copy lost: marker written" yes "$(marker)"
has "output copy lost: says so" "could not keep a complete copy of bolt-agent's install output" "$OUT"
has "output copy lost: dnf's output still shown" "scriptlet failed" "$OUT"

# 12. First install (no marker), full disk, %post went on past it: no false
#     success, the marker is written, the disk is named.
new_case first-install-enospc
echo https-off >"$D/dnf.install.post"
EXTRA_PATH="$T/fulldisk"
run_case
eq "first install, quiet full-disk %post: exit 1" 1 "$RC"
eq "first install, quiet full-disk %post: marker written" yes "$(marker)"
hasnt "first install, quiet full-disk %post: no success" "SUCCESS: bolt-agent installed" "$OUT"
has "first install, quiet full-disk %post: names the full disk" "(almost) full" "$OUT"

# 13. dnf's own line for a failed %post, without rpm's warning, counts too.
new_case first-install-dnf-line
echo "Error in POSTIN scriptlet in rpm package bolt-agent" >"$D/dnf.install"
echo clean >"$D/dnf.install.post"
run_case
eq "dnf's POSTIN line: exit 1" 1 "$RC"
has "dnf's POSTIN line: the %post message" "post-install script (%post) failed" "$OUT"

# 14. Files in place, but the agent never comes up.
new_case first-install-no-service
echo no-service >"$D/dnf.install.post"
run_case
eq "agent does not start: exit 1" 1 "$RC"
has "agent does not start: says so" "the bolt-agent service is not running" "$OUT"
eq "agent does not start: marker written" yes "$(marker)"

# 15. A damaged agent.conf (cut short, no certificate paths) on a running
#     agent without the marker: %post would keep it and stop on it at every
#     rerun. It is moved to a dated copy with a manifest, and the agent is
#     installed again, which writes a new one.
new_case damaged-conf
touch "$D/installed" "$D/active"; mkdir -p "$D/etc"
printf '[server]\nport=3030\nhttps_ena' >"$D/etc/agent.conf"
echo clean >"$D/dnf.reinstall.post"
run_case
eq "damaged agent.conf: exit 0" 0 "$RC"
hasnt "damaged agent.conf: not reported as already installed" "bolt-agent already installed" "$OUT"
eq "damaged agent.conf: bolt-agent reinstalled" "reinstall" "$(dnf_calls)"
saved=$(find "$D/backup" -name agent.conf 2>/dev/null | head -n1)
eq "damaged agent.conf: old file kept in a dated copy" "$(printf '[server]\nport=3030\nhttps_ena')" "$(cat "$saved" 2>/dev/null)"
manifest=$(cat "$(dirname "${saved:-$D/none/x}")/MANIFEST" 2>/dev/null)
has "damaged agent.conf: manifest names the original" "original=$D/etc/agent.conf" "$manifest"
has "damaged agent.conf: manifest says why" "reason=$D/etc/agent.conf has no https_cert_path" "$manifest"
has "damaged agent.conf: new agent.conf written" "token=fresh-token" "$(cat "$D/etc/agent.conf" 2>/dev/null)"

# 15b. ... and when it cannot be moved aside, nothing changes and the install stops.
new_case damaged-conf-stuck
touch "$D/installed" "$D/active"; mkdir -p "$D/etc"; : >"$D/etc/agent.conf"
touch "$D/blocked"
BACKUP_OVERRIDE="$D/blocked/backup" run_case
eq "damaged agent.conf, cannot move: exit 1" 1 "$RC"
eq "damaged agent.conf, cannot move: no dnf call" "" "$(dnf_calls)"
eq "damaged agent.conf, cannot move: file left where it was" yes "$([[ -e "$D/etc/agent.conf" ]] && echo yes || echo no)"
has "damaged agent.conf, cannot move: says so" "could not be moved aside" "$OUT"

# 16. Running agent, no marker, but its setup is incomplete (certificate
#     gone, HTTPS off - an install whose failure an older installer missed):
#     installed again rather than "already installed".
new_case incomplete-active
touch "$D/installed"; finished_setup; touch "$D/active"
rm -f "$D/ssl/cert.pem"
echo clean >"$D/dnf.reinstall.post"
run_case
eq "incomplete running agent: exit 0" 0 "$RC"
hasnt "incomplete running agent: not reported as already installed" "bolt-agent already installed" "$OUT"
has "incomplete running agent: says what is missing" "its setup is incomplete" "$OUT"
eq "incomplete running agent: bolt-agent reinstalled" "reinstall" "$(dnf_calls)"

# 16b. ... and it is not let through when it cannot be installed again.
new_case incomplete-nothing-newer
touch "$D/installed"; finished_setup; touch "$D/active"
rm -f "$D/ssl/cert.pem"
echo "Installed package bolt-agent-1.32.23-1.x86_64 (from bolt) not available." >"$D/dnf.reinstall"
echo 1 >"$D/dnf.reinstall.rc"
echo "Nothing to do." >"$D/dnf.upgrade"
run_case
eq "incomplete agent, no version to install: exit 1" 1 "$RC"
eq "incomplete agent, no version to install: reinstall, then upgrade" "reinstall upgrade" "$(dnf_calls)"

# 17. The marker cannot be written: the message must not promise a rerun
#     that retries the agent install, and says how to make it do so.
new_case marker-unwritable
echo "$POST_FAILED" >"$D/dnf.install"
touch "$D/blocked"
MARKER_OVERRIDE="$D/blocked/agent-post-failed" run_case
eq "marker unwritable: exit 1" 1 "$RC"
hasnt "marker unwritable: no promise of a retry" "it retries the agent install" "$OUT"
has "marker unwritable: says the failure was not recorded" "could not record this failure in $D/blocked/agent-post-failed" "$OUT"
has "marker unwritable: next step" "touch $D/blocked/agent-post-failed" "$OUT"

# 18. The end of the install checks the agent once more.
new_case end-check-ok
finished_setup; touch "$D/active"
run_case check_agent_setup_at_end
eq "end check, finished setup: exit 0" 0 "$RC"
eq "end check, finished setup: no marker" no "$(marker)"

new_case end-check-https-off
finished_setup; touch "$D/active"
sed -i.bak 's/^https_enabled=true/https_enabled=false/' "$D/etc/agent.conf"
run_case check_agent_setup_at_end
eq "end check, HTTPS turned off: exit 1" 1 "$RC"
has "end check, HTTPS turned off: says so" "HTTPS is off" "$OUT"
eq "end check, HTTPS turned off: marker written for the rerun" yes "$(marker)"

echo "passed: $PASS, failed: $FAIL"
((FAIL == 0))
