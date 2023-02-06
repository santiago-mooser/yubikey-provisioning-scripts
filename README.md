
# Yubikey provisioning scripts

The scripts found in this repo help automate the provisioning of a yubikey's OpenPGP applet. It essentially automates the instructions found in @drduh 's repository to provision a yubikey's OpenPGP applet: https://github.com/drduh/YubiKey-Guide

## Table of contents

- [Yubikey provisioning scripts](#yubikey-provisioning-scripts)
  - [Table of contents](#table-of-contents)
  - [Usage](#usage)
  - [Individual scripts](#individual-scripts)
  - [Using the scripts](#using-the-scripts)
  - [Assumptions about the scripts](#assumptions-about-the-scripts)
  - [Compatibility](#compatibility)
  - [Futher documentation on scripts](#futher-documentation-on-scripts)
  - [Authors](#authors)

## Usage

The simplest way to use these scripts is to simply clone the repo and run the main [yubikey_provision.sh](./yubikey_provision.sh) script:

```bash
git clone https://github.com/santiago-mooser/yubikey-provisioning-scripts.git
cd yubikey-provisioning-scripts
./yubikey_provision.sh -h
   This script provisions a yubikey by generating a master key, 3 subkeys and moving the subkeys to the yubikey. Please read the documentation for more information.

   Usage: yubikey_provision.sh [-e|--email EMAIL_ADDRESS] [-u|--user-pin USER_PIN] [-a|--admin-pin ADMIN_PIN] [-y|--yes]

   optional arguments:
     -h, --help           show this help message and exit.
     -e, --email          provide email used for PGP key. If it is not provided, the user is prompted for an email.
     -f, --first-name     provide first name used for PGP key. Defaults to an empty string.
     -l, --last-name      provide last name used for PGP key. Defaults to an empty string.
     -c, --comment        provide comment used for PGP key. Defaults to an empty string.
         --username       provide username used for PGP key. Defaults to an empty string.
     -p, --password       provide password used for PGP key. If it is not provided, a random one is generated.
     -u, --user-pin       provide new user pin for the yubikey. If none is provided, a random one is generated.
     -a, --admin-pin      provide new admin pin for the yubikey. If none is provided, a random one is generated.
     -y, --yes            skips prompts to reset the yubikey.
     -v, --version        prints out the version number.
```

This script will help you run all of the other helper scripts in the right order and with the right flags to create a new private key, subkeys, reset the openPGP applet of the connected yubikey and upload the subkeys to the yubikey.

**WARNING**

The script will also upload your public key to openPGP's public key server! Please disable this in the script if this is not what you want.

**WARNING**

To understand how the scripts work, I recommend reading through the various scripts found in the [helper scripts folder](./helper_scripts/). All of the code is commented so if you're familiar with Shell scripts, it shouldn't be too hard to understand what they all do.

## Individual scripts

The [helper scripts folder](./helper_scripts/) holds the various scripts used by the main script to provision yubikeys. The scripts do the following tings:

1. [reset_smartcard.sh](./helper_scripts/reset_smartcard.sh): Reset the connected yubikey's OpenPGP applet.
2. [gen_key.sh](./helper_scripts/gen_key.sh): Create a master PGP key.
3. [subkey_gen.sh](./helper_scripts/subkey_gen.sh): Create three PGP subkeys (One each for Encryption, Authentication and Signing).
4. [key_to_card.sh](./helper_scripts/key_to_card.sh): Move PGP subkeys to smartcard (private keys are not kept! they are *moved*).
5. [yubikey_change_pin.sh](./helper_scripts/yubikey_change_attributes.sh): Change the attributes of the connected yubikey (name, comment, url, etc...).

The [yubikey_provision.sh](./yubikey_provision.sh) script will fully provision a yubikey by running all the above scripts in the given order.

## Using the scripts

**WARNING**

The private key of the yubikey is not exported. If you would like to export your private keys, please uncomment the lines 363-365 of the [yubikey_provision.sh script](yubikey_provision.sh#L362)

Alternatively, to reprovision new subkeys, please create new subkeys as per [this official yubikey guide](https://github.com/drduh/YubiKey-Guide#sub-keys), but select option `14` and continue with the rest of the guide (including moving the subkeys to the yubikey):

**WARNING**

```bash
[...]
gpg> addkey
Secret parts of primary key are stored on-card.
Please select what kind of key you want:
   (3) DSA (sign only)
   (4) RSA (sign only)
   (5) Elgamal (encrypt only)
   (6) RSA (encrypt only)
  (14) Existing key from card
Your selection?
[...]
```

## Assumptions about the scripts

1. All scripts
   1. The utility `expect` is installed and available in PATH.
   2. The `gpg` commandline utility is installed and available in PATH (for MacOS the GnuPG suite needs to be installed).
   3. The `scdaemon` utility is installed (Ubuntu only) OR GnuPG suite is installed (MacOS)

## Compatibility

This script has been tested with MacOS Monetrrey and Ventura and Ubutuntu 20.04 LTS onwards. It will likely work with earlier versions, but it's not a guarantee.

## Futher documentation on scripts

Some extra documentation can be found in the [docs/ folder](./docs/).

1. [docs/yubikey_provision.md](./docs/yubikey_provision.md)

## Authors

Santiago Espinosa Mooser - (yps@santiago-mooser.com)
