#!/usr/bin/python3 -su

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

"""
Scenario assertions for the Tier-1 Tor-clock model.

Each test encodes a security claim from the sdwdate timezone / clock
review, so CI fails if a design invariant is ever violated. Runs under
both ``pytest`` and ``python3 -m unittest``.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

## pylint: disable=wrong-import-position
from tor_clock_sim import (  # noqa: E402
    DAY,
    HOUR,
    ONION_KEY_GRACE,
    ONION_KEY_ROTATION,
    ARTI,
    CONSENSUS_LIFETIME,
    CTOR,
    Consensus,
    circuit_gated_nudge,
    honest_network,
    with_attackers,
)

REAL_NOW = 1_700_000_000
## Replay floor (minimum-unixtime-show): last good sync, ~2 days ago.
FLOOR = REAL_NOW - 2 * DAY


class ForgeryTest(unittest.TestCase):
    """Pinned authority keys => an adversary can replay but not forge."""

    def test_unsigned_consensus_never_builds(self) -> None:
        net = honest_network(REAL_NOW)
        forged = Consensus(valid_after=REAL_NOW, authority_signed=False)
        self.assertFalse(net.circuit_builds(REAL_NOW, forged, CTOR))
        self.assertFalse(net.circuit_builds(REAL_NOW, forged, ARTI))


class ToleranceTest(unittest.TestCase):
    """Source contradicts the wiki's '~3h future' figure: a 6h offset
    is well within tolerance for both implementations."""

    def test_six_hour_offset_is_within_tolerance(self) -> None:
        net = honest_network(REAL_NOW)
        cons = Consensus(valid_after=REAL_NOW)
        clock = REAL_NOW + 6 * HOUR
        self.assertTrue(net.circuit_builds(clock, cons, CTOR))
        self.assertTrue(net.circuit_builds(clock, cons, ARTI))

    def test_arti_tolerates_more_staleness_than_ctor(self) -> None:
        ## A 2-day-future clock: outside C-Tor's 24h window, inside
        ## Arti's 3-day post tolerance.
        net = honest_network(REAL_NOW)
        cons = Consensus(valid_after=REAL_NOW)
        clock = REAL_NOW + 2 * DAY
        self.assertFalse(net.circuit_builds(clock, cons, CTOR))
        self.assertTrue(net.circuit_builds(clock, cons, ARTI))


class BenignRecoveryTest(unittest.TestCase):
    """A fast clock beyond tolerance is corrected back to ~now once a
    real circuit confirms it."""

    def test_large_fast_offset_recovers_to_now(self) -> None:
        net = honest_network(REAL_NOW)
        cons = Consensus(valid_after=REAL_NOW)
        clock = REAL_NOW + 2 * DAY
        res = circuit_gated_nudge(clock, FLOOR, cons, net, CTOR)
        self.assertTrue(res.committed)
        ## Landed within the consensus window, i.e. ~real now.
        self.assertLessEqual(abs(res.clock - REAL_NOW), CONSENSUS_LIFETIME)
        ## Floor advanced (strictly non-decreasing).
        self.assertGreaterEqual(res.floor, FLOOR)


class BlockingTest(unittest.TestCase):
    """Adversary that blocks circuits gets a DoS, not clock leverage."""

    def test_replay_plus_block_makes_no_change(self) -> None:
        ## Stale-but-above-floor consensus so the floor check passes and
        ## we isolate the circuit gate. Adversary blocks circuits.
        net = honest_network(REAL_NOW)
        net.block = True
        clock = REAL_NOW + 6 * HOUR
        cons = Consensus(valid_after=REAL_NOW - 1 * DAY)
        res = circuit_gated_nudge(clock, FLOOR, cons, net, CTOR)
        self.assertFalse(res.committed)
        self.assertEqual(res.clock, clock)  ## unchanged
        self.assertEqual(res.floor, FLOOR)  ## not lowered

    def test_fetch_staler_loop_is_bounded_and_unwalked(self) -> None:
        ## Adversary serves ever-staler consensuses while blocking
        ## circuits. Assert the clock never moves and never drops below
        ## the floor across the whole loop.
        net = honest_network(REAL_NOW)
        net.block = True
        clock = REAL_NOW + 6 * HOUR
        floor = FLOOR
        for age_days in range(1, 41):
            cons = Consensus(valid_after=REAL_NOW - age_days * DAY)
            res = circuit_gated_nudge(clock, floor, cons, net, CTOR)
            self.assertFalse(res.committed)
            self.assertGreaterEqual(res.clock, floor)
            self.assertEqual(res.clock, clock)
            self.assertEqual(res.floor, floor)
            clock, floor = res.clock, res.floor
        self.assertEqual(clock, REAL_NOW + 6 * HOUR)


class OnionKeyCapTest(unittest.TestCase):
    """The unforgeable, relay-side staleness cap."""

    def test_within_grace_builds_beyond_rotation_grace_fails(
        self,
    ) -> None:
        net = honest_network(REAL_NOW)
        ## <= grace (7d): every honest relay still accepts.
        fresh = Consensus(valid_after=REAL_NOW - ONION_KEY_GRACE)
        self.assertTrue(net.circuit_builds(fresh.middle_range, fresh, CTOR))
        ## > rotation + grace (35d): no honest relay accepts.
        stale = Consensus(
            valid_after=REAL_NOW - (ONION_KEY_ROTATION + ONION_KEY_GRACE) - DAY
        )
        self.assertFalse(net.circuit_builds(stale.middle_range, stale, CTOR))

    def test_cap_is_independent_of_victim_clock(self) -> None:
        ## Holding liveness+signature satisfied, the onion-key gate
        ## (accepting-relay count) depends only on consensus age and
        ## real_now - never on the victim's clock value.
        net = honest_network(REAL_NOW)
        for age_days in [1, 10, 20, 30, 40, 60]:
            cons = Consensus(valid_after=REAL_NOW - age_days * DAY)
            base = net.accepting_relays(cons)
            ## Two different clocks that both keep the consensus live.
            for clock in [cons.valid_after, cons.middle_range]:
                live = net.consensus_live(clock, cons, CTOR)
                sig = net.signature_valid(clock, cons)
                builds = net.circuit_builds(clock, cons, CTOR)
                self.assertEqual(builds, live and sig and base >= 3)


class DeepRollbackTest(unittest.TestCase):
    """Beyond the onion-key cap, a circuit needs a full path of
    attacker relays - i.e. effective control of the path."""

    def test_deep_rollback_requires_full_attacker_path(self) -> None:
        ## 60-day-stale consensus: all honest relays reject.
        cons = Consensus(valid_after=REAL_NOW - 60 * DAY)
        clock = cons.middle_range
        honest = honest_network(REAL_NOW)
        self.assertFalse(honest.circuit_builds(clock, cons, CTOR))
        ## Two attacker relays: still not a full 3-hop path.
        self.assertFalse(
            with_attackers(honest, 2).circuit_builds(clock, cons, CTOR)
        )
        ## Three attacker relays: a full attacker path builds.
        self.assertTrue(
            with_attackers(honest, 3).circuit_builds(clock, cons, CTOR)
        )


class FloorInvariantTest(unittest.TestCase):
    """The replay floor is never violated and never lowered, across a
    broad sweep of offsets, consensus ages, and blocking."""

    def test_floor_never_violated_in_sweep(self) -> None:
        offsets = [-2 * DAY, 0, 6 * HOUR, 2 * DAY, 10 * DAY]
        ages = [0, 1, 3, 7, 20, 40, 90]
        for block in (False, True):
            net = honest_network(REAL_NOW)
            net.block = block
            for off in offsets:
                clock = REAL_NOW + off
                for age_days in ages:
                    cons = Consensus(valid_after=REAL_NOW - age_days * DAY)
                    res = circuit_gated_nudge(clock, FLOOR, cons, net, ARTI)
                    self.assertGreaterEqual(res.clock, FLOOR)
                    self.assertGreaterEqual(res.floor, FLOOR)
                    if res.committed:
                        ## A commit only ever moves the clock backward
                        ## toward (never below) the proposed target.
                        self.assertLessEqual(res.clock, clock)


if __name__ == "__main__":
    unittest.main(verbosity=2)
