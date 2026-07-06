#!/usr/bin/env bash
# Run the full non-hardware test suite. Requires gpg (and shellcheck for the
# lint stage) — on nix: nix-shell -p gnupg shellcheck --command tests/run.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "${HERE}")
rc=0

echo "### shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S style "${ROOT}/yubikey_provision.sh" "${ROOT}"/lib/*.sh "${HERE}"/*.sh "${HERE}"/stubs/gpg \
    && echo "  shellcheck clean" || rc=1
else
  echo "  (skipped: shellcheck not installed)"
fi

for suite in test_cli.sh test_keys.sh test_responder.sh; do
  echo
  echo "### ${suite}"
  bash "${HERE}/${suite}" || rc=1
done

echo
if (( rc == 0 )); then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit "${rc}"
