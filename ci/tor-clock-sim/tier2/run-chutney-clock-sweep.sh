#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Tier-2 harness: measure the REAL tor client clock-skew tolerance
## against a local private Tor network (chutney), to confirm or refute
## the Tier-1 model's predicted tolerance window
## (~ -24h .. +27h for C-Tor). No external Tor egress is needed; the
## whole network runs on localhost.
##
## What it does:
##   1. Clone chutney (if missing) and configure a small network.
##   2. Apply the IPv4-only fix (this harness was developed in a
##      container with no IPv6; tor treats a failed IPv6 listener bind
##      as fatal, so OR/Dir ports are pinned to 0.0.0.0).
##   3. Start the network and wait for a consensus.
##   4. For each clock offset, launch a SEPARATE real tor client under
##      faketime (network nodes stay at real time) and record whether
##      it reaches "Bootstrapped 100%".
##   5. Print a results table and tear the network down.
##
## Requirements: tor, tor-gencert, faketime, git, python3.
## Usage: ALLOW_LOCAL=true ./run-chutney-clock-sweep.sh
## Tunables (env): CHUTNEY_TOR, CHUTNEY_TOR_GENCERT, WORK_DIR,
##   OFFSETS_HOURS, NETWORK, BOOTSTRAP_TIMEOUT, CLIENT_TIMEOUT.

set -o errexit
set -o nounset
set -o pipefail

CHUTNEY_TOR="${CHUTNEY_TOR:-/usr/bin/tor}"
CHUTNEY_TOR_GENCERT="${CHUTNEY_TOR_GENCERT:-/usr/bin/tor-gencert}"
WORK_DIR="${WORK_DIR:-/tmp/tier2-chutney}"
NETWORK="${NETWORK:-networks/basic-min}"
## Offsets to probe, in hours (relative to true time). The model
## predicts builds within roughly [-24h, +27h] for C-Tor.
OFFSETS_HOURS="${OFFSETS_HOURS:--48 -24 -6 0 6 24 27 30 48}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-180}"
## Max seconds to wait for a client to bootstrap. A client whose clock
## is outside tolerance never bootstraps, so this only bounds the
## failure case; successful clients are detected and killed early.
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-45}"

export CHUTNEY_TOR CHUTNEY_TOR_GENCERT

log() { printf '%s\n' "=== $* ==="; }

require() {
  local tool
  for tool in "$@"; do
    command -v -- "$tool" >/dev/null 2>&1 ||
      { printf '%s\n' "MISSING: $tool" >&2; exit 1; }
  done
}

ipv4_only_fix() {
  ## Pin OR/Dir ports to IPv4 so a missing-IPv6 host does not abort tor
  ## with "Failed to bind one of the listener ports."
  local f
  for f in "${CHUTNEY_PATH}"/net/nodes/*/torrc; do
    sed -i -E \
      's/^OrPort ([0-9]+)$/OrPort 0.0.0.0:\1/I; '\
's/^DirPort ([0-9]+)$/DirPort 0.0.0.0:\1/I' "$f"
    grep -q AddressDisableIPv6 "$f" ||
      printf '%s\n' "AddressDisableIPv6 1" >>"$f"
  done
}

extract_authorities() {
  ## DirAuthority lines are identical across nodes; take them from one.
  grep -h '^DirAuthority ' \
    "${CHUTNEY_PATH}"/net/nodes/000a/torrc
}

client_bootstraps_at_offset() {
  ## $1 = offset hours. Returns "YES"/"NO" on stdout.
  local off="$1"
  local cdir="${WORK_DIR}/client_${off}"
  rm -rf -- "$cdir"; mkdir -p -- "$cdir/data"; chmod 700 -- "$cdir/data"
  {
    printf '%s\n' "TestingTorNetwork 1"
    printf '%s\n' "DataDirectory ${cdir}/data"
    printf '%s\n' "Log notice file ${cdir}/notice.log"
    printf '%s\n' "SocksPort auto"
    printf '%s\n' "ControlPort auto"
    printf '%s\n' "OrPort 0"
    printf '%s\n' "DirPort 0"
    printf '%s\n' "ClientOnly 1"
    printf '%s\n' "AddressDisableIPv6 1"
    printf '%s\n' "RunAsDaemon 0"
    extract_authorities
  } >"${cdir}/torrc"

  local faked
  faked="$(date -u -d "${off} hours" '+%Y-%m-%d %H:%M:%S')"
  ## Do not fake the monotonic clock or tor's internal timers break.
  ## Run in the background and kill as soon as it bootstraps - tor is a
  ## daemon and would otherwise sit until CLIENT_TIMEOUT even on
  ## success, making the whole sweep needlessly slow.
  FAKETIME_DONT_FAKE_MONOTONIC=1 \
    faketime "${faked}" \
    "${CHUTNEY_TOR}" -f "${cdir}/torrc" >/dev/null 2>&1 &
  local pid="$!"

  local result="NO" waited=0
  while [ "${waited}" -lt "${CLIENT_TIMEOUT}" ]; do
    if grep -aq "Bootstrapped 100%" "${cdir}/notice.log" 2>/dev/null
    then
      result="YES"; break
    fi
    kill -0 "${pid}" 2>/dev/null || break  ## tor died
    sleep 1
    waited=$((waited + 1))
  done
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  printf '%s\n' "${result}"
}

main() {
  require git python3 "${CHUTNEY_TOR}" "${CHUTNEY_TOR_GENCERT}" faketime

  mkdir -p -- "${WORK_DIR}"
  CHUTNEY_PATH="${WORK_DIR}/chutney"
  if [ ! -d "${CHUTNEY_PATH}" ]; then
    log "cloning chutney"
    git clone --depth 1 https://github.com/torproject/chutney \
      "${CHUTNEY_PATH}"
  fi
  cd -- "${CHUTNEY_PATH}"

  log "configure ${NETWORK}"
  ./chutney configure "${NETWORK}" >/dev/null
  ipv4_only_fix
  log "start ${NETWORK}"
  ./chutney start "${NETWORK}" >/dev/null

  log "wait for consensus (<= ${BOOTSTRAP_TIMEOUT}s)"
  local waited=0
  until ./chutney wait_for_bootstrap "${NETWORK}" >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    [ "${waited}" -ge "${BOOTSTRAP_TIMEOUT}" ] && break
  done

  log "RESULTS: real tor ${CHUTNEY_TOR##*/} client bootstrap vs clock offset"
  ## Probe every offset in PARALLEL. Each client has its own datadir
  ## and uses SocksPort/ControlPort auto, so there are no conflicts;
  ## the sweep then costs ~one client timeout instead of their sum.
  local off
  local pids=()
  for off in ${OFFSETS_HOURS}; do
    { client_bootstraps_at_offset "${off}" \
        >"${WORK_DIR}/result_${off}" 2>/dev/null; } &
    pids+=("$!")
  done
  wait "${pids[@]}" 2>/dev/null || true

  printf '  %8s | %s\n' "offset" "bootstraps?"
  for off in ${OFFSETS_HOURS}; do
    local sign="+"; [ "${off#-}" != "${off}" ] && sign=""
    printf '  %8s | %s\n' "${sign}${off}h" \
      "$(cat "${WORK_DIR}/result_${off}" 2>/dev/null || printf 'ERR')"
  done

  log "teardown"
  ./chutney stop "${NETWORK}" >/dev/null 2>&1 || true
}

main "$@"
