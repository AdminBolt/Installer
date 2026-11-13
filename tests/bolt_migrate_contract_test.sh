#!/usr/bin/env bash
#
# The installer's contract with bolt-migrate (AB-2331). bolt-migrate downloads
# this script at run time (branch latest) and converts live cPanel servers
# with it. A change here once broke every conversion while all of this
# repository's tests passed, so what bolt-migrate relies on is pinned here:
#   - the flags it passes are parsed: --skip-database, --skip-apache,
#     --version=, --source=, --agent-version=, --package=, --channel=;
#   - an argument the installer does not know is ignored, not refused
#     (bolt-migrate passes --auto-upgrade=1, and an older bolt-migrate passes
#     flags a newer installer may have dropped);
#   - CloudLinux 9 is accepted;
#   - the closing summary keeps the lines bolt-migrate reads when the
#     installer exits non-zero (AB-2480): "CRITICAL <step>: <reason>",
#     "CONVERSION  <step>: <why>", "STOPPED" and "Stage 3 finished with
#     failed critical components", and --cpanel-conversion is parsed;
#   - the report channel convert is in REPORT_CHANNELS (AB-2447): bolt-migrate
#     passes --channel=convert only to an installer whose line lists it.
# Renaming or removing any of these needs a matching bolt-migrate release
# first. bolt-migrate also checks the published installer every day
# (bolt-migrate .github/workflows/installer-compat.yml).
#
#   bash tests/bolt_migrate_contract_test.sh
# INSTALL_SH=/path/to/install.sh runs the same checks against another copy.
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

bash -n "$INSTALL_SH" && ok "install.sh parses" || nok "install.sh parses"

for arm in '--skip-database)' '--skip-apache)' '--cpanel-conversion)' '--version=*)' '--source=*)' '--agent-version=*)' '--package=*)' '--channel=*)'; do
    if grep -qF -- "$arm" "$INSTALL_SH"; then ok "parser has $arm"; else nok "parser has $arm (bolt-migrate passes it)"; fi
done

# The argument loop must not refuse what it does not know: no catch-all arm
# that exits between the loop's `case "$arg" in` and its `esac`.
loop=$(awk '/for arg in "\$@"/{f=1} f{print} f&&/^[[:space:]]*esac/{exit}' "$INSTALL_SH")
if [[ -z "$loop" ]]; then
    nok "argument loop found"
elif grep -qE '^[[:space:]]*\*\)' <<<"$loop" && grep -A3 -E '^[[:space:]]*\*\)' <<<"$loop" | grep -qE 'exit|print_error'; then
    nok "unknown arguments are ignored (a catch-all arm refuses them; bolt-migrate passes --auto-upgrade=1)"
else
    ok "unknown arguments are ignored"
fi

if grep -qE 'almalinux\|rocky\|cloudlinux\)|cloudlinux\)' "$INSTALL_SH"; then ok "CloudLinux 9 accepted by detect_distribution"; else nok "CloudLinux 9 accepted by detect_distribution"; fi

# AB-2480: what bolt-migrate (internal/install) reads from the summary.
for line in '"${RED}CRITICAL${NC}" "$step"' '"${CYAN}CONVERSION${NC}" "$step"' '"${RED}STOPPED${NC}" "$STOPPED_STEP"' 'print_error "Stage 3 finished with failed critical components"'; do
    if grep -qF -- "$line" "$INSTALL_SH"; then ok "summary prints $line"; else nok "summary prints $line (bolt-migrate reads it)"; fi
done
for owned in 'postfix cpanel-exim' 'dovecot cpanel-dovecot' 'powerdns cpanel-pdns'; do
    if grep -qF -- "\"$owned\"" "$INSTALL_SH"; then ok "conversion leaves $owned to the cutover"; else nok "conversion leaves $owned to the cutover (bolt-migrate expects it)"; fi
done

# AB-2447: bolt-migrate (internal/install) reads this line to decide whether
# it passes --channel=convert.
if grep -qE '^REPORT_CHANNELS="([^"]* )?convert( [^"]*)?"$' "$INSTALL_SH"; then ok "REPORT_CHANNELS lists convert"; else nok "REPORT_CHANNELS lists convert (bolt-migrate passes --channel=convert)"; fi

echo "# passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
