<!-- docs/audits/performance/ahk/2026_10_02/menu_third_pass/report.md -->

# Configured native menu publication, third pass

## Scope and result

Continue on dev without pushing. Baseline is 61ed853592a16d6441c5cc945c82d2c0edfa7cd6.
The complete configured native root now publishes before input registration.
The root includes the real feature categories, language choices and terminal
commands. Prepared leaf menus still complete before their first paint or
prewarm after genuine input readiness. No loading window or loading row is added.

The one-second process-start deadline is not achieved in the controlled samples.
Repeated startup reaches root publication in a median 1085 ms, versus 2255 ms
for the baseline. The remaining parse/load phase alone costs approximately
500–650 ms. These measurements describe menu availability, not completion of
every input registration or an externally enforced wall-clock deadline.

This is a Windows implementation change: AutoHotkey parsing, native HMENUs,
dispatcher identities and Win32 context-menu notification ownership. macOS and
Linux retain the same declarations, defaults, state and features; neither uses
this interpreter representation or notification path. No platform loses a
feature, so no unsupported-feature reason is introduced.

## Measured causes and changes

The former root waited for layout/remap registration, hotstrings and the prefix
index. Those owners still finish before input readiness, but now follow menu
publication. Physical magic-key source resolution also follows publication.
Pure tap-key and key-combination configuration reads precede the root; actual
hotkey variant registration retains its original input level and ordering.

Early feature selections retain arguments and dispatcher registration identity
until input owners exist. Retired registrations and terminal cancellation cannot
replay an accepted selection. A pending lifecycle action supersedes retained
feature actions. Restored pause is consumed synchronously before releasing
feature selections, and a pending physical pause also refuses their execution.

AI saved-state restoration remains available to the early renderer. Hotkey
activation, health probes, model corrections and backend scheduling have a
separate runtime activation owner after input registration. Binding failure
cannot publish that activation latch. Existing transient binding refusals retain
bounded retry ownership rather than replaying saved settings.

The shipped migration registry has a persistent typed parse cache. It fences
reuse with authoritative source content and hashes of the parser, validator,
codec and interpreter; compiled releases fingerprint their executable. Hits
still validate the schema. An unreadable authoritative source fails, and a
corrupt or invalid cached model reparses the authoritative source. The codec
preserves map comparison, strings, integers, floats, arrays and TOML booleans;
it never evaluates cached source. Verified atomic publication occurs after
menu publication and owns only its exclusively created staging file.

Read-only feature lookup now selects the desired root directly, without cloning
the whole top-level feature view. Whole-tree hotstring checkbox enumeration
does not deep-clone or seed live state; writers retain detached seeding. Locale
initialization retains the already loaded active map when source identity,
locale, path and map ownership match. A changed magic glyph rebinds only saved
raw templates. Ordinary text is not searched for the previous glyph.

The 17:01 live logs expose an additional mechanism: the first early click entered
the three-command bootstrap menu during root construction. Its 828 ms navigation
interval inflated the AI row to 924 ms wall with only 94 ms process CPU. The
complete-root stage took 1175 ms wall and 313 ms CPU. Context requests now wait
for the configured root; they cannot enter this blocking bootstrap loop. The
first-run onboarding owner remains available.

## Controlled measurements

AutoHotkey 2.0.26, Windows 11, pinned Node 22.22.2. Copy the real configuration
read-only from D:/Documents/GitHub/config/ergopti_plus. Each private code fixture
has its own wrapper and writable generated include. Live driver and production
forwarder remain untouched. Use the main runtime log under
%LOCALAPPDATA%/ergopti_plus/logs, without double-counting its severity mirror.

`tools/dev/bench-ahk-startup.cjs --menu-latency` omits only the smoke fixture's
synthetic 650 ms onboarding pump in its private copied entry. Its first sample
has an absent registry cache; subsequent launches reuse that private cache. The
default benchmark retains the correctness pump and independent fixtures.
Offsets exclude previous launches' log lines.

Run the current benchmark with:

```powershell
node tools/dev/bench-ahk-startup.cjs `
  --config-dir=D:/Documents/GitHub/config/ergopti_plus `
  --samples=3 --menu-latency
```

The final comparison uses A/B/B/A order, three launches per block, no concurrent
test or benchmark process. The baseline is materialized from git into an owned
temporary fixture, with one publication timing marker inserted after its
successful root build. Both versions use the same configuration and pump policy.

| Condition                              | Root publication samples, ms       | Median, ms | Maximum, ms |
| -------------------------------------- | ---------------------------------- | ---------- | ----------- |
| Baseline, six launches                 | 2229, 2258, 2255, 2255, 2238, 2261 | 2255       | 2261        |
| Candidate, two absent-cache launches   | 1239, 1277                         | 1258       | 1277        |
| Candidate, four cache-reusing launches | 1237, 1088, 1080, 1082             | 1085       | 1237        |

Cache-reusing root publication improves by approximately 52%. The slower
1237 ms candidate includes 652 ms before auto-execute; the other repeated samples
have 512–529 ms there. Small sample counts cannot support a production p99 claim.
Typed registry hits were approximately 31–63 ms in the exploratory batches,
versus approximately 200–234 ms for fresh parse and validation. The live 17:01
session confirms a validated registry hit at 47 ms and retained locale data.

An earlier comparison overlapped short focused tests and is excluded from this
table. Deferring nested parents as well as leaves gave no clear measured gain
and was reverted. Whole-menu serialization and speculative feature-count caches
were not introduced.

Temporary evidence: ergopti-third-paired-receipt.json and
ergopti-third-paired-{baseline,candidate}-{a,b}.jsonl under %TEMP%. The isolated
baseline fails the new full-startup publication receipt: its complete root
appears after input readiness. The candidate passes the same receipt.

## Regression verification

Behavioral coverage includes typed round trips, every truncated payload prefix,
hostile headers, exact shipped-model and validated-plan equality, source/parser
invalidation, missing source and a checksum-valid invalid cached schema.
Additional tests cover direct desired-root ownership, detached returned UI
state, whole-tree enumeration without mutation, locale glyph rebinding and a
same-timestamp source edit, command cancellation/retirement, lifecycle precedence
and separate AI activation.

The source-edit case also checks the next translated value. It exposed a stale
TSV whose retained timestamp passed the old freshness rule. A byte-proven source
change now bypasses that TSV on reload. The extended test failed with the old
translation before this correction and passes with the new value afterward.

The real-process startup smoke covers fresh and repeated launch, inherited pause,
extensions, neutral defaults and older-release migration fixtures. It verifies
early complete-root publication, retained feature selection, exactly-once
execution after readiness and refusal while the restored driver remains paused.
The receipt waits for the existing configuration write lease rather than assuming
its timer fires within 50 ms.

The complete AHK run has 7754 passed and zero failed; the execution manifest
confirms 7754/7754 terminal results. After the final locale hardening, all fifty
tests selected by the i18n filter pass and the complete include graph compiles.
The real-process startup smoke passes all fixtures. Pure expansion E2E is 5/5;
interactive desktop E2E is not claimed. Strict conventions and all 1775 AHK
encoding checks pass. Changed JavaScript and documentation pass Prettier.

The final broad JS receipt has 342/349 passing checks. Six previously reproduced
baseline/environment failures remain: Linux installed-layout discovery on
Windows Lua, macOS signing shell replay, Ollama bootstrap/server ownership,
release-install path normalization and the HS-274 Python runtime. The additional
drift-perturbation failure reports native UNKNOWN file-open/restoration refusals;
it repeats without a concurrent generator and the generated tree remains
unchanged. These gates are not reported green. Full formatting also retains
fifteen untouched-file failures and the installed Ruff version mismatch.

Receipts are under %TEMP%: ergopti-final-ahk-third-final-green.{out,tap}, its
manifest JSON, ergopti-third-pass-js-final.out and the targeted gate outputs.
