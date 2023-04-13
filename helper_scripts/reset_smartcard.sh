#!/bin/bash

###########################################################
##                   READ BEFORE USE                     ##
###########################################################
##                                                       ##
##   This script simply resets the connected Smartcard,  ##
##   Yubikey or other.                                   ##
##                                                       ##
##   Usage:                                              ##
##   ./reset_smartcard.sh                                ##
##                                                       ##
###########################################################

VERSION="1.1.2"

function red(){
    echo -e "\x1B[31m $1 \x1B[0m"
    if [ -n "${2}" ]; then
    echo -e "\x1B[31m $($2) \x1B[0m"
    fi
}
function yellow(){
    echo -e "\x1B[33m $1 \x1B[0m"
    if [ -n "${2}" ]; then
    echo -e "\x1B[33m $($2) \x1B[0m"
    fi
}
function green(){
    echo -e "\x1B[32m $1 \x1B[0m"
    if [ -n "${2}" ]; then
    echo -e "\x1B[32m $($2) \x1B[0m"
    fi
}

function usage()
{
   cat << HEREDOC
   This script simply resets the connected Smartcard, Yubikey or other.

   Usage: ${progname}

   optional arguments:

     -g, --gnupg-home     provide gnupg home directory. Defauts to \${SUDO_USER}/.gnupg
     -v, --version        print version number.
HEREDOC
}
progname=$(basename "$0")


# Parse arguments... So complicated in bash....
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)
      echo ${VERSION}
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -g|--gnupg-home*)
      GNUPGHOME="$2"
      shift
      shift
      ;;
    *)
      red "Unknown option \"$1\""
      usage
      exit 1
      ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Set the right user
if [ -z ${SUDO_USER+x} ]; then
  USER_NAME=${USER}
else
  USER_NAME=${SUDO_USER}
fi

# Set GNUPGHOME if none is provided.
if [ -x ${GNUPGHOME+x} ]; then

  # Get the machine type
  unameOut="$(uname -s)"
  case "${unameOut}" in
      Linux*)     machine=Linux;;
      Darwin*)    machine=Mac;;
      *)          machine="UNKNOWN:${unameOut}"
  esac

  # Choose the right gnupg default for the machine type
  if [ "${machine}" == "Linux" ]; then
    green "Linux detected"
    GNUPGHOME="/home/${USER_NAME}/.gnupg"
    yellow "GNUPGHOME set to ${GNUPGHOME}"
  elif [ "${machine}" == "Mac" ]; then
    green "MacOS detected"
    GNUPGHOME="/Users/${USER_NAME}/.gnupg"
    yellow "GNUPGHOME set to ${GNUPGHOME}"
  fi
fi

# Check that the smartcard is connected
while true; do
  if ! gpg  --homedir "${GNUPGHOME}" --card-status &>/dev/null; then
    yellow "Please (re)insert your OpenPGP smart card and press Enter"
    read -r _
    continue
  else
    break
  fi
done


expect -c "
  set send_slow {10 .001}
  set timeout 5
  # Reset yubikey's OpenPGP application
  spawn gpg --homedir \"${GNUPGHOME}\" --edit-card
  expect \"gpg/card> \"
  send -s \"admin\r\"
  expect \"gpg/card> \"
  send -s \"factory-reset\r\"
  expect \"Continue? (y/N) \"
  send -s \"y\r\"
  expect \"Really do a factory reset? \"
  send -s \"yes\r\"
  expect \"gpg/card> \"
  send -s \"quit\r\"
  expect eof"