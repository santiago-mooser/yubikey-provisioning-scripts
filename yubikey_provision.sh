#!/usr/bin/env bash
#
# yubikey_provision.sh — provision a YubiKey's OpenPGP applet with a fresh
# certify-only master key and sign/encrypt/auth subkeys, generated on the
# host and moved to the card.
#
# v2 rewrite: batch gpg interfaces + a status-driven responder instead of
# expect prompt-scraping; safe ordering (artifacts exported before the
# destructive card transfer); opt-in keyserver upload; single secret summary.
#
# See --help for options and README.md for the full workflow and caveats.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/gpg_keys.sh
source "${SCRIPT_DIR}/lib/gpg_keys.sh"
# shellcheck source=lib/gpg_card.sh
source "${SCRIPT_DIR}/lib/gpg_card.sh"

# ------------------------------------------------------------- defaults

YESMODE=0
BACKUP_MASTER=0
DO_UPLOAD=0
KEY_ALGO="rsa4096"
KEY_EXPIRY="2y"
TOUCH_POLICY="cached"
KEYSERVER="https://keys.openpgp.org"
OUTPUT_DIR=""
YK_SERIAL=""
FIRST_NAME="" LAST_NAME="" KEY_EMAIL="" KEY_COMMENT="" CARD_LOGIN=""
KEY_PASSPHRASE="" USER_PIN="" ADMIN_PIN=""
KEY_FPR="" CARD_URL="" KEY_UID=""
SUBKEY_FPRS=()

# Factory OpenPGP defaults the card starts from after a reset.
CARD_USER_CURRENT="123456"
CARD_ADMIN_CURRENT="12345678"

usage() {
  cat <<EOF
${0##*/} v${VERSION}

Provision a connected YubiKey's OpenPGP applet: factory-reset it, generate a
new master key + 3 subkeys on this host, move the subkeys to the card, set
PINs and touch policy, and export the public key and revocation certificate.

Usage: ${0##*/} --email <addr> [options]

Identity:
  -e, --email <addr>       Email for the key UID (required; prompted if omitted).
  -f, --first-name <name>  First name (also written to the card as given name).
  -l, --last-name <name>   Last name  (also written to the card as surname).
  -c, --comment <text>     UID comment.
      --login <text>       Card login/account name (defaults to email).

Key parameters:
      --algo <rsa4096|ed25519>  Key algorithm (default: rsa4096;
                                ed25519 needs card firmware 5.2.3+).
      --expiry <spec>      Subkey expiry: e.g. 2y, 18m, 730d, 0=never,
                           or YYYY-MM-DD (default: 2y).
      --touch <off|on|fixed|cached|cached-fixed>
                           Touch policy for all key slots (default: cached).

Secrets (all generated with a CSPRNG if omitted; shown once at the end):
  -p, --passphrase <str>   Master-key passphrase.
  -u, --user-pin <pin>     New card user PIN  (>= 6 chars).
  -a, --admin-pin <pin>    New card admin PIN (>= 8 chars).

Output / distribution:
  -o, --output-dir <dir>   Where to write public-key.asc, revocation cert, and
                           (with --backup-master) the secret key backup.
                           Default: ./yubikey-<fpr8>-<user>.
      --backup-master      Also export the master + subkey secret keys to the
                           output dir (encrypted with the passphrase). Off by
                           default — see README on why you may want this.
      --upload             Upload the public key to the keyserver (opt-in).
      --keyserver <url>    Keyserver for --upload (default: ${KEYSERVER}).
      --serial <serial>    Target a specific YubiKey when several are attached.

Misc:
  -y, --yes                Do not prompt for confirmation (non-interactive).
  -h, --help               Show this help and exit.
  -v, --version            Print version and exit.

WARNING: this FACTORY-RESETS the connected YubiKey's OpenPGP applet,
irreversibly erasing any OpenPGP keys already on it.
EOF
}

# ------------------------------------------------------------- arg parse

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -e|--email)        KEY_EMAIL=$2; shift 2 ;;
      -f|--first-name)   FIRST_NAME=$2; shift 2 ;;
      -l|--last-name)    LAST_NAME=$2; shift 2 ;;
      -c|--comment)      KEY_COMMENT=$2; shift 2 ;;
      --login)           CARD_LOGIN=$2; shift 2 ;;
      --algo)            KEY_ALGO=$2; shift 2 ;;
      --expiry)          KEY_EXPIRY=$2; shift 2 ;;
      --touch)           TOUCH_POLICY=$2; shift 2 ;;
      -p|--passphrase)   KEY_PASSPHRASE=$2; shift 2 ;;
      -u|--user-pin)     USER_PIN=$2; shift 2 ;;
      -a|--admin-pin)    ADMIN_PIN=$2; shift 2 ;;
      -o|--output-dir)   OUTPUT_DIR=$2; shift 2 ;;
      --backup-master)   BACKUP_MASTER=1; shift ;;
      --upload)          DO_UPLOAD=1; shift ;;
      --keyserver)       KEYSERVER=$2; shift 2 ;;
      --serial)          YK_SERIAL=$2; shift 2 ;;
      -y|--yes)          YESMODE=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      -v|--version)      echo "${VERSION}"; exit 0 ;;
      --) shift; break ;;
      -*) die "Unknown option: $1 (see --help)." ;;
      *)  die "Unexpected argument: $1 (see --help)." ;;
    esac
  done
}

# ---------------------------------------------------- validation & setup

detect_os() {
  case "$(uname -s)" in
    Linux*)  MACHINE=Linux ;;
    Darwin*) MACHINE=Mac ;;
    *)       die "Unsupported OS: $(uname -s)." ;;
  esac
}

resolve_config() {
  if [[ -z ${KEY_EMAIL} ]]; then
    (( YESMODE )) && die "--email is required in --yes mode."
    while :; do
      read -r -p "Email for the PGP key: " KEY_EMAIL
      validate_email "${KEY_EMAIL}" && break
      warn "Invalid email; expected local@domain.tld."
    done
  fi
  validate_email "${KEY_EMAIL}" || die "Invalid email: ${KEY_EMAIL}"

  [[ ${KEY_ALGO} == rsa4096 || ${KEY_ALGO} == ed25519 ]] || die "--algo must be rsa4096 or ed25519."
  validate_expiry "${KEY_EXPIRY}"
  case ${TOUCH_POLICY} in off|on|fixed|cached|cached-fixed) ;; *) die "--touch must be off|on|fixed|cached|cached-fixed." ;; esac

  [[ -n ${KEY_PASSPHRASE} ]] || KEY_PASSPHRASE=$(random_passphrase)
  [[ -n ${USER_PIN} ]]  || USER_PIN=$(random_digits 6)
  [[ -n ${ADMIN_PIN} ]] || ADMIN_PIN=$(random_digits 8)
  validate_pin "User PIN" "${USER_PIN}" 6
  validate_pin "Admin PIN" "${ADMIN_PIN}" 8

  local name
  if [[ -n ${FIRST_NAME}${LAST_NAME} ]]; then
    name=$(printf '%s %s' "${FIRST_NAME}" "${LAST_NAME}"); name=${name## }; name=${name%% }
  else
    name=${USER_NAME}
  fi
  (( ${#name} >= 5 )) || die "Key name '${name}' is under 5 characters (gpg requires >= 5); pass --first-name/--last-name."
  KEY_UID=${name}
  [[ -n ${KEY_COMMENT} ]] && KEY_UID+=" (${KEY_COMMENT})"
  KEY_UID+=" <${KEY_EMAIL}>"

  [[ -n ${CARD_LOGIN} ]] || CARD_LOGIN=${KEY_EMAIL}
}

# Referenced by cleanup() in common.sh to tell the operator what state the
# hardware is in after an abort.
card_state_hint() {
  case ${PROVISION_STAGE} in
    "not started"|"selecting yubikey")
      echo "Card was not modified. Safe to re-run." ;;
    "factory reset")
      echo "Card was reset to factory defaults (no keys). Safe to re-run." ;;
    "generating keys"|"exporting artifacts")
      echo "Card was factory-reset but no keys were transferred. Re-run to provision." ;;
    "transferring keys to card")
      echo "Key transfer was interrupted; the card may hold a partial key set. Re-run (it factory-resets first)." ;;
    "setting touch policy"|"changing card user PIN")
      echo "Keys are on the card. User PIN is still ${CARD_USER_CURRENT}, admin PIN ${CARD_ADMIN_CURRENT}. Re-running factory-resets and starts over." ;;
    "changing card admin PIN")
      echo "Keys are on the card and the user PIN is set. Admin PIN is still ${CARD_ADMIN_CURRENT}; set it with 'gpg --change-pin' (option 3)." ;;
    "setting card attributes"|"uploading key"|"done")
      echo "Keys, PINs and touch policy are set; the key is usable. Only card attributes/upload remained." ;;
    *) echo "State unknown — inspect with: gpg --card-status" ;;
  esac
}

# ------------------------------------------------------------- pipeline

print_plan() {
  info "Provisioning plan:"
  info "  Key UID:        ${KEY_UID}"
  info "  Algorithm:      ${KEY_ALGO}"
  info "  Subkey expiry:  ${KEY_EXPIRY}"
  info "  Touch policy:   ${TOUCH_POLICY}"
  info "  Output dir:     ${OUTPUT_DIR}"
  info "  Backup master:  $( ((BACKUP_MASTER)) && echo 'yes (secret key WILL be exported)' || echo 'no' )"
  info "  Upload:         $( ((DO_UPLOAD)) && echo "yes -> ${KEYSERVER}" || echo 'no' )"
  info "  YubiKey serial: ${YK_SERIAL}"
}

upload_key() {
  info "Uploading public key to ${KEYSERVER} ..."
  if ! curl -fsS --data-urlencode "keytext@${OUTPUT_DIR}/public-key.asc" \
        "${KEYSERVER}/vks/v1/upload" >>"${RUN_LOG}" 2>&1; then
    warn "Keyserver upload failed. The key is on the card and saved locally; upload later with:"
    warn "  gpg --keyserver ${KEYSERVER} --send-keys ${KEY_FPR}"
    return 1
  fi
  CARD_URL="${KEYSERVER}/vks/v1/by-fingerprint/${KEY_FPR^^}"
  info "Upload accepted. NOTE: keys.openpgp.org serves the UID only after you verify the email;"
  info "until then a 'fetch' from the card URL returns a key without identity (stock gpg rejects it)."
}

final_summary() {
  local backup_lines="" backup_note upload_note=""
  if (( BACKUP_MASTER )); then
    backup_lines=$'\n  master-secret-key.asc       (OFFLINE backup — needed to renew/extend subkeys)\n  secret-subkeys.asc'
    backup_note="is backed up in the output dir above."
  else
    backup_note="was NOT backed up: you cannot extend subkey expiry or add subkeys later. Re-run with --backup-master if you need that."
  fi
  (( DO_UPLOAD )) && [[ -n ${CARD_URL} ]] && upload_note="Uploaded to ${KEYSERVER} (verify the email to publish the UID)."

  cat >&2 <<EOF

==================== PROVISIONING COMPLETE ====================
Record these secrets now — they are shown only once and were not written to
disk (except a --backup-master export, if you asked for one).

  Key fingerprint  : ${KEY_FPR}
  Key UID          : ${KEY_UID}
  Master passphrase: ${KEY_PASSPHRASE}
  Card user PIN    : ${USER_PIN}
  Card admin PIN   : ${ADMIN_PIN}
  Subkey expiry    : $(subkey_expiry_date)
  Touch policy     : ${TOUCH_POLICY}

Artifacts written to ${OUTPUT_DIR}:
  public-key.asc              (import on your machines / share)
  revocation-certificate.asc  (store OFFLINE; revokes a lost key)${backup_lines}

The master secret key is NOT on the card and ${backup_note}
${upload_note}
==============================================================
EOF
}

main() {
  require_not_root
  detect_os
  parse_args "$@"

  if [[ -n ${SUDO_USER-} ]]; then USER_NAME=${SUDO_USER}; else USER_NAME=${USER-user}; fi

  # Validate arguments first (pure, no external tools) so a typo is reported
  # without needing the hardware toolchain installed. Then gate on deps.
  resolve_config
  require_deps gpg gpgconf ykman curl
  install_traps

  PROVISION_STAGE="selecting yubikey"
  select_yubikey

  [[ -n ${OUTPUT_DIR} ]] || OUTPUT_DIR="__AUTO__"

  print_plan
  warn "This will FACTORY-RESET the OpenPGP applet on YubiKey serial ${YK_SERIAL}."
  confirm "Proceed?" || die "Aborted by user."

  setup_tmp_gnupghome

  PROVISION_STAGE="factory reset"
  info "Factory-resetting OpenPGP applet on ${YK_SERIAL} ..."
  card_factory_reset

  PROVISION_STAGE="generating keys"
  info "Generating ${KEY_ALGO} master key ..."
  generate_master_key "${KEY_UID}"
  info "Master key: ${KEY_FPR}"
  info "Generating subkeys (sign/encrypt/auth, expiry ${KEY_EXPIRY}) ..."
  generate_subkeys

  [[ ${OUTPUT_DIR} == "__AUTO__" ]] && OUTPUT_DIR="./yubikey-${KEY_FPR: -8}-${USER_NAME}"

  PROVISION_STAGE="exporting artifacts"
  info "Exporting public key and revocation certificate to ${OUTPUT_DIR} ..."
  export_artifacts

  PROVISION_STAGE="transferring keys to card"
  info "Moving subkeys to the card (this destroys the on-disk subkey secrets) ..."
  keytocard_subkeys
  verify_keys_on_card
  info "All three subkeys confirmed on the card."

  PROVISION_STAGE="setting touch policy"
  if [[ ${TOUCH_POLICY} != off ]]; then
    info "Setting touch policy '${TOUCH_POLICY}' on all slots ..."
    set_touch_policy "${TOUCH_POLICY}"
  fi

  change_card_pins

  PROVISION_STAGE="setting card attributes"
  set_card_attributes

  if (( DO_UPLOAD )); then
    PROVISION_STAGE="uploading key"
    upload_key || true
  fi

  test_signature || true

  PROVISION_STAGE="done"
  final_summary
}

main "$@"
