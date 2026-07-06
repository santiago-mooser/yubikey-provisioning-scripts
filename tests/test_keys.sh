#!/usr/bin/env bash
# Integration test for lib/gpg_keys.sh against a REAL gpg (no smartcard).
# Uses ed25519 so keygen is instant. Verifies the batch keygen, subkey
# generation, artifact export, expiry recording, and master-key backup.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "${HERE}")
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"

# Provide the globals the lib expects, then source it. common.sh turns on
# errexit; run the lib calls in a subshell-free way but tolerate failures via
# the harness (we check outcomes explicitly).
# shellcheck source=lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=lib/gpg_keys.sh
source "${ROOT}/lib/gpg_keys.sh"
set +e  # the harness inspects results rather than aborting

MACHINE=Linux
KEY_ALGO=ed25519
KEY_EXPIRY=2y
KEY_PASSPHRASE="test-pass-$$"
BACKUP_MASTER=1
OUTPUT_DIR=$(mktemp -d)
trap 'rm -rf "${OUTPUT_DIR}" "${TMP_GNUPGHOME:-}"' EXIT

echo "== lib/gpg_keys.sh integration (real gpg, ed25519) =="

setup_tmp_gnupghome
t "tmp homedir created 0700"
assert_eq "$(stat -c '%a' "${TMP_GNUPGHOME}")" "700"

t "passphrase file written, not world-readable"
assert_eq "$(stat -c '%a' "${PASSPHRASE_FILE}")" "600"

generate_master_key "Test User <test@example.com>"
t "master key fingerprint captured (40 hex)"
if [[ ${KEY_FPR} =~ ^[0-9A-F]{40}$ ]]; then pass; else fail "bad fpr: ${KEY_FPR}"; fi

generate_subkeys
t "exactly 3 subkeys generated"
assert_eq "${#SUBKEY_FPRS[@]}" "3"

export_artifacts
t "public key exported"
assert_file "${OUTPUT_DIR}/public-key.asc"
t "public key is a real armored block"
assert_contains "$(cat "${OUTPUT_DIR}/public-key.asc")" "BEGIN PGP PUBLIC KEY BLOCK"
t "revocation certificate exported"
assert_file "${OUTPUT_DIR}/revocation-certificate.asc"
t "master secret key backed up (--backup-master)"
assert_file "${OUTPUT_DIR}/master-secret-key.asc"
t "secret subkeys backed up"
assert_file "${OUTPUT_DIR}/secret-subkeys.asc"
t "backup files are 0600"
assert_eq "$(stat -c '%a' "${OUTPUT_DIR}/master-secret-key.asc")" "600"

t "subkey expiry ~2y out (not never)"
exp=$(subkey_expiry_date)
if [[ ${exp} =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
  yr_now=$(date +%Y); yr_exp=${exp%%-*}
  if (( yr_exp == yr_now + 1 || yr_exp == yr_now + 2 )); then pass; else fail "expiry year ${yr_exp} not ~2y from ${yr_now}"; fi
else
  fail "expiry not a date: ${exp}"
fi

t "public export omits secret material"
assert_fail grep -q "PRIVATE KEY" "${OUTPUT_DIR}/public-key.asc"

# Confirm the on-disk secret keys still exist here (keytocard would stub them,
# but this test never touches a card).
t "master secret present in temp keyring"
assert_contains "$(gpg_ --list-secret-keys --with-colons 2>/dev/null)" "${KEY_FPR}"

summary
