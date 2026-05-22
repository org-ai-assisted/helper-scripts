#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Real-Tor test: "circuit established" is a FALSE POSITIVE for onion
## reachability.
##
## sdwdate / onion-time-pre-script gate on Tor control GETINFO
## status/circuit-established (via tor-circuit-established-check). That
## reflects a GENERAL-purpose circuit, NOT onion (rendezvous)
## reachability - which is what sdwdate's onion time-source fetch needs.
## Maintainer experience: it can read 1 while onion connections fail.
##
## Demonstration (local Tor net, no onion service needed): with the
## client reporting circuit-established=1, an onion fetch to a valid but
## unpublished .onion still fails. So circuit-established=1 does not
## imply the onion time sources are reachable. Consequence for the now
## default gate (proceed on circuit established): sdwdate proceeds, the
## fetch fails, and it retries - non-fatal, but it does proceed on a
## false positive, so a real onion-connectivity probe would be a more
## accurate gate.
##
## The control query uses a raw control-port socket (not stem), because
## stem.control pulls in cryptography, whose Rust bindings may be broken
## in minimal environments.
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
WORK="${WORK:-/tmp/cfp-test}"
NETWORK="networks/basic-min"
## A valid v3 .onion that is NOT published in this network -> a general
## circuit exists, but this onion lookup must fail.
ABSENT_ONION="${ABSENT_ONION:-\
4skwf7fw3xgxidig2g4xunzlzldpbfhdi74q47bw62j3mm3m4axldcid.onion}"
export CHUTNEY_TOR CHUTNEY_TOR_GENCERT

log() { printf '%s\n' "=== $* ==="; }
fail() { printf 'CIRCUIT-FALSEPOSITIVE RESULT: FAIL - %s\n' "$*"; exit 1; }

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

fetch() {  ## $1 socksport $2 url -> unixtime or empty
  timeout 45 python3 "${URL2UT}" 127.0.0.1 "$1" "$2" false 2>/dev/null
}

main() {
  command -v "${CHUTNEY_TOR}" >/dev/null || fail "tor missing"
  [ -x "${URL2UT}" ] || fail "url_to_unixtime not at ${URL2UT}"
  python3 -c "import socks, requests, dateutil" 2>/dev/null ||
    fail "python3 PySocks/requests/dateutil missing"

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
  printf '  circuit-established = %s\n' "${ce:-<none>}"
  [ "${ce}" = "1" ] || fail "client never reported a circuit (got '${ce}')"

  log "fetch a valid-but-UNPUBLISHED onion via client socks ${socks}"
  local url="http://${ABSENT_ONION}:5858"
  local out
  out="$(fetch "${socks}" "${url}")"
  local ce2
  ce2="$(circuit_established "${ctrl}" "${cookie}")"
  printf '  circuit-established = %s   absent-onion fetch = %s\n' \
    "${ce2}" "${out:-<fail>}"

  ## Verdict: a general circuit exists, but the onion fetch fails.
  if [ "${ce2}" = "1" ] && { [ -z "${out}" ] || \
      case "${out}" in *[!0-9]*) true;; *) false;; esac; }; then
    printf '%s\n' "CIRCUIT-FALSEPOSITIVE RESULT: PASS - circuit-established=1 \
yet the onion fetch failed. 'circuit established' (a general-purpose \
circuit) does NOT imply onion reachability, confirming it is a false \
positive for sdwdate's needs; the default gate proceeds on it and the \
fetch then fails -> retry (non-fatal)."
  else
    fail "expected circuit=1 and a failed onion fetch; got ce=${ce2} out=${out}"
  fi
}

main "$@"
