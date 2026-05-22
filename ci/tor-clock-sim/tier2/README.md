# Tier-2 harness - real tor clock-skew tolerance (chutney)

Tier 1 (`../tor_clock_sim.py`) is a logic *model*. This Tier-2 harness
measures the **real tor binary's** behavior: it stands up a private Tor
network with [chutney](https://gitlab.torproject.org/tpo/core/chutney)
(all nodes on localhost, no external Tor egress) and then launches a
separate real tor client under [`faketime`](https://github.com/wolfcw/libfaketime)
at a range of clock offsets, recording whether each client reaches
`Bootstrapped 100%`.

Goal: confirm or refute the model's predicted tolerance window
(roughly `-24h .. +27h` for C-Tor, from `REASONABLY_LIVE_TIME = 24h`)
and find the real "circuits stop building" offset, which may bind
tighter than the model because the real binary also checks relay
Ed25519 / link certificates that the model omits.

## Requirements

`tor`, `tor-gencert`, `faketime`, `git`, `python3`. On Debian/Ubuntu:

```bash
sudo apt-get install -y tor faketime git python3
```

## Run

```bash
ALLOW_LOCAL=true ./run-chutney-clock-sweep.sh
```

Tunables (env): `CHUTNEY_TOR`, `CHUTNEY_TOR_GENCERT`, `WORK_DIR`,
`NETWORK`, `OFFSETS_HOURS`, `BOOTSTRAP_TIMEOUT`, `CLIENT_TIMEOUT`.

Performance: offsets are probed in parallel and each client is killed
the moment it reports `Bootstrapped 100%`, so a full sweep costs about
one `CLIENT_TIMEOUT` (the slowest failing client) regardless of how
many offsets are probed. A measured 4-offset run took ~2.7 min, almost
all of it the one-time chutney consensus-formation setup; the clone is
cached in `WORK_DIR` between runs.

Output is a table:

```
  offset | bootstraps?
   -48h  | NO
   -24h  | YES
    ...  | ...
   +27h  | YES
   +30h  | NO
```

Compare the YES/NO boundary against the Tier-1 prediction. If the real
edge is markedly tighter than +27h, that is the relay-cert constraint
the model does not include - capture the offset and feed it back into
the model / the maintainer proposal.

## Environment notes (discovered while developing this)

- **No IPv6:** if the host lacks IPv6, tor aborts with "Failed to bind
  one of the listener ports" because the default `OrPort <n>` /
  `DirPort <n>` bind both families. The harness pins them to
  `0.0.0.0:<n>` and sets `AddressDisableIPv6 1`. (`AddressDisableIPv6`
  alone is **not** enough - the explicit IPv4 bind address is required.)
- **Restricted egress:** environments that allow only specific domains
  (e.g. Debian/GitHub mirrors) block tor relay ORPorts, so a *live*
  Tor bootstrap stalls at ~5%. That is why this harness uses a fully
  local chutney network instead of the public network.
- **faketime + tor:** set `FAKETIME_DONT_FAKE_MONOTONIC=1` so faking
  the wall clock does not also shift `CLOCK_MONOTONIC` and break tor's
  internal timers. Pass an **absolute** timestamp (`YYYY-MM-DD
  HH:MM:SS`); the wrapper rejects relative forms like `+6h`.
- **Do not** clean up with `pkill -f '/usr/bin/tor -f'` from a shell
  whose own command line contains that string - `pkill -f` matches the
  shell itself. Use `pkill -x tor` (match the process name).

## Limitations

- chutney's `TestingTorNetwork` shortens many timers and uses tiny
  consensus intervals, so absolute numbers differ from the public
  network; the harness measures the *tolerance behavior*, not
  production latencies.
- Onion-key rotation (28d) / grace (7d) are impractical to exercise at
  real durations; to test the *staleness* cap, lower
  `onion-key-rotation-days` / `onion-key-grace-period-days` via the
  network's consensus params and replay an aged consensus (future
  work; the model already covers this in Tier 1).
- This measures one client implementation (the installed `tor`). Run
  again with an Arti client to compare the 1d/3d `DirTolerance`.
