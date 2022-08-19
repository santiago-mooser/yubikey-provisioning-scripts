# Using yubikey_provision.sh

[yubikey_provision.sh](../yubikey_provision.sh) will only generate a new keyfile, subkeys and upload the subkeys to a connected yubikey.

## Usage

```Bash
❯ ./yubikey_provision.sh -h
   This script provisions a yubikey by generating a master key, 3 subkeys and moving the subkeys to the yubikey. Please read the documentation for more information.

   Usage: yubikey_provision.sh [-e|--email EMAIL_ADDRESS] [-u|--user-pin USER_PIN] [-a|--admin-pin ADMIN_PIN] [-y|--yes] [-x|--no-upgrade]

   optional arguments:
     -h, --help           show this help message and exit.
     -e, --email          provide email used for PGP key. If it is not provided, the user is promted for an email.
     -n, --name           provide name used for PGP key. If it is not provided, the user is prompted for an email.
     -c, --comment        provide comment used for PGP key. Defaults to an empty string.
     -p, --password       provide password used for PGP key. If it is not provided, a random one is generated.
     -u, --user-pin       provide new user pin for the yubikey. If none is provided, a random one is generated.
     -a, --admin-pin      provide new admin pin for the yubikey. If none is provided, a random one is generated.
     -y, --yes            skips prompts to reset the yubikey.
     -v, --version        prints out the version number.
```

Basic usage involves simply running the script with an email. This will generate random passwords for the OpenPGP key and yubikey:

```Bash
./yubikey_provision.sh --email contact@santiago-mooser.com
 Key name:                      santiagoespinosa
 Key email:                     contact@santiago-mooser.com
 Key comment:
 Key password:                  'VRdN2ErvKP2acdevU00KgMjbiq5c4YHK'
 New smartcard admin pin:       43951169
 New Smartcard user pin:        50151805
 Please (re)insert your OpenPGP smart card and press Enter
 System entropy available: 3700/4096
[...]
```

You can also choose to skip prompts by using the `-y` or `--yes` option, as well as pass other options:

```Bash
./yubikey_provision.sh --email contact@santiago-mooser.com \
--name "Santiago Espinosa" \
--comment "Test comment" \
--password "pass1234" \
--user-pin "123456" \
--admin-pin "12345678" \
--yes
 Key name:                      Santiago Espinosa
 Key email:                     contact@santiago-mooser.com
 Key comment:                   Test comment
 Key password:                  'pass1234'
 New smartcard admin pin:       12345678
 New Smartcard user pin:        123456
 WARNING: Prompts disabled!
 Please (re)insert your OpenPGP smart card and press Enter
 System entropy available: 3700/4096
 [...]
```

Everything else is pretty intuitive.
