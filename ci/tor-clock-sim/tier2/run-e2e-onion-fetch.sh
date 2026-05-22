#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## FULL end-to-end test of the circuit-confirmed backward clock fix,
## on real binaries with no external Tor egress and WITHOUT changing
## the host clock.
##
## It stands up a local Tor network (chutney hs-v3-min) containing a
## real onion service that forwards to a true-time HTTP "Date" server,
## then runs sdwdate's real fetch primitive (url_to_unixtime) over real
## Tor circuits against that onion - once at the true clock and once
## under a faked +6h clock - and checks sdwdate's clock math: the fetch
## returns the TRUE time regardless of the fake clock, so sdwdate
## computes a backward (-6h) correction to the true time, gated by the
## replay floor. The actual clock is never set; we compute what
## sdwdate WOULD set.
##
## Requirements: tor, tor-gencert, faketime, git, python3, curl, and
## python3 PySocks (pip install PySocks). Usage:
##   ALLOW_LOCAL=true ./run-e2e-onion-fetch.sh

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
## sdwdate's real fetch primitive (installed path, or repo override).
URL2UT="${URL2UT:-/usr/bin/url_to_unixtime}"
WORK="${WORK:-/tmp/e2e-onion}"
NETWORK="networks/hs-v3-min"
HTTP_PORT=4747   ## onion 5858 -> 127.0.0.1:4747 (hs-v3.tmpl default)
FAST_HOURS="${FAST_HOURS:-6}"
export CHUTNEY_TOR CHUTNEY_TOR_GENCERT

log() { printf '%s\n' "=== $* ==="; }
fail() { printf 'E2E RESULT: FAIL - %s\n' "$*"; exit 1; }

CHUTNEY="${WORK}/chutney"
HTTP_PID=""
cleanup() {
  [ -n "${HTTP_PID}" ] && kill "${HTTP_PID}" 2>/dev/null
  if [ -d "${CHUTNEY}" ]; then
    ( cd "${CHUTNEY}" && ./chutney stop "${NETWORK}" >/dev/null 2>&1 )
  fi
  pkill -x tor 2>/dev/null
}
trap cleanup EXIT

ensure_all_nodes_running() {
  ## chutney's phased launch is flaky in a container; launch any node
  ## whose tor is not running, directly. Auths first, then the rest.
  local torrc node order
  for order in a r c h; do
    for torrc in net/nodes/*"${order}"/torrc; do
      [ -e "${torrc}" ] || continue
      node="$(basename "$(dirname "${torrc}")")"
      if ! ps -C tor -o args= 2>/dev/null | grep -q "/${node}/torrc"; then
        nohup "${CHUTNEY_TOR}" -f "${torrc}" \
          >"net/nodes/${node}/launch.log" 2>&1 &
        disown
      fi
    done
    sleep 3
  done
}

main() {
  command -v faketime >/dev/null || fail "faketime missing"
  command -v "${CHUTNEY_TOR}" >/dev/null || fail "tor missing"
  [ -x "${URL2UT}" ] || fail "url_to_unixtime not found at ${URL2UT}"
  python3 -c "import socks" 2>/dev/null || fail "python3 PySocks missing"

  mkdir -p "${WORK}"
  if [ ! -d "${CHUTNEY}" ]; then
    git clone --depth 1 https://github.com/torproject/chutney "${CHUTNEY}"
  fi
  cd "${CHUTNEY}" || fail "cd chutney"

  log "configure ${NETWORK}"
  ./chutney configure "${NETWORK}" >/dev/null 2>&1 || fail "configure"
  ## IPv4-only fix (no-IPv6 hosts abort on listener bind).
  local f
  for f in net/nodes/*/torrc; do
    sed -i -E 's/^OrPort ([0-9]+)$/OrPort 0.0.0.0:\1/I; '\
's/^DirPort ([0-9]+)$/DirPort 0.0.0.0:\1/I' "${f}"
    grep -q AddressDisableIPv6 "${f}" ||
      printf '%s\n' "AddressDisableIPv6 1" >>"${f}"
  done

  log "launch nodes"
  pkill -x tor 2>/dev/null
  sleep 2
  ./chutney start "${NETWORK}" >/dev/null 2>&1
  ensure_all_nodes_running

  ## Derive the client SOCKS port and start the true-time HTTP server.
  local socksport
  socksport="$(grep -h '^SocksPort ' net/nodes/*c/torrc | awk '{print $2}' | head -1)"
  [ -n "${socksport}" ] || fail "no client SocksPort"
  local socks="127.0.0.1:${socksport}"
  mkdir -p "${WORK}/www"
  ( cd "${WORK}/www" && exec python3 -m http.server "${HTTP_PORT}" \
    --bind 127.0.0.1 ) >"${WORK}/http.log" 2>&1 &
  HTTP_PID="$!"

  ## A cold network must form a consensus (and assign HSDir flags)
  ## before the onion can publish; wait for that before testing it.
  log "wait for network consensus"
  local w=0
  until ./chutney wait_for_bootstrap "${NETWORK}" >/dev/null 2>&1; do
    ensure_all_nodes_running
    sleep 5
    w=$((w + 5))
    [ "${w}" -ge 300 ] && break
  done

  log "wait for onion descriptor + reachability via ${socks}"
  local onion="" out="" i
  for i in $(seq 1 90); do
    onion="$(cat net/nodes/*h/hidden_service/hostname 2>/dev/null | head -1)"
    if [ -n "${onion}" ]; then
      out="$(curl -s -m 20 --socks5-hostname "${socks}" \
        -I "http://${onion}:5858/" 2>&1 || true)"
      printf '%s' "${out}" | grep -qi '^Date:' && break
    fi
    sleep 8
  done
  if ! printf '%s' "${out}" | grep -qi '^Date:'; then
    printf 'diag: onion=%s\n' "${onion:-<none>}"
    printf 'diag: hs log:\n'
    tail -4 net/nodes/*h/notice.log 2>/dev/null
    printf 'diag: client log:\n'
    tail -4 net/nodes/*c/notice.log 2>/dev/null
    fail "onion never reachable (HS warmup/bootstrap)"
  fi
  log "onion reachable: ${onion}"

  ## (1) fetch at the true clock; (2) under a faked fast clock.
  local url="http://${onion}:5858"
  local t_true t_fast faked
  t_true="$(timeout 60 "${URL2UT}" 127.0.0.1 "${socksport}" "${url}" \
    false 2>/dev/null)"
  faked="$(date -u -d "+${FAST_HOURS} hours" '+%Y-%m-%d %H:%M:%S')"
  t_fast="$(FAKETIME_DONT_FAKE_MONOTONIC=1 timeout 60 faketime "${faked}" \
    "${URL2UT}" 127.0.0.1 "${socksport}" "${url}" false 2>/dev/null)"
  log "url_to_unixtime: true-clock=${t_true} faked-clock=${t_fast}"
  case "${t_true}" in ''|*[!0-9]*) fail "true-clock fetch failed";; esac
  case "${t_fast}" in ''|*[!0-9]*) fail "faked-clock fetch failed";; esac

  ## (3) sdwdate clock math.
  python3 - "${t_fast}" "${FAST_HOURS}" <<'PY' || fail "clock math"
import sys, time
remote = int(sys.argv[1])
fast_h = int(sys.argv[2])
faked_now = int(time.time()) + fast_h * 3600
diff = remote - faked_now
new = faked_now + diff
floor = int(time.time()) - 2 * 86400
print(f"  remote(onion)      = {remote}")
print(f"  faked local now    = {faked_now} (+{fast_h}h)")
print(f"  diff = remote - now = {diff/3600:+.2f} h")
print(f"  new = now + diff    = {new} ({(new-faked_now)/3600:+.2f} h)")
print(f"  replay floor        = {floor};  new >= floor: {new >= floor}")
ok = abs(diff + fast_h*3600) < 180 and new >= floor \
    and abs(new - (faked_now - fast_h*3600)) < 180
sys.exit(0 if ok else 1)
PY

  printf 'E2E RESULT: PASS - real onion fetch over Tor under a +%sh '\
'clock yields a backward correction to true now.\n' "${FAST_HOURS}"
}

main "$@"
