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
    circuit_confirmed="${circ}"
    if circuit_confirmed_backward_proceed; then
      echo "proceed"
    else
      echo "wait"
    fi
  )
}

printf '%s\n' "=== gate: circuit_confirmed_backward_proceed (circuit alone) ==="
## A built circuit => proceed, regardless of the consensus verdict.
chk "circuit + fast -> proceed" "proceed" "$(decide fast 1)"
chk "circuit + slow -> proceed" "proceed" "$(decide slow 1)"
chk "circuit + ok   -> proceed" "proceed" "$(decide ok 1)"
## No circuit => wait (anondate / retry), whatever the verdict.
chk "no-circuit + fast -> wait" "wait" "$(decide fast 0)"
chk "no-circuit + ok   -> wait" "wait" "$(decide ok 0)"

printf '%s\n' "=== determine_circuit_confirmed (VM-aware confirmation) ==="
decide_confirm() {
  ## $1 VM, $2 active-build exit code, $3 sticky flag -> circuit_confirmed
  local vm="$1" built_code="$2" sticky="$3"
  (
    HELPER_SCRIPTS_PATH="${REPO}" source "${SCRIPT}" >/dev/null 2>&1
    trap - EXIT ERR
    set +e
    output_cmd() { :; }
    ## Stub the leaprun-backed active build (no real Tor in CI).
    check_tor_circuit_built() {
      tor_circuit_built_check_exit_code="${built_code}"
      tor_circuit_built_output="stub"
    }
    VM="${vm}"
    tor_circuit_established="${sticky}"
    circuit_confirmed=""
    determine_circuit_confirmed >/dev/null 2>&1
    printf '%s\n' "${circuit_confirmed}"
  )
}
## Gateway uses the active build result and ignores the sticky flag.
chk "gw + build ok (sticky 0)  -> confirmed=1" "1" "$(decide_confirm Gateway 0 0)"
chk "gw + build fail (sticky 1) -> confirmed=0" "0" "$(decide_confirm Gateway 1 1)"
## Workstation cannot EXTENDCIRCUIT (onion-grater); defers to sticky flag.
chk "ws + flag 1 -> confirmed=1" "1" "$(decide_confirm Workstation 1 1)"
chk "ws + flag 0 -> confirmed=0" "0" "$(decide_confirm Workstation 0 0)"

printf '%s\n' "--------------------------------------------------"
printf 'RESULT: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
