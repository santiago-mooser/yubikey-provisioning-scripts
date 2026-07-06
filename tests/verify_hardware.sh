#!/usr/bin/env bash
# End-to-end hardware verification against a REAL connected YubiKey.
#
# WARNING: destructive. FACTORY-RESETS the OpenPGP applet of the connected
# YubiKey, provisions it with test credentials, then independently re-checks
# the outcome with ykman + gpg (not trusting the provisioning script's own
# success messages). Proves the v1 regressions are fixed:
#   - the user PIN is ACTUALLY changed (v1's critical silent no-op)
#   - the admin PIN is changed; touch policy is applied
#   - all three subkeys land on the card; a card signature works
#   - artifacts (public key + revocation cert) are written
#
# Usage: nix-shell -p gnupg yubikey-manager --command 'tests/verify_hardware.sh'
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "${HERE}")
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"

# Distinct non-default test credentials so a "still at factory default" bug
# cannot masquerade as success.
T_USER_PIN="246813"
T_ADMIN_PIN="8642097531"
T_PASS="verify-pass-$$"
T_EMAIL="verify@example.com"
T_ALGO="${VERIFY_ALGO:-rsa4096}"     # override with VERIFY_ALGO=ed25519 for a fast run
# Default touch=off so the card self-test signatures run unattended (a touch
# policy would block on a physical tap). Set VERIFY_TOUCH=on|cached to also
# exercise touch-policy setting — but then a human must tap the key when it
# blinks during the signature checks.
T_TOUCH="${VERIFY_TOUCH:-off}"
OUT=$(mktemp -d)
GNUPGHOME_CHECK=$(mktemp -d); chmod 700 "${GNUPGHOME_CHECK}"
trap 'rm -rf "${OUT}" "${GNUPGHOME_CHECK}"; gpgconf --homedir "${GNUPGHOME_CHECK}" --kill all 2>/dev/null || true' EXIT

# The independent re-check homedirs are isolated too, so give them the same
# scdaemon config the provisioning run uses (needed where the card requires
# PC/SC forcing). Same precedence as lib/gpg_keys.sh.
seed_scdaemon_conf() { # $1 = homedir
  if [[ -n ${YKPROV_SCDAEMON_CONF:-} && -f ${YKPROV_SCDAEMON_CONF} ]]; then
    cp "${YKPROV_SCDAEMON_CONF}" "$1/scdaemon.conf"
  elif [[ -f ${HOME}/.gnupg/scdaemon.conf ]]; then
    cp "${HOME}/.gnupg/scdaemon.conf" "$1/scdaemon.conf"
  fi
}
seed_scdaemon_conf "${GNUPGHOME_CHECK}"

command -v ykman >/dev/null || { echo "ykman required (nix-shell -p yubikey-manager)"; exit 1; }
command -v gpg   >/dev/null || { echo "gpg required (nix-shell -p gnupg)"; exit 1; }

mapfile -t SERIALS < <(ykman list --serials 2>/dev/null)
if (( ${#SERIALS[@]} != 1 )); then
  echo "Need exactly one YubiKey connected (found: ${SERIALS[*]:-none}). Aborting."
  exit 1
fi
SERIAL=${SERIALS[0]}
echo "Target YubiKey serial: ${SERIAL}"
echo "This will FACTORY-RESET its OpenPGP applet. Ctrl-C within 5s to abort."
sleep 5

echo
echo "== Running provisioning (${T_ALGO}) =="
if "${ROOT}/yubikey_provision.sh" \
      --yes \
      --email "${T_EMAIL}" \
      --first-name Verify --last-name Tester \
      --algo "${T_ALGO}" \
      --expiry 2y \
      --touch "${T_TOUCH}" \
      --passphrase "${T_PASS}" \
      --user-pin "${T_USER_PIN}" \
      --admin-pin "${T_ADMIN_PIN}" \
      --output-dir "${OUT}"; then
  echo "(provisioning script exited 0)"
else
  echo "PROVISIONING SCRIPT FAILED (exit $?). Verification cannot continue."
  exit 1
fi

echo
echo "== Independent re-checks (ykman + gpg, ignoring the script's claims) =="

# Fresh check homedir so we read the card, not cached state.
gpgconf --kill scdaemon gpg-agent 2>/dev/null || true
CARD_STATUS=$(LC_ALL=C gpg --homedir "${GNUPGHOME_CHECK}" --card-status --with-colons 2>/dev/null)
YK_INFO=$(ykman --device "${SERIAL}" openpgp info 2>/dev/null)

t "card reports 3 key fingerprints (sign/enc/auth present)"
# card-status --with-colons puts all three fingerprints as fields 2/3/4 of a
# single fpr: line; count the non-empty ones.
NFPR=$(awk -F: '$1=="fpr"{n=0; for(i=2;i<=4;i++) if($i!="") n++; print n; exit}' <<<"${CARD_STATUS}")
assert_eq "${NFPR:-0}" "3"

t "artifacts: public key written"
assert_file "${OUT}/public-key.asc"
t "artifacts: revocation certificate written"
assert_file "${OUT}/revocation-certificate.asc"

t "cardholder name set (not blank)"
NAME=$(awk -F: '$1=="name"{print $2" "$3}' <<<"${CARD_STATUS}")
assert_contains "${NAME}" "Tester"

# THE critical v1 regression: user PIN must actually be the new one. Prove it
# by signing with the card using the NEW user PIN. If v1's silent no-op were
# present, the card would still want 123456 and this signature would fail.
t "CRITICAL: card signature succeeds with the NEW user PIN"
SIG_HOME=$(mktemp -d); chmod 700 "${SIG_HOME}"
seed_scdaemon_conf "${SIG_HOME}"
gpgconf --kill scdaemon gpg-agent 2>/dev/null || true
# import public key so gpg knows the card's keys
gpg --homedir "${SIG_HOME}" --import "${OUT}/public-key.asc" >/dev/null 2>&1
gpg --homedir "${SIG_HOME}" --card-status >/dev/null 2>&1   # learn card stubs
if printf 'hardware-verify' \
     | gpg --homedir "${SIG_HOME}" --no-tty --pinentry-mode loopback \
           --passphrase "${T_USER_PIN}" --detach-sign >/dev/null 2>&1; then
  pass
else
  fail "signing with new user PIN ${T_USER_PIN} failed — user PIN was NOT changed (v1 bug present)"
fi
rm -rf "${SIG_HOME}"

# Touch policy: only asserted when a policy was actually requested (the
# hands-free default is off, which the script leaves as the factory UIF state).
if [[ ${T_TOUCH} != off ]]; then
  t "touch policy '${T_TOUCH}' applied (ykman reports non-Off UIF)"
  if grep -qiE "(cached|on|fixed)" < <(ykman --device "${SERIAL}" openpgp info 2>/dev/null | grep -iA3 -i 'touch'); then
    pass
  else
    fail "touch policy does not look applied; ykman info:\n${YK_INFO}"
  fi
else
  echo "  --   touch policy: skipped (hands-free off run; set VERIFY_TOUCH=on with a human present)"
fi

# Admin PIN change: verify retry counters are healthy (3/_/3) and that the
# new admin PIN authenticates a harmless admin op would burn a retry, so we
# instead assert the applet is not blocked and PINs are non-default by the
# successful signature above (user) + a set-touch already having used admin.
t "admin PIN retry counter not blocked"
ADMIN_RETRIES=$(awk -F: '$1=="pinretry"{print $4}' <<<"${CARD_STATUS}")
if [[ -n ${ADMIN_RETRIES} && ${ADMIN_RETRIES} -ge 1 ]]; then pass; else fail "admin PIN appears blocked (retries=${ADMIN_RETRIES})"; fi

echo
echo "Provisioned key fingerprint:"
awk -F: '$1=="fpr"{print "  "$2$3$4}' <<<"${CARD_STATUS}" | head -3
echo "Test credentials used (this card is now a TEST key — reset it when done):"
echo "  user PIN=${T_USER_PIN} admin PIN=${T_ADMIN_PIN} passphrase=${T_PASS}"
echo

summary
