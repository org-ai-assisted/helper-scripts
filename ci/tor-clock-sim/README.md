# tor-clock-sim - Tier-1 model for sdwdate backward-clock safety

A small, dependency-free **logic simulator** used to mechanically check
the security invariants of a *proposed* sdwdate / anondate recovery
feature: a **circuit-gated, provisional backward clock nudge** that
would let a machine recover from a too-fast clock (e.g. a dual-boot
Windows that left the RTC in local time) without weakening Tor's
replay protections.

It is **a model, not real Tor.** Its job is to turn the design
arguments into executable assertions so CI fails if an invariant is
violated. The real per-implementation thresholds must still be
confirmed against the real binaries (see *Tier 2* below).

## Why this exists

sdwdate sets the system clock from Tor, and **Tor trusts the system
clock as its sole time reference** - confirmed in both implementations:

- C-Tor: all liveness/expiry checks use `time(NULL)`/`approx_time()`;
  there is no independent time source (open gap, Tor issue #8170).
- Arti: all time validity funnels through `SystemTime::now()` /
  `rt.wallclock()`; the channel-based `ClockSkew` signal is advisory
  ("could be lying"), never used to set the clock.

So any relaxation of sdwdate's "never move the clock backward" rule
must be proven safe. This model encodes the safety argument.

## What it models (and the source for each constant)

| Constant | Value | Source |
|---|---|---|
| `onion-key-rotation-days` | 28 | Tor param-spec |
| `onion-key-grace-period-days` | 7 | Tor param-spec |
| C-Tor staleness tolerance | +/-24h symmetric | `REASONABLY_LIVE_TIME` (`networkstatus.c`) |
| Arti staleness tolerance | 1d pre / 3d post | `DirTolerance` (`tor-dircommon/src/config.rs`) |
| Authority keys | pinned | `auth_dirs.inc` (C-Tor) / `default_v3idents()` (Arti) |

Core idea encoded in `tor_clock_sim.py`:

- **The consensus *proposes* a target time; a real *circuit* commits
  it.** A backward nudge is provisional and reverted (forward) unless a
  circuit actually builds. The replay floor (`minimum-unixtime-show`)
  is a hard lower bound and is never lowered.
- **Consensus liveness and signatures are checked against the (possibly
  manipulated) client clock** - so they do *not* bound a rollback.
- **Onion-key acceptance is decided by each relay's *own* clock**, so
  it *does* bound a rollback, and the bound cannot be forged by
  manipulating the client clock.

## What the assertions prove (`test_tor_clock_sim.py`)

- **No forgery:** an unsigned consensus never builds a circuit (pinned
  authority keys => replay-only adversary).
- **Doc vs. source:** a 6h offset is *within* tolerance for both
  implementations - contradicting the wiki's "~3h future" figure;
  Arti tolerates more staleness (3d) than C-Tor (24h).
- **Benign recovery:** a large fast offset is corrected back to ~now
  once a real circuit confirms it.
- **Blocking => DoS, not leverage:** an adversary that blocks circuits
  (even while serving replayed consensuses, even in a fetch-staler
  loop) produces no clock change and never drops below the floor.
- **Onion-key cap:** a replayed consensus builds circuits via honest
  relays only within ~grace (7d), and never beyond rotation+grace
  (~35d) - and this cap is independent of the victim's clock.
- **Deep rollback needs a full attacker path:** beyond the onion-key
  cap, a circuit builds only if the adversary controls every hop.
- **Floor invariant:** across a broad sweep, the clock is never set
  below the replay floor and the floor is never lowered.

## Run

```bash
python3 tor_clock_sim.py            # human-readable prediction tables
python3 -m unittest test_tor_clock_sim   # assertions (also pytest-discoverable)
```

CI-only: this folder is not shipped in the `.deb`. To wire it into
`run-tests`, run the `test_tor_clock_sim.py` module under pytest;
`black --line-length 79 --check` keeps it style-consistent.

## Tier 2 - confirm against the real binaries (TODO)

This model's *thresholds* are predictions. Validate them with
[Shadow](https://shadow.github.io/), which runs **real C-Tor (and
Arti)** in a simulated network with controllable time:

1. Stand up a private net (dir auths + relays + client).
2. Sweep the client clock offset `{-35d ... -1h, 0, +1h, +3h, +6h,
   +14h, +1d, +35d}` and record bootstrap / first-circuit success per
   implementation - resolving the "3h vs 24h vs 3d" question
   empirically.
3. Shorten onion-key params to their minimums (`rotation=1d`,
   `grace=1d`) to exercise the staleness cap in feasible sim-time, and
   replay a stale consensus to confirm circuits stop building past the
   grace window.

Chutney is a lighter alternative, but per-node clock control is harder.

## Caveats

- A logic model: path selection is a feasibility proxy (>=3 accepting
  relays = a buildable path), not bandwidth-weighted selection.
- Authority signing-cert lifetime is modeled generously; it is not the
  binding constraint in these scenarios.
- The exact "circuits stop building" offset depends on the tightest
  cert check in the real binary (relay Ed25519 / link certs), which
  Tier 2 must measure.
