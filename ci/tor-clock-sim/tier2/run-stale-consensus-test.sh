#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Stale-consensus safety test (real Tor consensus, no onion needed).
##
## Why it matters: with the circuit-confirmed backward fix now default,
## a clock that is "fast" per the Tor consensus proceeds. But the SAME
## "fast" verdict (current >= consensus/valid-until) also arises when
## the CLOCK is correct and the cached consensus is merely STALE (e.g. a
## gateway that was off for a while). This test proves the verdict and
## its consequence: the consensus-sanity check that gates sdwdate flips
## ok -> fast as a real consensus ages past valid-until. That same check
## is applied per source in sdwdate's fetch (remote_times.py), so in the
## stale case the (correct) fetched times are ALSO flagged "fast" and
## REJECTED - sdwdate sets nothing and retries until a fresh consensus
## arrives. No wrong clock is set.
##
## Method: bring up a local chutney network, read the real consensus
## valid-after/valid-until, then stop the authorities so the cached
## consensus ages past valid-until, and show the verdict flip.
##
## Requirements: tor, tor-gencert, git, python3, GNU date.
## Usage: ALLOW_LOCAL=true ./run-stale-consensus-test.sh

set -o pipefail

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "true" ]; then
  printf '%s\n' "$0: refuse outside CI; set ALLOW_LOCAL=true." >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]; then
  printf '%s\n' "$0: must run as root." >&2
  exit 1
fi

CHUTNEY_TOR="${CHUTNEY_TOR:-/usr/bin/tor}"
CHUTNEY_TOR_GENCERT="${CHUTNEY_TOR_GENCERT:-/usr/bin/tor-gencert}"
WORK="${WORK:-/tmp/stale-consensus}"
NETWORK="networks/basic-min"
AGE_TIMEOUT="${AGE_TIMEOUT:-420}"
export CHUTNEY_TOR CHUTNEY_TOR_GENCERT

log() { printf '%s\n' "=== $* ==="; }
fail() { printf 'STALE-CONSENSUS RESULT: FAIL - %s\n' "$*"; exit 1; }

CHUTNEY="${WORK}/chutney"
cleanup() {
  [ -d "${CHUTNEY}" ] &&
    ( cd "${CHUTNEY}" && ./chutney stop "${NETWORK}" >/dev/null 2>&1 )
  pkill -x tor 2>/dev/null
}
trap cleanup EXIT

## slow | ok | fast - exactly onion-time-pre-script's verdict.
verdict() {
  if [ "$1" -lt "$2" ]; then printf 'slow\n'
  elif [ "$1" -ge "$3" ]; then printf 'fast\n'
  else printf 'ok\n'; fi
}

read_consensus_field() {
  ## $1 = field (valid-after|valid-until). Echo "YYYY-MM-DD HH:MM:SS".
  local f
  f="$(ls "${CHUTNEY}"/net/nodes/*/cached-microdesc-consensus \
    2>/dev/null | head -1)"
  [ -n "${f}" ] || return 1
  sed -n "s/^$1 \([0-9].*\)\$/\1/p" "${f}" | head -1
}

stop_authorities() {
  local node pid
  for node in "${CHUTNEY}"/net/nodes/*a; do
    [ -d "${node}" ] || continue
    for pid in $(ps -C tor -o pid=,args= 2>/dev/null \
      | grep "/$(basename "${node}")/torrc" | awk '{print $1}'); do
      kill "${pid}" 2>/dev/null
    done
  done
}

main() {
  command -v "${CHUTNEY_TOR}" >/dev/null || fail "tor missing"
  mkdir -p "${WORK}"
  [ -d "${CHUTNEY}" ] || git clone --depth 1 \
    https://github.com/torproject/chutney "${CHUTNEY}"
  cd "${CHUTNEY}" || fail "cd chutney"

  log "configure ${NETWORK}"
  ./chutney configure "${NETWORK}" >/dev/null 2>&1 || fail "configure"
  local f
  for f in net/nodes/*/torrc; do
    sed -i -E 's/^OrPort ([0-9]+)$/OrPort 0.0.0.0:\1/I; '\
's/^DirPort ([0-9]+)$/DirPort 0.0.0.0:\1/I' "${f}"
    grep -q AddressDisableIPv6 "${f}" ||
      printf '%s\n' "AddressDisableIPv6 1" >>"${f}"
  done

  log "start + wait for consensus"
  pkill -x tor 2>/dev/null
  pkill -9 -x tor 2>/dev/null
  sleep 2
  ./chutney start "${NETWORK}" >/dev/null 2>&1
  local w=0
  until ./chutney wait_for_bootstrap "${NETWORK}" >/dev/null 2>&1; do
    sleep 5; w=$((w + 5)); [ "${w}" -ge 240 ] && break
  done

  ## Get a FRESH consensus (now < valid-until). Authorities keep voting,
  ## so retry until we catch a fresh one.
  local va vu va_e vu_e now
  for w in $(seq 1 24); do
    va="$(read_consensus_field valid-after)"
    vu="$(read_consensus_field valid-until)"
    [ -n "${vu}" ] || { sleep 5; continue; }
    va_e="$(date -u -d "${va}" +%s 2>/dev/null)"
    vu_e="$(date -u -d "${vu}" +%s 2>/dev/null)"
    now="$(date -u +%s)"
    [ -n "${vu_e}" ] && [ "${now}" -lt "${vu_e}" ] && break
    sleep 5
  done
  [ -n "${vu_e}" ] || fail "no consensus valid-until found"

  log "fresh consensus: valid-after='${va}' valid-until='${vu}'"
  now="$(date -u +%s)"
  local v_fresh
  v_fresh="$(verdict "${now}" "${va_e}" "${vu_e}")"
  printf '  now=%s in [va,vu] -> verdict=%s\n' "${now}" "${v_fresh}"
  [ "${v_fresh}" = "ok" ] ||
    fail "expected fresh verdict 'ok', got '${v_fresh}'"

  log "stop authorities so the cached consensus goes stale"
  stop_authorities

  ## Wait for real aging: now to pass valid-until.
  local aged="no"
  for w in $(seq 1 "$((AGE_TIMEOUT / 5))"); do
    now="$(date -u +%s)"
    [ "${now}" -gt "${vu_e}" ] && { aged="yes"; break; }
    sleep 5
  done
  [ "${aged}" = "yes" ] || fail "consensus did not age past valid-until \
within ${AGE_TIMEOUT}s (valid-until too far out)"

  ## Same cached consensus is still present (Tor keeps it for circuits),
  ## but now is past its valid-until -> STALE.
  va="$(read_consensus_field valid-after)"
  vu="$(read_consensus_field valid-until)"
  va_e="$(date -u -d "${va}" +%s)"
  vu_e="$(date -u -d "${vu}" +%s)"
  now="$(date -u +%s)"
  log "stale consensus: valid-until='${vu}' now is $(( (now - vu_e) ))s past it"
  local v_stale
  v_stale="$(verdict "${now}" "${va_e}" "${vu_e}")"
  printf '  correct clock now=%s, consensus stale -> verdict=%s\n' \
    "${now}" "${v_stale}"
  [ "${v_stale}" = "fast" ] ||
    fail "expected stale verdict 'fast', got '${v_stale}'"

  printf '%s\n' "STALE-CONSENSUS RESULT: PASS - verdict flips ok->fast as \
the consensus ages; the correct clock now reads 'fast', so sdwdate's \
per-source check rejects the (correct) fetched times instead of \
mis-setting the clock (it retries until a fresh consensus arrives)."
}

main "$@"
