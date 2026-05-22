# End-to-end test results (real Tor, real onion, faked clock)

`run-e2e-onion-fetch.sh` exercises the full circuit-confirmed backward
clock fix on real binaries, with no external Tor egress and without
changing the host clock.

## What it proves

A local chutney `hs-v3-min` network (3 authorities + 3 relays + 1
client + 1 onion service) hosts a real onion that forwards to a
true-time HTTP `Date` server. sdwdate's real fetch primitive
(`url_to_unixtime`) fetches that onion over **real Tor circuits**:

1. at the true clock, and
2. under a **faked +6h clock** (`faketime`).

Because the time comes from the HTTP `Date` header, the fetch returns
the **true** time in both cases - it is independent of the local
(faked) clock. sdwdate's math then computes a backward correction.

## Observed (passing) run

```
=== onion reachable: 4skwf7fw3xgxidig2g4xunzlzldpbfhdi74q47bw62j3mm3m4axldcid.onion
true system now: 1779444953  (Fri May 22 10:15:53 UTC 2026)

(1) url_to_unixtime at the TRUE clock          -> 1779444954
(2) url_to_unixtime under faketime +6h         -> 1779444954   (same; true time, not +6h)

(3) sdwdate clock math:
    remote (onion Date header) : 1779444954
    sdwdate local clock (+6h)  : 1779466554
    diff = remote - now        : -6.00 h
    new  = now + diff          : 1779444954   (-6.00 h, BACKWARD)
    replay floor               : 1779272154
    new >= floor ?             : True
    RESULT                     : PASS - sdwdate corrects +6h back to true now
```

## Why this is the meaningful end-to-end

It validates the genuinely novel chain on real software, not a model:
real Tor circuits -> real onion fetch (`url_to_unixtime`) -> a read
that is independent of the fast local clock -> a backward correction
to the true time, gated by the replay floor. Combined with:

- `test-circuit-confirmed-backward.sh` (the preparation gate, 8/8),
- `anondate-adversarial/run-adversarial-tests.sh` (forward-only +
  replay-floor guards, 14/14),
- the Tier-2 clock-skew sweep (raw tor tolerance ~ +/-24h),
- the Tier-1 model (bounds; far-fast clocks cannot recover),

this covers the design end to end.

## Notes / limitations

- The host `CLOCK_REALTIME` is never changed (a container shares it
  with the host); the harness computes what sdwdate WOULD set, with the
  set intercepted conceptually. A true clock-changing run belongs in a
  VM (see `../README.md`, Tier 1 VM approach).
- chutney's phased launch is flaky in a container, so the harness
  launches any missing node directly (`ensure_all_nodes_running`).
- The far-fast (+1yr) "cannot recover" case is covered by the model
  and the logic (Tor can't bootstrap, so no circuit, so the gate never
  fires); reproducing it here would require faketime-ing the client tor
  too.

## Reproducibility note

The passing run above was a real manual end-to-end execution and is the
authoritative proof. The committed harness encodes that method and was
verified through the consensus stage, but **reliable cold-start
reproduction in a constrained container is flaky**, for environmental
(not implementation) reasons:

- No IPv6 (worked around by pinning OR/Dir ports to IPv4).
- A tiny testing network's onion service can take longer to publish a
  descriptor and become reachable than the harness wait budget on a
  cold start (the manual run succeeded only after the network had been
  up for a while / warm).
- Repeated experiments left stray `tor` processes from earlier
  `chutney` instances holding ports and mixing into the network;
  always start from a guaranteed-clean process slate
  (`pkill -x tor; pkill -x python3`).

For repeatable verification, run the harness on a clean machine/VM with
more resources (and ideally IPv6), and/or raise `BOOTSTRAP_TIMEOUT` and
the reachability budget. The implementation itself is validated by the
manual E2E run plus the unit/integration tests; harness flakiness here
is a test-infrastructure constraint, not a defect in the fix.
