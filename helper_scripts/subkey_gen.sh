#!/bin/bash

##############################################################
##                   READ BEFORE USE
##############################################################
##
##   This script generates three different subkeys for
##   the given key: one for Encryption, one for
##   Authentication and one for Signing.
##
##   Usage:
##   ./subkey_gen.sh -i <key_id>
##
##   Advanced Usage:
##   ./subkey_gen.sh -i <key_id> \
##                   -g <GNUPGHOME> \
##                   -p '<key passphrase>'
##
##############################################################

VERSION="2.1.0"

# Set the right user
if [ -z ${SUDO_USER+x} ]; then
  USER_NAME=$USER
else
  USER_NAME=$SUDO_USER
fi

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
   This script generates three different subkeys for the given key: one for Encryption, one for Authentication and one for Signing.

   Usage: $progname {-i|--key-id <key_id>} [-g|--gnupg-home <dir>] [-p|--passphrase <passphrase>]

   required arguments:
     -k, --key-id        ID of PGP key to be uploaded to yubikey.

   optional arguments:
     -h, --help           show this help message and exit.
     -g, --gnupg-home     provide gnupg home directory. Defauts to \$SUDO_USER/.gnupg
     -p, --passphrase     provide passphrase for key.
     -v, --version        print version number and exit.

HEREDOC
}
progname=$(basename "$0")


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
    -p|--passphrase*)
      KEY_PASS="$2" # Set the password variable
      shift
      shift
      ;;
    -g|--gnupg-home*)
      GNUPGHOME="$2"
      shift
      shift
      ;;
    -k|--key-id*)
      KEY_ID="$2"
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

if [ -z ${KEY_ID+x} ]; then
  red "Missing Key ID! Exiting...."
  exit 1
fi
if [ -z ${KEY_PASS+x} ]; then
    KEY_PASS=""
    yellow "No password provided to script. Assuming key has no password."
fi

# Set the right user
if [ -z ${SUDO_USER+x} ]; then
  USER_NAME=$USER
else
  USER_NAME=$SUDO_USER
fi

EXPECT_PARAMETERS="-c"

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
    yellow "Enabled debug mode for expect due to MacOS's bad terminal design"
    EXPECT_PARAMETERS="-d -c"
  fi
fi

# Check that the gnupg folder actually exists
if [ ! -d "$GNUPGHOME" ]; then
  red "Folder '$GNUPGHOME' does not exist!"
  exit 1
fi

# Once all the variables are set, we also need to check the level of entropy
# in the system. MacOS does not allow checking the level of entry but it uses
# multiple sources of entropy.
if [ "$machine" = "Linux" ]; then
  # Otherwise if the machine is Linux, we can check the entropy pool
  # and make sure it meets hte necessary requirements of 80% "full"
  entropy_available=$(cat /proc/sys/kernel/random/entropy_avail)
  pool_size=$(cat /proc/sys/kernel/random/poolsize)
  entropy_percentage=$(echo "($entropy_available*100/$pool_size)"|bc)
  while true; do
    if [ "$entropy_percentage" -le "80" ];
      then
        echo "Insuficient entropy available. Please move mouse and click around the terminal."
        entropy_available=$(cat /proc/sys/kernel/random/entropy_avail)
        pool_size=$(cat /proc/sys/kernel/random/poolsize)
        entropy_percentage=$(echo "($entropy_available*100/$pool_size)"|bc)
        echo -ne "Entropy available:\t$entropy_available/$pool_size\r"
    else
      break
    fi
  done
  green "Done"
  green "System entropy available: $entropy_available/$pool_size"
fi

#Create subkeys
expect $EXPECT_PARAMETERS "
  set timeout 5
  set send_slow {10 .001}
  spawn gpg --homedir $GNUPGHOME --pinentry-mode loopback --passphrase \"$KEY_PASS\" --expert --edit-key $KEY_ID

  # Create Sign Subkey
  expect \"gpg>\"
  send -s \"addkey\r\"
  expect \"Your selection? \"
  send -s \"4\r\"
  expect \"What keysize do you want? (3072) \"
  send -s \"4096\r\"
  expect \"Key is valid for? (0) \"
  send -s \"1y\r\"
  expect \"Is this correct? (y/N) \"
  send -s \"y\r\"
  expect \"Really create? (y/N) \"
  send -s \"y\r\"

  # Create Encryption Subkey
  expect \"gpg>\"
  send -s \"addkey\r\"
  expect \"Your selection? \"
  send -s \"6\r\"
  expect \"What keysize do you want? (3072) \"
  send -s \"4096\r\"
  expect \"Key is valid for? (0) \"
  send -s \"1y\r\"
  expect \"Is this correct? (y/N) \"
  send -s \"y\n\"
  expect \"Really create? (y/N) \"
  send -s \"y\n\"

  # Create Authentication Subkey
  expect \"gpg>\"
  send -s \"addkey\r\"
  expect \"Your selection? \"
  send -s \"8\r\"
  # Take away Encrypt & Sign capabilities and add Authentication capabilities
  expect \"Your selection? \"
  send -s \"S\r\"
  expect \"Your selection? \"
  send -s \"E\r\"
  expect \"Your selection? \"
  send -s \"A\r\"
  expect \"Your selection? \"
  send -s \"Q\r\"
  # Finalize key creation
  expect \"What keysize do you want? (3072)\"
  send -s \"4096\r\"
  expect \"Key is valid for? (0) \"
  send -s \"1y\r\"
  expect \"Is this correct? (y/N) \"
  send -s \"y\r\"
  expect \"Really create? (y/N) \"
  send -s \"y\r\"

  expect \"gpg>\"
  send -s \"save\r\"

  expect eof"
