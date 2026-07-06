#!/usr/bin/env bash
# CLI / argument-validation tests for yubikey_provision.sh. These exercise
# the parsing and validation paths that run before any hardware is touched,
# so they need no YubiKey. Missing-dependency and hardware paths are covered
# separately (real card / stub gpg).
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "${HERE}")
SCRIPT="${ROOT}/yubikey_provision.sh"
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"

run() { "${SCRIPT}" "$@" >/tmp/cli_out.$$ 2>&1; echo $?; }
out() { cat /tmp/cli_out.$$; }
trap 'rm -f /tmp/cli_out.$$' EXIT

help_has() { "${SCRIPT}" --help 2>&1 | grep -q "$@"; }

echo "== CLI: help / version =="
t "--version prints the version";  assert_eq "$("${SCRIPT}" --version)" "2.0.0"
t "--help exits 0";                assert_eq "$(run --help)" "0"
t "--help mentions factory reset"; assert_grep "no reset warning in help" help_has -i "factory-reset"
t "--help documents --upload opt-in"; assert_grep "no --upload in help" help_has -- "--upload"
t "--help documents --backup-master"; assert_grep "no --backup-master" help_has -- "--backup-master"

echo "== CLI: unknown / malformed args rejected =="
t "unknown option is rejected";    assert_eq "$(run --frobnicate)" "1"
t "unknown option names itself";   assert_contains "$(run --nope 2>&1; out)" "Unknown option"

echo "== CLI: validation rejects bad input (before any hardware) =="
# --yes makes email required and skips prompts, so these fail in validation.
t "invalid email rejected";        assert_eq "$(run --yes --email not-an-email)" "1"
t "invalid email message";         { run --yes --email nope >/dev/null; assert_contains "$(out)" "Invalid email"; }
t "TLD > 4 chars now ACCEPTED (v1 bug fixed)";
  # company.online must pass validation; it will fail later for lack of a card,
  # but not with an "Invalid email" message.
  run --yes --email "user@company.online" >/dev/null
  if grep -q "Invalid email" /tmp/cli_out.$$; then fail "company.online wrongly rejected"; else pass; fi
t "short user PIN rejected";       { run --yes --email a@b.com --user-pin 123 >/dev/null; assert_contains "$(out)" "User PIN must be"; }
t "short admin PIN rejected";      { run --yes --email a@b.com --admin-pin 123 >/dev/null; assert_contains "$(out)" "Admin PIN must be"; }
t "bad --algo rejected";           { run --yes --email a@b.com --algo rsa1024 >/dev/null; assert_contains "$(out)" "algo must be"; }
t "bad --expiry rejected";         { run --yes --email a@b.com --expiry banana >/dev/null; assert_contains "$(out)" "Invalid --expiry"; }
t "bad --touch rejected";          { run --yes --email a@b.com --touch sometimes >/dev/null; assert_contains "$(out)" "touch must be"; }
t "missing --email in --yes mode"; { run --yes >/dev/null; assert_contains "$(out)" "email is required"; }

summary
