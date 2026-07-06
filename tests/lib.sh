# shellcheck shell=bash
# Tiny test harness. Source this, then use pass/fail/assert_*.
TESTS_RUN=0 TESTS_FAILED=0
_cur=""

t() { _cur=$1; }
pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  ok   %s\n' "${_cur}"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf '  FAIL %s: %s\n' "${_cur}" "$1" >&2; }

assert_eq()      { if [[ $1 == "$2" ]]; then pass; else fail "expected [$2] got [$1]"; fi; }
assert_contains(){ if [[ $1 == *"$2"* ]]; then pass; else fail "[$1] does not contain [$2]"; fi; }
assert_ok()      { if "$@"; then pass; else fail "command failed: $*"; fi; }
assert_fail()    { if "$@"; then fail "expected failure: $*"; else pass; fi; }
assert_file()    { if [[ -s $1 ]]; then pass; else fail "missing/empty file: $1"; fi; }
assert_grep()    { if "${@:2}" >/dev/null 2>&1; then pass; else fail "$1"; fi; }

summary() {
  printf '\n%d tests, %d failed\n' "${TESTS_RUN}" "${TESTS_FAILED}"
  (( TESTS_FAILED == 0 ))
}
