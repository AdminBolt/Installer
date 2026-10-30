#!/usr/bin/env bash
#
# Tests for installing bolt-agent again after its %post failed (AB-2277).
# No network, no root: rpm, dnf and systemctl are replaced by fakes on PATH,
# and install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install
# itself never runs; only install_bolt_agent_and_check_post is called.
#
#   Linux:  bash tests/agent_post_rerun_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/agent_post_rerun_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
# The stubs and AGENT_POST_FAILED_MARKER are read by the sourced install.sh,
# and PATH is changed on purpose inside the subshell only.
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
#   installed        - present: rpm -q bolt-agent succeeds
#   active           - present: systemctl is-active bolt-agent succeeds
#   dnf.<subcommand> - output of that dnf call (exit code in dnf.<subcommand>.rc)
# dnf records each call in dnf.log, one per line.
mkdir -p "$T/bin"
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
exit "$(cat "$FAKE_DIR/dnf.$1.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/"*

POST_FAILED='warning: %post(bolt-agent-1.32.23-1.x86_64) scriptlet failed, exit status 1'

# new_case NAME: a fresh fake dir in $D, with the marker path inside it.
new_case() { D="$T/$1"; mkdir -p "$D"; }

# run_case: calls install_bolt_agent_and_check_post against $D; leaves the
# output in $OUT and the exit code in $RC.
run_case() {
    (
        export FAKE_DIR="$D" PATH="$T/bin:$PATH"
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        report_step_start() { :; }
        report_step_result() { :; }
        report_fail() { :; }
        AGENT_POST_FAILED_MARKER="$D/state/agent-post-failed"
        install_bolt_agent_and_check_post
    ) >"$D/out" 2>&1
    RC=$?
    OUT=$(cat "$D/out")
}
dnf_calls() { cut -d' ' -f1 "$D/dnf.log" 2>/dev/null | paste -sd' ' -; }

# 1. %post failed earlier and %posttrans started the agent anyway: the
#    marker alone makes the installer install bolt-agent again.
new_case marker-active
touch "$D/installed" "$D/active"; mkdir -p "$D/state"; touch "$D/state/agent-post-failed"
run_case
eq "marker + running agent: exit 0" 0 "$RC"
hasnt "marker + running agent: not reported as already installed" "bolt-agent already installed" "$OUT"
eq "marker + running agent: bolt-agent reinstalled" "reinstall" "$(dnf_calls)"
eq "marker + running agent: marker removed after a clean %post" no "$([[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no)"

# 2. Installed, no marker, agent not running (the case the ticket describes).
new_case no-marker-inactive
touch "$D/installed"
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
eq "%post fails again: marker kept" yes "$([[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no)"

# 4. A normal rerun: installed, running, no marker - nothing is reinstalled.
new_case healthy
touch "$D/installed" "$D/active"
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
run_case
eq "version gone from the repository: exit 0" 0 "$RC"
eq "version gone from the repository: reinstall, then upgrade" "reinstall upgrade" "$(dnf_calls)"

# 5b. Only stopped (no marker) and the version is not in the repository: no
#     upgrade, a warning, and the install goes on as before AB-2277.
new_case stopped-not-available
touch "$D/installed"
echo "Installed package bolt-agent-1.32.23-1.x86_64 (from bolt) not available." >"$D/dnf.reinstall"
echo 1 >"$D/dnf.reinstall.rc"
run_case
eq "stopped agent, version gone: exit 0 (continues)" 0 "$RC"
eq "stopped agent, version gone: reinstall only, no upgrade" "reinstall" "$(dnf_calls)"
has "stopped agent, version gone: warns" "keeping the installed version (continuing)" "$OUT"
eq "stopped agent, version gone: no marker" no "$([[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no)"

# 5c. Only stopped and the reinstall fails for another reason: same.
new_case stopped-reinstall-fails
touch "$D/installed"
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
eq "no version to install: marker kept" yes "$([[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no)"

# 7. First install with a failed %post: the marker is written.
new_case first-install-fails
echo "$POST_FAILED" >"$D/dnf.install"
run_case
eq "first install, %post failed: exit 1" 1 "$RC"
eq "first install, %post failed: plain install" "install" "$(dnf_calls)"
eq "first install, %post failed: marker written" yes "$([[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no)"

# 8. First install, clean: no marker, plain install.
new_case first-install-ok
run_case
eq "first install, clean: exit 0" 0 "$RC"
eq "first install, clean: plain install" "install" "$(dnf_calls)"
eq "first install, clean: no marker" no "$([[ -e "$D/state/agent-post-failed" ]] && echo yes || echo no)"

echo "passed: $PASS, failed: $FAIL"
((FAIL == 0))
