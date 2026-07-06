# YubiKey provisioning scripts

Automate provisioning a YubiKey's OpenPGP applet: generate a certify-only
master key plus signing / encryption / authentication subkeys on the host,
move the subkeys to the card, set the card PINs and touch policy, and export
the public key and a revocation certificate. It automates the workflow from
[drduh/YubiKey-Guide](https://github.com/drduh/YubiKey-Guide).

> **v2 rewrite.** The previous version drove `gpg` interactively with `expect`
> and could silently report success on failure — most seriously, it could
> leave the card's factory user PIN in place while printing a PIN it never
> applied. v2 replaces prompt-scraping with `gpg` batch commands and a
> status-driven responder, exports your recovery material *before* the
> destructive card transfer, and never uploads your key unless you ask. See
> [What changed in v2](#what-changed-in-v2).

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Usage](#usage)
- [What you get, and what you must keep](#what-you-get-and-what-you-must-keep)
- [Important behaviours and caveats](#important-behaviours-and-caveats)
- [How it works](#how-it-works)
- [Testing](#testing)
- [What changed in v2](#what-changed-in-v2)
- [Author](#author)

## What it does

Given a connected YubiKey, `yubikey_provision.sh`:

1. Verifies exactly one YubiKey is attached (or targets `--serial`).
2. **Factory-resets** the card's OpenPGP applet (`ykman openpgp reset`).
3. Generates, in an ephemeral GnuPG home on `tmpfs` (Linux) or a temp dir
   (macOS):
   - a **certify-only master key** (RSA-4096 by default, or ed25519), no expiry;
   - three subkeys — **sign / encrypt / authenticate** — with a configurable
     expiry (default 2 years).
4. **Exports** the public key and the revocation certificate (and, with
   `--backup-master`, the encrypted secret keys) to an output directory —
   *before* touching the card, so a later failure cannot lose them.
5. Moves the three subkeys to the card and **verifies** all three now report
   as on-card stubs whose fingerprints match.
6. Sets the **touch policy** on all three slots (default `cached`).
7. Changes the card **user and admin PINs** from the factory defaults, and
   verifies the new user PIN by requesting a card signature.
8. Sets cardholder name / login / key URL on the card.
9. Optionally (`--upload`) publishes the public key to a keyserver.
10. Prints all secrets **once** at the end. The temp home (with the master
    secret key) is shredded on exit, on **every** path including errors.

## Requirements

- `bash` 4+, `gpg` (GnuPG 2.2+), `gpgconf`
- `ykman` ([yubikey-manager](https://developers.yubico.com/yubikey-manager/))
- `curl` (only used with `--upload`)
- `od`, `tr`, `shred` (coreutils; `shred` optional, used for secure temp cleanup)

On NixOS / nix:

```bash
nix-shell -p gnupg yubikey-manager --command './yubikey_provision.sh --help'
```

The script refuses to run as root and validates its arguments before touching
any hardware.

## Usage

```bash
git clone https://github.com/santiago-mooser/yubikey-provisioning-scripts.git
cd yubikey-provisioning-scripts
./yubikey_provision.sh --email you@example.com
```

Fully non-interactive, with explicit credentials and a key backup:

```bash
./yubikey_provision.sh --yes \
  --email jane.doe@example.com \
  --first-name Jane --last-name Doe \
  --algo ed25519 --expiry 2y --touch cached \
  --user-pin 471902 --admin-pin 90318475 \
  --backup-master --output-dir ./jane-key
```

Run `./yubikey_provision.sh --help` for the complete, authoritative option
list. Key options:

| Option | Purpose |
| --- | --- |
| `-e, --email` | UID email (required; prompted if omitted). |
| `-f/-l, --first/last-name` | UID name and cardholder name. |
| `--algo rsa4096\|ed25519` | Key algorithm. ed25519 needs card firmware >= 5.2.3. |
| `--expiry 2y\|18m\|730d\|0\|YYYY-MM-DD` | Subkey expiry (default `2y`; `0` = never). |
| `--touch off\|on\|fixed\|cached\|cached-fixed` | Touch policy (default `cached`). |
| `-p/-u/-a` | Passphrase / user PIN / admin PIN (CSPRNG-generated if omitted). |
| `-o, --output-dir` | Where artifacts are written. |
| `--backup-master` | Also export the (encrypted) master + subkey secret keys. |
| `--upload` | Publish the public key to `--keyserver` (opt-in). |
| `--serial` | Target a specific card when several are attached. |
| `-y, --yes` | No prompts (requires `--email`). |

## What you get, and what you must keep

At the end the script prints, once, the key fingerprint, passphrase, both
PINs, the subkey expiry date, and the touch policy. **Record them then** — the
PINs and passphrase are not written to disk (unless you use `--backup-master`).

In `--output-dir` you get:

- `public-key.asc` — import this on every machine that will use the card, and
  share it as you like. It **cannot** be re-extracted from the YubiKey later.
- `revocation-certificate.asc` — store this **offline**. It is the only way to
  revoke the key if the card is lost or destroyed.
- With `--backup-master`: `master-secret-key.asc` and `secret-subkeys.asc`,
  encrypted with the passphrase — store **offline** (e.g. printed/paper or an
  encrypted USB kept in a safe).

## Important behaviours and caveats

- **This factory-resets the card.** Any OpenPGP keys already on the connected
  YubiKey are erased. Other applets (FIDO2, PIV, OTP) are untouched.
- **The master (certify) key is destroyed unless you back it up.** Without
  `--backup-master` there is no way to extend subkey expiry or add new subkeys
  later — when the subkeys expire (default 2 years) you must re-provision a new
  key. This is the offline-master model from drduh's guide; back it up if you
  want to renew rather than rotate.
- **`--upload` is opt-in.** The key is uploaded only if you pass it. Note that
  `keys.openpgp.org` serves an uploaded key's user ID *only after you verify
  the email*; until then the on-card key-URL fetch returns a key with no
  identity, which stock GnuPG refuses to import. Verify the email to publish
  the UID.
- **Secure erase is best-effort.** The temp GnuPG home is on `tmpfs`
  (`/dev/shm`) on Linux, which does not hit disk; on macOS it is a normal temp
  dir shredded on exit. On SSDs/APFS, overwrite-in-place is not a guarantee —
  prefer the Linux path for high-assurance ceremonies, ideally air-gapped.
- **On failure, nothing is silently half-done.** Every error path shreds the
  temp key material and prints exactly what state the card is in (e.g. "keys
  are on the card but the admin PIN is still default; set it with ...").

## How it works

```
yubikey_provision.sh      orchestrator: arg parsing, ordering, summary
lib/common.sh             logging, EXIT-trap cleanup/shred, CSPRNG, validation
lib/gpg_keys.sh           batch keygen/subkeys/exports/verification (no expect)
lib/gpg_card.sh           ykman reset/touch + a --status-fd/--command-fd
                          responder for keytocard / PIN change / card attrs
```

The card dialogues that have no batch equivalent are driven by reading
GnuPG's machine-readable `--status-fd` stream and answering each prompt **by
its prompt key**, from explicit FIFOs. Unknown prompts, or a PIN request with
no queued PIN, **abort** rather than guess — a wrong guess at a PIN prompt
would burn one of the card's three admin-PIN tries. `LC_ALL=C` makes this
locale-independent.

## Testing

The non-hardware suite (unit + integration, no YubiKey needed) covers CLI
validation, the key-generation/export library against real `gpg`, and the card
responder against a scripted fake `gpg` that proves it answers correctly and
fails closed:

```bash
nix-shell -p gnupg shellcheck --command 'tests/run.sh'
```

End-to-end hardware verification (destructive — factory-resets the connected
card, then independently re-checks the result with `ykman` + `gpg`):

```bash
nix-shell -p gnupg yubikey-manager --command 'tests/verify_hardware.sh'
# VERIFY_ALGO=ed25519 tests/verify_hardware.sh   # fast run
```

## What changed in v2

Driven by a full multi-perspective review of v1. Highlights:

- **Fixed:** the user-PIN change silently failing (corrupted `expect`
  quoting) — v1 shipped cards with the factory user PIN `123456` while
  printing a random PIN. v2 changes PINs via a checked responder and *verifies*
  the new user PIN with a card signature.
- **Fixed:** master key + revocation cert destroyed with no backup path and
  no revocation option. v2 exports the revocation cert always and the master
  key on request, before the card transfer.
- **Fixed:** `expect` blocks that timed out and reported success anyway; PINs
  from bash `$RANDOM`; secrets on the process command line; macOS `expect -d`
  echoing every PIN; publish-by-default; the broken email regex; the entropy
  `sudo` machinery; docs describing flags that didn't exist.
- **New:** configurable algorithm/expiry/touch policy; single-card safety
  check; opt-in upload; artifact export with a revocation certificate;
  end-to-end verification of the card state before declaring success.

## Author

Santiago Espinosa Mooser
