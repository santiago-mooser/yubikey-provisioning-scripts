#!/bin/bash

###########################################################
##                   READ BEFORE USE                     ##
###########################################################
##                                                       ##
##   This script is used to provision a new smartcard    ##
##   by generating a master key, the corresponding       ##
##   subkeys, uploading those subkeys to the             ##
##   connected smartcard and the company keyserver.      ##
##                                                       ##
##   Target OS Version:                                  ##
##       - Ubuntu 20.04.4 LTS                            ##
##       - Ubuntu 22.04 LTS                              ##
##       - MacOS ?????                                   ##
##                                                       ##
##   How to use:                                         ##
##      1. Insert new end-user (employee) yubikey        ##
##      2. Run script:                                   ##
##            ./yubikey_provision.sh                     ##
##                                                       ##
##         Optionally, you can also add other commands:  ##
##            ./yubikey_provision.sh --yes \             ##
##            --first-name "Firstname" \                 ##
##            --last-name "Lastname" \                   ##
##            --email firstname.lastname@example.com \  ##
##            --comment "Key comment" \                  ##
##            --user-pin 124356 \                        ##
##            --admin-pin 12346578                       ##
##                                                       ##
##         This will skip promts and generate a key with ##
##         the provided information as well as change    ##
##         the smartcard pins to the provided ones       ##
##                                                       ##
##      3. Sit back while the script generates a new     ##
##         key, adds it to the yubikey and uploads the   ##
##         public keyfile to the company keyserver       ##
##                                                       ##
###########################################################

VERSION="1.2.3"

# Set the right user
if [ -z ${SUDO_USER+x} ]; then
  USER_NAME=$USER
else
  USER_NAME=$SUDO_USER
fi

# If the script is interrupted, delete tmp dir
trap cleanup 1 2 3 6

function cleanup(){
  yellow "\nKeyboard interrupt detected! Exiting..."
  yellow "Cleaning up tmpdir..."
  rm -r "$TMPDIR"
  exit 0
}

# Set functions so instructions can be printed in ❀pretty colors❀
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

# The usage function just prints how the script works:
function usage()
{
   cat << HEREDOC
   This script provisions a yubikey by generating a master key, 3 subkeys and moving the subkeys to the yubikey. Please read the documentation for more information.

   Usage: $progname [-e|--email EMAIL_ADDRESS] [-u|--user-pin USER_PIN] [-a|--admin-pin ADMIN_PIN] [-y|--yes] [-x|--no-upgrade]

   optional arguments:
     -h, --help           show this help message and exit.
     -e, --email          provide email used for PGP key. If it is not provided, the user is promted for an email.
     -f, --first-name     provide first name used for PGP key.
     -l, --last-name      provide last name used for PGP key.
     -c, --comment        provide comment used for PGP key. Defaults to an empty string.
         --username       provide username used for PGP key. Defaults to an empty string.
     -p, --password       provide password used for PGP key. If it is not provided, a random one is generated.
     -u, --user-pin       provide new user pin for the yubikey. If none is provided, a random one is generated.
     -a, --admin-pin      provide new admin pin for the yubikey. If none is provided, a random one is generated.
     -y, --yes            skips prompts to reset the yubikey.
     -v, --version        prints out the version number.

HEREDOC
}
progname=$(basename "$0")


# Check that the script is NOT running as root
if [ ! "$EUID" -ne 0 ]; then
  red "Please don't run this script as root!"
  usage
  exit 1
fi

# Check that the dependent scripts are here
declare -a script_list=('gen_key.sh' 'key_to_card.sh' 'subkey_gen.sh' 'yubikey_change_attributes.sh')
for script in "${script_list[@]}"; do
    if [ ! -f "./helper_scripts/$script" ]; then
        red "$script missing"
        exit 1
    fi
done

# Check that type of OS the script is running on
unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=Linux;;
    Darwin*)    machine=Mac;;
    *)          machine="UNKNOWN:${unameOut}" && { red "Unknown OS!"; exit 1; }
esac

if [ "$machine" == "Mac" ]; then
  TMPDIR=$(mktemp -d)
else
  TMPDIR=$(mktemp --tmpdir=/dev/shm --directory)
fi

# Set home directory for gnupg
GNUPGHOME=$TMPDIR

# Set vars so we can check values later on
FIRST_NAME=""
LAST_NAME=""
yesmode="n"

# Parse arguments... So complicated in bash....
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    -e|--email)
      KEY_EMAIL="$2" # Set the GPG email variable
      shift # pass argument
      shift # pass variable
      ;;
    -f|--first-name)
      FIRST_NAME="$2" # Set the GPG name variable
      shift # pass argument
      shift # pass variable
      ;;
    -l|--last-name)
      LAST_NAME="$2" # Set the GPG name variable
      shift # pass argument
      shift # pass variable
      ;;
    -c|--comment)
      KEY_COMMENT="$2" # Set the GPG comment variable
      shift # pass argument
      shift # pass variable
      ;;
    --username*)
      KEY_USERNAME="$2" # Set the GPG password variable
      shift
      shift
      ;;
    -p|--password*)
      KEY_PASS="$2" # Set the GPG password variable
      shift
      shift
      ;;
    -u|--user-pin*)
      USER_PIN="$2"
      shift
      shift
      ;;
    -a|--admin-pin*)
      ADMIN_PIN="$2"
      shift
      shift
      ;;
    -y|--yes)
      yesmode='y'
      shift # pass argument
      ;;
    -v|--version)
      echo $VERSION
      exit 0
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

# If password not set, generate new random password
if [ -z ${KEY_PASS+x} ]; then
  KEY_PASS=$(gpg --gen-random --armor 0 24)
# Else if password is empty, prompt for confirmation
elif [ "$KEY_PASS" == "" ]; then
  red "Provided password is empty! Continue? [yN] "
  if [ "$yesmode" == 'n' ]; then
    read -r yn
    case $yn in
      [yY] )
      ;;
      * )
      red "exiting..."
      exit 1
      ;;
    esac
  fi
fi

# If email variable does not exist....
if [ -z ${KEY_EMAIL+x} ]; then
  # Get email from user and verify syntax
  while true; do
    read -pr "Please provide user email: " KEY_EMAIL
    # Check if it's a valid email...
    if [[ ! "$KEY_EMAIL" =~ ^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$) ]]; then
      yellow "Please provide a valid email: <username>@<domain>"
      continue
    else
      break
    fi
  done
elif [[ ! "$KEY_EMAIL" =~ ^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$) ]]; then
  red "Please provide a valid email: <username>@<domain>"
  exit 1
fi

# Set the name for the key in case first and last name are not provided
if [ "$FIRST_NAME" == "" ] && [ "$LAST_NAME" == "" ]; then
  KEY_NAME=$USER_NAME
else
  KEY_NAME="$FIRST_NAME $LAST_NAME"
fi

# If either the user pin or admin pin variables don't exist,
# automatically generate random pins
if [ -z ${ADMIN_PIN+x} ]; then
  ADMIN_PIN=("$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))")
fi
if [ -z ${USER_PIN+x} ]; then
  USER_PIN=("$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))$(( RANDOM % 10 ))")
fi

# Print instance information
green "Key name:\t\t\t$KEY_NAME"
green "Key email:\t\t\t$KEY_EMAIL"
green "Key comment:\t\t\t$KEY_COMMENT"
green "Key password: \t\t\t'$KEY_PASS'"
green "New Smartcard user pin:\t$USER_PIN"
if [ "$yesmode" == "y" ]; then
  yellow "WARNING: Prompts disabled!"
fi

# If it's running linux, we want to check the entropy level
# This is not needed in MacOS as they persist entropy between boots.
if [ "$machine" == "Linux" ]; then
  # Add more entropy if less than 3k is available
  entropy_available=$(cat /proc/sys/kernel/random/entropy_avail)
  pool_size=$(cat /proc/sys/kernel/random/poolsize)
  entropy_percentage=$(echo "($entropy_available*100/$pool_size)"|bc)
  while true; do
    if [ "$entropy_percentage" -le "80" ];
      then
        echo "SCD RANDOM 512" | gpg-connect-agent | sudo tee /dev/random &>/dev/null
        entropy_available=$(cat /proc/sys/kernel/random/entropy_avail)
        pool_size=$(cat /proc/sys/kernel/random/poolsize)
        entropy_percentage=$(echo "($entropy_available*100/$pool_size)"|bc)
        echo -ne "Entropy available: $entropy_available/$pool_size\r"
    else
      break
    fi
  done
  green "System entropy available: $entropy_available/$pool_size"
fi

# Harden gpg configuration
echo """
personal-cipher-preferences AES256 AES192 AES
personal-digest-preferences SHA512 SHA384 SHA256
personal-compress-preferences ZLIB BZIP2 ZIP Uncompressed
default-preference-list SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed
cert-digest-algo SHA512
s2k-digest-algo SHA512
s2k-cipher-algo AES256
charset utf-8
fixed-list-mode
no-comments
no-emit-version
keyid-format 0xlong
list-options show-uid-validity
verify-options show-uid-validity
with-fingerprint
require-cross-certification
no-symkey-cache
use-agent
throw-keyids
""" > "$GNUPGHOME"/gpg.conf

# Prompt to reset smartcard. Skip if -y or --yes is passed to the script
yellow """
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !! WARNING! The connected yubikey is about to be reset.  !!
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  Continue? [Y/n] """
if [ "$yesmode" == "n" ]; then
  read -r yn
  case $yn in
    [nN] ) echo exiting...;
      exit;;
    * ) : ;;
  esac
fi

# Reset smartcard so we can upload the new keys (since the admin pin is reset)
./helper_scripts/reset_smartcard.sh --gnupg-home "$GNUPGHOME" || { red "Failed to reset smartcard!";  exit 1; }
green "Smartcard successfully reset"

# Create master PGP key
bash ./helper_scripts/gen_key.sh --gnupg-home "$GNUPGHOME" \
                                 --passphrase "$KEY_PASS" \
                                 --name "$KEY_NAME" \
                                 --email "$KEY_EMAIL" \
                                 --comment "$KEY_COMMENT" || { red "Failed to generate masterkey!"; exit 1; }
KEY_ID=$(gpg --homedir "$GNUPGHOME" --list-secret-keys --with-colons | grep "$KEY_EMAIL" -B 2 | grep fpr | awk '{split($0,a,":"); print a[10]}')
if [ "$KEY_ID" == "" ]; then
  red "Error creating masterkey! Exiting...."
  exit 1
fi
green "User Master key successfully generated. Key ID: $KEY_ID"

# Create subkeys and move them to smartcard
bash ./helper_scripts/subkey_gen.sh --gnupg-home "$GNUPGHOME" \
                                    --key-id "$KEY_ID" \
                                    --passphrase "$KEY_PASS" || { red "Failed to generate subkeys!"; exit 1; }
green "Subkeys successfully generated"
bash ./helper_scripts/key_to_card.sh --gnupg-home "$GNUPGHOME" \
                                     --key-id "$KEY_ID" \
                                     --passphrase "$KEY_PASS" \
                                     --admin-pin "12345678" || { red "Failed to move subkeys to card!"; exit 1; }
green "Subkeys successfully transferred to card"


# Get GPG public key
PUBLIC_KEY=$(gpg --homedir "$TMPDIR" --export-options export-minimal --armor --export "${KEY_ID[0]}")

# Upload public key to keyserver
yellow """Upload yubikey to public openPGP keyserver? (recommended if you will not be using this in a company)"""
if [ "$yesmode" == "n" ]; then
  read -r yn
  case $yn in
    [nN] ) red "Please make sure to save public key as it is not possible to extract it from the yubieky later!"
    sleep 5;;
    * )
    CONFIRMATION_URL="$(echo $PUBLIC_KEY | curl -T - https://keys.openpgp.org/ | grep http)" || { red "Unable to upload public key to server!"; exit 1; };;
  esac
else
  CONFIRMATION_URL="$(echo $PUBLIC_KEY | curl -T - https://keys.openpgp.org/ | grep http)" || { red "Unable to upload public key to server!"; exit 1; };;
fi


# Finally, change the attributes of the yubikey,
# including the pin, name and puk url
echo "Changing yubikey attributes"
./helper_scripts/yubikey_change_attributes.sh --gnupg-home "$GNUPGHOME" \
                                              --current-user-pin "123456" \
                                              --current-admin-pin "12345678" \
                                              --new-user-pin "$USER_PIN" \
                                              --new-admin-pin "$ADMIN_PIN" \
                                              --username "$KEY_USERNAME" \
                                              --first-name "$FIRST_NAME" \
                                              --last-name "$LAST_NAME" \
                                              --key-url "https://keys.openpgp.org//vks/v1/by-fingerprint/$KEY_ID" || { red "Failed to change yubikey attributes!"; exit 1; }
green "Yubikey attributes successfully changed."

echo ""
# And print all the details:
green "public key:\n$PUBLIC_KEY"
green "Key password: \"$KEY_PASS\""
green "User pin: $USER_PIN"

yellow "Please visit the following url to confirm the public key:"
echo "$CONFIRMATION_URL"

# Remove TMPDIR
green "Deleting TMPDIR: $TMPDIR"
rm "$TMPDIR" -rf
