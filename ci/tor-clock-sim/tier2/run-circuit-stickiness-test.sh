#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Real-Tor test: "circuit established" is a FALSE POSITIVE even for
## GENERAL-purpose circuits, not only onion reachability.
##
## Maintainer experience: GETINFO status/circuit-established can read 1
## while general traffic does not flow. The C-Tor source confirms why:
## status/circuit-established returns have_completed_a_circuit(), a
## sticky global flag (can_complete_circuits) that is SET once on the
## first multi-hop circuit ever built and reset to 0 ONLY on coarse,
## event-driven triggers - a clock jump / long idle
## (circuit_note_clock_jumped), directory info going too stale
## (NOT_ENOUGH_DIR_INFO), or process teardown. A network that silently
## dies WITHOUT tripping one of those triggers leaves the flag at 1.
##
## Demonstration (local Tor net): bring the client to
## circuit-established=1, then kill every relay and authority (the
## network is now provably dead - 0 such tor processes), yet the
## client's circuit-established still reads 1 within the cached-info
## window. Corroboration: a general SOCKS connect through the client
## then fails. So circuit-established=1 does not imply current
## general-circuit connectivity; it is a stale historical signal.
##
## Consequence for sdwdate's default gate: it proceeds on this stale 1,
## but the time-source fetch is the ground-truth probe and fails closed
## -> retry. A false positive can only cost a retry, never a wrong set.
##
## The control query uses a raw control-port socket (not stem), because
## stem.control pulls in cryptography, whose Rust bindings may be broken
## in minimal environments.
##
## Usage: ALLOW_LOCAL=true ./run-circuit-stickiness-test.sh

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
WORK="${WORK:-/tmp/cstick-test}"
NETWORK="networks/basic-min"
export CHUTNEY_TOR CHUTNEY_TOR_GENCERT

log() { printf '%s\n' "=== $* ==="; }
fail() { printf 'CIRCUIT-STICKINESS RESULT: FAIL - %s\n' "$*"; exit 1; }

CHUTNEY="${WORK}/chutney"
cleanup() {
  [ -d "${CHUTNEY}" ] &&
    ( cd "${CHUTNEY}" && ./chutney stop "${NETWORK}" >/dev/null 2>&1 )
  pkill -x tor 2>/dev/null
}
trap cleanup EXIT

ensure_all_nodes_running() {
  local torrc node order
  for order in a r c; do
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

## circuit-established over a raw control socket (cookie auth). Avoids
## stem (its cryptography import can be broken in minimal envs).
circuit_established() {  ## $1 control port, $2 cookie file
  python3 - "$1" "$2" <<'PY'
import sys, socket, binascii
try:
    port = int(sys.argv[1])
    with open(sys.argv[2], "rb") as fh:
        cookie = fh.read()
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.settimeout(10)
    s.sendall(b"AUTHENTICATE " + binascii.hexlify(cookie) + b"\r\n")
    s.recv(4096)
    s.sendall(b"GETINFO status/circuit-established\r\n")
    data = s.recv(8192).decode("ascii", "replace")
    s.close()
    val = "empty"
    for line in data.splitlines():
        if "circuit-established=" in line:
            val = line.split("=", 1)[1].strip()
    sys.stdout.write(val)
except Exception as exc:
    sys.stdout.write("err:" + type(exc).__name__)
PY
}

## A general (non-onion) SOCKS5 CONNECT through the client. With the
## network dead, Tor cannot carry the stream -> non-success or timeout.
socks_general_connect() {  ## $1 socksport -> "ok" | "fail"
  python3 - "$1" <<'PY'
import sys, socket
port = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(8)
    s.sendall(b"\x05\x01\x00")
    if s.recv(2) != b"\x05\x00":
        sys.stdout.write("fail"); sys.exit()
    host = b"example.com"
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host
              + (80).to_bytes(2, "big"))
    r = s.recv(10)
    sys.stdout.write("ok" if (len(r) >= 2 and r[1] == 0) else "fail")
except Exception:
    sys.stdout.write("fail")
PY
}

kill_relays_and_authorities() {  ## leave only the client (*c) alive
  local node pid order
  for order in a r; do
    for node in "${CHUTNEY}"/net/nodes/*"${order}"; do
      [ -d "${node}" ] || continue
      for pid in $(ps -C tor -o pid=,args= 2>/dev/null \
        | grep "/$(basename "${node}")/torrc" | awk '{print $1}'); do
        kill -9 "${pid}" 2>/dev/null
      done
    done
  done
}

network_tor_count() {  ## count live relay/authority tor procs (not client)
  local n=0 order node
  for order in a r; do
    for node in "${CHUTNEY}"/net/nodes/*"${order}"; do
      [ -d "${node}" ] || continue
      ps -C tor -o args= 2>/dev/null \
        | grep -q "/$(basename "${node}")/torrc" && n=$((n + 1))
    done
  done
  printf '%s' "${n}"
}

main() {
  command -v "${CHUTNEY_TOR}" >/dev/null || fail "tor missing"

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
  pkill -x tor 2>/dev/null; pkill -9 -x tor 2>/dev/null; sleep 2
  ./chutney start "${NETWORK}" >/dev/null 2>&1
  ensure_all_nodes_running

  local socks ctrl datadir cookie
  socks="$(grep -h '^SocksPort ' net/nodes/*c/torrc | awk '{print $2}' \
    | head -1)"
  ctrl="$(grep -h '^ControlPort ' net/nodes/*c/torrc | awk '{print $2}' \
    | head -1)"
  datadir="$(grep -h '^DataDirectory ' net/nodes/*c/torrc \
    | awk '{print $2}' | head -1)"
  cookie="${datadir}/control_auth_cookie"

  log "wait for circuit (client control ${ctrl})"
  local ce="" w
  for w in $(seq 1 60); do
    ensure_all_nodes_running >/dev/null 2>&1
    [ -e "${cookie}" ] && ce="$(circuit_established "${ctrl}" "${cookie}")"
    [ "${ce}" = "1" ] && break
    sleep 5
  done
  printf '  circuit-established (network alive) = %s\n' "${ce:-<none>}"
  [ "${ce}" = "1" ] || fail "client never reported a circuit (got '${ce}')"

  log "kill ALL relays + authorities (leave only the client)"
  kill_relays_and_authorities
  sleep 3
  local live
  live="$(network_tor_count)"
  printf '  live relay/authority tor processes now = %s\n' "${live}"
  [ "${live}" = "0" ] ||
    fail "network not fully dead (${live} relay/authority tor still up)"

  ## The network is provably dead. Read the flag a few times inside the
  ## cached-info window; a stale 1 here is the false positive.
  log "probe stale flag + general connectivity (network is dead)"
  local stale="no" t ce_dead sc
  for t in 3 8 13; do
    ce_dead="$(circuit_established "${ctrl}" "${cookie}")"
    sc="$(socks_general_connect "${socks}")"
    printf '  +%2ss after kill: circuit-established=%s   general-socks=%s\n' \
      "${t}" "${ce_dead}" "${sc}"
    [ "${ce_dead}" = "1" ] && [ "${sc}" = "fail" ] && stale="yes"
    sleep 5
  done

  if [ "${stale}" = "yes" ]; then
    printf '%s\n' "CIRCUIT-STICKINESS RESULT: PASS - with every relay and \
authority killed (network provably dead, 0 such tor processes), the \
client still reported circuit-established=1 while a general SOCKS \
connect failed. 'circuit established' is a sticky historical flag, NOT \
a live connectivity check, so it is a false positive even for \
general-purpose circuits. sdwdate's default gate proceeds on it; the \
fetch then fails -> retry (non-fatal, never a wrong set)."
  else
    fail "expected a window with circuit-established=1 and a failed \
general connect after the network died"
  fi
}

main "$@"
