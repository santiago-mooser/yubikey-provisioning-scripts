#!/bin/bash

######################################################################
##                   READ BEFORE USE                                ##
######################################################################
##                                                                  ##
##   This script generates a new master GPG key based on the        ##
##   given information. It will check to make sure the level of     ##
##   entropy is sufficient before generating the key.               ##
##                                                                  ##
##   Usage:                                                         ##
##   expect ./gen_key.sh -e <email>                                 ##
##                                                                  ##
##   Advanced Usage:                                                ##
##   expect ./gen_key.sh -e <email> \                               ##
##                       -g <gnupghome> \                           ##
##                       -n <user name>                             ##
##                       -c <Key comment> \                         ##
##                       -p <key_pass>                              ##
##                                                                  ##
######################################################################

VERSION="2.2.3"

# Functions to print in ❀pretty colors❀
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

# Usage instructions for the script
function usage()
{
   cat << HEREDOC
    This script generates a new master GPG key.

   Usage: ${progname} {-e|--email <email>} [-g|--gnupg-home <dir>] [-p|--passphrase <passphrase>] [-e|--email <email>] [-u|--username <username>]

   required arguments:
     -e, --email          provide email for OpenPGP key.

   optional arguments:
     -h, --help           show this help message and exit.
     -g, --gnupg-home     provide gnupg home directory. Defauts to the .gnupg folder in the user's home directory.
     -n, --name           provide name for OpenPGP key. Defaults to \$SUDO_USER.
     -c, --comment        provide comment for OPenPGP key. Defaults to '\$KEY_NAME's key'.
     -p, --passphrase     provide passphrase for OpenPGP key. DEFAULTS TO NO PASSWORD.
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
    -e|--email*)
      KEY_EMAIL="$2" # Set the password variable
      shift
      shift
      ;;
    -g|--gnupg-home*)
      GNUPGHOME="$2"
      shift
      shift
      ;;
    -n|--name*)
      KEY_NAME="$2"
      shift
      shift
      ;;
    -c|--comment*)
      KEY_COMMENT="$2" # Set the password variable
      shift
      shift
      ;;
    -p|--passphrase*)
      KEY_PASS="$2" # Set the password variable
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

# Once the argument have been passed, we can set sane defaults
# base on what arguments were passed to the script:
if [ -z ${KEY_EMAIL+x} ]; then
  red "Missing Email! Exiting...."
  exit
fi

# check that the email matches the regex
if [[ ! ${KEY_EMAIL} =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
  red "Invalid email address!"
  exit 1
fi


# Set blank password if none is provided....
if [ -z ${KEY_PASS+x} ]; then
    KEY_PASS=""
    yellow "Private key will not be protected by a password!"
fi

# Set the right user based on who's executing the script
if [ -z ${SUDO_USER+x} ]; then
  USER_NAME=${USER}
else
  USER_NAME=${SUDO_USER}
fi

# Set GNUPGHOME if none is provided.
if [ -z ${GNUPGHOME+x} ]; then

  # Because the home folder is located in different locations based
  # on the OS, we must check which kernel type we're running:
  unameOut="$(uname -s)"
  case "${unameOut}" in
      Linux*)     machine=Linux;;
      Darwin*)    machine=Mac;;
      *)          machine="UNKNOWN:${unameOut}"
  esac

  # Then based on this, we can choose the right gnupg default for the machine type
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

# Check that the gnupg folder actually exists
if [ ! -d "${GNUPGHOME}" ]; then
  red "Folder '${GNUPGHOME}' does not exist!"
  exit 1
fi

# In case a name is not given, we can use the username of the user executing the script.
if [ -z ${KEY_NAME+x} ]; then
    yellow "No username provided! Defaulting to ${USER_NAME}"
    KEY_NAME=${USER_NAME}
fi

# Similarly with the comment
if [ -z ${KEY_COMMENT+x} ]; then
    yellow "No comment provided! Defaulting to '${KEY_NAME}'s key'"
    KEY_COMMENT="${KEY_NAME}'s key"
fi

# Once all the variables are set, we also need to check the level of entropy
# in the system. MacOS does not allow checking the level of entry but it uses
# multiple sources of entropy.
if [ "${machine}" = "Linux" ]; then
  # Otherwise if the machine is Linux, we can check the entropy pool
  # and make sure it meets hte necessary requirements of 80% "full"
  entropy_available=$(cat /proc/sys/kernel/random/entropy_avail)
  pool_size=$(cat /proc/sys/kernel/random/poolsize)
  entropy_percentage=$(echo "(${entropy_available}*100/${pool_size})"|bc)
  while true; do
    if [ "${entropy_percentage}" -le "80" ];
      then
        echo "Insuficient entropy available. Please move mouse and click around the terminal."
        entropy_available=$(cat /proc/sys/kernel/random/entropy_avail)
        pool_size=$(cat /proc/sys/kernel/random/poolsize)
        entropy_percentage=$(echo "(${entropy_available}*100/${pool_size})"|bc)
        echo -ne "Entropy available:\t${entropy_available}/${pool_size}\r"
    else
      break
    fi
  done
  green "Done"
  green "System entropy available: ${entropy_available}/${pool_size}"
fi

# Once everything is set, we can generate the key
  expect -c "
  set send_slow {10 .001}
  set timeout 5
  spawn gpg --homedir ${GNUPGHOME} --pinentry-mode loopback --passphrase ${KEY_PASS} --expert --full-generate-key

  # Generate master key
  expect \"Your selection?\"
  send -s \"8\r\"
  expect \"Your selection?\"
  send -s \"E\r\"
  expect \"Your selection?\"
  send -s \"S\r\"
  expect \"Your selection?\"
  send -s \"Q\r\"
  expect \"What keysize do you want? (3072)\"
  send -s \"4096\r\"
  expect \"Key is valid for? (0)\"
  send -s \"0\r\"
  expect \"Is this correct? (y/N)\"
  send -s \"y\r\"
  # Add user details
  expect \"Real name: \"
  send -s \"${KEY_NAME}\r\"
  expect \"Email address: \"
  send -s \"${KEY_EMAIL}\r\"
  expect \"Comment: \"
  send -s \"${KEY_COMMENT}\r\"

  expect \"Change (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? \"
  send -s \"o\r\"
  send -s \"\r\"
  send -s \"\r\"
  expect eof"
