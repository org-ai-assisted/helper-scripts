# Tier-2 results - real tor clock-skew tolerance

Measured with `run-chutney-clock-sweep.sh` against a local chutney
network, real `tor 0.4.8.10` client, clock skewed with `faketime`.

```
  offset | bootstraps?
   -48h  | NO
   -24h  | YES
    -6h  | YES
    +0h  | YES
    +6h  | YES
   +24h  | YES
   +27h  | NO
   +30h  | NO
   +48h  | NO
```

## What it shows

**Raw `tor` client bootstrap tolerance is ~ +/-24h** around the
consensus `valid-after`. This empirically confirms the source constant
`REASONABLY_LIVE_TIME = 24h` (`networkstatus.c`) and matches the Tier-1
model's `~[-24h, +27h]` prediction. The future edge lands at +24h
rather than +27h only because chutney's `TestingTorNetwork` shrinks the
consensus lifetime, so `valid_until ~= valid_after` (in production the
3h lifetime would push the raw-tor future edge to ~ +27h).

## Important reconciliation (doc vs. source)

The Whonix wiki says Tor breaks at ">1h past / >3h future". The Tier-2
result (+/-24h) looks like it contradicts that - but it does not:
**they are two different gates at two different layers.**

- **Raw `tor` bootstrap:** reasonably-live tolerance ~ +/-24h (measured
  here).
- **`sdwdate` preparation gate:** stricter. `onion-time-pre-script`
  flags the clock `slow` when `current < consensus/valid-after` and
  `fast` when `current >= consensus/valid-until`, and on anything other
  than `ok` it calls `anondate_use` and returns "wait" (exit 2),
  looping. So `sdwdate` only proceeds when the clock is inside the
  consensus window `[valid_after, valid_until]` (~3h wide). That window
  is exactly the wiki's "~1h past / ~3h future".

So the wiki figure describes **sdwdate's effective acceptance**, while
`REASONABLY_LIVE_TIME` describes **raw tor's**. Both are correct.

## Implications

- The **current** dual-boot fast-clock deadlock bites at roughly **+3h**
  (sdwdate's consensus-window gate), not +24h: a fast clock past
  `valid_until` keeps `onion-time-pre-script` returning "wait", and
  `anondate` refuses to move the clock backward (see
  `../../anondate-adversarial/`, scenario D).
- The Tier-1 model's `consensus_live` uses the +/-24h reasonably-live
  tolerance. That is the right gate for the *proposed* circuit-gated
  nudge (which would gate on a real circuit = raw tor). To model the
  *current* sdwdate preparation gate instead, use the consensus window
  `[valid_after, valid_until]`. (Follow-up: add a "current-sdwdate
  gate" mode + assertion to the Tier-1 model.)

## Caveats

- `TestingTorNetwork` uses tiny consensus intervals, so absolute edges
  differ from production; the *behavior* (±24h raw tor; ~3h sdwdate
  gate) is what transfers.
- One client implementation (`tor 0.4.8.10`). Re-run with Arti to
  measure its 1d/3d `DirTolerance` at the raw layer.
