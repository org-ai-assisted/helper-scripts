#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Unit tests for the "backward only when a real circuit confirms it"
## decision in onion-time-pre-script. Sources the script (source-safe
## via its BASH_SOURCE guard) and exercises:
##   - circuit_confirmed_backward_proceed (the gate),
##   - read_allow_circuit_confirmed_backward (the config flag).
## No real Tor is involved; the decision is a pure function of globals.
##
## Usage: ALLOW_LOCAL=true sudo ./test-circuit-confirmed-backward.sh

set -o pipefail

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "true" ]; then
  printf '%s\n' "$0: refuse outside CI; set ALLOW_LOCAL=true." >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]; then
  printf '%s\n' "$0: must run as root (writes /etc/sdwdate.d)." >&2
  exit 1
fi

REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${REPO}/usr/libexec/helper-scripts/onion-time-pre-script"
TEST_CONF="/etc/sdwdate.d/99_zz_circuit_confirmed_test.conf"

PASS=0
FAIL=0
chk() {
  if [ "$2" = "$3" ]; then
    printf '  PASS  %-42s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %-42s exp=%s got=%s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

decide() {
  ## $1 result, $2 flag, $3 circuit -> "proceed" | "wait"
  ## Capture args first: sourcing the script runs 'set -e errtrace',
  ## which clobbers the positional parameters.
  local res="$1" flag="$2" circ="$3"
  (
    HELPER_SCRIPTS_PATH="${REPO}" source "${SCRIPT}" >/dev/null 2>&1
    trap - EXIT ERR
    set +e
    clock_tor_consensus_check_result="${res}"
    allow_circuit_confirmed_backward="${flag}"
    tor_circuit_established="${circ}"
    if circuit_confirmed_backward_proceed; then
      echo "proceed"
    else
      echo "wait"
    fi
  )
}

read_cfg() {
  (
    HELPER_SCRIPTS_PATH="${REPO}" source "${SCRIPT}" >/dev/null 2>&1
    trap - EXIT ERR
    set +e
    read_allow_circuit_confirmed_backward
    echo "${allow_circuit_confirmed_backward}"
  )
}

cleanup() { rm -f -- "${TEST_CONF}"; }
trap cleanup EXIT

printf '%s\n' "=== gate: circuit_confirmed_backward_proceed ==="
chk "fast + flag-on + circuit  -> proceed" "proceed" "$(decide fast true 1)"
chk "fast + flag-OFF + circuit -> wait" "wait" "$(decide fast false 1)"
chk "fast + flag-on + NO-circuit -> wait" "wait" "$(decide fast true 0)"
chk "slow + flag-on + circuit -> wait" "wait" "$(decide slow true 1)"
chk "ok + flag-on + circuit -> wait" "wait" "$(decide ok true 1)"

printf '%s\n' "=== config: read_allow_circuit_confirmed_backward ==="
mkdir -p /etc/sdwdate.d
rm -f -- "${TEST_CONF}"
chk "no flag file -> false" "false" "$(read_cfg)"
printf 'ALLOW_CIRCUIT_CONFIRMED_BACKWARD=true\n' >"${TEST_CONF}"
chk "=true -> true" "true" "$(read_cfg)"
printf 'ALLOW_CIRCUIT_CONFIRMED_BACKWARD=false\n' >"${TEST_CONF}"
chk "=false -> false" "false" "$(read_cfg)"
rm -f -- "${TEST_CONF}"

printf '%s\n' "--------------------------------------------------"
printf 'RESULT: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
