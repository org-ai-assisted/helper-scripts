#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Real-Tor test of the "circuit established" FALSE POSITIVE.
##
## sdwdate / onion-time-pre-script use Tor control GETINFO
## status/circuit-established (via tor-circuit-established-check) as the
## "Tor is usable" signal. But that reflects a GENERAL-purpose circuit,
## not onion (rendezvous) reachability - which is what sdwdate's fetch
## actually needs. Maintainer experience: it can read 1 while onion
## connections still time out (e.g. stale consensus).
##
## This proves it: bring up a local Tor net with an onion time source,
## confirm circuit-established=1 AND a working onion fetch, then KILL
## the onion service and check that circuit-established STAYS 1 while the
## onion fetch now times out. Consequence for the now-default gate
## (proceed on circuit established): sdwdate proceeds, the fetch fails,
## and it retries - non-fatal, but it does proceed on a false positive.
##
## Usage: ALLOW_LOCAL=true ./run-circuit-falsepositive-test.sh

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
URL2UT="${URL2UT:-/usr/bin/url_to_unixtime}"
WORK="${WORK:-/tmp/e2e-onion}"
NETWORK="networks/hs-v3-min"
HTTP_PORT=4747
export CHUTNEY_TOR CHUTNEY_TOR_GENCERT

log() { printf '%s\n' "=== $* ==="; }
fail() { printf 'CIRCUIT-FALSEPOSITIVE RESULT: FAIL - %s\n' "$*"; exit 1; }

CHUTNEY="${WORK}/chutney"
HTTP_PID=""
cleanup() {
  [ -n "${HTTP_PID}" ] && kill "${HTTP_PID}" 2>/dev/null
  [ -d "${CHUTNEY}" ] &&
    ( cd "${CHUTNEY}" && ./chutney stop "${NETWORK}" >/dev/null 2>&1 )
  pkill -x tor 2>/dev/null
}
trap cleanup EXIT

ensure_all_nodes_running() {
  local torrc node order
  for order in a r c h; do
    for torrc in net/nodes/*"${order}"/torrc; do
      [ -e "${torrc}" ] || continue
      node="$(basename "$(dirname "${torrc}")")"
      ps -C tor -o args= 2>/dev/null | grep -q "/${node}/torrc" ||
        { nohup "${CHUTNEY_TOR}" -f "${torrc}" \
          >"net/nodes/${node}/launch.log" 2>&1 & disown; }
    done
    sleep 3
  done
}

## circuit-established via the client control port (cookie auth), the
## same GETINFO that tor-circuit-established-check uses.
circuit_established() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys
from stem.control import Controller
try:
    with Controller.from_port(address="127.0.0.1", port=int(sys.argv[1])) as c:
        c.authenticate()
        sys.stdout.write(c.get_info("status/circuit-established"))
except Exception:
    sys.stdout.write("err")
PY
}

fetch() {  ## $1 socksport $2 url -> unixtime or empty
  timeout 45 "${URL2UT}" 127.0.0.1 "$1" "$2" false 2>/dev/null
}

main() {
  command -v "${CHUTNEY_TOR}" >/dev/null || fail "tor missing"
  [ -x "${URL2UT}" ] || fail "url_to_unixtime not at ${URL2UT}"
  python3 -c "import stem, socks" 2>/dev/null ||
    fail "python3 stem/PySocks missing"

  mkdir -p "${WORK}"
  [ -d "${CHUTNEY}" ] || git clone --depth 1 \
    https://github.com/torproject/chutney "${CHUTNEY}"
  cd "${CHUTNEY}" || fail "cd chutney"
  [ -e net/nodes ] || ./chutney configure "${NETWORK}" >/dev/null 2>&1
  local f
  for f in net/nodes/*/torrc; do
    sed -i -E 's/^OrPort ([0-9]+)$/OrPort 0.0.0.0:\1/I; '\
's/^DirPort ([0-9]+)$/DirPort 0.0.0.0:\1/I' "${f}"
    grep -q AddressDisableIPv6 "${f}" ||
      printf '%s\n' "AddressDisableIPv6 1" >>"${f}"
  done

  log "clean slate + launch"
  pkill -x tor 2>/dev/null; pkill -9 -x tor 2>/dev/null
  for f in $(pgrep -x python3 2>/dev/null); do
    grep -aqs http.server "/proc/${f}/cmdline" 2>/dev/null && kill "${f}"
  done
  sleep 2
  ./chutney start "${NETWORK}" >/dev/null 2>&1
  ensure_all_nodes_running

  local socks ctrl
  socks="$(grep -h '^SocksPort ' net/nodes/*c/torrc | awk '{print $2}' \
    | head -1)"
  ctrl="$(grep -h '^ControlPort ' net/nodes/*c/torrc | awk '{print $2}' \
    | head -1)"
  mkdir -p "${WORK}/www"
  ( cd "${WORK}/www" && exec python3 -m http.server "${HTTP_PORT}" \
    --bind 127.0.0.1 ) >"${WORK}/http.log" 2>&1 &
  HTTP_PID="$!"

  log "wait for consensus"
  local w=0
  until ./chutney wait_for_bootstrap "${NETWORK}" >/dev/null 2>&1; do
    ensure_all_nodes_running; sleep 5; w=$((w + 5))
    [ "${w}" -ge 300 ] && break
  done

  log "wait for onion reachability (client socks ${socks})"
  local onion="" out=""
  for w in $(seq 1 90); do
    onion="$(cat net/nodes/*h/hidden_service/hostname 2>/dev/null | head -1)"
    if [ -n "${onion}" ]; then
      out="$(curl -s -m 20 --socks5-hostname "127.0.0.1:${socks}" \
        -I "http://${onion}:5858/" 2>&1 || true)"
      printf '%s' "${out}" | grep -qi '^Date:' && break
    fi
    sleep 8
  done
  printf '%s' "${out}" | grep -qi '^Date:' || fail "onion never reachable"

  local url="http://${onion}:5858"
  log "PHASE 1 (onion service UP)"
  local ce1 f1
  ce1="$(circuit_established "${ctrl}")"
  f1="$(fetch "${socks}" "${url}")"
  printf '  circuit-established=%s   onion fetch=%s\n' "${ce1}" "${f1:-<fail>}"

  log "kill the onion service (007h)"
  local node pid
  for node in net/nodes/*h; do
    for pid in $(ps -C tor -o pid=,args= 2>/dev/null \
      | grep "/$(basename "${node}")/torrc" | awk '{print $1}'); do
      kill "${pid}" 2>/dev/null
    done
  done
  sleep 8

  log "PHASE 2 (onion service DOWN)"
  local ce2 f2
  ce2="$(circuit_established "${ctrl}")"
  f2="$(fetch "${socks}" "${url}")"
  printf '  circuit-established=%s   onion fetch=%s\n' "${ce2}" "${f2:-<fail>}"

  ## Verdict.
  case "${f1}" in ''|*[!0-9]*) fail "phase1 fetch should have worked";; esac
  [ "${ce1}" = "1" ] || fail "phase1 circuit-established should be 1"
  if [ "${ce2}" = "1" ] && { [ -z "${f2}" ] || \
      case "${f2}" in *[!0-9]*) true;; *) false;; esac; }; then
    printf '%s\n' "CIRCUIT-FALSEPOSITIVE RESULT: PASS - with the onion \
DOWN, circuit-established stayed 1 while the onion fetch failed. So \
'circuit established' is a false positive for onion connectivity; the \
default gate proceeds and sdwdate's fetch then fails -> retry (non-fatal)."
  else
    fail "expected ce2=1 and a failed phase2 fetch; got ce2=${ce2} f2=${f2}"
  fi
}

main "$@"
