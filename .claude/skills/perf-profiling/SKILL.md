---
name: perf-profiling
description: Measuring this driver before optimising it — where the logs really are, how to aggregate the profiler, which segments nest inside which, why the numbers are censored at 5 ms, and how to bench a suspicion instead of arguing about it. Use before proposing any performance change.
---

# Measuring before touching

No optimisation is proposed without a number. An "obvious" unmeasured
optimisation is a hypothesis, and usually a readability regression for nothing.

## The logs are not where you expect

`<ConfigDir>` is redirected by `%APPDATA%\Ergopti\paths.toml`. On the
maintainer's machine the driver logs land in

```
D:\Documents\GitHub\config\ergopti_plus\autohotkey\logs\
```

Two earlier audit passes concluded "no measurement available" because they looked
in the repo. The filename carries the date the **driver started**, not the date of
the entries — read the timestamp on the line.

Cheapest possible check first: if `grep -c Slow <log>` is 0, there is no
measurement, so do not theorise on top of it.

## What the profiler records

`lib/hotpath_profiler.ahk` (QPC) emits `Slow <segment>: <ms> ms` only past
`_HOTPATH_SLOW_MS := 5.0`. `lib/boot_profiler.ahk` does the equivalent for boot,
with `A_TickCount` resolution (~15 ms, so a delta of 0 means "under 15 ms").

Aggregate with one pass and report **max alongside mean** — a p99 of 300 ms loses
characters even when the mean is 1 ms:

```bash
gawk 'match($0, /\[HotPath\] Slow ([A-Za-z._0-9]+): ([0-9.]+) ms/, m) {
  n[m[1]]++; s[m[1]]+=m[2]; if (m[2]>x[m[1]]) x[m[1]]=m[2]; if (m[2]>100) h[m[1]]++
} END { for (k in n) printf "%-26s n=%-6d max=%-9.1f mean=%-7.1f >100ms=%d\n",
  k, n[k], x[k], s[k]/n[k], h[k]+0 }' ErgoptiPlus_2026-*.log | sort -t= -k3 -rn
```

The `errors_` files are a mirror of the main log's WARNING+ lines — include them
and you double-count.

## Three ways to misread the numbers

**Segments nest.** `HSE.FeedChar` is timed *inside* `OnChar`; identical
timestamps and near-identical durations are the same stall seen twice. Never sum
segments.

**The distribution is censored at 5 ms.** Mean and median describe only the slow
keystrokes, never the typical one. They are therefore *not* comparable to the
"< 1 ms median" budget, and there is no denominator in the logs: 2000 slow
`OnChar` events over two weeks could be 0.1 % or 5 % of keystrokes.

**Wall-clock is not CPU.** The profiler measures elapsed QPC, so a `Slow` line can
be a scheduling preemption rather than work — a known and bounded effect here
(`tests/meta/test_hotpath_priority_starvation.ahk`). Before blaming an algorithm,
check whether the same input produces wildly different times.

## The budget is correctness, not comfort

Windows will not wait past `LowLevelHooksTimeout` (~300 ms) for a low-level
keyboard hook: it **delivers the keystroke without it** and may uninstall the
hook. A slow enough hot path is silent data loss, not a slow feel. Target < 1 ms
median and < 5 ms p99 on the typing path.

Reason in **factors**, not milliseconds — "N allocations and M lookups per
keystroke" transposes to a weak machine; "it takes 3 ms" does not.

## Bench a suspicion instead of arguing about it

When a cost is disputed, settle it with a standalone script that includes the
driver's own code and measures the real input with `QueryPerformanceCounter`.
Report mean **and** median over a few hundred iterations after a warm-up.

This is not theoretical: a verification pass dismissed a measured 38 ms JSON parse
as "implausible, realistically 2-5 ms" and demanded a re-bench. The re-bench
measured **44.3 ms** against the real 12.5 KB file — the original figure was right
and conservative. A refutation is a hypothesis too.

Keep temporary instrumentation out of the delivered change, or fold it into the
profiler properly. Never leave an orphan measurement in the code.

## Before proposing anything

Read `docs/PROJECT_MEMORY.md` first. Several attractive optimisations are recorded
as **tried and reverted** with their reasons — tooltip window reuse, chunking the
emoji registration, timing tricks around the WebView2 cold start. Re-proposing one
wastes a whole pass.

And check a cache proposal twice: this repo has shipped two desynchronised caches.
A cache is an optimisation only if its invalidation is *proved*; when the
computation is short, deriving at read removes an entire class of bug.
