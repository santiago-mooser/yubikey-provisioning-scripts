# shellcheck shell=bash
# GnuPG key operations against an ephemeral GNUPGHOME, using batch
# interfaces only (--quick-generate-key / --quick-add-key). No prompt
# scraping: every call either succeeds or the script aborts.

# All gpg invocations share these flags. LC_ALL=C so output parsing is
# locale-independent; loopback + passphrase-file keeps secrets off argv.
gpg_() {
  LC_ALL=C gpg --homedir "${TMP_GNUPGHOME}" --batch --no-tty \
    --pinentry-mode loopback --passphrase-file "${PASSPHRASE_FILE}" "$@"
}

setup_tmp_gnupghome() {
  local base
  if [[ ${MACHINE} == Linux && -d /dev/shm ]]; then
    base=$(mktemp -d /dev/shm/ykprov.XXXXXX)
  else
    base=$(mktemp -d) # macOS: plain disk; cleanup shreds, README documents limits
  fi
  chmod 700 "${base}"
  TMP_GNUPGHOME=${base}
  RUN_LOG="${base}/run.log"
  : > "${RUN_LOG}"

  PASSPHRASE_FILE="${base}/passphrase"
  (umask 077 && printf '%s' "${KEY_PASSPHRASE}" > "${PASSPHRASE_FILE}")

  # An isolated GNUPGHOME does not see the host's smartcard configuration.
  # If the card needs specific scdaemon settings (e.g. forcing PC/SC on some
  # systems), inherit them: an explicit YKPROV_SCDAEMON_CONF wins, otherwise
  # copy the user's ~/.gnupg/scdaemon.conf if present.
  if [[ -n ${YKPROV_SCDAEMON_CONF:-} && -f ${YKPROV_SCDAEMON_CONF} ]]; then
    cp "${YKPROV_SCDAEMON_CONF}" "${base}/scdaemon.conf"
  elif [[ -f ${HOME}/.gnupg/scdaemon.conf ]]; then
    cp "${HOME}/.gnupg/scdaemon.conf" "${base}/scdaemon.conf"
  fi

  cat > "${base}/gpg.conf" <<'EOF'
personal-cipher-preferences AES256 AES192 AES
personal-digest-preferences SHA512 SHA384 SHA256
personal-compress-preferences ZLIB BZIP2 ZIP Uncompressed
default-preference-list SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed
cert-digest-algo SHA512
s2k-digest-algo SHA512
s2k-cipher-algo AES256
charset utf-8
no-comments
no-emit-version
keyid-format 0xlong
with-fingerprint
require-cross-certification
no-symkey-cache
EOF
}

# Master key: certify-only, never expires (subkeys carry the expiry).
generate_master_key() {
  local uid=$1 algo
  case ${KEY_ALGO} in
    rsa4096) algo="rsa4096" ;;
    ed25519) algo="ed25519" ;;
  esac
  gpg_ --quick-generate-key "${uid}" "${algo}" cert never >>"${RUN_LOG}" 2>&1 \
    || die "Master key generation failed (see gpg output above)."

  KEY_FPR=$(gpg_ --list-secret-keys --with-colons 2>>"${RUN_LOG}" \
    | awk -F: '$1=="fpr" {print $10; exit}')
  [[ -n ${KEY_FPR} ]] || die "Master key generated but fingerprint not found."
}

generate_subkeys() {
  local usage algo
  for usage in sign encrypt auth; do
    case ${KEY_ALGO} in
      rsa4096) algo="rsa4096" ;;
      ed25519) [[ ${usage} == encrypt ]] && algo="cv25519" || algo="ed25519" ;;
    esac
    gpg_ --quick-add-key "${KEY_FPR}" "${algo}" "${usage}" "${KEY_EXPIRY}" \
      >>"${RUN_LOG}" 2>&1 || die "Failed to add ${usage} subkey."
  done

  mapfile -t SUBKEY_FPRS < <(gpg_ --list-secret-keys --with-colons 2>>"${RUN_LOG}" \
    | awk -F: '$1=="fpr" && NR>1 {print $10}' | tail -n 3)
  (( ${#SUBKEY_FPRS[@]} == 3 )) || die "Expected 3 subkeys, found ${#SUBKEY_FPRS[@]}."
}

# Exports happen BEFORE keytocard so a later failure can never lose the
# public key or the ability to revoke.
export_artifacts() {
  mkdir -p "${OUTPUT_DIR}"
  chmod 700 "${OUTPUT_DIR}"

  gpg_ --export --armor --export-options export-minimal "${KEY_FPR}" \
    > "${OUTPUT_DIR}/public-key.asc" || die "Public key export failed."
  [[ -s ${OUTPUT_DIR}/public-key.asc ]] || die "Public key export produced an empty file."

  # gpg drops a revocation certificate in openpgp-revocs.d at keygen time.
  local revoc="${TMP_GNUPGHOME}/openpgp-revocs.d/${KEY_FPR}.rev"
  if [[ -f ${revoc} ]]; then
    (umask 077 && cp "${revoc}" "${OUTPUT_DIR}/revocation-certificate.asc")
  else
    warn "No auto-generated revocation certificate found; generating one is recommended."
  fi

  if (( BACKUP_MASTER )); then
    (umask 077 && gpg_ --export-secret-keys --armor "${KEY_FPR}" \
      > "${OUTPUT_DIR}/master-secret-key.asc") || die "Master secret key export failed."
    [[ -s ${OUTPUT_DIR}/master-secret-key.asc ]] || die "Master secret key export produced an empty file."
    (umask 077 && gpg_ --export-secret-subkeys --armor "${KEY_FPR}" \
      > "${OUTPUT_DIR}/secret-subkeys.asc") || die "Secret subkey export failed."
  fi
}

# The subkey expiry as gpg actually recorded it (epoch -> ISO date).
subkey_expiry_date() {
  local epoch
  epoch=$(gpg_ --list-keys --with-colons "${KEY_FPR}" 2>/dev/null \
    | awk -F: '$1=="sub" {print $7; exit}')
  if [[ -n ${epoch} ]]; then
    date -d "@${epoch}" +%Y-%m-%d 2>/dev/null || date -r "${epoch}" +%Y-%m-%d 2>/dev/null || echo "epoch:${epoch}"
  else
    echo "never"
  fi
}

# After keytocard: every subkey's secret must be a card stub ('+' means the
# secret is still on disk, '#' missing; '>' is the on-card marker).
verify_keys_on_card() {
  local listing
  listing=$(gpg_ --list-secret-keys 2>>"${RUN_LOG}")
  local stubs
  stubs=$(grep -c '^ssb>' <<<"${listing}" || true)
  (( stubs == 3 )) || die "Expected 3 on-card subkey stubs (ssb>), found ${stubs}. Card transfer incomplete — do NOT trust this provisioning run."

  # Cross-check the card itself reports our subkey fingerprints.
  local card_fprs fpr
  card_fprs=$(LC_ALL=C gpg --homedir "${TMP_GNUPGHOME}" --card-status --with-colons 2>>"${RUN_LOG}" \
    | awk -F: '$1=="fpr" {print $2 $3 $4}')
  for fpr in "${SUBKEY_FPRS[@]}"; do
    [[ ${card_fprs} == *"${fpr}"* ]] \
      || die "Subkey ${fpr} not reported by the card. Card transfer incomplete."
  done
}
