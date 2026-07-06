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

echo "== responder: happy path (menu + slot + PIN FIFOs, in order) =="
reset_drive_state
DRIVE_CMDS=("key 1" "keytocard" "save")
DRIVE_SLOTS=(1)
DRIVE_PINS=("12345678")
DRIVE_MAP=(["keyedit.save.okay"]="y")
run_drive 'S GET_LINE keyedit.prompt
R cmd1
S GET_LINE keyedit.prompt
R cmd2
S GET_LINE cardedit.genkeys.storekeytype
R slot
S NEED_PASSPHRASE_PIN OPENPGP.3 1
S GET_HIDDEN passphrase.pin.ask
R pin
S GET_LINE keyedit.prompt
R cmd3
S GET_BOOL keyedit.save.okay
R saveokay
X 0'
t "happy path returns 0"; assert_eq "${RC}" "0"
t "menu FIFO answered in order (key 1)"; assert_contains "${RECORD}" "cmd1=key 1"
t "menu FIFO answered in order (keytocard)"; assert_contains "${RECORD}" "cmd2=keytocard"
t "slot FIFO answered"; assert_contains "${RECORD}" "slot=1"
t "PIN dispatched to GET_HIDDEN after NEED_PASSPHRASE_PIN"; assert_contains "${RECORD}" "pin=12345678"
t "save command sent"; assert_contains "${RECORD}" "cmd3=save"
t "mapped GET_BOOL answered"; assert_contains "${RECORD}" "saveokay=y"

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

echo "== responder: fail-closed on GET_HIDDEN with no NEED_PASSPHRASE* =="
reset_drive_state
DRIVE_PINS=("12345678")
run_drive 'S GET_HIDDEN passphrase.pin.ask
R leaked
X 0'
t "bare GET_HIDDEN aborts (refuses to guess a secret)"; assert_fail test "${RC}" -eq 0
t "no secret was sent into the unguarded field"; assert_fail grep -q "leaked=" "${FAKE_GPG_RECORD}"

echo "== responder: abort on BAD_PASSPHRASE =="
reset_drive_state
DRIVE_PINS=("0000")
run_drive 'S NEED_PASSPHRASE_PIN OPENPGP.3 1
S GET_HIDDEN passphrase.pin.ask
R pin
S BAD_PASSPHRASE OPENPGP.3
X 2'
t "BAD_PASSPHRASE aborts (non-zero)"; assert_fail test "${RC}" -eq 0

echo "== responder: abort on PIN-queue exhaustion (no reuse/guessing) =="
reset_drive_state
DRIVE_PINS=("11111111")   # only one PIN available
run_drive 'S NEED_PASSPHRASE_PIN OPENPGP.3 1
S GET_HIDDEN passphrase.pin.ask
R pin1
S NEED_PASSPHRASE_PIN OPENPGP.3 1
S GET_HIDDEN passphrase.pin.ask
R pin2
X 0'
t "second PIN request with empty queue aborts"; assert_fail test "${RC}" -eq 0
t "first PIN was sent exactly once"; assert_contains "$(cat "${FAKE_GPG_RECORD}")" "pin1=11111111"
t "did not reuse a PIN for the second request"; assert_fail grep -q "pin2=" "${FAKE_GPG_RECORD}"

summary
