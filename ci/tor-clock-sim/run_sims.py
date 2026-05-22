#!/usr/bin/python3 -su

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

"""
Comprehensive Tier-1 simulation driver.

Runs the scenarios from the sdwdate timezone / clock review against the
model in ``tor_clock_sim.py`` and prints empirical evidence for each
claim. This is the human-readable "proof" companion to the assertions
in ``test_tor_clock_sim.py`` (which encode the same claims as CI
checks).

Model only - confirm the real per-implementation thresholds against the
binaries with Shadow (Tier 2, see README.md).
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

## pylint: disable=wrong-import-position
from tor_clock_sim import (  # noqa: E402
    DAY,
    HOUR,
    ONION_KEY_GRACE,
    ONION_KEY_ROTATION,
    ARTI,
    CTOR,
    Consensus,
    Impl,
    circuit_gated_nudge,
    honest_network,
    with_attackers,
)

NOW = 1_700_000_000
## Replay floor (minimum-unixtime-show): last good sync, ~2 days ago.
FLOOR = NOW - 2 * DAY


def fmt(seconds: int) -> str:
    sign = "+" if seconds >= 0 else "-"
    mag = abs(seconds)
    if mag >= DAY:
        return f"{sign}{mag / DAY:g}d"
    return f"{sign}{mag / HOUR:g}h"


def tolerance_edges(impl: Impl) -> tuple[int, int]:
    """Empirical [past, future] offset edges (in seconds) at which the
    CURRENT consensus still builds a circuit."""
    net = honest_network(NOW)
    cons = Consensus(valid_after=NOW)
    lo = hi = 0
    for hours in range(0, 6 * 24 + 1):
        if net.circuit_builds(NOW + hours * HOUR, cons, impl):
            hi = hours * HOUR
        if net.circuit_builds(NOW - hours * HOUR, cons, impl):
            lo = -hours * HOUR
    return lo, hi


def sim1_tolerance() -> None:
    print("SIM 1 - Tolerance window (fresh consensus, honest net)")
    print("  Wiki claims Tor breaks at >1h past / >3h future.")
    for impl in (CTOR, ARTI):
        lo, hi = tolerance_edges(impl)
        print(
            f"  {impl.name:>6}: builds for offsets in "
            f"[{fmt(lo)} .. {fmt(hi)}]"
        )
    print("  => a 6h dual-boot offset is well INSIDE tolerance for both;")
    print("     the model's edge is far past the wiki's 3h (real binary")
    print("     may bind tighter via relay certs - Tier 2 to measure).")


def sim2_staleness() -> None:
    print("\nSIM 2 - Staleness cap (replayed consensus, clock matched)")
    print("  How old can a replayed consensus be and still build via")
    print("  HONEST relays? (onion-key rotation=28d, grace=7d)")
    net = honest_network(NOW)
    print(f"    {'age':>5} | {'accept%':>7} | builds")
    last_build = -1
    for days in [0, 3, 7, 14, 21, 28, 32, 35, 36, 40, 60]:
        cons = Consensus(valid_after=NOW - days * DAY)
        acc = net.accepting_relays(cons)
        builds = net.circuit_builds(cons.middle_range, cons, CTOR)
        if builds:
            last_build = days
        pct = 100 * acc / len(net.relays)
        print(f"    {days:>4}d | {pct:>6.0f}% | {builds}")
    print(
        f"  => safe within grace (<= {ONION_KEY_GRACE // DAY}d: 100% "
        f"accept); last age that builds in this sweep: {last_build}d;"
    )
    print(
        f"     none past rotation+grace "
        f"({(ONION_KEY_ROTATION + ONION_KEY_GRACE) // DAY}d)."
    )


def sim3_replay_block() -> None:
    print("\nSIM 3 - Replay + block circuits (adversary)")
    print("  Serve a replayed consensus AND drop all circuits.")
    net = honest_network(NOW)
    net.block = True
    changed = False
    for off in [6 * HOUR, 1 * DAY, 10 * DAY]:
        for age in [1, 10]:
            cons = Consensus(valid_after=NOW - age * DAY)
            res = circuit_gated_nudge(NOW + off, FLOOR, cons, net, CTOR)
            if res.clock != NOW + off or res.floor != FLOOR:
                changed = True
    print(
        f"  => across offsets/ages: any clock or floor change? "
        f"{changed} (False = pure DoS, no leverage)."
    )


def sim4_fetch_staler_loop() -> None:
    print("\nSIM 4 - Fetch-staler loop while blocking")
    net = honest_network(NOW)
    net.block = True
    clock = NOW + 6 * HOUR
    floor = FLOOR
    start = clock
    lowest = clock
    below_floor = False
    for age in range(1, 60):
        cons = Consensus(valid_after=NOW - age * DAY)
        res = circuit_gated_nudge(clock, floor, cons, net, CTOR)
        clock, floor = res.clock, res.floor
        lowest = min(lowest, clock)
        below_floor = below_floor or clock < FLOOR
    print(
        f"  start={fmt(start - NOW)} end={fmt(clock - NOW)} "
        f"lowest={fmt(lowest - NOW)} ever_below_floor={below_floor}"
    )
    print(
        "  => clock never walks back and never crosses the floor: "
        "bounded, not boundless."
    )


def sim5_deep_rollback() -> None:
    print("\nSIM 5 - Deep rollback (60d stale) vs attacker relay count")
    cons = Consensus(valid_after=NOW - 60 * DAY)
    clock = cons.middle_range
    base = honest_network(NOW)
    print(f"    {'attackers':>9} | builds")
    for count in range(0, 6):
        net = with_attackers(base, count)
        builds = net.circuit_builds(clock, cons, CTOR)
        print(f"    {count:>9} | {builds}")
    print("  => beyond the onion-key cap a circuit needs a FULL attacker")
    print("     path (>=3 hops): honest relays reject the stale keys.")


def sim6_end_to_end() -> None:
    print("\nSIM 6 - End-to-end nudge (fresh consensus available)")
    print(f"    {'blocked':>7} | {'offset':>7} | {'commit':>6} | result")
    for block in (False, True):
        net = honest_network(NOW)
        net.block = block
        cons = Consensus(valid_after=NOW)
        for off in [-1 * DAY, 6 * HOUR, 1 * DAY, 2 * DAY, 10 * DAY]:
            res = circuit_gated_nudge(NOW + off, FLOOR, cons, net, CTOR)
            delta = fmt(res.clock - NOW)
            print(
                f"    {str(block):>7} | {fmt(off):>7} | "
                f"{str(res.committed):>6} | {delta} ({res.reason})"
            )
    print(
        "  => unblocked fast clock recovers to ~now; blocked = no "
        "change (DoS); slow clock left to anondate's forward path."
    )


def main() -> None:
    print("=" * 64)
    print("Tier-1 Tor-clock simulations (MODEL, not real Tor)")
    print(
        f"rotation={ONION_KEY_ROTATION // DAY}d "
        f"grace={ONION_KEY_GRACE // DAY}d  "
        f"c-tor_tol=24h  arti_tol=1d/3d"
    )
    print("=" * 64)
    sim1_tolerance()
    sim2_staleness()
    sim3_replay_block()
    sim4_fetch_staler_loop()
    sim5_deep_rollback()
    sim6_end_to_end()
    print("\n" + "=" * 64)
    print("All scenarios ran. Assertions live in test_tor_clock_sim.py.")
    print("Confirm real thresholds with Shadow (Tier 2, README.md).")


if __name__ == "__main__":
    main()
