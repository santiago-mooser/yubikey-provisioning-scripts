# shellcheck shell=bash
# Card operations. Replaces v1's expect scraping with:
#   - ykman for applet reset, device selection and touch policy
#   - a status-driven responder (--command-fd/--status-fd) for the gpg
#     dialogues that have no batch equivalent (keytocard, PIN change, attrs)
#
# Responder safety rules:
#   - every prompt is answered by its prompt KEY (from --status-fd), never by
#     position in a blind stream, so gpg-agent caching can't desync it
#   - unknown prompts fail the run instead of guessing (a wrong guess at a
#     GET_HIDDEN costs a PIN retry; three brick the applet)
#   - BAD_PASSPHRASE / SC_OP_FAILURE abort immediately

DRIVE_TIMEOUT=${DRIVE_TIMEOUT:-60}

# Menu-style GET_LINE prompts whose answers come from the DRIVE_CMDS FIFO.
_MENU_PROMPTS="keyedit.prompt cardedit.prompt cardutil.change_pin.menu"

# ------------------------------------------------------------------ ykman

ykman_() {
  if [[ -n ${YK_SERIAL} ]]; then ykman --device "${YK_SERIAL}" "$@"; else ykman "$@"; fi
}

# Enforce exactly one connected YubiKey (or an explicit --serial) before
# doing anything destructive.
select_yubikey() {
  local serials s found=0
  mapfile -t serials < <(ykman list --serials 2>/dev/null)
  if [[ -n ${YK_SERIAL} ]]; then
    for s in "${serials[@]}"; do [[ ${s} == "${YK_SERIAL}" ]] && found=1; done
    (( found )) || die "YubiKey serial ${YK_SERIAL} not found (connected: ${serials[*]:-none})."
  else
    case ${#serials[@]} in
      0) die "No YubiKey detected. Connect the key to be provisioned and re-run." ;;
      1) YK_SERIAL=${serials[0]} ;;
      *) die "Multiple YubiKeys connected (${serials[*]}). Pass --serial to choose which one to WIPE and provision." ;;
    esac
  fi
}

# gpg's scdaemon and ykman (pcscd) fight over exclusive card access, so kill
# scdaemon before every ykman call. Killing gpg-agent too clears cached PIN
# verifications, keeping responder dialogues deterministic.
release_card_from_gpg() {
  gpgconf --homedir "${TMP_GNUPGHOME}" --kill scdaemon gpg-agent 2>/dev/null || true
  gpgconf --kill scdaemon 2>/dev/null || true
}

card_serial_info() { ykman_ openpgp info 2>/dev/null || true; }

card_factory_reset() {
  release_card_from_gpg
  ykman_ openpgp reset --force >>"${RUN_LOG}" 2>&1 \
    || die "ykman openpgp reset failed (transcript in the run log)."
}

# ykman slot names: sig / dec / aut. Admin PIN on stdin, never argv.
set_touch_policy() {
  local policy=$1 slot
  [[ ${policy} == off ]] && return 0
  release_card_from_gpg
  for slot in sig dec aut; do
    printf '%s\n' "${ADMIN_PIN}" \
      | ykman_ openpgp keys set-touch "${slot}" "${policy}" --force >>"${RUN_LOG}" 2>&1 \
      || die "Failed to set touch policy '${policy}' on slot ${slot}."
  done
}

# --------------------------------------------------------- gpg responder

# gpg_card_drive <description> -- <gpg args...>
#
# GnuPG under --pinentry-mode loopback emits every secret prompt as
# `GET_HIDDEN passphrase.enter` with NO NEED_PASSPHRASE hint and no distinct
# prompt key for PIN vs key-passphrase (verified against GnuPG 2.x + YubiKey
# 5.2.7). So GET_HIDDEN is dispatched by DRIVE_HIDDEN_MODE:
#   pin       every GET_HIDDEN is a card PIN, answered from DRIVE_PINS in order
#             (change-pin: current,new,new; card attrs: admin PIN each time)
#   keytocard the first GET_HIDDEN after each slot selection is the source
#             key's passphrase (each subkey has its own keygrip, so it is
#             always prompted, first); the admin PIN(s) follow from DRIVE_PINS
#
# Answer sources (globals set via reset_drive_state + assignment per call):
#   DRIVE_CMDS[]      FIFO for menu prompts (edit/card menus, change-pin menu)
#   DRIVE_SLOTS[]     FIFO for keytocard slot selection
#   DRIVE_PINS[]      FIFO for GET_HIDDEN card PINs
#   DRIVE_PASSPHRASE  key passphrase (keytocard mode, first hidden per slot)
#   DRIVE_MAP[key]    fixed answer for a specific GET_LINE/GET_BOOL prompt key
#   DRIVE_HIDDEN_MODE pin | keytocard
gpg_card_drive() {
  local desc=$1; shift
  [[ ${1-} == -- ]] && shift
  local cmd_i=0 slot_i=0 pin_i=0 want_keypass=0 line key rc
  local mode=${DRIVE_HIDDEN_MODE:-pin}

  coproc GPGD {
    LC_ALL=C gpg --homedir "${TMP_GNUPGHOME}" --no-tty --expert \
      --pinentry-mode loopback --command-fd 0 --status-fd 1 "$@" 2>>"${RUN_LOG}"
  }
  local in=${GPGD[1]} out=${GPGD[0]} pid=${GPGD_PID}
  send() { printf '%s\n' "$1" >&"${in}"; }
  fail_drive() {
    error "gpg dialogue '${desc}': $1"
    kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
    return 1
  }

  while IFS= read -r -t "${DRIVE_TIMEOUT}" line <&"${out}"; do
    case ${line} in
      "[GNUPG:] GET_HIDDEN "*)
        key=${line#"[GNUPG:] GET_HIDDEN "}
        if [[ ${mode} == keytocard && ${want_keypass} == 1 ]]; then
          printf '[drive:%s] GET_HIDDEN %s (key passphrase)\n' "${desc}" "${key}" >>"${RUN_LOG}"
          send "${DRIVE_PASSPHRASE}"; want_keypass=0
        else
          printf '[drive:%s] GET_HIDDEN %s (card PIN #%s)\n' "${desc}" "${key}" "${pin_i}" >>"${RUN_LOG}"
          (( pin_i < ${#DRIVE_PINS[@]} )) \
            || { fail_drive "PIN requested (${key}) but PIN queue exhausted — refusing to guess"; return 1; }
          send "${DRIVE_PINS[pin_i]}"; (( ++pin_i ))
        fi ;;

      "[GNUPG:] GET_LINE cardedit.genkeys.storekeytype")
        (( slot_i < ${#DRIVE_SLOTS[@]} )) || { fail_drive "slot prompt, empty slot queue"; return 1; }
        send "${DRIVE_SLOTS[slot_i]}"; (( ++slot_i ))
        want_keypass=1 ;;   # next GET_HIDDEN unlocks this subkey's secret

      "[GNUPG:] GET_LINE "*|"[GNUPG:] GET_BOOL "*)
        key=${line#"[GNUPG:] GET_"}; key=${key#* }
        if [[ " ${_MENU_PROMPTS} " == *" ${key} "* ]]; then
          (( cmd_i < ${#DRIVE_CMDS[@]} )) || { fail_drive "menu prompt '${key}', empty command queue"; return 1; }
          send "${DRIVE_CMDS[cmd_i]}"; (( ++cmd_i ))
        elif [[ -n ${DRIVE_MAP[${key}]+x} ]]; then
          send "${DRIVE_MAP[${key}]}"
        else
          fail_drive "unmapped prompt '${key}' — refusing to guess"; return 1
        fi ;;

      "[GNUPG:] BAD_PASSPHRASE"*)
        fail_drive "BAD_PASSPHRASE (wrong passphrase/PIN — check retry counters before re-running)"; return 1 ;;
      "[GNUPG:] SC_OP_FAILURE"*)
        fail_drive "smartcard operation failed (${line})"; return 1 ;;

      *) printf '%s\n' "${line}" >>"${RUN_LOG}" ;;
    esac
  done
  rc=$?
  if (( rc > 128 )); then fail_drive "no output from gpg for ${DRIVE_TIMEOUT}s"; return 1; fi

  exec {in}>&- 2>/dev/null || true
  wait "${pid}" || { error "gpg dialogue '${desc}' exited non-zero"; return 1; }
  return 0
}

reset_drive_state() {
  DRIVE_CMDS=() DRIVE_SLOTS=() DRIVE_PINS=()
  DRIVE_PASSPHRASE=""
  DRIVE_HIDDEN_MODE="pin"
  unset DRIVE_MAP; declare -gA DRIVE_MAP=()
}

# ---------------------------------------------------------- card dialogues

# Move the three subkeys to the card. On 'save' the on-disk secrets become
# card stubs, so exports must already be written before this runs.
keytocard_subkeys() {
  reset_drive_state
  DRIVE_HIDDEN_MODE="keytocard"
  DRIVE_CMDS=("key 1" "keytocard" "key 1"
              "key 2" "keytocard" "key 2"
              "key 3" "keytocard"
              "save")
  DRIVE_SLOTS=(1 2 3)                 # signature=1, encryption=2, authentication=3
  DRIVE_PASSPHRASE=${KEY_PASSPHRASE}
  # One admin-PIN prompt per subkey at most (scdaemon caches PW3 after the
  # first), but provide a generous queue; extra entries are never consumed.
  local i; DRIVE_PINS=(); for ((i=0; i<6; i++)); do DRIVE_PINS+=("${CARD_ADMIN_CURRENT}"); done
  DRIVE_MAP=( ["cardedit.genkeys.replace_key"]="y" ["keyedit.save.okay"]="y" )
  release_card_from_gpg
  gpg_card_drive "keytocard" -- --edit-key "${KEY_FPR}" \
    || die "Moving subkeys to the card failed. Nothing was saved; on-disk keys are intact."
}

# One --change-pin invocation per PIN. Menu option 1 = user PIN (PW1),
# 3 = admin PIN (PW3). Separate invocations keep the PIN FIFO unambiguous.
change_card_pin() { # $1=menu-option $2=current $3=new $4=label
  reset_drive_state
  DRIVE_CMDS=("$1" "q")
  DRIVE_PINS=("$2" "$3" "$3")        # current, new, repeat (repeat may be skipped)
  release_card_from_gpg
  gpg_card_drive "change $4 PIN" -- --change-pin \
    || die "Changing the $4 PIN failed. The card may still use the previous $4 PIN; check 'ykman openpgp info' retry counters before retrying."
}

change_card_pins() {
  # PROVISION_STAGE is consumed by card_state_hint() in the orchestrator.
  # shellcheck disable=SC2034
  PROVISION_STAGE="changing card user PIN"
  change_card_pin 1 "${CARD_USER_CURRENT}" "${USER_PIN}" user
  CARD_USER_CURRENT=${USER_PIN}
  # shellcheck disable=SC2034
  PROVISION_STAGE="changing card admin PIN"
  change_card_pin 3 "${CARD_ADMIN_CURRENT}" "${ADMIN_PIN}" admin
  CARD_ADMIN_CURRENT=${ADMIN_PIN}
}

# Cardholder name / login / URL via --card-edit admin commands.
set_card_attributes() {
  local cmds=(admin)
  [[ -n ${FIRST_NAME}${LAST_NAME} ]] && cmds+=(name)
  [[ -n ${CARD_LOGIN} ]] && cmds+=(login)
  [[ -n ${CARD_URL} ]] && cmds+=(url)
  (( ${#cmds[@]} > 1 )) || return 0
  cmds+=(quit)

  reset_drive_state
  DRIVE_CMDS=("${cmds[@]}")
  local i; DRIVE_PINS=(); for ((i=0; i<4; i++)); do DRIVE_PINS+=("${CARD_ADMIN_CURRENT}"); done
  DRIVE_MAP=(
    ["keygen.smartcard.surname"]="${LAST_NAME}"
    ["keygen.smartcard.givenname"]="${FIRST_NAME}"
    ["cardedit.change_login"]="${CARD_LOGIN}"
    ["cardedit.change_url"]="${CARD_URL}"
  )
  release_card_from_gpg
  gpg_card_drive "card attributes" -- --card-edit \
    || die "Setting card attributes failed."
}

# Optional end-to-end proof: detach-sign with the on-card signing subkey.
# Verifies the new user PIN works and (if a touch policy is set) touch.
test_signature() {
  release_card_from_gpg
  local out
  info "Requesting a test signature from the card — touch the YubiKey if it blinks."
  if out=$(printf 'provisioning self-test' \
      | LC_ALL=C gpg --homedir "${TMP_GNUPGHOME}" --no-tty --pinentry-mode loopback \
          --passphrase "${CARD_USER_CURRENT}" --armor --detach-sign 2>>"${RUN_LOG}"); then
    [[ -n ${out} ]] && { info "Test signature OK — card user PIN verified."; return 0; }
  fi
  warn "Test signature failed — verify the card manually before handing it out."
  return 1
}
