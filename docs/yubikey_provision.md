# Using yubikey_provision.sh

`yubikey_provision.sh` provisions a connected YubiKey's OpenPGP applet
end to end. It performs two irreversible actions you should understand before
running it:

1. It **factory-resets** the connected card's OpenPGP applet, erasing any
   OpenPGP keys already on it.
2. With `--upload`, it **publishes your public key** to a keyserver.

## Full option reference

The `--help` output is the authoritative source; this doc mirrors it.

```
Usage: yubikey_provision.sh --email <addr> [options]

Identity:
  -e, --email <addr>       Email for the key UID (required; prompted if omitted).
  -f, --first-name <name>  First name (also written to the card as given name).
  -l, --last-name <name>   Last name  (also written to the card as surname).
  -c, --comment <text>     UID comment.
      --login <text>       Card login/account name (defaults to email).

Key parameters:
      --algo <rsa4096|ed25519>   Key algorithm (default rsa4096; ed25519 needs
                                 card firmware 5.2.3+).
      --expiry <spec>            Subkey expiry: 2y, 18m, 730d, 0=never, or
                                 YYYY-MM-DD (default 2y).
      --touch <off|on|fixed|cached|cached-fixed>
                                 Touch policy for all slots (default cached).

Secrets (CSPRNG-generated if omitted; shown once at the end):
  -p, --passphrase <str>   Master-key passphrase.
  -u, --user-pin <pin>     New card user PIN  (>= 6 chars).
  -a, --admin-pin <pin>    New card admin PIN (>= 8 chars).

Output / distribution:
  -o, --output-dir <dir>   Where public-key.asc, the revocation cert, and (with
                           --backup-master) the secret-key backup are written.
      --backup-master      Also export the encrypted master + subkey secret keys.
      --upload             Upload the public key to the keyserver (opt-in).
      --keyserver <url>    Keyserver for --upload (default keys.openpgp.org).
      --serial <serial>    Target a specific YubiKey when several are attached.

Misc:
  -y, --yes                Non-interactive (no confirmation prompt).
  -h, --help               Show help and exit.
  -v, --version            Print version and exit.
```

## Basic run

Provide an email; everything else is generated. You are asked to confirm the
destructive reset before anything happens.

```console
$ ./yubikey_provision.sh --email jane.doe@example.com
Provisioning plan:
  Key UID:        jane (Jane's key) <jane.doe@example.com>
  Algorithm:      rsa4096
  Subkey expiry:  2y
  Touch policy:   cached
  Output dir:     ./yubikey-<fpr8>-jane.doe
  Backup master:  no
  Upload:         no
  YubiKey serial: 12345678
This will FACTORY-RESET the OpenPGP applet on YubiKey serial 12345678.
Proceed? [y/N]
```

At the end the credentials and artifact locations are printed once:

```console
==================== PROVISIONING COMPLETE ====================
  Key fingerprint  : AABBCCDD...
  Master passphrase: <generated>
  Card user PIN    : 4719 (example)
  Card admin PIN   : <generated>
  Subkey expiry    : 2028-07-06
  Touch policy     : cached

Artifacts written to ./yubikey-<fpr8>-jane.doe:
  public-key.asc
  revocation-certificate.asc
```

## Non-interactive run

Use `--yes` to skip the confirmation, and pass any values you want to control.
`--email` is required in this mode.

```bash
./yubikey_provision.sh --yes \
  --email jane.doe@example.com \
  --first-name Jane --last-name Doe \
  --passphrase 'correct horse battery staple' \
  --user-pin 471902 --admin-pin 90318475 \
  --touch cached --expiry 2y \
  --backup-master --output-dir ./jane-key
```

## Notes

- Keep the printed passphrase and PINs, and the `revocation-certificate.asc`
  file — see the README section "What you get, and what you must keep".
- Without `--backup-master` the master key is destroyed and subkeys cannot be
  renewed after they expire; you would re-provision instead.
- `--upload` to `keys.openpgp.org` only serves your user ID after you verify
  the email from the confirmation message.
