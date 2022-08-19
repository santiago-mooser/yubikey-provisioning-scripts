# Smartcard scripts

This repository holds the various scripts use internally to provision company yubikeys. The scripts do the following tings:

1. [reset_smartcard.sh](./helper_scripts/reset_smartcard.sh): Reset the connected yubikey.
2. [gen_key.sh](./helper_scripts/gen_key.sh): Create a master PGP key.
3. [subkey_gen.sh](./helper_scripts/subkey_gen.sh): Create PGP subkeys (One each for Encryption, Authentication and Signing).
4. [key_to_card.sh](./helper_scripts/key_to_card.sh): Move PGP subkeys to smartcard.
5. [yubikey_change_pin.sh](./helper_scripts/yubikey_change_pin.sh): Change the attributes of the connected yubikey

The [yubikey_provision.sh](./yubikey_provision.sh) script will fully provision a yubikey by running all the above scripts in the given order.

## Using the scripts

**WARNING** the private key of the yubikey is not exported. To reprovision new subkeys, please create a new as per [this official yubikey guide](https://github.com/drduh/YubiKey-Guide#sub-keys), but select option `14` and continue with the rest of the guide:

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

### Assumptions about the scripts

1. All scripts
   1. The `gpg` commandline utility is installed and available in PATH (for MacOS the GnuPG suite needs to be installed).
   2. The `scdaemon` is installed (Ubuntu only) OR GnuPG suite is installed (MacOS)

### Futher documentation on scripts

More documentation can be found in the [docs/ folder](./docs/).

1. [docs/yubikey_provision.md](./docs/yubikey_provision.md)

## Authors

Santiago Espinosa Mooser - (contact@santiago-mooser.com)
