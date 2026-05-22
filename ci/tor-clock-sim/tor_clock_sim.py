#!/usr/bin/python3 -su

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

"""
Tier-1 logic simulator: Tor consensus liveness x onion-key rotation x
the system clock. Used to validate the proposed "circuit-gated
provisional backward nudge" for sdwdate / anondate and its security
bounds (replay floor, onion-key staleness cap, no boundless rollback,
revert-on-failure).

This is a MODEL, not real Tor. The constants come from C-Tor / Arti
source and the Tor spec (see README.md). Its purpose is to mechanically
check the design's invariants in CI. The real per-implementation
thresholds (e.g. the exact clock offset that stops circuit building)
must be confirmed against the real binaries with Shadow (Tier 2, see
README.md).
"""

from __future__ import annotations

from dataclasses import dataclass

HOUR: int = 3600
DAY: int = 86400

## Network-wide consensus parameters (Tor param-spec defaults):
## onion-key-rotation-days=28, onion-key-grace-period-days=7.
ONION_KEY_ROTATION: int = 28 * DAY
ONION_KEY_GRACE: int = 7 * DAY

## Consensus document lifetime: valid_after -> valid_until.
CONSENSUS_LIFETIME: int = 3 * HOUR

## Authority signing-key certificate lifetime is on the order of
## months and is not the binding constraint in these scenarios. It is
## modeled generously so a replayed-but-real consensus still verifies
## when the clock is set near its valid_after.
SIGNING_CERT_LIFETIME: int = 90 * DAY


@dataclass(frozen=True)
class Impl:
    """A client implementation's consensus staleness tolerance."""

    name: str
    tol_pre: int  ## accept a consensus this long before valid_after
    tol_post: int  ## accept a consensus this long after valid_until


## C-Tor: REASONABLY_LIVE_TIME = 24h, symmetric (networkstatus.c).
CTOR: Impl = Impl("c-tor", 24 * HOUR, 24 * HOUR)
## Arti: DirTolerance pre=1d / post=3d, asymmetric (tor-dircommon).
ARTI: Impl = Impl("arti", 1 * DAY, 3 * DAY)


@dataclass(frozen=True)
class Consensus:
    """A directory consensus.

    Only authority-signed consensuses can exist: the directory
    authority identity keys are pinned in both C-Tor and Arti, so an
    adversary can REPLAY a real (old) consensus but cannot FORGE one.
    ``authority_signed=False`` models a forgery attempt, which a client
    always rejects.
    """

    valid_after: int
    authority_signed: bool = True

    @property
    def valid_until(self) -> int:
        return self.valid_after + CONSENSUS_LIFETIME

    @property
    def middle_range(self) -> int:
        return self.valid_after + CONSENSUS_LIFETIME // 2


@dataclass(frozen=True)
class Relay:
    """An honest or adversary relay.

    Honest relays rotate their ntor onion key every ONION_KEY_ROTATION
    and keep the previous key usable for ONION_KEY_GRACE. Acceptance is
    decided by the relay's OWN clock (``real_now``), never by the
    client's clock - that is what makes the staleness cap unforgeable
    by client-clock manipulation. An adversary relay kept its old
    private keys and accepts anything.
    """

    phase: int
    attacker: bool = False

    def _epoch(self, when: int) -> int:
        return (when - self.phase) // ONION_KEY_ROTATION

    def accepts(self, consensus_time: int, real_now: int) -> bool:
        if self.attacker:
            return True
        ref = self._epoch(consensus_time)
        cur = self._epoch(real_now)
        if ref == cur:
            return True
        if ref == cur - 1:
            boundary = self.phase + cur * ONION_KEY_ROTATION
            return real_now - boundary <= ONION_KEY_GRACE
        return False


@dataclass
class Network:
    """A set of relays and the (true) wall-clock time, plus an optional
    adversary that drops every circuit attempt."""

    relays: list[Relay]
    real_now: int
    block: bool = False

    def consensus_live(self, clock: int, cons: Consensus, impl: Impl) -> bool:
        """Clock-relative liveness check (per implementation)."""
        return (
            cons.valid_after - impl.tol_pre
            <= clock
            <= cons.valid_until + impl.tol_post
        )

    def signature_valid(self, clock: int, cons: Consensus) -> bool:
        """Clock-relative signature/cert check. Unsigned (forged)
        consensuses never validate."""
        if not cons.authority_signed:
            return False
        return abs(clock - cons.valid_after) <= SIGNING_CERT_LIFETIME

    def accepting_relays(self, cons: Consensus) -> int:
        """Number of relays that still accept the onion keys named in
        ``cons`` - decided purely by relay clocks (``real_now``), NOT
        by the client clock."""
        return sum(
            1
            for relay in self.relays
            if relay.accepts(cons.valid_after, self.real_now)
        )

    def circuit_builds(self, clock: int, cons: Consensus, impl: Impl) -> bool:
        """Can the client build a 3-hop circuit with this consensus at
        this clock? Needs: not blocked, signatures verify
        (clock-relative), consensus accepted as live (clock-relative),
        AND >=3 relays still accept the named onion keys
        (relay-clock-relative)."""
        if self.block:
            return False
        if not self.signature_valid(clock, cons):
            return False
        if not self.consensus_live(clock, cons, impl):
            return False
        return self.accepting_relays(cons) >= 3


@dataclass(frozen=True)
class NudgeResult:
    clock: int
    floor: int
    committed: bool
    reason: str


def circuit_gated_nudge(
    clock: int,
    floor: int,
    cons: Consensus,
    net: Network,
    impl: Impl,
) -> NudgeResult:
    """The proposed sdwdate / anondate recovery step.

    The consensus only PROPOSES a target time; a real circuit COMMITS
    it. Backward moves are provisional and reverted (forward) if no
    circuit builds. The replay floor is a hard lower bound and is never
    lowered. This function governs backward moves only; forward moves
    keep anondate's existing behavior.
    """
    target = cons.middle_range
    ## minimum-time-check: never set below the replay floor.
    if target < floor:
        return NudgeResult(clock, floor, False, "below-floor")
    if target >= clock:
        return NudgeResult(clock, floor, False, "no-backward-needed")
    ## Backward move: provisionally set, then require a real circuit.
    if net.circuit_builds(target, cons, impl):
        return NudgeResult(target, max(floor, target), True, "commit")
    ## Revert forward to the original clock; do not lower the floor.
    return NudgeResult(clock, floor, False, "no-circuit-revert")


def honest_network(real_now: int, count: int = 120) -> Network:
    """``count`` honest relays whose rotation phases are spread evenly
    across one rotation period, so every phase is represented."""
    step = ONION_KEY_ROTATION // count
    relays = [Relay(phase=i * step) for i in range(count)]
    return Network(relays=relays, real_now=real_now)


def with_attackers(net: Network, count: int) -> Network:
    """Return a copy of ``net`` with ``count`` adversary relays added
    (they kept old keys, so they accept any consensus)."""
    relays = list(net.relays) + [
        Relay(phase=0, attacker=True) for _ in range(count)
    ]
    return Network(relays=relays, real_now=net.real_now, block=net.block)


def _fmt(seconds: int) -> str:
    sign = "+" if seconds >= 0 else "-"
    mag = abs(seconds)
    if mag >= DAY:
        return f"{sign}{mag / DAY:g}d"
    return f"{sign}{mag / HOUR:g}h"


def report() -> None:
    real_now = 1_700_000_000
    print("Tier-1 model (NOT real Tor; confirm thresholds with Shadow).")
    print(
        f"rotation={ONION_KEY_ROTATION // DAY}d "
        f"grace={ONION_KEY_GRACE // DAY}d "
        f"consensus_lifetime={CONSENSUS_LIFETIME // HOUR}h"
    )
    net = honest_network(real_now)

    print(
        "\nA) Fresh consensus, honest net: does the CURRENT consensus "
        "stay\n   usable as the client clock is offset? (doc says ~3h "
        "future;\n   source says ~24h C-Tor / ~3d Arti)"
    )
    cons = Consensus(valid_after=real_now)
    print(f"   {'offset':>8} | {'c-tor':>6} | {'arti':>6}")
    for off in [
        -2 * DAY,
        -1 * DAY,
        -3 * HOUR,
        0,
        3 * HOUR,
        6 * HOUR,
        14 * HOUR,
        1 * DAY,
        2 * DAY,
        4 * DAY,
    ]:
        clock = real_now + off
        builds_c = net.circuit_builds(clock, cons, CTOR)
        builds_a = net.circuit_builds(clock, cons, ARTI)
        print(
            f"   {_fmt(off):>8} | {str(builds_c):>6} | " f"{str(builds_a):>6}"
        )

    print(
        "\nB) Replayed STALE consensus, clock set to match it: how "
        "stale can\n   it be and still build circuits via HONEST "
        "relays? (onion-key cap)"
    )
    print(f"   {'age':>6} | {'builds':>6}")
    for age_days in [1, 7, 14, 28, 35, 36, 60]:
        old = Consensus(valid_after=real_now - age_days * DAY)
        clock = old.middle_range
        builds = net.circuit_builds(clock, old, CTOR)
        print(f"   {age_days:>5}d | {str(builds):>6}")


if __name__ == "__main__":
    report()
