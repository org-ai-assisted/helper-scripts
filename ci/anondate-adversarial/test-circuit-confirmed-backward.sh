#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Unit tests for the "backward only when a real circuit confirms it"
## decision in onion-time-pre-script (default behavior, no config).
## Sources the script (source-safe via its BASH_SOURCE guard) and
## exercises circuit_confirmed_backward_proceed (the gate). No real Tor
## is involved; the decision is a pure function of globals.
##
## Usage: ALLOW_LOCAL=true ./test-circuit-confirmed-backward.sh

set -o pipefail

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "true" ]; then
  printf '%s\n' "$0: refuse outside CI; set ALLOW_LOCAL=true." >&2
  exit 1
fi
REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${REPO}/usr/libexec/helper-scripts/onion-time-pre-script"

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
  ## $1 result, $2 circuit -> "proceed" | "wait"
  ## Capture args first: sourcing the script runs 'set -e errtrace',
  ## which clobbers the positional parameters.
  local res="$1" circ="$2"
  (
    HELPER_SCRIPTS_PATH="${REPO}" source "${SCRIPT}" >/dev/null 2>&1
    trap - EXIT ERR
    set +e
    clock_tor_consensus_check_result="${res}"
    tor_circuit_established="${circ}"
    if circuit_confirmed_backward_proceed; then
      echo "proceed"
    else
      echo "wait"
    fi
  )
}

printf '%s\n' "=== gate: circuit_confirmed_backward_proceed (default, no flag) ==="
chk "fast + circuit    -> proceed" "proceed" "$(decide fast 1)"
chk "fast + NO-circuit -> wait" "wait" "$(decide fast 0)"
chk "slow + circuit    -> wait" "wait" "$(decide slow 1)"
chk "ok + circuit      -> wait" "wait" "$(decide ok 1)"

printf '%s\n' "--------------------------------------------------"
printf 'RESULT: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
