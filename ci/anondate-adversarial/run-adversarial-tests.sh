#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Adversarial tests for the REAL anondate-set / minimum-* scripts.
##
## Threat model: an adversary controls what Tor reports, i.e. what
## 'anondate-get' returns (a proposed time + exit code). anondate-set's
## security guards must hold regardless:
##   - never move the clock BACKWARD (replay protection),
##   - never set BELOW minimum-unixtime-show (the replay floor),
##   - and minimum-unixtime-show must take the MAX (an attacker cannot
##     LOWER the floor by writing a small value to one input file).
##
## Safety: the only clock-write in anondate-set is 'date ... --set',
## which this harness intercepts and RECORDS - the real system clock is
## never changed. Tor-facing inputs (anondate-get) are stubbed, so no
## Tor is required.
##
## Usage: ALLOW_LOCAL=true sudo ./run-adversarial-tests.sh

set -o errexit
set -o nounset
set -o pipefail

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "true" ]; then
  printf '%s\n' "$0: refuse outside CI; set ALLOW_LOCAL=true." >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]; then
  printf '%s\n' "$0: must run as root (creates /run/anondate etc)." >&2
  exit 1
fi

REPO="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
export HELPER_SCRIPTS_PATH="${REPO}"
ANONDATE_SET="${REPO}/usr/sbin/anondate-set"
MIN_SHOW="${REPO}/usr/bin/minimum-unixtime-show"
MIN_CHECK="${REPO}/usr/bin/minimum-time-check"

DAY=86400
HOUR=3600
FLOOR=1700000000  ## 2023-11-14 - the simulated replay floor

WORK="$(mktemp -d)"
STUB="${WORK}/bin"
mkdir -p -- "${STUB}"
RECORD_SET_FILE="${WORK}/set-requests.txt"
export RECORD_SET_FILE

## Files we create and must remove afterwards.
CREATED=()
cleanup() {
  local f
  for f in "${CREATED[@]:-}"; do [ -n "${f}" ] && rm -f -- "${f}"; done
  rm -f -- /run/anondate/tor_certificate_lifetime_set 2>/dev/null || true
  rm -rf -- "${WORK}"
}
trap cleanup EXIT

set_floor_file() {
  ## $1 path, $2 value. Refuse to clobber a pre-existing file.
  if [ -e "$1" ]; then
    printf '%s\n' "PRE-EXISTING ${1}; aborting to avoid clobber." >&2
    exit 1
  fi
  mkdir -p -- "$(dirname -- "$1")"
  printf '%s' "$2" >"$1"
  CREATED+=("$1")
}

## ---- stubs -------------------------------------------------------
cat >"${STUB}/date" <<'STUB'
#!/bin/bash
## date stub: current time = FAKE_NOW_EPOCH; --set is recorded only.
set_mode=0; set_val=""; date_arg=""; fmt=""; have_date=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set) set_mode=1; shift; set_val="${1:-}";;
    --set=*) set_mode=1; set_val="${1#--set=}";;
    --date) have_date=1; shift; date_arg="${1:-}";;
    --date=*) have_date=1; date_arg="${1#--date=}";;
    --utc|-u) : ;;
    +*) fmt="$1";;
    *) : ;;
  esac
  shift || true
done
if [ "$set_mode" = 1 ]; then
  printf '%s\n' "$set_val" >>"$RECORD_SET_FILE"
  printf '%s\n' "(stubbed set; clock unchanged)"
  exit 0
fi
if [ "$have_date" = 1 ]; then
  exec /usr/bin/date --utc --date "$date_arg" "$fmt"
fi
if [ -n "${FAKE_NOW_EPOCH:-}" ]; then
  exec /usr/bin/date --utc --date "@${FAKE_NOW_EPOCH}" "$fmt"
fi
exec /usr/bin/date --utc "$fmt"
STUB

cat >"${STUB}/anondate-get" <<'STUB'
#!/bin/bash
printf '%s\n' "${ANONDATE_GET_RESULT:-}"
printf '%s\n' "${ANONDATE_GET_STDERR:-stub}" >&2
exit "${ANONDATE_GET_EXIT:-0}"
STUB

cat >"${STUB}/systemd-cat" <<'STUB'
#!/bin/bash
cat >/dev/null 2>&1 || true
STUB

chmod +x "${STUB}/date" "${STUB}/anondate-get" "${STUB}/systemd-cat"
## Stubs first; then the REAL minimum-* scripts; then the system.
export PATH="${STUB}:${REPO}/usr/bin:${REPO}/usr/sbin:${PATH}"

## ---- assertions --------------------------------------------------
PASS=0; FAIL=0
hr() { /usr/bin/date -u --date "@$1" '+%Y-%m-%d %H:%M:%S'; }

check() {
  ## $1 label, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then
    printf '  PASS  %-44s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %-44s exp=%s got=%s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

run_set() {
  ## $1 fake_now, $2 target_epoch, $3 get_exit. Echoes "rc did_set".
  : >"${RECORD_SET_FILE}"
  export FAKE_NOW_EPOCH="$1"
  export ANONDATE_GET_EXIT="$3"
  ANONDATE_GET_RESULT="$(hr "$2")"; export ANONDATE_GET_RESULT
  local rc=0
  "${ANONDATE_SET}" >/dev/null 2>&1 || rc=$?
  local did="no"; [ -s "${RECORD_SET_FILE}" ] && did="yes"
  printf '%s %s\n' "${rc}" "${did}"
}

main() {
  printf '%s\n' "=================================================="
  printf '%s\n' "anondate adversarial tests (real scripts; clock"
  printf '%s\n' "writes intercepted). floor=$(hr ${FLOOR})"
  printf '%s\n' "=================================================="

  ## Replay floor used by minimum-time-check during set scenarios.
  set_floor_file /usr/local/etc/minimum-unixtime "${FLOOR}"
  mkdir -p /run/anondate

  printf '\n[A] replay: clock ok, attacker proposes time 6h EARLIER\n'
  read -r rc did < <(run_set "$((FLOOR + 2 * DAY))" \
    "$((FLOOR + 2 * DAY - 6 * HOUR))" 0)
  check "refuses backward set" "no" "${did}"
  check "exit code 3 (not-needed)" "3" "${rc}"

  printf '\n[B] floor: clock behind floor, target forward but BELOW floor\n'
  read -r rc did < <(run_set "$((FLOOR - 2 * DAY))" \
    "$((FLOOR - 1 * DAY))" 0)
  check "refuses sub-floor set" "no" "${did}"
  check "exit code 3" "3" "${rc}"

  printf '\n[C] baseline: slow clock, legit FORWARD target above floor\n'
  read -r rc did < <(run_set "$((FLOOR + 1 * DAY))" \
    "$((FLOOR + 1 * DAY + 2 * HOUR))" 0)
  check "performs forward set" "yes" "${did}"
  check "exit code 0" "0" "${rc}"

  printf '\n[D] dual-boot: FAST clock, honest target = true now (earlier)\n'
  read -r rc did < <(run_set "$((FLOOR + 5 * DAY))" \
    "$((FLOOR + 1 * DAY))" 0)
  check "refuses to fix fast clock (deadlock)" "no" "${did}"
  check "exit code 3" "3" "${rc}"

  printf '\n[E] cert-lifetime (exit 2): forward set only ONCE per boot\n'
  rm -f /run/anondate/tor_certificate_lifetime_set
  read -r rc did < <(run_set "$((FLOOR + 1 * DAY))" \
    "$((FLOOR + 1 * DAY + 2 * HOUR))" 2)
  check "first run sets forward" "yes" "${did}"
  read -r rc did < <(run_set "$((FLOOR + 1 * DAY))" \
    "$((FLOOR + 1 * DAY + 2 * HOUR))" 2)
  check "second run does NOT set again" "no" "${did}"
  rm -f /run/anondate/tor_certificate_lifetime_set

  printf '\n[F] floor integrity: minimum-unixtime-show takes the MAX\n'
  ## /usr/local/etc/minimum-unixtime already = FLOOR (high). Add a LOW
  ## attacker value in /etc/minimum-unixtime; output must stay = FLOOR.
  set_floor_file /etc/minimum-unixtime "1650000000"
  got="$("${MIN_SHOW}" 2>/dev/null)"
  check "MAX wins (attacker cannot lower)" "${FLOOR}" "${got}"
  rm -f /etc/minimum-unixtime

  printf '\n[G] minimum-time-check accept/reject + malformed input\n'
  rc=0; "${MIN_CHECK}" "$((FLOOR + 1))" >/dev/null 2>&1 || rc=$?
  check "accepts time >= floor" "0" "${rc}"
  rc=0; "${MIN_CHECK}" "$((FLOOR - 1))" >/dev/null 2>&1 || rc=$?
  check "rejects time < floor" "1" "${rc}"
  rc=0; "${MIN_CHECK}" "not-a-number" >/dev/null 2>&1 || rc=$?
  check "rejects malformed input" "1" "${rc}"

  printf '\n--------------------------------------------------\n'
  printf 'RESULT: %s passed, %s failed\n' "${PASS}" "${FAIL}"
  [ "${FAIL}" -eq 0 ]
}

main "$@"
