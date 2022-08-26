#!/bin/bash

##############################################################
##                   READ BEFORE USE                        ##
##############################################################
##                                                          ##
##   This script changes the attributes of a connected      ##
##   yubikey. It can be used simply to change the pin but   ##
##   it also servers to change all other information.       ##
##                                                          ##
##                                                          ##
##   Usage:                                                 ##
##   ./yubikey_change_pin.sh -u <user pin> \                ##
##                           -a <admin_pin>                 ##
##                                                          ##
##   Usage:                                                 ##
##   ./yubikey_change_pin.sh -u <user pin> \                ##
##                           -a <admin_pin> \               ##
##                           -o <old_user_pin> \            ##
##                           -d <old_admin_pin> \           ##
##                           -f Firstname \                 ##
##                           -l Lastname \                  ##
##                           -k key_url \                   ##
##                           -u username \                  ##
##                           -s salutation                  ##
##                                                          ##
##############################################################

VERSION="3.1.3"

set +x
function red(){
    echo -e "\x1B[31m $1 \x1B[0m"
    if [ -n "${2}" ]; then
    echo -e "\x1B[31m $($2) \x1B[0m"
    fi
}
function green(){
    echo -e "\x1B[32m $1 \x1B[0m"
    if [ -n "${2}" ]; then
    echo -e "\x1B[32m $($2) \x1B[0m"
    fi
}
function yellow(){
    echo -e "\x1B[33m $1 \x1B[0m"
    if [ -n "${2}" ]; then
    echo -e "\x1B[33m $($2) \x1B[0m"
    fi
}


function usage()
{
   cat << HEREDOC
   This script changes the attributes of a connected yubikey. It can be used simply to change the pin but it also servers to change all other information in the yubikey. All attribute changes can be included at the same time.

   Usage: $progname [options]

   Example usage: $progname --current-admin-pin 12345678 --first-name John --last-name "Doe Doe"

   optional arguments:
     -h, --help               show this help message and exit.
     -g, --gnupg-home         provide gnupg home directory. Defauts to \$SUDO_USER/.gnupg
     -o, --current-user-pin   provide current user pin. Required if user pin is going to change
     -d, --current-admin-pin  provide current admin pin. Required to change admin pin, first name, last name or key URL.
     -u, --new-user-pin       provide new user pin. Only needed if user pin is being changed.
     -a, --new-admin-pin      provide new admin pin. Only needed if admin pin is being changed.
     -f, --first-name         provide the first name of the user.
     -l, --last-name          provide the last name of the user.
     -k, --key-url            provide the url of the public key.
         --username           provide username of the user.
     -s, --salutation         provide salutation. Can be: M or F.
     -v, --version            print version number and exit.

HEREDOC
}
progname=$(basename "$0")


# Set the first name and last name variables so it's easier to change the yubikey attributes later on
FIRST_NAME=""
LAST_NAME=""

# Parse arguments... So complicated in bash....
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)
      echo $VERSION
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
    -u|--new-user-pin*)
      NEW_USER_PIN="$2" # Set the password variable
      shift
      shift
      ;;
    -a|--new-admin-pin*)
      NEW_ADMIN_PIN="$2" # Set the password variable
      shift
      shift
      ;;
    -o|--current-user-pin*)
      CURRENT_USER_PIN="$2" # Set the password variable
      shift
      shift
      ;;
    -d|--current-admin-pin*)
      CURRENT_ADMIN_PIN="$2" # Set the password variable
      shift
      shift
      ;;
    -f|--first-name*)
      FIRST_NAME="$2" # Set the password variable
      shift
      shift
      ;;
    -l|--last-name*)
      LAST_NAME="$2" # Set the password variable
      shift
      shift
      ;;
    -k|--key-url*)
      PUK_URL="$2" # Set the password variable
      shift
      shift
      ;;
    --username*)
      KEY_USERNAME="$2" # Set the password variable
      shift
      shift
      ;;
    -s|--salutation*)
      SALUTATION="$2" # Set the password variable
      shift
      shift
      ;;
    -*)
      red "Unknown option \"$1\""
      usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Once the parameters have been parsed, check the values:

# Set the right user
if [ -z ${SUDO_USER+x} ]; then
  USER_NAME=$USER
else
  USER_NAME=$SUDO_USER
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
  if [ "$machine" == "Linux" ]; then
    green "Linux detected"
    GNUPGHOME="/home/$USER_NAME/.gnupg"
    yellow "GNUPGHOME set to $GNUPGHOME"
  elif [ "$machine" == "Mac" ]; then
    green "MacOS detected"
    GNUPGHOME="/Users/$USER_NAME/.gnupg"
    yellow "GNUPGHOME set to $GNUPGHOME"
  fi
fi


# Check that the smartcard is connected & detected
while true; do
  if ! gpg --homedir "$GNUPGHOME" --card-status &>/dev/null; then
    yellow "Please (re)insert your OpenPGP smart card and press [Enter]"
    read -r _
    continue
  else
    break
  fi
done

# Once we know it's detected, we change the attributes

# If the user pin variable is set, change the user pin
if [ -n "${NEW_USER_PIN+x}" ]; then
  if [ -n "${CURRENT_USER_PIN+x}" ]; then
    if expect -c "
      set timeout 5
      set send_slow {10 .001}
      spawn gpg --homedir \"$GNUPGHOME\" --pinentry-mode loopback --edit-card
      expect \"gpg/card>\"
      send -s \"admin\r\"
      expect \"gpg/card>\"
      send -s \"passwd\r\"
      expect \"Your selection?\"
      send -s \"1\r\"
      expect \"Enter passphrase:\"
      send -s \"$CURRENT_USER_PIN\r\"
      expect \"Enter passphrase:\"
      send -s \"$NEW_USER_PIN\r\"
      expect \"Enter passphrase:\"
      send -s \"$NEW_USER_PIN\r\"
      expect {
        -re \"Bad PIN\"       { puts \"\n BAD USER PIN!\"; exit 1 }
        -re \"PIN blocked\"   { puts \"\n PIN BLOCKED!\"; exit 1 }
        \"Your selection?\"   { send -s \"q\r\"; }
        timeout               { exit 1 }
      }
      expect \"gpg/card>\"
      send -s \"q\r\"
      expect eof
      exit 0"; then
        green "Successfully changed admin pin"
        CURRENT_USER_PIN=$NEW_USER_PIN
    else
      red "Failed to change User pin!";
    fi
  else
    red "To change the user pin you must provide the old user pin!"
  fi
fi

# If the admin pin variable is set, then change the admin pin
if [ -n "${NEW_ADMIN_PIN+x}" ]; then
  if [ -n "${CURRENT_ADMIN_PIN+x}" ]; then
    if expect -c "
      set timeout 5
      set send_slow {10 .001}
      spawn gpg --homedir \"$GNUPGHOME\" --pinentry-mode loopback --edit-card
      expect \"gpg/card>\"
      send -s \"admin\r\"
      expect \"gpg/card>\"
      send -s \"passwd\r\"
      expect \"Your selection?\"
      send -s \"3\r\"
      expect \"Enter passphrase:\"
      send -s \"$CURRENT_ADMIN_PIN\r\"
      expect \"Enter passphrase:\"
      send -s \"$NEW_ADMIN_PIN\r\"
      expect \"Enter passphrase:\"
      send -s \"$NEW_ADMIN_PIN\r\"
      expect {
        -re \"Bad PIN\"       { puts \"\n BAD ADMIN PIN!\"; exit 1 }
        -re \"PIN blocked\"   { puts \"\n PIN BLOCKED!\"; exit 1 }
        \"Your selection?\"   { send -s \"q\r\"; }
        timeout               { exit 1 }
      }
      expect \"gpg/card>\"
      send -s \"q\r\"
      expect eof"; then
        green "Successfully changed user pin"
        CURRENT_ADMIN_PIN=$NEW_ADMIN_PIN
    else
      red "Failed to change Admin pin!";
    fi
  else
    red "To change the admin pin you must provide the old admin pin!"
  fi
fi

# If either the first name or last name variables is
# non-empty, change them on the yubikey
if [ -n "$FIRST_NAME" ] || [ -n "$LAST_NAME" ]; then

  # Check that the current admin pin is provided
  if [ -n "${CURRENT_ADMIN_PIN}" ]; then
    if expect -c "
      set timeout 5
      set send_slow {10 .001}
      spawn gpg --homedir \"$GNUPGHOME\" --pinentry-mode loopback --edit-card
      expect \"gpg/card>\"
      send -s \"admin\r\"
      expect \"gpg/card>\"
      send -s \"name\r\"
      expect \"Cardholder's surname:\"
      send -s \"$LAST_NAME\r\"
      expect \"Cardholder's given name:\"
      send -s \"$FIRST_NAME\r\"
      expect {
          \"gpg/card>\"           { send -s \"q\r\" }
          \"Enter passphrase:\"   {
              send -s \"$CURRENT_ADMIN_PIN\r\"; expect {
                -re \"Bad PIN\"       { puts \"\n BAD ADMIN PIN!\"; exit 1 }
                -re \"PIN blocked\"   { puts \"\n PIN BLOCKED!\"; exit 1 }
                \"gpg/card>\"         { send -s \"q\r\"; }
                timeout               { exit 1 }
              }
          }
        }
      expect eof"; then
        green "Successfully changed name" 
    else
      red "Failed to change key name!"
    fi
  else
    red "Current admin pin required to change cardholder name!"
  fi
fi

# If the public key url is declared, change it on the yubikey
if [ -n "${PUK_URL+x}" ]; then

  # Check that the current admin pin is provided
  if [ -n "${CURRENT_ADMIN_PIN}" ]; then

    # Once the required information is found to exist, we can use expect to change the URL
    if expect -c "
      set timeout 5
      set send_slow {10 .001}
      spawn gpg --homedir \"$GNUPGHOME\" --pinentry-mode loopback --edit-card
      expect \"gpg/card>\"
      send -s \"admin\r\"
      expect \"gpg/card>\"
      send -s \"url\r\"
      expect \"URL to retrieve public key:\"
      send -s \"$PUK_URL\r\"
      expect {
        \"gpg/card>\"           { send -s \"q\r\" }
        \"Enter passphrase:\"   {
            send -s \"$CURRENT_ADMIN_PIN\r\"; expect {
              -re \"Bad PIN\"       { puts \"\n BAD ADMIN PIN!\"; exit 1 }
              -re \"PIN blocked\"   { puts \"\n PIN BLOCKED!\"; exit 1 }
              \"gpg/card>\"         { send -s \"q\r\"; }
              timeout               { exit 1 }
            }
        }
      }
      expect eof"; then
      green "Successfully changed public key url"
    else
      red "Failed to change key URL!"
    fi
  else
    red "Current admin pin required to change key URL"
  fi
fi

# If the username is declared, change it on the yubikey
if [ -n "${KEY_USERNAME+x}" ]; then

  if expect -c "
    set timeout 5
    set send_slow {10 .001}
    spawn gpg --homedir \"$GNUPGHOME\" --pinentry-mode loopback --edit-card
    expect \"gpg/card>\"
    send -s \"admin\r\"
    expect \"gpg/card>\"
    send -s \"login\r\"
    expect \"Login data (account name):\"
    send -s \"$KEY_USERNAME\r\"
    expect \"gpg/card>\"
    send -s \"q\r\"
    expect eof"; then
    green "Successfully changed username"
  else
    red "Failed to change key username!"
  fi
fi

# If the salutation is declared, change it on the yubikey
if [ -n "${SALUTATION+x}" ]; then
  if [ ! "$SALUTATION" == "M" ] && [ ! "$SALUTATION" == "F" ]; then
    red "Salutation must be one of the following values: [M, F]"
  else
    expect -c "
      set timeout 5
      set send_slow {10 .001}
      spawn gpg --homedir \"$GNUPGHOME\" --pinentry-mode loopback --edit-card
      expect \"gpg/card>\"
      send -s \"admin\r\"
      expect \"gpg/card>\"
      send -s \"salutation\r\"
      expect \"Salutation (M = Mr., F = Ms., or space):\"
      send -s \"$SALUTATION\r\"
      expect \"gpg/card>\"
      send -s \"q\r\"
      expect eof"
    green "Successfully changed salutation"
  fi
fi
