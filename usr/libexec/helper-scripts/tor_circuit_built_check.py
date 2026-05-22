#!/usr/bin/python3 -Bsu

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Check whether Tor's transport is live RIGHT NOW by actively building one
## fresh general-purpose circuit and waiting for it to reach BUILT. The build
## sends EXTENDCIRCUIT 0 (no path given), so Tor's own path selection picks the
## relays - there is no named clearnet host and no named onion destination, and
## therefore no single point of centralization to depend on. Reaching BUILT
## proves, at this moment, that the guard link is up and the ntor handshakes
## with guard, middle and exit all completed with cells flowing bidirectionally
## through the circuit (the EXTENDED cells return over the circuit itself).
##
## Why active, not status/circuit-established (tor-circuit-established-check):
## that value is C-Tor's sticky have_completed_a_circuit() flag - set once on
## the first multi-hop circuit and reset only on a clock-jump/idle, stale
## directory info, or process teardown, never on a failed fetch - so it can
## read 1 long after the paths it referred to are gone, a false positive even
## for general-purpose (not just onion) circuits:
##   https://gitlab.torproject.org/tpo/core/tor/-/issues/28027
##   https://gitlab.torproject.org/tpo/core/tor/-/issues/21422
## Forcing a brand-new build sidesteps staleness by construction: freshness is
## guaranteed by us, not left to whether Tor happened to build a circuit
## recently. A passive "is any built circuit fresh?" check cannot offer that -
## on an idle, long-running Tor every existing circuit can already be many
## minutes old while Tor is perfectly healthy, so a tight freshness window
## would false-negative and a loose one would let staleness back in.
##
## Scope - this proves Tor TRANSPORT liveness, not reachability of the open
## internet or of any onion service. That heavier end-to-end proof is
## onion-time-pre-script's job and is expected to have already run and passed
## before sdwdate starts; by then "Tor is most likely fully ready" and this
## check only needs to confirm that a circuit can still be built right now. For
## the end-to-end usability signal (an actual stream reaching SUCCEEDED) see the
## passive companion tor_stream_success_check.py, which needs traffic to
## observe; this script needs no destination and generates only the one extra
## circuit, making it a decentralized, non-stale boot-time liveness gate.
##
## Exit codes (mirroring tor-circuit-established-check):
##   0   - a freshly built circuit reached BUILT within the timeout
##   1   - no freshly built circuit reached BUILT within the timeout
##   255 - could not connect to the Tor control port
##
## Usage: tor_circuit_built_check.py [timeout_seconds]
##   timeout_seconds: how long to wait for the new circuit to build (default 30)

import sys
import stem
from stem.connection import connect

try:
    timeout = float(sys.argv[1])
except (IndexError, ValueError):
    timeout = 30.0

controller = connect()

if not controller:
    sys.exit(255)

try:
    ## path=None -> EXTENDCIRCUIT 0, so Tor selects the path itself.
    circuit_id = controller.new_circuit(
        purpose="general", await_build=True, timeout=timeout
    )
## stem.Timeout is a subclass of stem.ControllerError, so catch it first.
except stem.Timeout:
    controller.close()
    print("no new circuit reached BUILT within {}s".format(timeout))
    sys.exit(1)
except stem.ControllerError as build_error:
    controller.close()
    print("circuit build failed: {}".format(build_error))
    sys.exit(1)

controller.close()

print("CIRC {} BUILT".format(circuit_id))
sys.exit(0)
