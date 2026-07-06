# shellcheck shell=bash
# Shared plumbing: logging, cleanup, dependency checks, randomness, validation.
# Sourced by yubikey_provision.sh — not executable on its own.

set -o errexit -o nounset -o pipefail

# shellcheck disable=SC2034  # used by the orchestrator (usage/-v)
VERSION="2.0.0"

# ------------------------------------------------------------------ logging

_color() { # $1=ansi-code $2=message (stderr, so stdout stays machine-readable)
  if [[ -t 2 ]]; then printf '\e[%sm%s\e[0m\n' "$1" "$2" >&2; else printf '%s\n' "$2" >&2; fi
}
info()  { _color 32 "$*"; }
warn()  { _color 33 "$*"; }
error() { _color 31 "$*"; }

die() {
  error "ERROR: $*"
  exit 1
}

# ----------------------------------------------------------- state tracking
# Updated by the orchestrator as it progresses, so an abort can tell the
# operator exactly what state the card and keyring are in.
# shellcheck disable=SC2034  # read by card_state_hint() in the orchestrator
PROVISION_STAGE="not started"

# ---------------------------------------------------------------- cleanup

TMP_GNUPGHOME=""
RUN_LOG=""
CLEANUP_DONE=0

cleanup() {
  local rc=$?
  (( CLEANUP_DONE )) && return 0
  CLEANUP_DONE=1

  if [[ -n ${TMP_GNUPGHOME} && -d ${TMP_GNUPGHOME} ]]; then
    # Kill the agent/scdaemon serving the temp home so nothing holds cached
    # secrets or an open card handle after we exit.
    gpgconf --homedir "${TMP_GNUPGHOME}" --kill all 2>/dev/null || true
    shred_dir "${TMP_GNUPGHOME}"
  fi
  stty sane 2>/dev/null || true

  if (( rc != 0 )); then
    error ""
    error "Provisioning FAILED during: ${PROVISION_STAGE}"
    error "$(card_state_hint)"
    [[ -n ${RUN_LOG} && -f ${RUN_LOG} ]] && error "(the gpg transcript was in the temp dir and has been shredded with it)"
  fi
  return "${rc}"
}

# Best-effort secure delete. /dev/shm contents die with the machine anyway;
# on plain disk (macOS) we overwrite before unlinking. On SSDs/APFS this is
# not a guarantee — the README documents the limitation.
shred_dir() {
  local dir=$1
  if command -v shred >/dev/null 2>&1; then
    find "${dir}" -type f -exec shred -fu {} + 2>/dev/null || true
    rm -rf "${dir}"
  else
    rm -rfP "${dir}" 2>/dev/null || rm -rf "${dir}" # macOS rm -P overwrites
  fi
}

install_traps() {
  trap cleanup EXIT
  # Signals: let cleanup run via EXIT, then propagate a conventional code.
  trap 'trap - EXIT; cleanup; exit 130' INT
  trap 'trap - EXIT; cleanup; exit 143' TERM
  trap 'trap - EXIT; cleanup; exit 129' HUP
}

# ------------------------------------------------------------ dependencies

require_deps() { # $@ = binaries
  local missing=() bin
  for bin in "$@"; do
    command -v "${bin}" >/dev/null 2>&1 || missing+=("${bin}")
  done
  (( ${#missing[@]} == 0 )) || die "Missing required tools: ${missing[*]} (on nix: nix-shell -p gnupg yubikey-manager)"
}

require_not_root() {
  [[ ${EUID} -ne 0 ]] || die "Do not run this script as root."
}

# -------------------------------------------------------------- randomness

# N cryptographically random decimal digits via rejection sampling from
# /dev/urandom (bytes 250-255 discarded, so no modulo bias). Avoids the
# `tr | head` pattern which SIGPIPEs tr and trips pipefail+errexit.
random_digits() {
  local n=$1 out="" b
  while (( ${#out} < n )); do
    b=$(od -An -N1 -tu1 /dev/urandom | tr -dc '0-9')
    if (( b < 250 )); then out+=$(( b % 10 )); fi
  done
  printf '%s' "${out:0:n}"
}

# URL-safe random passphrase, 32 alnum chars (~190 bits). Read a bounded
# chunk into a process substitution (so tr sees EOF and exits 0), then slice.
random_passphrase() {
  local s
  s=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))
  printf '%s' "${s:0:32}"
}

# -------------------------------------------------------------- validation

# OpenPGP card spec (and YubiKey 5): user PIN >= 6, admin PIN >= 8, max 127.
validate_pin() { # $1=label $2=value $3=minlen
  local label=$1 pin=$2 min=$3
  [[ ${#pin} -ge ${min} && ${#pin} -le 127 ]] \
    || die "${label} must be ${min}-127 characters (got ${#pin})."
  [[ ${pin} != *$'\n'* && ${pin} != *$'\r'* ]] || die "${label} must not contain newlines."
}

validate_email() {
  # Deliberately loose: local@domain.tld with any TLD length. gpg and the
  # keyserver are the real arbiters; v1's {2,4} TLD cap rejected valid mail.
  [[ $1 =~ ^[^[:space:]@]+@[^[:space:]@.]+(\.[^[:space:]@.]+)+$ ]]
}

validate_expiry() {
  # gpg --quick-add-key format: 0 (never), N, Nd/Nw/Nm/Ny, or ISO date.
  [[ $1 =~ ^(0|[0-9]+[dwmy]?|20[0-9]{2}-[0-9]{2}-[0-9]{2})$ ]] \
    || die "Invalid --expiry '$1' (expected e.g. 2y, 18m, 730d, 0 for never, or YYYY-MM-DD)."
}

confirm() { # $1=prompt — returns 0 on yes; auto-yes when YESMODE=1
  local yn
  (( YESMODE )) && return 0
  if [[ ! -t 0 ]]; then
    die "stdin is not a terminal and --yes was not given; refusing to assume consent for: $1"
  fi
  read -r -p "$1 [y/N] " yn
  [[ ${yn} == [yY] ]]
}
