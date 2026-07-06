#!/usr/bin/env bash
# Unit tests for the status-driven card responder (lib/gpg_card.sh
# gpg_card_drive) using a scripted fake gpg. Proves the safety properties
# that replace v1's blind expect scraping:
#   - answers menu/slot/PIN prompts from their FIFOs, in order
#   - fails closed on an unmapped prompt (never guesses)
#   - fails closed on GET_HIDDEN with no NEED_PASSPHRASE* (never leaks a secret
#     into the wrong field)
#   - aborts on BAD_PASSPHRASE and on PIN-queue exhaustion
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "${HERE}")
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"

# Put the fake gpg first on PATH.
export PATH="${HERE}/stubs:${PATH}"
chmod +x "${HERE}/stubs/gpg"

# shellcheck source=lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=lib/gpg_card.sh
source "${ROOT}/lib/gpg_card.sh"
set +e

TMP_GNUPGHOME=$(mktemp -d)
RUN_LOG=$(mktemp)
DRIVE_TIMEOUT=10
WORK=$(mktemp -d)
export FAKE_GPG_SCENARIO="${WORK}/scenario" FAKE_GPG_RECORD="${WORK}/record"
trap 'rm -rf "${TMP_GNUPGHOME}" "${RUN_LOG}" "${WORK}"' EXIT

run_drive() { # writes $1 as scenario, runs gpg_card_drive, sets RC/RECORD
  printf '%s\n' "$1" > "${FAKE_GPG_SCENARIO}"
  gpg_card_drive "unit" -- --fake >/dev/null 2>>"${RUN_LOG}"
  RC=$?
  RECORD=$(cat "${FAKE_GPG_RECORD}" 2>/dev/null)
}

# GnuPG under loopback emits every secret as `GET_HIDDEN passphrase.enter`
# with no NEED_PASSPHRASE and no distinct PIN/passphrase key. The scenarios
# below mirror the real protocol captured from GnuPG 2.x + YubiKey 5.2.7.

echo "== responder: keytocard mode (slot anchors key passphrase, admin PIN follows) =="
reset_drive_state
DRIVE_HIDDEN_MODE="keytocard"
DRIVE_CMDS=("key 1" "keytocard" "key 1" "key 2" "keytocard" "save")
DRIVE_SLOTS=(1 2)
DRIVE_PASSPHRASE="KEYPASS"
DRIVE_PINS=("ADMIN" "ADMIN" "ADMIN")
run_drive 'S GET_LINE keyedit.prompt
R c0
S GET_LINE keyedit.prompt
R c1
S GET_LINE cardedit.genkeys.storekeytype
R slot0
S GET_HIDDEN passphrase.enter
R h0
S GET_HIDDEN passphrase.enter
R h1
S GET_LINE keyedit.prompt
R c2
S GET_LINE keyedit.prompt
R c3
S GET_LINE keyedit.prompt
R c4
S GET_LINE cardedit.genkeys.storekeytype
R slot1
S GET_HIDDEN passphrase.enter
R h2
S GET_LINE keyedit.prompt
R c5
X 0'
t "keytocard returns 0"; assert_eq "${RC}" "0"
t "slot 1 selected then slot 2"; assert_contains "${RECORD}" "slot0=1"
t "second slot answered"; assert_contains "${RECORD}" "slot1=2"
t "subkey 1: first hidden = key passphrase"; assert_contains "${RECORD}" "h0=KEYPASS"
t "subkey 1: second hidden = admin PIN"; assert_contains "${RECORD}" "h1=ADMIN"
t "subkey 2: first hidden after slot = key passphrase again (own keygrip)"; assert_contains "${RECORD}" "h2=KEYPASS"
t "save sent"; assert_contains "${RECORD}" "c5=save"

echo "== responder: pin mode (change-pin: current,new,new from FIFO in order) =="
reset_drive_state   # DRIVE_HIDDEN_MODE defaults to pin
DRIVE_CMDS=("1" "q")
DRIVE_PINS=("CUR" "NEW" "NEW")
run_drive 'S GET_LINE cardutil.change_pin.menu
R m0
S GET_HIDDEN passphrase.enter
R p0
S GET_HIDDEN passphrase.enter
R p1
S GET_HIDDEN passphrase.enter
R p2
S SC_OP_SUCCESS
S GET_LINE cardutil.change_pin.menu
R m1
X 0'
t "change-pin returns 0"; assert_eq "${RC}" "0"
t "menu option then quit"; { assert_contains "${RECORD}" "m0=1"; assert_contains "${RECORD}" "m1=q"; }
t "PINs sent in order current,new,new"; { assert_contains "${RECORD}" "p0=CUR"; assert_contains "${RECORD}" "p1=NEW"; assert_contains "${RECORD}" "p2=NEW"; }

echo "== responder: fail-closed on an unmapped prompt =="
reset_drive_state
DRIVE_CMDS=("something")
run_drive 'S GET_LINE keyedit.prompt
R cmd1
S GET_LINE some.unknown.prompt
R never
X 0'
t "unmapped prompt aborts (non-zero)"; assert_fail test "${RC}" -eq 0
t "did not answer the unknown prompt"; assert_fail grep -q "never=" "${FAKE_GPG_RECORD}"

echo "== responder: abort on BAD_PASSPHRASE =="
reset_drive_state
DRIVE_PINS=("0000")
run_drive 'S GET_HIDDEN passphrase.enter
R pin
S BAD_PASSPHRASE OPENPGP.3
X 2'
t "BAD_PASSPHRASE aborts (non-zero)"; assert_fail test "${RC}" -eq 0

echo "== responder: abort on SC_OP_FAILURE =="
reset_drive_state
DRIVE_PINS=("12345678")
run_drive 'S GET_HIDDEN passphrase.enter
R pin
S SC_OP_FAILURE
X 2'
t "SC_OP_FAILURE aborts (non-zero)"; assert_fail test "${RC}" -eq 0

echo "== responder: abort on PIN-queue exhaustion (no reuse/guessing) =="
reset_drive_state
DRIVE_PINS=("11111111")   # only one PIN available
run_drive 'S GET_HIDDEN passphrase.enter
R pin1
S GET_HIDDEN passphrase.enter
R pin2
X 0'
t "second PIN request with empty queue aborts"; assert_fail test "${RC}" -eq 0
t "first PIN was sent exactly once"; assert_contains "$(cat "${FAKE_GPG_RECORD}")" "pin1=11111111"
t "did not reuse a PIN for the second request"; assert_fail grep -q "pin2=" "${FAKE_GPG_RECORD}"

summary
