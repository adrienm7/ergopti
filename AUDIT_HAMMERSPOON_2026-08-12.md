# Adversarial audit and hardening report — Hammerspoon macOS driver — 2026-08-12

## 1. Executive summary

**Scope.** This report covers `static/ergopti_plus/macos/`, its launcher/BLINDER
boundary, and the `static/ergopti_plus/_shared/` data and Lua consumed by the
macOS driver. The last fully replayed committed production/test source baseline
is `dafbcb591e073811c8c1e4b4f3bc39482ec1c4de`. Its complete portable Lua,
virtual-keyboard E2E and repository-gate replays are recorded below. This is a
committed source/test baseline, not native macOS runtime or production-profile
evidence.

This was an audit-and-fix campaign, not a read-only review. Each promoted
user-runtime issue below has a reachable action/state sequence, a root-cause
explanation, and a named implemented or proposed causal regression test for the
affected production boundary. Proof-integrity findings separately reproduce the
gate defect and show why the prior test could certify the bug. This current
ledger contains **89 confirmed findings: 86 with fixes present, one
(`HS-H-18`) only partially fixed, and two open (`HS-H-34`, `HS-M-20`):
 1 Critical, 56 High, 28 Medium and 4 Low**.
The later fixes have named causal tests. A
2026-08-13 post-merge adversarial replay proved that the pathname and symlink
half of `HS-H-18` is closed, while a non-cooperating writer can still publish
between the last source check and `rename(2)`. These are source/test totals, not
a claim that macOS-only runtime gaps are clean.

The most important outcome is the Karabiner ownership model. ErgoptiPlus no
longer treats “Karabiner” as one process that it may kill. It owns one exact,
one-shot remapping **lease**. Abrupt Hammerspoon loss, launcher loss, worker loss,
pipe EOF, or guardian restart converges on setting only that generation's
`ergopti_mode_<token>` / `ergopti_revoked_<token>` variables to the fenced state.
The only Karabiner executable a private worker may spawn is the canonical
`karabiner_cli`, and it may signal/reap only its own direct child/process group.
Karabiner's UI, Core Service (historically `karabiner_grabber`), console server,
session agents, observers/watchers, VirtualHID daemon and DriverKit process are
outside ErgoptiPlus ownership and remain alive for the user's personal rules.
Disabling the ErgoptiPlus Karabiner menu integration creates no active lease and
does not stop, restart, or otherwise manage stock Karabiner.

That distinction answers the original crash scenario precisely: the background
component does **not** kill “Karabiner”; an independent per-user launchd
guardian revokes only ErgoptiPlus's token-scoped remapping authority after the
embedded Hammerspoon/launcher path disappears. This survives Activity Monitor
Force Quit because it does not depend on a Lua shutdown callback running.

The other high-risk work concentrated on the same invariant at different
boundaries:

- synthetic input is identified by immutable event provenance rather than
  character/timing guesses in two separate trackers;
- quit, reload, pause/resume, layout change, and remap deployment publish state
  only after their external commitment is proven;
- tooltip pixels and logical ownership commit together;
- static, terminator, repeat, dynamic, and PersonalInfo magic actions use one
  arbitration result instead of independent “preview” and “fire” answers;
- registry/menu mutations roll back as one transaction and do not publish a
  checkmark, preference, or success notice for `false`, `nil`, or throw;
- HID-path provider/resolver failures enter a bounded in-memory mailbox with one
  lifecycle-owned pump, never a timer/logger/stringification operation per key;
- dynamic RulesEngine, PersonalInfo and root startup now commit as one
  generation or leave every staged callback inert and every registry snapshot
  restored;
- an existing unreadable `personal_info.toml` now fails startup closed and
  retains its exact bytes; only an exact `ENOENT` may authorize default creation;
- the macOS filesystem adapter distinguishes proven final-name absence from
  dangling links, directories, missing prefixes and inspection failures, then
  revalidates pathname and file identity around each transaction;
- remap and general menu preferences expose no candidate state until durable
  publication, and a rejected menu save restores the boot-seeded committed
  state plus every represented runtime owner.

**Verdict.** The prior replay plus current source and named causal test contracts
establish materially stronger G1, G2, G3 and G5 invariants than the pre-audit
revision. The global claim “no user
action can ever fail or lag” is still not proven: this Windows host cannot run
real `hs.eventtap`, `hs.canvas`, Accessibility, launchd, Karabiner, DriverKit, or
the Swift launcher tests, and no production macOS profiler artifact was found.
Physical Force Quit/keyboard-release validation and a real macOS performance
capture remain release gates, not optional polish.

### What this pass did that earlier passes did not

1. Replaced broad Karabiner process ownership with a canonical-shape,
   one-shot generation capability and audited the whole process-family class for
   forbidden stock mutations.
2. Added a launchd-owned guardian independent of both Hammerspoon and the app
   launcher, including EOF, stopped-parent, worker-loss, replacement-fence and
   late-orphan ordering tests in the native test source.
3. Tested keymap and keylogger against the same provenance transaction, including
   physical exact matches, `Cmd+V`, Backspace, reordered and evicted echoes.
4. Removed the second hotstring decision path: preview and magic dispatch now
   consume `Expander.resolve_magic_action()` and an exact visible-action lease;
   expiry, failed native hide and failed retry ownership are behaviorally fenced.
5. Exercised failure return values (`false` and `nil`) in addition to throws at
   native canvas, timer, task, filesystem, registry and menu boundaries.
6. Audited recent fixes for sibling-site damage, including error-reporting PII,
   stale integrity expectations, damaged UTF-8 test headers and three pcall-only
   assertions that could not prove their claimed behavior.
7. Re-opened the two formerly isolated follow-ups in final integration: the
   off-HID diagnostic mailbox and transactional dynamic-hotstring startup, then
   audited their lifecycle, rollback, privacy and fail-fast sibling sites.
8. Followed the AHK unreadable-config data-loss class into PersonalInfo and
   tested existing-file read failure separately from true absence and failed
   default publication.
9. Followed that absence-proof class across preferences, personal hotstrings,
   shortcuts, app categories, remap configuration and keylogger device identity;
   then tested dangling links, directories, missing prefixes and first-writer
   races through the central adapter.
10. Replayed POSIX component ordering with an intermediate symlink plus `..`,
    closing lexical redirection and narrowing stale writes with a final source
    recheck. The 2026-08-13 reconciliation explicitly leaves the final
    check-to-rename interval open against non-cooperating writers (`HS-H-18`).
11. Audited more than one hundred menu preference save sites as one transaction
    class, including first-click failure, LLM backend/profile/warmup ordering,
    hotkey stores, deferred keylogger start and gesture registries.
12. Replayed the entire Lua suite from a cold module boundary, found that a
    leaked shared `keymap.*` stub—not 79 independent product defects—was
    poisoning later files, replaced namespace guesses with source-root
    isolation, and then separated real production regressions from stale
    fixtures through the zero-failure aggregate run at exact `04e917cf`.
13. Reconciled every claim from the retired 2026-08-08 audit against current
    production code, behavioral tests, this report and `PROJECT_MEMORY`; old
    confirmed-looking claims that are now intentional or absorbed are recorded
    as explicit refutations rather than silently disappearing.
14. Followed the old clipboard, native-task, process-lifecycle and LLM callback
    findings across sibling call sites. The resulting source centralizes
    exact native-result commitment, callback visibility and retained cleanup
    ownership.
15. Re-opened the eventtap performance claim from the sink outward. This found
    that the earlier “deferred DEBUG flush” optimization still performs
    synchronous console and filesystem writes in the keyDown callback, and that
    its structural guard explicitly allowed the defect (`HS-H-34`, `HS-M-20`).
16. Replayed the recurring-owner class beyond the adapter: four raw timers,
    the KC persistence/cursor gates, root's scheduler-wide finalizer, both
    Metrics dashboards, the Metrics OFF capability boundary, Apps window
    continuations, Healthcheck proof integrity and deferred dialog focus. This
    added `HS-H-53`–`HS-H-56`, `HS-M-24`–`HS-M-27` and `HS-L-04`.
17. Challenged the apparently green virtual-keyboard E2E transcript itself. It
    exposed a shared `hs.canvas` double that logged renderer failures while the
    gate still exited zero; the replacement now preserves element and native
    visibility state, and the intentional crash test owns its own fault injector
    (`HS-M-28`).

### Evidence baseline

| Artifact | Re-derived result |
| --- | --- |
| Last fully replayed committed source baseline | Exact driver/test baseline `dafbcb591e073811c8c1e4b4f3bc39482ec1c4de`. `npm run test:hs` exited 0: **803 modules, 5,218 passed, 0 failed**. `npm run test:hs:e2e` passed **64/64** with one explicitly driver-specific corpus vector skipped and no unexpected renderer ERROR record. `npm run test:js` exited 0: **all 173 checks passed**. These are portable Windows-host test-run results, not driver latency measurements or native macOS evidence. |
| Retired-audit ledger | The 2026-08-08 report was used only as a candidate ledger. Its 26 IDs and non-finding refutations were rechecked against current source/tests, migrated here or into `PROJECT_MEMORY`, then the superseded file was removed. |
| Config path | `C:/Users/admin/AppData/Roaming/Ergopti/paths.toml` currently resolves `ConfigDirPath` to `D:/Documents/GitHub/config/ergopti_plus/`. |
| Production Hammerspoon log target | Code and config resolve it to `D:/Documents/GitHub/config/ergopti_plus/hammerspoon/logs/`. That directory was absent on this host. The fallback paths `C:/Users/admin/.config/ergopti_plus/hammerspoon/logs/` and `C:/Users/admin/.hammerspoon/logs/` were also absent. This is not a claim that the driver has never logged. |
| Inspected daily fallback | `D:/tmp/ErgoptiPlus_2026-08-13.log` was opened and identified as mutable Windows-harness output. It continued growing during the current gates, so the earlier size and `Slow` counts are not presented as a final artifact. No production latency claim is derived from it. |
| Boot artifact | `D:/tmp/ErgoptiPlus_boot.log` was opened and contained exactly zero `Slow` matches. It is likewise a test/fallback artifact and cannot prove production boot cost. No dated `ErgoptiPlus_boot_2026-08-13.log` existed. |
| Logger sink reachability | Code-derived from `modules/keymap/init.lua` into `infra/logger.lua`: accepted keyDown logging can synchronously reach console output, file open/write/routing and periodic or severity-driven flush/notification before the callback returns. The earlier in-memory-spy operation totals were not retained as an independently replayable artifact, so no exact counts are cited. This supports the open call-chain finding `HS-H-34`; it is not a duration measurement. |
| Prior mailbox/lifecycle Lua tests | Direct runs at exact `cd3e72066987171421ca40e5f45163493d630cab` passed `50/0`: mailbox `10`, provider `1`, resolver `1`, keymap start `22`, TimerScheduler `16`. |
| Prior dynamic-transaction Lua tests | Direct runs at exact `cd3e72066987171421ca40e5f45163493d630cab` passed `17/0`: RulesEngine start `5`, root orchestrator start `3`, trigger synchronization `2`, registry transactions `7`. |
| Prior PersonalInfo read/start transaction | Behavioral red/green artifact: before the fix, the module was `2 passed / 2 failed`; at exact `04e917cf` the same four-test module was `4 passed / 0 failed` (`4/4`). |
| Late filesystem/remap/preferences/LLM matrices | Through `04e917cf`, the production branches and exact assertions in `test_file_system_atomic_write.lua`, remap's three config/lease modules, `test_preferences_save_transaction.lua`, `test_llm_activation_save_gate.lua`, `test_menu_preference_calls_fail_closed.lua`, the keylogger identity/rollover modules, the model-backend guard and their named sibling tests were opened and reconciled line-by-line. |
| Prior late LLM behavioral replay | Direct runs at exact `04e917cf` passed `3/0`: backend-switch invalidation `1`, recommended-profile refuse/accept decisions `2`. The earlier filtered aggregate attempt timed out during discovery and is not counted as a run result. |
| Prior aggregate Lua gate | Fresh POSIX checkout at exact `04e917cf`, Lua `5.4.6` plus LuaFileSystem `1.9.0`: **751 modules, 4,881 passed, 0 failed, exit 0**. Stderr contained only the deliberately injected fixture command `ls /no/such/dir`. This is historical portable-Lua evidence for that exact baseline, not a result for the current working tree and not real Hammerspoon/macOS runtime evidence. |
| Comparative suite archaeology | With the corrected source-root isolation helper applied to the campaign baseline, the aggregate was `729` modules / `4,713` pass / `23` fail. On late code before the runner fix, cross-file pollution inflated the result to `203` failures; purging the leaked shared modules reduced it to `66`, and causal production/fixture repairs brought exact `04e917cf` to `0`. These are test-run counts, not user-runtime measurements. |
| Prior Hammerspoon E2E | At exact `04e917cf`, `npm run test:hs:e2e` passed `64/64`; one explicitly driver-specific corpus vector was skipped. This is the portable virtual-keyboard harness, not real macOS eventtap/canvas evidence. |
| Prior repository gates | At exact `04e917cf`, `npm run lint:conventions:strict` passed; `npm run test:hs-integrity` passed `14/0`; `npm run test:source-encoding` scanned 2,947 text assets clean; `npm run test:find-false-greens` reported `0`; the privacy gate judged 18 Windows trigger-carrying sinks and 12 Lua value-carrying sinks, with 8 Lua sinks reduced/redacted. |
| Prior aggregate JavaScript gate | A clean third `npm run test:js` at exact `04e917cf` exited `0` in `545.4 s`: **`All 172 JS check(s) passed.`** Earlier red runs were contaminated by untracked runtime artifacts or a Linux build-copy failure and are retained only as test archaeology, not current evidence. |
| Current post-reconciliation supporting gates | At the same source baseline, Hammerspoon integrity passed `14/14`; the false-green detector reported zero findings in every category; strict conventions passed for `1,081` AHK, `1,344` Lua and `40` TOML files; the final source-encoding replay scanned **3,009** text assets clean. Native macOS and production-performance results remain unclaimed. |
| Swift/native tests | Source and CI wiring were inspected. They were **not executed** on this Windows host; no Swift/macOS runtime result is claimed. |

### Audit passes and dry status

- **Pass 0 — evidence:** project rules, `PROJECT_MEMORY`, historical audit,
  current config-path resolution, log classification, commit and test inventory.
- **Pass 1 — entry points:** eventtaps, persistent hotkeys, menu callbacks,
  gestures, timers, task completions, layout watchers, launcher/worker/guardian,
  quit/reload and first-run writers.
- **Pass 2 — flows:** typing → expansion → synthetic provenance → keylogger;
  preview → action; pause/resume; layout switch; controlled and uncontrolled
  process death; disabled Karabiner integration.
- **Pass 3 — sibling damage:** every recent invariant was followed into sibling
  call sites, including public registry writers, menu publications, both dynamic
  engines, both input consumers, and all shared Karabiner process families.
- **Pass 4 — G5:** static, terminator, repeat, RulesEngine, PersonalInfo, no-op,
  case, timing and composite-event arbitration.
- **Pass 5 — BLINDER/refutation:** candidate findings were searched against
  current tests and backstops. The refuted ledger is in section 3.
- **Pass 6 — post-fix sibling damage:** re-opened the integrated G5/PersonalInfo
  artifacts, tested pre-paint expiry, failed-hide retry ownership, provider and
  resolver observability/privacy, durable personal-data publication, source
  encoding, integrity gates and false-green assertions.
- **Pass 7 — final integration:** re-derived the bounded diagnostic mailbox,
  exact pump ownership, transactional RulesEngine/PersonalInfo/root startup,
  registry/startup diagnostic redaction, top-level fail-fast order and the final
  portable gates listed above.
- **Pass 8 — unreadable configuration:** drove existing-file `EACCES`, exact
  `ENOENT`, read/close commitment, failed default publication, callback ordering,
  byte preservation and redacted diagnostics through PersonalInfo startup.
- **Pass 9 — filesystem ownership:** followed the same absence and exact-commit
  invariant through every late config consumer, then drove symlink, directory,
  missing-prefix, identity-replacement, create-only and concurrent-source cases.
- **Pass 10 — remap/menu transactions:** drove corrupt and unreadable Karabiner
  configuration, setter/save failure, valid-source control, first-click menu
  rejection, runtime rollback, deferred work cancellation, success-only UI and
  model-requirements completion after a sibling backend switch.
- **Pass 11 — aggregate isolation and residual triage:** reproduced the shared
  `keymap.terminators` stub leak, replaced prefix-based runner cleanup with
  source-root isolation, classified the remaining failures as production versus
  fixture drift, and replayed all 751 Lua modules to zero failures.
- **Pass 12 — historical retirement reconciliation:** reopened every 2026-08-08
  finding/refutation and its current production/test backstop. Eleven High and four
  Medium findings were restored to the current ledger; two old claims were
  explicitly superseded or decided against. The affected source/test zones were
  replayed at the then-final committed executable baseline.
- **Pass 13 — logger sink from the user entry point:** followed every accepted
  keyDown log through console, unified, topical, errors-only and notification
  sinks; falsified the flush-only structural guard; rejected a timer-only
  prototype because it remains on Hammerspoon's main run loop (`HS-H-34`,
  `HS-M-20`).
- **Pass 14 — native producer transactions:** re-derived the chainable timer
  contract, then swept adapter consumers, raw recurring owners and composite
  timer+watcher/eventtap groups. This pass found the root keylogger, KC, WPM,
  Metrics, Healthcheck and WebKit-after-yield siblings (`HS-H-43`–`HS-H-52`),
  plus the incomplete whole-class inventory (`HS-M-22`, `HS-M-23`).
- **Pass 15 — adversarial replay/refutation:** challenged each pass-14 claim
  against existing backstops and current tests. It rejected unconditional KC
  OFF→ON replay and missing terminal cleanup as overbroad, retained only the
  failed-resync sequence, followed WPM commitment through its menu caller, and
  replayed the then-current causal and aggregate gates recorded in the evidence
  table.
- **Pass 16 — residual owner and proof sweep:** followed raw recurring timers,
  KC's separate producer/persistence/cursor states, the root global timer drain,
  dashboard ingest subscriptions and generations, required Metrics stop,
  Healthcheck's nil-poller assertion and deferred dialog focus. This pass found
  `HS-H-53`–`HS-H-56`, `HS-M-24`–`HS-M-27` and `HS-L-04`, then added causal
  source/behavior tests for those boundaries.
- **Pass 17 — aggregate transcript challenge:** the first post-pass-16 replay
  passed assertions but its E2E transcript contained renderer ERROR lines. The
  cause was the shared canvas double, not production rendering; this pass found
  and fixed `HS-M-28`, then replayed E2E without those errors and the portable
  Lua aggregate at `803` modules / `5,218` assertions / zero failures.
- **Pass 18 — final portable dry replay:** replayed the complete post-`M-28`
  source/test tree. Lua passed `5,218/5,218`, virtual-keyboard E2E passed `64/64`
  with its one documented driver-specific skip, JavaScript passed `173/173`,
  integrity passed `14/14`, the pcall-only detector reported zero and encoding
  scanned `3,009` assets clean. The exact committed code baseline is
  `dafbcb591e073811c8c1e4b4f3bc39482ec1c4de`. This closes the portable replay;
  it does not close the three named source gaps or any native-runtime gap.

Karabiner/lease source became dry on pass 5 for the inspected ownership class;
keymap/provenance and pause correctness became dry on pass 4; the reconciled
tooltip/G5 follow-ups became dry on pass 6; config-path persistence and logger
retention became dry on pass 3; off-HID diagnostics and dynamic startup became source/test
dry on pass 7; PersonalInfo read/default publication became source/test dry on
pass 8; central filesystem/config ownership became source/test dry on pass 9;
the remap-config and represented menu-preference transaction classes became
source/test dry on pass 10; the inspected model/backend completion identity also
became source/test dry on pass 10; aggregate runner isolation and residual
classification became dry on pass 11 at `04e917cf`. The pass-12 clipboard,
native-task and LLM additions were replayed at
`cd3e72066987171421ca40e5f45163493d630cab`, but the broad lifecycle class was
reopened by pass 14 rather than declared dry. Timer/native producer ownership,
KC, WPM, Metrics and Healthcheck became portable source/test dry only after the
pass-16 sibling replay. Tooltip test-double fidelity was reopened by pass 17 and
became portable dry on pass 18 after the stateful-canvas replay. All zones
claimed as portable source/test clean completed a no-new-defect pass. The
logger/eventtap G4 boundary was reopened on pass 13 and is
explicitly **not dry**. LLM service integration, actual
Accessibility/canvas behavior, touch hardware, multi-day runtime and native
launchd scheduling remain runtime coverage debt.

---

## 2. Confirmed findings and fix status

### Critical

### `HS-C-01` — Hammerspoon/launcher death left Ergopti remaps live, while broad cleanup endangered the user's stock Karabiner

**Severity:** Critical. **Confidence:** High for the source/control-flow defect;
native end-to-end confidence remains gated on macOS execution. **Guarantees:**
G1, G2, G3. **Locations:** `launcher/README.md:28-63`;
`launcher/Sources/ErgoptiPlus/RemapLeaseGuardian.swift:1-12,1292-1305,1679-1688,1876-1888`;
`launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift:10-32,60-63,1070-1095,1275-1290,2521-2560`;
`platform/remap/lease_contract.lua:29-33,55-61,115-142`;
`platform/remap/lease_controller.lua:226-260,597-626`;
`platform/remap/init.lua:2801-3001,4332-4379`.

**Concrete reproduction.** Enable ErgoptiPlus Karabiner remapping while the user
also has ordinary Karabiner UI/services and personal rules. Then Force Quit the
embedded Hammerspoon or the Ergopti launcher in Activity Monitor. A Lua shutdown
callback cannot run after `SIGKILL`; before this fix, the variables authorizing
ErgoptiPlus mappings could remain live. The historical sibling workaround
constructed `launchctl bootout`/`pkill` commands for Karabiner UI, console,
observer/session and service processes, so attempting to “clean up Karabiner”
could also stop the user's unrelated Karabiner session.

**Root cause and silence.** Ownership was inferred from process family and a
volatile marker, but Karabiner is a collection of shared processes. Abrupt death
has no Lua epilogue, so the absence of an error is expected: remapping simply
continues after the UI disappears. Conversely, broad shell cleanup cannot prove
which configuration a shared Karabiner process serves.

**Implemented fix.** Each activation allocates a never-reused 32-lowercase-hex
token. Generated rules require that token's mode be ACTIVE/PAUSED and its
monotone revocation tombstone remain clear. A retained private worker owns the
standard-stream protocol and only direct canonical `karabiner_cli` children. A
per-user launchd guardian independently watches a locked exact-token record and,
after host/worker loss, publishes only that token's OFF+tombstone payload. Late
writes from the old generation cannot authorize a replacement token. Process
signals are restricted to direct private child/process-group ownership; there
is no stock Karabiner process discovery or termination path. When the
ErgoptiPlus Karabiner menu integration is disabled, no lease activation or
guardian-owned remap side effect occurs.

**Why the fix does not kill the wrong Karabiner process.** The allowlisted
executable is exactly
`/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli`.
The worker retains the PID/process group it created and reaps that child. It
does not obtain PIDs by name. The whole-source isolation guard rejects `pkill`,
`killall`, destructive `launchctl`, stock GUI launches, PIDs derived from stock
names, Core Service/old grabber, console server, session agents, observers,
watchers, VirtualHID daemon and DriverKit targets. The sole permitted stock-GUI
capability is the explicit user menu action that opens Karabiner.

**Regression tests.** `tests/meta/test_karabiner_stock_process_isolation.lua`
asserts zero whole-driver offenders and mutation-tests direct shell kills,
constant-folded names, Swift `Process` launches and PID-to-`/bin/kill` data flow.
`tests/unit/ui/menu/test_menu_karabiner_disabled_isolation.lua` asserts the
disabled integration creates no lease/process side effect.
`tests/unit/platform/remap/test_guardian_auto_recovery.lua` drives FAILED → exact
fence → fresh-token redeploy and asserts `os.execute`, `io.popen` and stock
process signaling are unreachable. Native source tests
`RemapLeaseWorkerTests.testEOFBeforeActivationFencesWithoutReady`,
`testEOFAfterReadyFencesTheGeneration`,
`testAuthenticatedOuterFencesDirectlyWhenReplacementSpawnerStaysUnavailable`,
`testKilledInnerGroupReapsOrphanAndPreservesSharedProcessSiblings`, and
`testUnrelatedSiblingSurvivesEveryDirectChildPreemption` encode the exact
failure class. These Swift tests still require execution on macOS.

### High

### `HS-H-01` — Character/timing heuristics let physical input drain synthetic expectations

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3.
**Locations:** `adapters/event_provenance.lua:130-194`;
`adapters/synthetic_input.lua:1230-1351,2109-2159,2284-2320`;
`modules/keymap/init.lua:958-1005,1277-1327`;
`modules/keylogger/init.lua:543-590`.

**Reproduction.** Begin a synthetic `AB` replacement, deliver a physical `A`
or physical `Cmd+V`/Backspace before the delayed owned echo, then deliver the
owned event. With equality/counter tracking, the physical event consumes the
expectation and the later owned event is treated as human text by one or both
consumers. Private replacement bytes can then enter the keylogger or the keymap
buffer can diverge from the screen.

**Root cause and silence.** Two consumers independently guessed identity from
payload, timing and counters. A queue reaching zero looks healthy; no exception
records that the wrong event drained it.

**Implemented fix.** `SyntheticInput` owns one provenance-bearing transaction
and immutable tagged-event ledger. `EventProvenance.classify_with_fence()`
classifies once and atomically claims the physical ordering boundary. Keymap and
keylogger claim independent consumer slots for the same tag; foreign or
unreadable events cannot impersonate owned output. Every injector uses the same
transactional choke point.

**Regression test.** `tests/unit/modules/keymap/test_synthetic_provenance_interleaving.lua`
asserts identical same-process physical input survives, reordered/evicted owned
echoes stay filtered, physical `Cmd+V` and Backspace do not consume tagged
operations, and stale loopback cannot regain authority. The cross-consumer
fixtures in `tests/support/synthetic_input_stack.lua` and
`tests/support/keylogger_provenance_fixture.lua` ensure the test does not model
only one tracker.

### `HS-H-02` — Controlled quit/reload and teardown reported completion before exact external cleanup

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `infra/termination_coordinator.lua:108-174,211-237`;
`infra/teardown_transaction.lua:58-95`; `platform/remap/init.lua:4332-4499`.

**Reproduction.** Request reload, then quit while the exact lease stop is still
pending; alternatively make one local stop return `false` or throw. The old
shape could run terminal actions independently, forget a failed handle, or exit
before remap fencing. A reload/quit race could also apply the wrong teardown
policy.

**Root cause and silence.** Terminal entry points duplicated sequencing and
treated invocation as completion. Failed teardown steps were not retained as
retryable ownership. `os.exit()` bypasses Hammerspoon shutdown, so a premature
exit removes the only Lua witness.

**Implemented fix.** `TerminationCoordinator` serializes reload/exit behind the
exact lease callback; exit safely supersedes reload. `TeardownTransaction`
commits only exact-successful steps, retains unfinished steps, and reruns them
without repeating completed siblings. The public remap stop releases local
consumers only after controller idle is proven.

**Regression test.** `tests/unit/lib/test_termination_coordinator.lua` asserts
one shared fence, reload-to-exit upgrade, duplicate-callback rejection and no
terminal action on failed fence. `tests/unit/lib/test_teardown_transaction.lua`
injects false/throw at each step and asserts only incomplete steps retry.
`tests/unit/modules/gestures/test_script_quit_revokes_karabiner_lease.lua` drives
the real script action through the coordinator.

### `HS-H-03` — Pause/resume could publish a split state across Hammerspoon and Karabiner

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `modules/shortcuts/script_control.lua:272-472,638-899,931-939`;
`platform/remap/init.lua:3819-4084`.

**Reproduction.** Press the pause key and fail one local subsystem after
Karabiner reports PAUSED, or fail RESUME before local modules restart. Rapidly
press pause then resume while the native transition is pending. Previously the
menu/notification and local features could say “paused” while native remapping
was live, or vice versa; a second request could overlap the first.

**Root cause and silence.** The cross-process transition was a list of side
effects with no commit point or inverse preflight. State and success UI were
published from the initiating callback rather than the exact native ACK.

**Implemented fix.** Pause is a serialized transaction. It waits for PAUSED,
preflights inverse methods, snapshots local states, rolls back every partial
local mutation, and publishes only after all required modules quiesce. Resume
keeps the private paused state until RESUMED and every local restart commit;
rapid reversals queue one desired target. Non-lifecycle script-control actions,
public keylogger sinks and owned global hotkeys are fenced while paused.

**Regression test.** `tests/unit/modules/shortcuts/test_pause_transaction.lua`
failure-injects every pause/resume step and asserts no listener, checkmark or
success notice precedes commitment, every partial local mutation rolls back,
and rapid pause→resume serializes. `test_paused_script_control_dispatch_fence.lua`,
`test_paused_public_shortcut_sink.lua`, and
`test_paused_global_hotkey_ownership.lua` enumerate sibling entry points.

### `HS-H-04` — Configuration-directory writes mutated/published state before durable persistence

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2.
**Locations:** `infra/config_paths.lua:304-327,408-466,531-563`;
`ui/menu/menu_paths.lua:126-148,236-270,311-343`;
`ui/onboarding/init.lua:343-410,424-481`.

**Reproduction.** Make the managed `paths.toml` destination unwritable or make
write/close/rename fail, then confirm a new directory in the editor or
onboarding. The old behavior could report success/reload with only in-memory
state changed; the next process reopened the old directory and the user's
choices disappeared.

**Root cause and silence.** A successful Lua call was confused with durable
write commitment, and two writers disagreed about target/reload behavior.

**Implemented fix.** There is one managed-path writer. It writes a same-target
staging file, checks write/close, performs atomic publication with rollback, and
changes in-memory state only after success. The packaged launcher exports a
stable user-writable absolute managed path; source mode never falls back through
an empty or ambiguous `HOME`. Editor/onboarding stop on any non-true result.

**Regression test.** `tests/unit/lib/test_config_paths_write_transaction.lua`
and `test_config_paths_managed_bootstrap.lua` inject open/write/close/rename
failures and assert old bytes/state survive. `tests/unit/ui/test_config_dir_write_failure_propagation.lua`
asserts the path editor stays open, no reload/deletion occurs, and onboarding
accepts only explicit true.

### `HS-H-05` — Tooltip logic could own keys when no native pixels committed

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G5.
**Locations:** `ui/tooltip/renderer.lua:194-229,355-478,639-837`;
`ui/tooltip/tooltip_hotstring.lua:489-747`;
`ui/tooltip/init.lua:87-172`; `modules/keymap/llm_bridge.lua:857-974`.

**Reproduction.** Make canvas creation, element update, `show()`, `hide()`, or
native `isShowing()` return nil/false or throw. The previous facade could mark a
tooltip visible and arm Escape/navigation although nothing was visible, or clear
logical ownership while pixels remained. The next key was then swallowed or an
old promise stayed on screen.

**Root cause and silence.** Renderer and facade had no strict commitment
contract. `pcall` success was accepted even when the native method returned a
failure value, and logical visibility was published before native read-back.

**Implemented fix.** Every render/update/hide returns exact true only after the
native canvas state is observable. Watchers, visibility, callback ownership and
the opaque hotstring lease publish only after that result. A failed show revokes
the surface; a failed hide retains ownership for retry instead of pretending the
pixels disappeared.

**Regression test.** `tests/unit/ui/test_tooltip_renderer_native_commit.lua`
table-drives throw/nil/false/no-visible-change for standard and stacked canvases
and asserts callbacks/visibility never publish early. `test_escape_owned_by_trap.lua`,
`test_tooltip_user_callback_visibility.lua`, and
`test_tooltip_on_show_callback_visibility.lua` assert invisible UI cannot own a
user key and callback failure revokes the surface.

### `HS-H-06` — LLM asynchronous callbacks could mutate state after ownership changed or UI failed

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `modules/llm/prediction_engine.lua:580-734,734-1071`;
`modules/llm/streaming_handler.lua:188-568`;
`modules/keymap/llm_bridge.lua:1325-1551`.

**Reproduction.** Start a request, then reset/pause/change action context before
an `on_chunk` or `on_done`; separately make loading tooltip or watchdog arming
return false. Without a shared owner, a stale result could repaint or an engine
could fetch despite having no visible committed request surface.

**Root cause and silence.** Backend generation, UI visibility, synthetic action
ordering and cleanup were independent. Raw native task callbacks and locally
discarded protected-call errors can remain outside the file logger; timer
callbacks created after `infra/logger.lua` installs runtime capture are globally
wrapped. Non-true UI/timer results are not throws at all and therefore still
require explicit operational-result checks.

**Implemented fix.** A shared action epoch quarantines text/LLM state across
physical and synthetic actions. Pre-fetch stages require exact UI and watchdog
commitment. Streaming callbacks recheck generation/owner, contain errors with
tracebacks, cancel backend work, stop retained timers, and revoke their exact
surface. Reset publishes a safe epoch only after full cleanup and a second
generation check.

**Regression test.** `tests/unit/modules/llm/test_prediction_engine_ui_commit_gate.lua`
asserts no backend fetch after false/nil/throw at loading, chain timer or
watchdog; callback failures cancel once and hide. `test_streaming_handler_stale.lua`,
`test_streaming_handler_ui_commit_gate.lua`,
`test_prediction_engine_action_epoch_guard.lua`, and
`test_llm_bridge_action_epoch_quarantine.lua` interleave reset/new actions with
late chunks and terminal callbacks.

### `HS-H-07` — Focus/ignored-window transitions reused text observed in another application

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `modules/keymap/init.lua:320-352,958-1017`;
`modules/keymap/utils.lua:419-470,752-845`.

**Reproduction.** Type a partial trigger in app A, focus an ignored app and type
before the deferred classification refresh, then return to A and finish a
trigger. Reusing the previous cache/buffer can delete or expand against text
that is not at the current caret. An old tooltip can also remain visible while
focus ownership is unknown.

**Root cause and silence.** Dirty focus classification was treated as the old
boolean value, and text/preview state was not one window-scoped generation.

**Implemented fix.** Window changes enter an explicit quarantine that severs
observed text and prediction ownership. Ignored input exits before character,
modifier, interceptor, keylogger or tooltip work. Classification occurs off the
tap; only a settled normal context reopens the runtime and reconstructs a
preview from new text.

**Regression test.** `tests/unit/modules/keymap/test_ignored_window_deferred_buffer_snapshot.lua`
drives normal→ignored→normal before timers, asserts ignored keys never enter
interceptors/buffers, no autocorrection emits, old pixels hide while ownership
is unknown, and a new preview appears only after normal recovery.

### `HS-H-08` — Failed native lifecycle operations discarded the only retry handle

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/timer_scheduler.lua`; `adapters/shell_runner.lua`;
`adapters/hotkey_registrar.lua`; `infra/teardown_transaction.lua:58-95`.

**Reproduction.** Make a timer constructor return nil, task `start()` return
false, hotkey/eventtap `delete()` fail, or task termination fail. Treating a
non-throwing return as success loses the handle or leaves “running/stopped” state
opposite to the OS. Retry then becomes impossible and async completion may never
arrive.

**Root cause and silence.** The code checked `pcall` rather than the operation's
documented return contract, and cleared ownership before teardown committed.

**Implemented fix.** Scheduling and start APIs require exact commitment;
construction/start failure leaves no published owner. Cancellation/termination
failure retains the handle and pending state for retry. `ShellRunner` owns task
stdin, GC pin and completion as one supervised operation.

**Regression test.** `tests/unit/adapters/test_timer_scheduler.lua` covers nil
construction and retained callbacks; `test_shell_runner_gc_pin_release.lua` and
`test_shell_runner_stream_input.lua` cover false start, stdin, one terminal
callback and GC release; `test_hotkey_registrar.lua` plus teardown tests assert
failed native removal remains retryable.

### `HS-H-09` — Tooltip and magic-key dispatch answered the same question through different engines

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `modules/keymap/expander.lua:287-627`;
`modules/keymap/llm_bridge.lua:331-353,562-1032`;
`modules/keymap/init.lua:776-830`.

**Reproduction.** Register competing auto and terminator mappings that share a
tail, a mapping rejected by the auto gate, a no-op, case-folded trigger, or a
French composite magic event. Type the prefix, observe the preview, then press
the magic key. Independent scans can choose different winners or show a row for
an action the engine will decline.

**Root cause and silence.** Preview duplicated boundary, delay, case,
auto-expand, terminator and precedence logic. Agreement depended on every future
writer changing both copies identically.

**Implemented fix.** `Expander.resolve_magic_action()` owns matching and
cross-kind arbitration. It returns one candidate/attempt ledger and opaque
action identity. The tooltip renders that result; dispatch consumes the same
winner subject to the exact visible lease and current physical event. The old
preview matcher was removed rather than “kept in sync”.

**Regression test.** `tests/unit/modules/keymap/test_preview_cross_kind_winner.lua`
drives the real eventtap and asserts the sole active row equals the exact emitted
replacement. `test_preview_star_requires_auto_expand.lua`,
`test_preview_star_tail_casefold.lua`,
`test_preview_respects_terminator_state.lua`, and
`test_star_validation_beats_repeat_key.lua` encode the rejected/gated siblings.

### `HS-H-10` — Semantic mutation could leave an already visible tooltip promising the old action

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `modules/keymap/llm_bridge.lua:1346-1382`;
`modules/keymap/init.lua:365-437,485-528`;
`modules/dynamic_hotstrings/rules_engine.lua:87-103,407-444`.

**Reproduction.** Show a hotstring row, make native hide fail, then change the
magic key, base delay, registry corpus, dynamic data, group or preview setting.
If mutation commits anyway, the visible row describes old semantics while the
next key is evaluated against new semantics.

**Root cause and silence.** The UI lease was treated as decoration instead of a
promise. Public writers mutated independent sources without first revoking that
promise, and non-throwing hide failure was ignored.

**Implemented fix.** `invalidate_hotstring_preview()` fences deferred renders,
requires native pixel revocation, and only then clears logical state. Every
public registry/trigger/delay writer and dynamic semantic writer passes through
that fence and returns exact false without mutation when revocation cannot
commit.

**Regression test.** `tests/unit/modules/keymap/test_preview_mutation_commit_gate.lua`
keeps a row visible while hide returns false, then asserts old delay, trigger,
registry and lease all remain intact. Its second test enumerates the complete
public writer class so a future sibling cannot bypass the gate.

### `HS-H-11` — Winner expiry could discard or strand the action lease behind stale native pixels

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `ui/tooltip/tooltip_hotstring.lua:39,403-440,750-796`.

**Reproduction.** Display a stacked tooltip whose timed literal is the active
winner and whose star action is dimmed, advance the clock past the literal's
deadline, then make native stacked hide return `false`. In the sibling failure,
also make `hs.timer.doAfter` return `false`, return `nil`, or throw while the
cleanup retry is being armed. The original expiry callback could re-arbitrate
after a refused hide, so old pixels remained while their exact action lease had
already been cleared. The first repair retained the lease but still left no
cleanup owner when retry construction failed.

**Root cause and silence.** `hide_forced()` tears down dequeue/watchers before it
can know whether native pixels actually disappeared. Expiry treated that
attempt as commitment, and retry scheduling treated invocation as ownership.
Neither failure necessarily raises; the stale row simply survives with no
future callback responsible for it.

**Implemented fix.** A refused hide restores the exact `_dequeue_rows` owner and
keeps the visible lease coupled to those pixels. Cleanup first gets one bounded
positive-delay retry. If timer construction is not exactly committed, ownership
transfers to a freshly verified physical-input watcher set; its callback never
consumes the user's event and defers canvas work until after the eventtap returns.
Only a successful native hide may delegate one fresh arbitration.

**Regression test.** `tests/unit/ui/test_tooltip_watcher_reuse.lua:1003-1143`
asserts retained pixels/lease and zero premature expiry callback, then
table-drives false/nil/throw retry construction. It requires a fresh enabled
watcher generation, no live fake timer, no synchronous canvas work in the
physical callback, and eventual exact lease revocation after deferred cleanup.

### `HS-H-12` — Preview-provider exceptions were silent; naive diagnostics could block or disclose on HID

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G4, G5; privacy
invariant. **Locations:** `modules/keymap/llm_bridge.lua:282-290,605-620`;
`modules/diagnostics/hid_diagnostic_mailbox.lua:36-45,80-188,201-293`;
`modules/keymap/init.lua:171-176,1735-1743,1845-1863`.

**Reproduction.** Register a dynamic preview provider that raises while a static
mapping can still match the same buffer, then type that buffer repeatedly. The
old `pcall(provider, buf)` branch silently skipped the failed provider on every
keystroke: its row disappeared, no file diagnostic identified the broken
feature, and only the static fallback remained. The first observability repair
allocated a zero-delay timer per newly failed provider and could fall back to a
synchronous log when scheduling failed; interpolating the exception could also
write an IBAN, phone number or other private value from PersonalInfo.

**Root cause and silence.** Provider failure and ordinary no-match shared the
same branch. A logger, timer constructor or `tostring(error)` inside that branch
is still HID work, and callback exceptions are otherwise swallowed into the
Hammerspoon console rather than the file logger.

**Implemented fix.** The bridge latches one report per weak provider identity
and enqueues only its numeric index. The mailbox is bounded to 64 records and
coalesces overflow visibly. One lifecycle-owned 250 ms repeating pump drains it;
the producer performs zero timer allocation, logger call or error
stringification on HID. A record is removed only after its redacted logger call
commits; refusal/throw retains the exact record and pump ownership for retry.
Keymap starts this sole pump before eventtaps and fails closed if it cannot arm.
Stop drains first and relinquishes the timer only after exact cancellation, so a
failed cancel remains retry-owned instead of creating a duplicate/stale pump.

**Regression tests.** `tests/unit/modules/keymap/test_preview_provider_failure_visible.lua`
drives the real bridge twice and asserts the static winner remains, no HID-time
log occurs, one later redacted diagnostic appears, and the sentinel is absent.
`tests/unit/modules/diagnostics/test_hid_diagnostic_mailbox.lua:121-271` poisons
`__tostring`, counts zero producer-side timers/logs, proves the 64-record bound,
overflow visibility, exact-record retry after logger failure, start/cancel
false/nil/throw ownership, and absence of duplicate/stale pumps. The direct
final mailbox/provider/resolver/keymap/timer group passed `50/0`.

### `HS-H-13` — Shared dynamic resolver exceptions were indistinguishable from a legitimate no-match

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G4, G5;
privacy invariant. **Locations:** `_shared/lua/dynamic_hotstrings/init.lua:160-181`;
`modules/dynamic_hotstrings/rules_engine.lua:159-160,600-724`;
`modules/diagnostics/hid_diagnostic_mailbox.lua:105-223`.

**Reproduction.** Register two enabled rules with the same suffix: the first
resolver raises and the second returns `SIBLING`. Type the suffix and press the
magic key. Before the fix, `SharedEngine.match_buffer()` swallowed the first
exception. With no healthy sibling the feature became a silent no-op; with one,
the fallback happened to work but no artifact explained why the primary rule
vanished. Repeating the key repeated the invisible failure on the hot path.

**Root cause and silence.** The portable shared matcher used `pcall` only as a
control-flow filter. It had no platform-aware way to move the diagnostic beyond
Hammerspoon's eventtap callback, and a raw exception may itself contain resolved
personal data.

**Implemented fix.** Each registered rule owns a one-shot error latch. macOS
installs a token-owned reporter only as part of the successful RulesEngine start
transaction and clears it before rules become reachable on stop. The reporter
passes the mailbox only numeric section/suffix lengths; the exception argument
is never stringified on the installed HID path. The same single 250 ms pump from
`HS-H-12` performs the redacted file log later, with bounded queue, retry and
overflow ownership. The matcher continues to later same-suffix rules, so a
healthy sibling remains both preview and exact injected action. The portable
shared fallback remains outside this installed macOS path; keymap fails closed
before eventtaps if the required mailbox pump is unavailable.

**Regression tests.** `tests/unit/modules/dynamic_hotstrings/test_resolver_failure_visible.lua`
drives the real shared matcher and macOS interceptor. It asserts one deferred,
redacted diagnostic, healthy sibling preview/output equality, continued resolver
evaluation without diagnostic spam, and no leaked reporter after failed start.
The poisoned-string/no-producer-timer assertions in
`tests/unit/modules/diagnostics/test_hid_diagnostic_mailbox.lua:121-153` cover
this producer class as well; transactional reporter ownership is additionally
driven by `test_rules_engine_start_transaction.lua`.

### `HS-H-14` — PersonalInfo save published live secrets before durable file and editor commitment

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `modules/dynamic_hotstrings/personal_info.lua:203-289,347-378`;
`ui/personal_info_editor/init.lua:113-137`.

**Reproduction.** Open the PersonalInfo editor with `first_name=Alice`, keep an
Alice preview visible, enter Bob, and make preview revocation refuse/throw or
make write, flush, close or rename fail. The prior writer mutated `_info` before
opening the file, used an unchecked direct write, and returned no commit result;
the editor wrapped the callback in `pcall` and closed regardless. Live
expansions could therefore become Bob while disk and visible pixels remained
Alice, or a partial file could replace the last durable value with no retry UI.

**Root cause and silence.** Memory, preview ownership, bytes on disk and editor
lifecycle were four independent side effects with no exact commit boundary.
`pcall` answered only whether the callback raised, not whether the save worked.

**Implemented fix.** Save builds an isolated complete candidate, requires exact
preview revocation, writes/flushes/closes a same-directory staging file, and
publishes it with exact-successful `os.rename`. Only then does it update the
existing shared `_info` table in place. Any refusal preserves table identity,
old values and old bytes; the editor closes only on literal `true` and otherwise
keeps the submitted form available for retry.

**Regression test.** `tests/unit/modules/dynamic_hotstrings/test_personal_info_save_transaction.lua:170-288`
injects false, truthy-non-boolean, throw and rename failure, checks old bytes and
live table identity at each boundary, observes the complete staging file before
publication, and asserts the real editor remains open until exact commit.

### `HS-H-15` — Dynamic-hotstring startup published half-initialized callbacks and registry state

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `modules/dynamic_hotstrings/init.lua:45-158`;
`modules/dynamic_hotstrings/personal_info.lua:83-116,807-936`;
`modules/dynamic_hotstrings/rules_engine.lua:83-154,600-724`;
`modules/keymap/registry_groups.lua:91-157`;
`init.lua:1090-1098`.

**Reproduction.** From a cold start, use a keymap registrar that appends the
PersonalInfo interceptor or preview callback and then returns `false` or throws.
Alternatively, let RulesEngine register its append-only callbacks and rules but
make the final registry sort/transaction return `false`. Retry startup with the
same keymap, then type a PersonalInfo or dynamic trigger. Before the fix, stale
callbacks from the failed generation could still execute, shared rules/groups
could remain partially published, and the top-level initializer unconditionally
advertised the dynamic hotfile even though no exact start commit existed.

**Root cause and silence.** Three owners performed progressive side effects with
no encompassing transaction. Append-only callback registries cannot physically
unregister a failed callback, ordinary `stop()` did not reconstruct every shared
registry table, and the caller ignored the startup result. A registrar that
appends and then refuses is therefore strictly worse than one that throws before
mutation; later keystrokes expose the stale generation without a boot-time Lua
exception necessarily escaping.

**Implemented fix.** PersonalInfo and RulesEngine stage callbacks behind fresh
generation tokens; every failed token remains inert forever. Rules/sections and
registry state are snapshotted and restored, and the final RulesEngine
publication commits inside `keymap.registry_transaction`. The root orchestrator
accepts only literal `true`, rolls both children back on refusal/throw, rejects
concurrent or different-keymap ownership, and permits a clean retry with one live
generation. Top-level `init.lua` now raises before adding `dynamichotstrings` to
`hotfiles` unless the root start returned exactly `true`. Startup and rollback
diagnostics expose only controlled step labels and terminal types.

**Regression tests.** `tests/unit/modules/dynamic_hotstrings/test_rules_engine_start_transaction.lua:166-258`
forces append-then-false/throw, final-sort refusal and reporter-install failure;
it asserts stale callbacks are inert, shared rules/groups/hooks/mappings are
absent after refusal, registry state is restored, and retry owns the sole live
generation. `tests/unit/modules/dynamic_hotstrings/test_start_transaction.lua:86-144`
proves root rollback for false/throw, inert stale PersonalInfo callbacks,
different-keymap rejection, sole-generation retry, and source order requiring
top-level fail-fast before hotfile publication. The direct transaction group
(RulesEngine `5`, orchestrator `3`, trigger `2`, registry `7`) passed `17/0`.

### `HS-H-16` — An unreadable existing `personal_info.toml` was treated as absent and overwritten with defaults

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2.
**Locations:** `modules/dynamic_hotstrings/personal_info.lua:71,291-317,807-910`;
`tests/unit/modules/dynamic_hotstrings/test_personal_info_save_transaction.lua:266-369`.

**Reproduction.** Put real user data in an existing `personal_info.toml`, make
that file unreadable while leaving its parent directory writable, then start the
dynamic-hotstring subsystem. The prior `io.open(path, "r")` returned nil for the
permission failure, `load_config()` classified that as “not found,” and startup
selected defaults. It then called the default writer without checking its result;
on a writable parent, staged rename could replace the unreadable existing file.
Callbacks subsequently exposed default PersonalInfo behavior instead of the
user's committed values.

**Root cause and silence.** A nil file handle collapsed absence, permission
denial and other open failures into one state. Read/close results and default
publication were not exact commit boundaries. None of those failures had to
raise, so startup could log the benign missing-file path, continue normally and
turn a recoverable access problem into silent data loss plus missing output.

**Implemented fix.** `load_config()` protects `io.open` and authorizes defaults
only when the returned OS error code is exactly `ENOENT` (`2`). Every other
open failure returns nil and rolls startup back without touching the file.
Successful open is insufficient: read must return a string and close must return
literal `true`. For true absence, the staged default save must itself return
literal `true` before state initialization or either keyboard callback is
registered. Failure details remain withheld from logs.

**Regression test.** The first new case stubs an existing read as permission
failure (`13`) with a writable parent, then asserts exact `false`, zero callback
registrations, zero rename attempts, unchanged sentinel bytes and no private
failure text in logs. The second stubs exact `ENOENT` but refuses the staged
default write, then asserts exact `false`, zero callbacks and no committed file.
In the red phase the four-test module reported `2 passed / 2 failed`; after the
fix, direct execution of
`tests/unit/modules/dynamic_hotstrings/test_personal_info_save_transaction.lua`
reported `4 passed / 0 failed` (`4/4`).

### `HS-H-17` — Unknown filesystem state authorized creation over user-owned configuration

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/file_system.lua:127-184,316-477,588-670`;
`infra/preferences.lua:431-452`; `modules/hotstrings/hotstrings_config.lua:120-143`;
`platform/remap/config.lua:60-77`; `modules/keylogger/log_manager.lua:248-309,1328-1349`;
`ui/metrics_apps/init.lua:127-160`; `init.lua:211-215`.

**Reproduction.** Keep an existing `config.toml`, personal-hotstrings file,
`config_karabiner.toml`, `device.json`, personal-shortcuts file or app-category
file, then make the final pathname unreadable, replace it with a directory, or
make it a dangling link while its parent remains writable. Start the driver or
invoke the corresponding editor. Before the fix, a nil read could be classified
as first launch: preferences/defaults or an empty category/hotstring candidate
were then eligible for publication. For keylogger identity, the same ambiguity
generated a second UUID and could split one Mac's metrics between device trees.

**Root cause and silence.** Lua's file APIs report ordinary lookup failures as
nil values; several consumers treated that nil as `ENOENT`, while local errno
checks could not prove ownership of a path containing a link, a non-directory
prefix, or an uninspectable final entry. No exception was required, so the UI or
boot path could continue with an empty table and later advertise a normal save.

**Implemented fix.** `FileSystem.read_with_status()` now walks components with
lstat-style observations and authorizes `absent` only after a successful parent
listing excludes the final basename. Dangling links, directories, missing
prefixes, identity-changing reads and inspection failures are `error`.
`create_if_absent()` publishes through a create-only hard link and treats a
readable concurrent winner as `exists`; it never replaces that winner. Every
late consumer now branches on `ok`/`absent`/`error`: preferences may use safe
in-memory defaults for the session but cannot factory-save over a corrupt path,
while editors and first-use creators withhold publication. Root `init.lua`
returns before logger relocation, input hooks or remap activation when
`paths.toml` ownership is not established. Fresh device identity becomes live
only after `device.json` commits.

**Fix commits.** `42d673915`, `94b1c19cc`, `bae6036d4`, `16ccc611f`,
`ce407718a`, `82425349d`, `b50cc6dd9`, `2fda549ca`, `246ecb115`,
`314fd0ee5` and `3f7a6a1c5` close the sibling sites rather than only the first
reported loader.

**Regression tests.** `tests/unit/adapters/test_file_system_atomic_write.lua:131-364`
distinguishes genuine absence from dangling link, directory, EACCES-style
inspection failure and missing prefix, rejects a file replaced after read, and
asserts a create-only loser preserves the foreign winner byte-for-byte.
`test_preferences_corrupt_not_absent.lua:96-254` proves unreadable/read-failed/
close-failed/corrupt preferences never become `absent` or trigger factory save.
`test_hotstring_editor_unreadable_source.lua:94-287`,
`test_personal_shortcuts_file_ownership.lua:80-132`,
`test_metrics_apps_categories_transaction.lua:136-238` and
`test_device_identity_fail_closed.lua:325-359` assert the appropriate zero
writer, UI or runtime side effect at each unsafe boundary and exact publication
before first use.
`tests/meta/test_config_paths_boot_fail_fast.lua:14-31` guards the root return
before the first config-path consumer.

### `HS-H-18` — Lexical path collapse and stale source snapshots could redirect or overwrite a transaction

**Status:** Partially fixed; non-cooperating-writer CAS remains open.
**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/file_system.lua:187-313,402-477,672-833`;
`_shared/lua/toml_codec/writer.lua:52-108,200-249,427-499`.

**Reproduction.** Create `request/link -> target/subdir`, then read, create or
write `request/link/../config.toml`. POSIX resolves the link first and applies
`..` to its target, whereas the old lexical normalization could inspect or write
`request/config.toml`. Put foreign bytes at that lexically collapsed pathname to
make the wrong-file overwrite visible. Separately, change the destination link
or source bytes after the candidate is staged but before rename. The prior
writer could publish a stale edit over the other writer or report success after
the path no longer denoted the object it had validated.

**Root cause and silence.** Path components were normalized before kernel-order
symlink resolution, and an atomic rename was mistaken for a compare-and-swap.
Atomicity prevents torn bytes but does not establish that the destination,
symlink chain or source snapshot is still the one the user edited.

**Implemented fix (bounded).** Component order is preserved until each preceding symlink
is resolved; only the substituted target is normalized. Reads revalidate both
the observed link chain and final regular-file identity after close. Writes use
a private same-directory staging area, revalidate links before and after
publication, and accept an optional `{status, content}` precondition checked
after staging and immediately before rename. Shared TOML batch edits carry that
snapshot through the macOS adapter and require literal success for write, close
and rename. A retarget/refusal preserves the last committed bytes and, when
ownership is uncertain, preserves the staging sidecar rather than unlinking a
pathname that may now belong to another process.

**2026-08-13 adversarial correction.** The precondition is a last-moment check,
not an atomic compare-and-swap. A writer that does not participate in an
Ergopti-owned serialization protocol can publish after that read and before
`os.rename`, and its complete successor is then overwritten. Darwin's public
`RENAME_SWAP` exchanges names atomically but takes no expected inode/hash, so it
cannot close this condition. The four-day-old detached CAS prototype was
discarded: beyond preserving the same fundamental TOCTOU, it temporarily
removed the live pathname and could overwrite a foreign recovery sidecar. A
strong repair requires a single transaction authority or an explicitly
cooperative writer protocol plus native multi-process/APFS validation; it is
not honestly implementable as another Lua rename sequence.
Primary references: Apple's open-source Darwin [`rename(2)` manual](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2)
and [Secure Coding Guide on TOCTOU](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html).

**2026-08-13 bounded follow-up.** The smaller useful part was completed without
the rejected recovery protocol. `FileSystem.write()` and
`write_if_unchanged()` and `create_if_absent()` now take the same stable adjacent
non-blocking `hs.fs.lock` before staging, comparison and publication. That closes
the gap among cooperating Ergopti writers, including create-only bootstrap and
unconditional reset, while contention fails visibly and no stale lock is
reclaimed: Darwin releases the process-associated `fcntl` lock on process death
and the empty lock inode stays in place. Behavioral tests inject a second
conditional writer, an unconditional sibling and a create-only sibling precisely
inside the former compare/publication gaps, assert zero losing publications,
verify lock-before-read-before-release ordering, and prove a rename failure does
not strand the next writer. The non-cooperating-writer and native crash/APFS
limits above remain.

**Fix commits.** `46bc59b9f`, `ce407718a`, `fa5becaff`, `3cb2c4a23` and
`a21930037` establish the transaction from codec through platform pathname.

**Regression tests.** `tests/unit/adapters/test_file_system_atomic_write.lua:177-271`
drives real `link/../file` read and create-only publication and asserts the
kernel destination changes while the lexical foreign file does not. Its
`301-364`, `382-435`, `620-666` and `703-829` cases reject final-identity
replacement, a concurrent creator, source-byte change and symlink retargeting.
`tests/unit/lib/test_toml_writer_transaction.lua` injects returned write/close/
rename failures and a changed batch source, asserting no replacement or success;
`tests/meta/test_toml_writer_atomic.lua` and `test_no_sync_toml_formatter.lua`
enumerate the writer class and keep the synchronous cosmetic formatter out of
the save path.

### `HS-H-19` — Remap setters and enablement could diverge from their durable Karabiner state

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `platform/remap/config.lua:60-77,507-576`;
`platform/remap/init.lua:2801-2882,3009-3047,3316-3350`.

**Reproduction.** Start with an unreadable or malformed
`config_karabiner.toml`, then click a tap/hold, combo or timeout setter. The old
load path fell back to defaults and the next setter could overwrite the still
recoverable file. In a second path, make config publication return false after
the setter mutates `_state`; the menu/runtime used the candidate although reload
restored the old bytes. For enablement, let the lease reach READY and then make
the `enabled=true` preference save fail: without a transaction the remap could
remain active while the menu/disk said disabled.

**Root cause and silence.** Load status, decoded ownership, live table mutation,
file publication and token activation were independent acknowledgements.
`pcall` success and a decoded fallback table were treated as sufficient even
when the writer returned false. The first hardening draft also used consecutive
`if` branches, so a valid `ok` snapshot fell through to the refusal branch; that
would have turned every ordinary setter into a silent no-op.

**Implemented fix.** The config loader preserves `absent`, `read_error` and
`parse_error`. Every setter mutates a detached deep candidate, revalidates a
successfully decoded source snapshot through `FileSystem.write`, and publishes
the candidate into `_state` only after exact true. Only the explicit
reset-to-defaults action may replace corrupt TOML. Enablement remains false
until READY plus durable preference commit; a failed commit revokes the exact
prepared/live lease and settles callbacks only after STOPPED/fallback fencing.
The valid-source branch was independently corrected so normal existing config
remains writable.

**Fix commits.** `bae6036d4` preserves unsafe remap input; `efce5dd4b` adds the
candidate/config/lease transaction; `f7f74a640` repairs and guards the valid
source control path found during adversarial integration.

**Regression tests.** `tests/unit/platform/remap/test_config_corrupt_toml.lua:46-163`
separates absent, unreadable and parse-error states.
`test_config_corrupt_toml_write_guard.lua:113-307` asserts corrupt/unreadable
bytes remain exact, no staging occurs for unsafe input, returned write failure
rejects the save, valid existing and absent sources still commit, and only reset
bypasses corruption. `test_set_enabled_lease_transaction.lua:428-529` asserts
state/disk remain false before READY, every pre-READY or persistence failure
revokes its exact token without touching stock Karabiner, and failure is not
published until fencing completes.

### `HS-H-20` — Rejected menu preference saves left live runtime and UI on an uncommitted value

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `infra/preferences.lua:455-561`;
`ui/menu/preferences_transaction.lua:49-144`;
`ui/menu/init.lua:334-347,592-609,700-724`;
`ui/menu/menu_state.lua:151-445`; `modules/llm/init.lua:437-459`.

**Reproduction.** Start with `update_channel=dev`, click the stable channel as
the first menu action after boot, and make the atomic config writer return false.
Before the fix, the callback changed `state`, then restarted updater work and
refreshed the menu even though the next reload restored `dev`. The same ordering
existed across LLM backend/profile/model/trigger controls, keylogger encryption,
gesture registries, shortcut hotkeys, metrics hotkeys and global enable/disable.
A rejected profile could also leave a deferred same-backend warmup armed, and a
rollback from enabled keylogger state could leave its old deferred start timer
able to fire after the state had returned to disabled. A late sibling defect
also let a runtime setter throw during rollback while `sync_state_to_modules()`
still returned success, so the transaction could invoke its success-only
`on_rollback` hook with one represented runtime left stale.

**Root cause and silence.** `save_prefs()` was used as a best-effort side effect;
many callers ignored its return or wrapped it only in `pcall`. Memory, module
runtimes, `hs.settings`, hotkeys, deferred work, menu cache and `config.toml`
therefore had no common commit owner. The first click was especially exposed
because no previous successful save had seeded a rollback snapshot.

**Implemented fix.** Boot seeds detached committed state and complete preference
snapshots. The central transaction accepts only literal `true`; on false, nil or
throw it restores shared tables in place, re-synchronizes represented runtime
owners, restores LLM/global/profile hotkeys and withholds cache invalidation,
notifications and subsequent external work. Commit replaces both snapshots only
after atomic publication. Deferred keylogger starts and LLM profile warmups carry
generations, so rollback invalidates already queued work. Config-backed gesture
and script-control bindings enter the candidate before save; irreversible
Karabiner/`hs.settings` clearing occurs only after commit. The canonical
hotstring override writer is checked directly and no redundant `config.toml`
save can masquerade as its success. Runtime synchronization now treats a nil
setter return as normal but records every thrown setter and returns false; a
failed restoration therefore remains a loud failed rollback and cannot invoke
the success-only rollback hook.

**Fix commits.** `b553e4ed9` establishes exact preference publication; the
whole caller/runtime rollback and sibling-damage repair is `c157ba258`;
`3d02fe901` makes contained runtime-setter exceptions part of the transaction's
result instead of merely logging them.

**Regression tests.** `tests/unit/ui/test_preferences_save_transaction.lua:55-233`
drives false, nil and throw, then a real first-click About callback; it asserts
the boot value and retained nested identities are restored, updater/menu effects
remain zero, and keylogger cipher plus gesture-owned registries receive the
committed values. `tests/meta/test_menu_preference_calls_fail_closed.lua:13-47`
enumerates at least 100 `save_prefs` call sites, forbids pcall-only saves,
requires every site to gate on exact success, and requires core backend identity
restoration before warmup-capable keymap setters. `test_menu_state_group_sync.lua:69-122`
proves rollback invalidates a queued keylogger start;
`tests/unit/modules/llm/test_init.lua:304-360` rejects stale profile warmup;
`tests/unit/ui/menu/test_hotstrings_override_failure_gate.lua:12-68` asserts a
failed canonical override write causes zero keymap, redundant save or UI update.
The final two cases in `test_preferences_save_transaction.lua` inject a nil-
returning setter and a throwing setter, then inject a throwing setter during a
rejected-save rollback; they assert respectively `true`, `false`, zero
`on_rollback` calls and the visible failed-rollback diagnostic.

### `HS-H-21` — A pending model callback survived a sibling backend switch

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3.
**Locations:** `ui/menu/menu_llm/model_switcher.lua:259-301,421-486`.

**Reproduction.** Enable LLM on the MLX backend and choose a new model, leaving
its asynchronous requirements check pending; that action locks predictions.
Before the callback returns, use the sibling backend menu to select the API or
Ollama backend without selecting another model. Now deliver the old MLX success
callback. Before the fix it passed the model-request token check, published the
MLX candidate into the newly selected backend's model/state/config and updated
the menu. If discarded incompletely, the abandoned MLX action could instead
leave predictions locked with no later model request available to unlock them.

**Root cause and silence.** The completion captured only `req_token`. That token
changes when another model request supersedes it, but a backend selection is a
separate producer and does not increment it. The callback ran later from the
requirements subsystem, so no synchronous menu exception exposed the cross-owner
write; each local action looked valid in isolation.

**Implemented fix.** Each requirements request now captures both its request
token and exact backend identity. Success and failure callbacks derive a stale
reason before any state, core-model, persistence or UI mutation. A request-token
replacement discards the old callback while leaving the newer request's lock
ownership intact; a backend change additionally invokes the captured stale
cleanup to release the abandoned MLX prediction lock.

**Fix commit.** `3e50bb392` adds the two-dimensional ownership guard.

**Regression test.** `tests/unit/ui/menu/menu_llm/test_model_switcher_backend_guard.lua:12-92`
captures the real requirements completion, changes `state.llm_backend` from MLX
to API without issuing another model request, then fires the callback. It asserts
the global and MLX model remain old, core model setters/save/menu update remain
at zero, and prediction states are exactly `{false, true}`. The neighboring
profile-decision regression was converted from a fragile source-window check to
real accept/refuse callback behavior in `a50c9d55a` so the exact-save guard cannot
create a false red merely by moving lines.

### `HS-H-22` — Enabling LLM could start an unowned backend or publish a backend that failed setup

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `ui/menu/menu_llm/init.lua:842-952`.

**Reproduction.** With LLM disabled, select Ollama, click Enable, and make the
preference writer return false. Before the first fix, dependency setup ran before
the rejected preference save, leaving backend work alive while the durable and
rolled-back UI state said disabled. The MLX path was worse: its asynchronous
bootstrap started before the enable was even attempted. In a second concrete
sequence, let the MLX enable commit, then have bootstrap report failure (or
callback twice, callback and then throw, or finish after a backend switch). The
old flow had no single owner that could compensate the committed enable, reject
the stale completion, or prevent duplicate requirements/startup effects.

**Root cause and silence.** Persistence, keymap enablement, dependency bootstrap,
requirements dispatch and success UI were separate side effects around a boolean
toggle. The async MLX callback had neither a generation/backend fence nor an
exactly-once settlement bit, and direct backend/requirements exceptions crossed
callback boundaries without a compensating transaction. A setup process could
therefore survive a false-return save without any Lua exception at the click
site; later callback failures appeared as backend problems rather than an
uncommitted ownership violation.

**Implemented fix.** Activation now applies the runtime candidate and commits
`llm_enabled=true` before any backend process starts. The action captures an
activation generation and backend identity, settles once, contains direct
throws, and delays menu/notification success until setup and requirements
dispatch succeed. A post-commit setup failure attempts a durable compensating
disable; if that save itself fails, the central preference transaction restores
the last durable enabled state and no false success is announced. Disabling uses
the same exact commit gate.

**Fix commits.** `c6e69e19b` first moves toggle-owned dependency setup behind
the preference commit; `412929aa8` closes the outer MLX bootstrap path and
completes the async ownership, exactly-once and compensation
transaction. `b55d64e72` adds sibling behavioral spies for backend panels,
external binding teardown and rollback-owned runtime state.

**Regression test.** `tests/unit/ui/menu/menu_llm/test_llm_activation_save_gate.lua:203-329`
drives rejected Ollama and MLX saves, failed and uncommittable compensation,
sibling backend replacement, direct bootstrap/requirements throws, a double
success callback and callback-then-throw. It asserts no pre-commit bootstrap,
requirements, notification or menu update; exact `{true,false}` runtime
compensation; no stale mutation; and one settlement only. The sibling tests
`test_backend_panel_save_gate.lua`, `test_disable_all_external_save_gate.lua`
and `test_preferences_runtime_restore_behavior.lua` assert rejected writes leave
backend resources, external bindings and secondary display/URL/editor state on
the committed value.

### `HS-H-23` — A same-request streaming repaint could undo physical tooltip navigation

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `ui/tooltip/tooltip_llm.lua:445-475,1191-1199,1267-1320,1397-1403`;
`modules/llm/streaming_handler.lua:196-231,350-353,475-478,543-546,573-625`.

**Reproduction.** Display two predictions for request A, press Down so row two
is selected, then deliver another token frame for request A whose producer still
carries row one. Press Enter before the deferred canvas repaint drains. The old
path treated the frame as a fresh interaction, restored row one and reset
navigation engagement, so Enter could accept the wrong row or pass through even
though row two was still the user's selected action.

**Root cause and silence.** The streaming producer and the physical-navigation
consumer both wrote the cursor. `show_predictions()` advanced the UI generation
and trusted the producer index on every token frame, although token frames are
not new user sessions. No callback threw: the race produced internally valid but
stale state and therefore no file-log error.

**Implemented fix.** Every streaming frame carries its exact fetch/session ID.
Only a new session resets engagement or advances the UI generation; a repaint
for the same session preserves and clamps the tooltip-owned cursor. Navigation
commits its O(1) logical state synchronously before deferring AX/canvas work.

**Regression test.** `tests/unit/ui/test_tooltip_watcher_reuse.lua:1475-1513`
selects row two, injects a stale row-one repaint for the same request, and asserts
that Enter accepts `{2}` exactly once; request B must reset engagement. The
ordering siblings at `1515-1605` assert immediate Down→Enter, accepted-action
ownership across a later arrow/frame, and rapid-arrow render coalescing.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-24` — Selecting “No Model” could leave a live inference identity

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `ui/menu/menu_llm/model_switcher.lua:498-535`;
`modules/llm/api_remote.lua:220-286`; `modules/llm/prediction_engine.lua:286-302,775-779`.

**Reproduction.** Configure two remote entries, select the first, then choose No
Model and type enough context to request a prediction. A sibling sequence is a
ready MLX backend followed by No Model and a new prediction check. Before the
fix, the empty selection could fall back to the first remote entry or leave the
old engine model active, allowing warmup/fetch/UI despite the menu promising
that no model was selected.

**Root cause and silence.** No Model was represented as display/menu state rather
than a committed runtime identity. Remote resolution treated an empty/unknown ID
as “use the first entry”, and readiness gates did not independently require a
non-empty model. Every call could succeed normally, so no Lua exception exposed
the semantic mismatch.

**Implemented fix.** `disable_model()` invalidates pending requirements, clears
both runtime model setters, then persists the empty identity transactionally and
rolls back both sides on refusal. Remote lookup returns nil for empty or unknown
IDs, and the prediction engine neither warms nor fetches without a non-empty
model.

**Regression test.** `tests/unit/modules/llm/test_api_remote_identity_generation.lua:39-57`
asserts empty identity issues zero warmup requests.
`tests/unit/modules/llm/test_prediction_engine_reset.lua:261-281` asserts the
empty model resets without warmup, while
`tests/unit/modules/llm/test_prediction_engine.lua:465-496` keeps a ready MLX
backend from rendering, fetching or warming with no model. Menu transaction and
pause siblings are exercised by `test_model_switcher_backend_guard.lua`,
`test_models_selector_pause_gate.lua` and `test_api_panel_runtime_identity.lua`.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-25` — Remote callbacks could mutate a replacement API entry

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `modules/llm/api_remote.lua:184-228,301-312,559-569,615-625,659-715,845-905`.

**Reproduction.** Select remote entry A and start its health probe or inference.
Before its HTTP callback returns, select entry B or No Model, then deliver A's
response. The old callback could mark B ready, publish A's prediction into B's
session, or report A's authentication failure against the current request.

**Root cause and silence.** HTTP request generation did not own the independently
mutable active-entry identity. Status/body values remained well-formed after the
selection change, so stale mutation followed ordinary success/failure control
flow and produced no exception.

**Implemented fix.** Entry-list and active-ID changes increment one identity
generation and clear readiness. Decrypt, warmup, availability and inference
callbacks capture both that generation and the exact entry object, and discard
themselves before any shared mutation when either no longer matches.

**Regression test.** `tests/unit/modules/llm/test_api_remote_identity_generation.lua:59-104`
captures A's real health and inference callbacks, selects B, then fires them. It
asserts B remains not ready and that neither inference success nor failure runs.
`tests/unit/ui/menu/menu_llm/test_api_panel_runtime_identity.lua:19-117` also
requires reset-before-change and aborts publication when reset fails.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-26` — Deferred LLM work could re-enable or warm a runtime disabled after scheduling

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `modules/llm/init.lua:439-468`;
`ui/menu/menu_llm/model_switcher.lua:430-450`;
`ui/menu/menu_llm/init.lua:318-329`.

**Reproduction.** While LLM is enabled, change profile so a zero-delay warmup is
queued, then disable LLM before the callback fires. Alternatively begin an MLX
model requirements check, disable or pause the runtime, then deliver success.
The old callbacks used the state captured at scheduling and could dispatch a
warmup or turn predictions back on after the newer user action.

**Root cause and silence.** The enable gate was checked at entry but not at the
later side-effect boundary. MLX's internal stop flag protected one backend path,
not the API/Ollama profile timer or model-switch unlock sibling. A late callback
successfully calling a valid API does not throw, so the stale enable was silent.

**Implemented fix.** Deferred profile warmup re-reads live runtime enablement and
backend/profile identity immediately before dispatch. Model-switch unlock uses
the injected live runtime gate and requires current durable enablement; menu
construction supplies the pause/enable-aware gate.

**Regression test.** `tests/unit/modules/llm/test_init.lua:231-242,331-356`
asserts disabled state schedules no warmup and that a timer classified while
enabled performs zero warmups after disable. The behavioral cases in
`tests/unit/ui/menu/menu_llm/test_model_switcher_backend_guard.lua:136-176`
deliver completion after disable/pause and assert the prediction-state sequence
never contains a stale `true`.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-27` — A failed streaming transport could publish parseable partial output as success

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `modules/llm/api_ollama.lua:771-804`;
`modules/llm/api_mlx_inference.lua:743-768`.

**Reproduction.** Start an Ollama or MLX stream, deliver one syntactically valid
prediction chunk, then make curl exit 28. The old completion path could flush and
parse the accumulated text and call success because output was non-empty, even
though the transport explicitly failed and the prediction was truncated.

**Root cause and silence.** Parser success was treated as transport success; the
exit code was checked too late or not made authoritative. Partial JSON/text can
be perfectly parseable, so neither the parser nor Lua raised an error.

**Implemented fix.** Completion relinquishes the exact task owner, then rejects
every non-zero exit before appending residual bytes or parsing. It publishes one
failure and no prediction. MLX exit 15 remains the explicit user-cancellation
terminal and intentionally invokes neither success nor failure.

**Regression test.** `tests/unit/modules/llm/test_api_ollama.lua:394-428` and
`tests/unit/modules/llm/test_api_mlx_stream_bound.lua:249-290` feed parseable
partial output followed by a non-zero completion and assert `successes == 0`,
`failures == 1`, and the active task slot is nil. The MLX cancellation control
keeps exit 15 distinct.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-28` — MLX startup failure stranded callers that joined the same readiness operation

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `ui/menu/menu_llm/models_manager_mlx_server.lua:71-80,145-171,272-327,687-775`.

**Reproduction.** Start MLX model A and, while its process is alive but not yet
ready, request the same model again. Then make the server stream callback throw,
the task exit non-zero, or readiness-task/timer construction fail. The old
success path knew how to drain joined callers, but failure released only the
primary continuation; the second caller's prediction lock remained forever.

**Root cause and silence.** Joined startup was modeled as a success-callback
queue rather than a set of two-terminal owners. Failure had no symmetric drain,
and exceptions inside native task callbacks otherwise terminate at the
Hammerspoon console boundary. The stranded caller produced no output and no
remaining callback to report why.

**Implemented fix.** Each waiter owns `on_success` and `on_cancel`.
`fail_server_start()` settles the primary and drains every joined cancellation
exactly once; async callback guards log tracebacks, and scheduler/task refusal
terminates the exact server owner before releasing callers.

**Regression test.** `tests/unit/ui/menu/menu_llm/test_mlx_server_readiness_is_shared.lua:124-266`
joins two callers, throws from the real stream callback, fires failure twice and
asserts zero successes, one cancellation per caller, a file-log error and a
stopped task. It separately rejects readiness-task construction and retry-timer
allocation and requires one cancellation plus server teardown.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-29` — Native clipboard refusal could consume the trigger without replacement and lose clipboard ownership

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/clipboard.lua:58-129`;
`modules/keymap/utils.lua:97-216,235-310`; `adapters/text_sender.lua:62-155,165-233`.

**Reproduction.** Put an image/RTF value on the clipboard, type a long hotstring,
and make `hs.pasteboard.setContents()` mutate the pasteboard but return `false`.
Before the fix, protected-call success was accepted as write success: the trigger
was deleted, Cmd+V/state/keylogger telemetry could commit, and restoration could
release ownership after `writeAllData(false)`. The user saw missing or stale text
and could permanently lose the original non-text clipboard. The same contract
error was reachable from direct text sends, wrap/transform actions, web search,
path/pixel copy and healthcheck copy.

**Root cause and silence.** `pcall` success was confused with the native method's
operational result, ownership was published after entering a mutate-then-refuse
boundary, and some paths captured text instead of every pasteboard type. Native
`false`/`nil` is ordinary control flow, so no exception reached the logger.

**Implemented fix.** Clipboard borrowers snapshot all UTI data, publish a
generation owner before mutation, require literal `true` from `setContents()` and
`writeAllData()` (while accepting `clearContents()`' documented void success),
arm a strongly retained restore owner before Cmd+V, and publish logical output
only after every prerequisite commits. Failed restoration retains the exact
snapshot and retries autonomously; a newer transaction cannot be released by an
older callback.

**Regression test.** `tests/unit/modules/keymap/test_clipboard_synthetic_telemetry.lua:167-223`
drives the real expander through mutate-then-false and asserts literal failure,
no consumed delete/Cmd+V, unchanged buffer, zero keylogger commit and exact
all-type restoration. `tests/unit/adapters/test_clipboard_native_result_contract.lua:21-50`
pins false/nil and void contracts; `test_text_sender_clipboard_serial.lua:128-167`
pins retained retry, timer refusal and bounded synchronous-callback behavior.
Sibling behavioral matrices cover wrap, transforms, search, path/pixel and
healthcheck copy refusal.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-30` — Pause/resume could join pre-pause text with unobserved edits

**Severity:** High. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `modules/keymap/init.lua:331-350,407-418`.

**Reproduction.** Type `ae`, pause, type physical `x` while the tap intentionally
passes everything through, resume, then type `u`. The old engine could retain
`ae` because it observed neither the paused edit nor cursor movement, producing
the impossible logical buffer `aeu` and firing/previewing a hotstring that no
longer matched the application text.

**Root cause and silence.** Pause disabled observation but did not sever text
ownership. The retained buffer and word-boundary bit were locally valid values,
so resumption raised no exception while silently describing a different screen.

**Implemented fix.** Both pause and resume call one context-discard function that
clears the keymap buffer, clears the preview-recovery owner and marks the cursor
as an unproven word boundary. The first post-resume physical terminator must
re-establish context.

**Regression test.** `tests/unit/modules/keymap/test_action_epoch_reconciliation.lua:397-415`
starts with buffer `ae`, drives real pause, an unconsumed physical `x`, resume and
`u`, then asserts an empty boundary at resume and that the final buffer contains
no `ae` prefix.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-31` — Async lifecycle failures could stay out of the file log or publish a keylogger with no event tap

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/process_lifecycle.lua:52-65,227-304`;
`adapters/keyboard_hook.lua`; `modules/keylogger/init.lua`.

**Reproduction.** Start in a normal non-secure application, activate a browser
password/private context, and make the optional browser-filter setup or canonical
context refresh throw. A discarded `pcall` could leave the old non-secure bit
live while the keyboard hook continued persisting keys. Independently, register
a throwing ProcessLifecycle activation subscriber before a healthy sibling and
fire the native watcher: the error could exist only in the Hammerspoon Console or
be discarded, making the file log and later subscriber state incomplete.
As the missed sibling, make the native keyboard tap refuse activation or make
`eventtap:isEnabled()` throw during keylogger startup. The former implementation
still set its local event-tap sentinel and returned `true`; every key could then
pass through without telemetry while the menu reported an enabled keylogger.

**Root cause and silence.** Callback containment was local and non-reporting, and
optional setup preceded the security-critical context commit. Native task/watcher
boundaries do not automatically route every exception to Ergopti's file logger;
the global timer wrapper also cannot make a discarded `pcall` result visible.
Keylogger startup additionally treated invoking `KeyboardHook.start()` as a
commit without proving the native tap was enabled, while `KeyboardHook.isRunning()`
let a native state-query exception escape.

**Implemented fix.** ProcessLifecycle invokes each subscriber independently
under `xpcall(debug.traceback)` and logs every failure while continuing healthy
siblings. Keylogger activation commits canonical context first; context failure
forces `is_secure_field=true`, optional browser setup cannot undo it, lifecycle
watcher startup must commit before the keyboard hook, and cold start remains
secure until initial foreground capture succeeds. The keyboard adapter now
contains native state-query errors and reports uncertain state as stopped.
Keylogger startup requires that exact live state before publishing success; a
refusal drives the normal teardown transaction, releases the application
watcher, stops partial producers and leaves the feature disabled for a clean
retry.

**Regression test.** `tests/unit/adapters/test_process_lifecycle_running_guard.lua:219-234`
requires a throwing subscriber to reach ERROR while its healthy sibling runs.
`tests/unit/modules/keylogger/test_activation_callback_fail_closed.lua:148-219`
injects optional/context failures and asserts refreshed or forced-secure state,
no pre-lifecycle eventtap, zero persistence before initial capture and clean
retry after start refusal. Its eventtap-commit case makes `isRunning()` return
false and asserts startup refusal plus teardown of the process watcher, partial
hook and persistence producer. `tests/unit/adapters/test_keyboard_hook_restart_clears_callbacks.lua`
makes `eventtap:isEnabled()` throw and asserts a contained, fail-closed `false`.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-32` — Raw `hs.task` consumers had three independent silent failure contracts

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/task_lifecycle.lua:35-126`; production raw-task owner
boundary `adapters/shell_runner.lua:242-274`.

**Reproduction.** At any former direct task site, make `hs.task.new()` return nil
or throw, make `task:start()` return false or throw, or throw from completion/
streaming after a nominal start. The historical sites could index nil, publish a
pin/in-flight latch for a process that never launched, or lose the callback error
to the Hammerspoon Console, leaving UI, predictions or cleanup permanently
pending.

**Root cause and silence.** Construction, launch commitment and asynchronous
callback execution are separate native contracts, but each caller implemented a
different subset. A one-site source assertion could remain green while a sibling
used raw `hs.task.new`; false start is not an exception, and callback throws occur
after the initiating action returned.

**Implemented fix.** `TaskLifecycle` centralizes nullable/throwing construction,
guarded completion and stream callbacks with traceback logging, and strict
truthy-start commitment. Callers still own their feature pin and rollback, but
must branch on the adapter result. `ShellRunner` remains the sole lower-level raw
owner with its independent equivalent contract.

**Regression test.** `tests/unit/adapters/test_task_lifecycle.lua:37-119`
behaviorally rejects nil/throw construction and false/throw start, preserves
successful multi-returns and proves both native callbacks log rather than escape.
`tests/unit/adapters/test_raw_task_start_contract.lua:78-156` dynamically walks
the production tree, requires at least 50 files and 20 adapter sites, rejects any
raw owner outside the two adapters, and requires a conditional start/rollback
branch at every consumer.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-33` — The shared gesture keystroke helper swallowed native dispatch refusal

**Severity:** High. **Confidence:** High. **Guarantees:** G1, G2.
**Locations:** `modules/gestures/actions.lua:73-87`.

**Reproduction.** Enable gestures, bind or invoke `mission_control` (the same
helper serves the other keyboard-backed gesture actions), then make
`SyntheticInput.emit_key_stroke()` return false or throw. The old nested `pcall`
discarded both status and result; `execute_single()` still recognized and owned
the gesture, but emitted no key and produced no file-log error.

**Root cause and silence.** `postKeyStroke()` was the single fan-out helper for
dozens of actions, but locally swallowed the exact native result. The outer
`Logger.pcall` around action dispatch could observe only errors that escaped the
helper, so both false and throw were converted into a clean-looking no-op.

**Implemented fix.** The helper executes under `xpcall(debug.traceback)`, requires
literal `true`, and raises one controlled error on false or throw. That error
reaches the existing logged action boundary without changing the dispatcher's
recognized-action ownership contract.

**Regression test.** `tests/unit/modules/gestures/test_actions.lua:377-396`
drives the real registered `mission_control` action with the shared emitter
returning false. It asserts the dispatcher still recognizes the configured
action and the central logger ring contains an ERROR with the exact synthetic
keystroke-refusal cause.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-H-34` — Logger sinks perform blocking console and filesystem work inside the keyDown eventtap

**Status:** Open. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G4. **Provenance:** code-derived and behaviorally reachable; native duration
is unmeasured. **Locations:** `modules/keymap/init.lua:775-885,979-1244,1284-1394`;
`modules/keymap/expander.lua:83-190,711-720,870-879,984`;
`infra/hotpath_profiler.lua:83-87`; `infra/logger.lua:554-558,574-729,748-775`.

**Reproduction.** Set the reachable runtime log level to `DEBUG`, start the
driver, and fire any static auto-expansion. The real `hs.eventtap` callback
enters `onKeyDown()`, then `run_trigger_checks()`, then
`Expander.perform_text_replacement()`. Before the callback returns, its
`Logger.trace`, `Logger.done` and mapping-specific `Logger.debug` calls reach
`_driver_sink()`, which calls the console, `_ensure_log_file()`, `fh:write()` and
the topical fan-out synchronously. Forty accepted, non-deduplicated DEBUG
records additionally force `fh:flush()` by construction. On any slow key,
`HotPath.log_if_slow()` emits a WARNING before return; a callback error also
opens, writes and closes the errors-only mirror and invokes the notification
handler in the same stack. Injecting a blocking `io.open`/`write`/`flush` or
console spy at these boundaries makes the callback wait, without changing this
sequence. No production milliseconds are claimed.

**Root cause and silence.** The prior optimization equated “do not flush every
DEBUG line” with “no blocking I/O in the eventtap.” Buffering only removes some
flushes: every accepted line still executes console output, date/path checks and
`fh:write`, while the fortieth DEBUG and every WARNING/ERROR flush synchronously.
The sink wraps most failures in `pcall`, so a refused write can also disappear
without a file diagnostic. If the main-thread stall crosses Quartz's deadline,
macOS disables the tap and the watchdog can only repair the resulting outage
after the fact.

**Proposed fix.** Publish immutable, privacy-filtered records into a bounded
in-memory mailbox whose producer performs no clock, formatting, console,
notification or filesystem operation beyond data already computed by the
logger core. Start one persistent out-of-process writer before any input tap and
fail closed if it cannot accept work. Send one ordered batch at a time, retain it
until an explicit ACK, retry a refused delivery without losing the head record,
and keep WARNING/ERROR capacity independent from DEBUG overflow accounting.
The worker—not an `hs.timer` callback—must own rotation, topical/error fan-out,
open/write/flush/close and purge. Console/notification delivery must likewise
leave the eventtap stack. A zero-delay timer alone is not the fix: it returns the
tap sooner but still executes blocking work on Hammerspoon's main run loop.

**Required regression test.** Add
`tests/unit/modules/keymap/test_eventtap_logger_side_effects.lua`. Drive the real
registered keyDown callback through one successful expansion and one injected
error while spies own `io.open`, file `write`/`flush`, console output and the
error notification. The exact pre-return assertions are zero calls to every
side-effect spy and an ordered mailbox containing the expected redacted records.
Then drive the real worker boundary: before ACK the head record remains owned;
after a refused send it is retried exactly once; after ACK the unified, topical
and errors-only outputs contain the records in order. The test must fail against
this baseline and pass only when the harmful operations—not merely their
scheduling call—leave the callback.

### `HS-H-35` — Timer migrations published uncommitted native candidates as live feature timers

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`adapters/timer_scheduler.lua:86-224`; representative consumers
`modules/shortcuts/script_control.lua:1141-1265`,
`modules/llm/warmup_controller.lua:124-237`,
`modules/keymap/terminator_replay.lua:115-379`,
`modules/updater/init.lua:383-472`.

**Reproduction.** Make `hs.timer.new(...):start()` activate its native producer
and then throw; make the exact `stop()` return false. The scheduler must return
the retained candidate with `committed == false`. Before this fix, sibling
callers tested only the handle's truthiness, published their feature as armed,
and either accepted an inert timer or lost the only capability able to stop the
partially active producer. A stale callback could then mutate a replacement
generation, or an output path could remain permanently waiting for a timer that
never committed.

**Root cause and silence.** The earlier lifecycle repair changed the adapter to
the two-result `(handle, committed)` contract, but the guarantee was applied at
the adapter site rather than followed through its caller class. A retained
cleanup handle is intentionally truthy. Most async callback throws are owned by
Hammerspoon, so a missing local traceback boundary made the resulting no-op or
orphan visible only as absent output.

**Fix.** The enumerated script-control, updater, warmup, terminator-replay and
system-action consumers capture `committed` and refuse to publish the timer as
usable. The scheduler retains native cleanup debt; these callers retain the
feature identity needed to block conflicting successors. This did **not** prove
the whole recurring-owner class: the later sweep found UI restore, KC, WPM,
Metrics, Healthcheck and root-keylogger siblings (`HS-H-43`, `HS-H-48`–`HS-H-52`)
and exposed the inventory false green (`HS-M-22`).

**Regression tests.** `tests/unit/adapters/test_timer_scheduler.lua` drives
activate-then-throw, pre-commit delivery and stop refusal. Causal sibling tests
include `test_script_control_start_transaction.lua`,
`test_updater_timer_transaction.lua`, `test_warmup_timer_transaction.lua`,
`test_terminator_replay_gate.lua` and `test_system_eventtap_transaction.lua`.
Those behavioral tests assert that the candidate is not published as active and
that exact refused cleanup remains retryable. The structural
`test_recurring_timer_single_owner.lua` inventories raw owners only; it is not
behavioral proof of any caller (`HS-M-22`).

### `HS-H-36` — Root boot could publish a half-started input control plane

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`init.lua:740-768`; `infra/startup_transaction.lua:78-134`;
`modules/shortcuts/init.lua:116-149`.

**Reproduction.** Let gestures commit, then make `shortcuts.start()` or the
script-control eventtap return false or throw after a partial native start. The
former boot sequence continued and could log readiness with only some keyboard
owners alive; the panic/pause path or configurable shortcuts could be absent
while another layer still consumed input.

**Root cause and silence.** Independent best-effort `pcall` calls proved only
that Lua returned, not that required native ownership committed. No coordinator
remembered which predecessors needed reverse rollback. A false return raised no
exception and therefore produced an especially quiet half-start.

**Fix.** Required input owners now run through one ordered startup transaction.
Each exact commit is recorded; the first refusal rolls predecessors back in
reverse and prevents boot publication. Optional steps are declared explicitly.

**Regression test.** `tests/unit/infra/test_startup_transaction.lua` injects
false, throw and rollback refusal and asserts exact reverse order. Because the
native root file cannot be loaded headlessly,
`tests/meta/test_init_prestart_transaction.lua` connects the real gesture,
shortcut and script-control calls to that tested coordinator and pins the early
panic-button ordering.

### `HS-H-37` — Keylogger and remap watchers overwrote one setter-only input-source callback

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived from the Hammerspoon setter contract and
behaviorally reproduced. **Locations:** `adapters/input_source_broker.lua:26-125`;
`modules/keylogger/init.lua:1621-1633`; `platform/remap/watchers.lua:815-834`.

**Reproduction.** Enable keylogger and Ergopti Karabiner integration, then let
both initialize. Each formerly called `hs.keycodes.inputSourceChanged(fn)` as if
it subscribed. The second call replaced the first. Switch keyboard layout: one
subsystem refreshes, while the evicted sibling silently misses its layout or
context update.

**Root cause and silence.** `inputSourceChanged` owns one process-wide callback;
it is not a multi-subscriber watcher. Setter replacement succeeds normally, so
there is no exception or native error to log.

**Fix.** `InputSourceBroker` is the sole native setter and multiplexes named
subscribers from a mutation-safe snapshot under independent traceback guards.
Last-subscriber removal unsets the slot; a refused unset remains retryable debt.

**Regression tests.** `tests/unit/adapters/test_input_source_broker.lua` drives
replacement, callback isolation, install-after-mutation failure and unset retry.
`tests/meta/test_input_source_single_native_owner.lua` inventories the entire
production tree; `test_input_source_broker_required.lua` asserts remap startup
fails closed when broker ownership cannot commit.

### `HS-H-38` — Keylogger ingest ownership survived failed initialization and database teardown

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/keylogger/log_manager.lua:98-105,1260-1315,1595-1692`;
`modules/keylogger/init.lua:1601-1858`.

**Reproduction.** Allow the ingest timer/database to be acquired, throw from a
later initialization dependency, then make the timer's native stop refuse.
Before the repair, failed init could look unpublished while the producer still
ran; a queued tick could touch the closed database, and retrying enablement could
create a second producer.

**Root cause and silence.** Initialization state was published piecemeal and
teardown cleared references after protected calls rather than exact operational
success. The ingest loop treats a missing database as “nothing to do,” turning
the failure into silent loss rather than a useful traceback.

**Fix.** LogManager and the enclosing keylogger now publish every cleanup
obligation before acquisition, commit initialization only after all owners are
live, revoke callbacks before close, retain stop debt, and refuse a successor
until cleanup settles.

**Regression test.** `tests/unit/modules/keylogger/test_log_manager_init_transaction.lua`
injects a post-acquisition initialization throw, queued stale callbacks and
explicit stop refusal. It asserts no published init, no callback against the
closed DB, exact retained ownership and one clean producer after retry.

### `HS-H-39` — A non-throwing keylogger append refusal discarded the only detached typing snapshot

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G2,
G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/keylogger/rotation.lua:179-231`;
`modules/keylogger/log_manager.lua:360-453,553-598`.

**Reproduction.** Buffer a typing run, make `file:write()` return
`nil, "ENOSPC"` without throwing, then turn Metrics off or quit. The old append
path ignored the return and used the same nil result for success and failure;
the deferred drain advanced after the non-throwing call even though CoreState
had already detached its only snapshot. The run was permanently lost and a
later record could overtake it.

**Root cause and silence.** `pcall == true` was treated as filesystem commit.
Lua file methods report many I/O failures as values, not exceptions, so the
logger saw no throw and the FIFO had no exact acceptance result to retain.

**Fix.** Rotation requires the documented success of unbuffered configuration
and write. LogManager swaps the hot buffer into an ordered in-memory FIFO and
does not advance its head until strict append acceptance.

**Regression test.** `tests/unit/modules/keylogger/test_log_manager_append_transaction.lua`
injects `nil, ENOSPC`, later-entry ordering and retry. Its exact assertions keep
the detached head, append it once after recovery, and forbid the later entry
from overtaking it.

### `HS-H-40` — Gesture primer and wake owners could fail while gesture startup reported success

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/gestures/init.lua:617-645,781-1036`.

**Reproduction.** On a touchdevice-capable host, make the physical-touch primer
eventtap start return false, or let the wake watcher activate and then throw.
The former lifecycle accepted the partial/missing owner and could report gesture
startup while no discovery or post-wake frame recovery would ever occur.

**Root cause and silence.** Primer, recurring health timer and wake watcher were
separate best-effort acquisitions. False native starts do not throw, and no
shared generation or cleanup-debt owner connected their handoff.

**Fix.** Both timer modes and native watchers use exact commit, rollback and
retryable teardown; every callback carries the lifecycle generation and global
pause gate. The kernel first-touch gate remains intentional—the fix owns the
primer, it does not pretend to bypass hardware dormancy.

**Regression test.** `tests/unit/modules/gestures/test_recurring_timer_transaction.lua`
drives primer false, wake start throw, partial recurring activation, refused
stop, retry and stale delivery, asserting no success publication and no callback
mutation outside its generation.

### `HS-H-41` — Shortcut lifecycle topology produced missing controls and resurrected disabled hotkeys

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** three behaviorally reproduced state/action cells.
**Locations:** `modules/shortcuts/init.lua:116-179`;
`ui/menu/menu_shortcuts.lua:352-389`; `ui/menu/menu_state.lua:423-428`;
`platform/remap/init.lua:2550-2667`.

**Reproduction.** (1) Cold boot with configurable shortcuts enabled: aggregate
start formerly bound only the base layer, so keyboard shortcuts appeared only
after the first pause/resume. (2) Toggle the Shortcuts menu off: whole-subsystem
stop killed AltGr+Enter/Backspace/Escape, although those lifecycle controls must
survive feature OFF. (3) While Shortcuts is disabled, change layout: unconditional
pause/resume rebound user hotkeys while the menu still displayed OFF.

**Root cause and silence.** Three owners—Bindings, KeyboardShortcuts and
ScriptControl—were treated as interchangeable by higher-level proxy methods.
Each local call could succeed while the aggregate topology violated the user's
enabled state.

**Fix.** Aggregate start commits Bindings plus KeyboardShortcuts transactionally;
ScriptControl remains a dedicated always-on lifecycle owner. Feature toggles and
layout rebinds operate on bindings only and preserve the committed disabled bit.

**Regression tests.** `test_start_starts_keyboard_shortcuts.lua`,
`test_feature_toggle_keeps_script_control.lua`,
`test_menu_state_keeps_script_control.lua`, and
`test_layout_rebind_preserves_disabled.lua` drive the three reproductions.
`test_start_transaction.lua` and `test_shortcuts_runtime_transaction.lua` add
partial-start rollback and exact menu-publication assertions.

### `HS-H-42` — HTTP requests were dispatched before their timeout capability committed

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G2,
G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`adapters/http_client.lua:109-340`; `modules/llm/api_mlx_inference.lua:259-334`.

**Reproduction.** Make the timeout timer return nil/false, or activate then throw
while exact stop refuses. The old POST/GET path still dispatched the request.
It could hang with no owned deadline, or a successor could reuse the logical
slot while the old timer remained natively active.

**Root cause and silence.** Timeout installation was a side effect after request
state publication rather than a precondition. Hammerspoon's async HTTP methods
normally return nil, which was also incorrectly used as the activity signal;
timer cleanup outcomes were swallowed.

**Fix.** The client commits a `TimerScheduler` deadline before network dispatch,
tracks request activity independently from the native return, generation-fences
all terminal paths, and blocks successors on exact cleanup debt. MLX's own hard
deadline applies the same pre-dispatch rule.

**Regression tests.** `tests/unit/adapters/test_http_client_timeout_transaction.lua`
drives constructor/start refusal, partial activation, response/timeout races and
terminal stop debt for POST and GET. `test_mlx_non_stream_timeout_transaction.lua`
asserts zero backend dispatch until MLX's hard deadline commits. The existing
superseded-response test covers a separate generation race and was not misused
as proof of timeout ownership.

### `HS-H-43` — UI restore and deferred reload could lose their only future execution opportunity

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`infra/ui_restore.lua:152-515`; `tests/unit/lib/test_ui_restore_defer_reentrancy.lua`;
`tests/unit/lib/test_ui_restore_timer_transaction.lua`.

**Reproduction.** First, leave a registered editor open and request a reload;
make timer construction/start throw, or make the scheduler's documented native
state probe show that activation did not commit. The old code parked the reload
callback, unconditionally reported no failure, and had no later event capable of
releasing it. Defensive doubles also cover explicit false returns, but native
`hs.timer:start()` is chainable and state is proved by `running()` (`HS-H-47`).
Second, persist an open UI across reload and
make `hs.timer.doAfter(0.5, ...)` return nil: `restore()` cleared the durable
restore record first and silently dropped the promised window. Third, let an
immediate reload callback call `defer_reload()` again while no UI is open. The
guard stored that second callback but armed neither a poller nor a one-shot, so
it was never invoked after the outer callback returned.

**Root cause and silence.** Timer construction/start was treated as infallible,
the module retained no exact cleanup capability or generation, and the
re-entrancy flag prevented double execution without creating a subsequent
execution opportunity. Hammerspoon owns these callbacks and reports their
throws only to its Console; false/nil activation does not throw at all.

**Fix.** Delayed restore, polling, and re-entrant dispatch now use the exact
`TimerScheduler` `(handle, committed)` contract. Candidates are published before
activation, callbacks validate identity plus generation, refused stops remain
retryable, and `M.stop()` fences all three owner sets. A missing restore timer
falls forward to one protected immediate reopen; a missing reload poller falls
forward to the already-requested recovery reload rather than parking it.

**Regression test.** `test_ui_restore_timer_transaction.lua` injects nil,
throwing and activate-then-fail acquisitions, stop refusal, stale delivery,
delayed-restore shutdown and a truly re-entrant reload. Exact assertions include
one later dispatch opportunity for the inner request, one reload total after a
stale callback, immediate reopen on timer loss, and retry of the same retained
native candidate. The older source-shape test is not counted as behavioral proof.

### `HS-H-44` — Keylogger startup accepted missing dependencies and partially active hardware watchers

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/keylogger/context_tracker.lua:585-614`;
`modules/keylogger/watchers.lua:543-706`;
`modules/keylogger/init.lua:1644-1662,1724-1737`.

**Reproduction.** Enable Metrics/keylogging while the Wi-Fi watcher starts and
the battery watcher returns false, or while the global audio callback setter
installs the callback and then throws. The old routine kept the earlier native
owners, continued through later sensors, logged “Hardware watchers started,”
and the root keylogger published enabled state. Independently, make either
`ContextTracker.init()` or `Watchers.init()` refuse its injected dependencies;
their caller ignored the result and continued toward the keyboard tap.

**Root cause and silence.** Required submodule initialization had no exact return
contract. Hardware setup was a sequence of independent `pcall`s, with native
handles published only after some fallible setters and without reverse rollback.
Explicit false/nil returns therefore looked successful, while caught exceptions
were downgraded to an optional warning even though the runtime depended on the
missing context.

**Fix.** Both injected submodules return literal success only for the same exact
dependency set, and keylogger startup aborts on anything else. Hardware watcher
acquisition publishes every exact candidate before native start, marks the
process-wide audio callback before its mutating setter, commits the full group
only after every required owner is live, and rolls back in reverse while
retaining any refused cleanup capability. Native callbacks are generation- and
pause-gated inside logged traceback boundaries.

**Regression test.** `tests/unit/modules/keylogger/test_watchers_lifecycle_transaction.lua`
drives sibling start refusal, partial audio setter mutation, reverse rollback,
stop refusal and callback failure. Its exact assertions require no enabled group
after partial acquisition, inert stale callbacks, and retry of the original
handle. `test_activation_callback_fail_closed.lua` separately makes
`LogManager.init()`, `ContextTracker.init()` and `Watchers.init()` refuse and
asserts that no keyboard eventtap/native producer is acquired. The two tests are
both required because watcher rollback does not prove parent dependency
propagation, and vice versa.

### `HS-H-45` — Wake and unlock continuations could resurrect keylogger AX work after stop

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/keylogger/watchers.lua:303-541,670-706`.

**Reproduction.** Enable keylogging, deliver `systemDidWake` or
`screensDidUnlock`, then disable/pause the feature before the 50 ms callback
fires. The old raw `hs.timer.doAfter` was not retained by the hardware lifecycle;
after stop it required the context tracker and called
`capture_frontmost_app()`, recreating Accessibility work and state for a feature
the user had just turned off. Repeating wake/unlock events queued unbounded
sibling callbacks with no latest-generation rule.

**Root cause and silence.** The caffeinate watcher was stopped, but its spawned
continuations belonged to no owner. The callback checked only whether an app name
was absent, not whether its originating hardware generation was still committed.
Its internal `pcall` also swallowed any AX failure outside the file logger.

**Fix.** Wake/unlock refreshes are retained `TimerScheduler` one-shots in the
hardware watcher transaction. Each captures the committed generation and exact
handle, becomes inert before cleanup, survives stop refusal as debt, and is
cancelled/retried by `stop_hardware_watchers()`.

**Regression test.** `test_watchers_lifecycle_transaction.lua` schedules a wake
refresh, refuses its first exact cancellation, delivers the queued callback
after stop, and asserts zero context-tracker/AX calls. A second stop must cancel
the same handle; the committed control case must capture context exactly once.

### `HS-H-46` — Click-hold posted mouseDown before acquiring the taps that make release recoverable

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/gestures/actions_click.lua:1-735`;
`tests/unit/modules/gestures/test_actions_click_acquisition_transaction.lua`.

**Reproduction.** Trigger left- or right-click hold and make either the keyboard
release watcher or the drag/mouseUp eventtap constructor/start fail. The old
path posted the synthetic mouseDown and set its held flag first, then continued
after protected failures and even logged “HELD.” The target application could
remain in a drag/pressed state with no working physical mouseUp or key-release
tap. On the inverse path, make mouseUp construction/post or tap stop refuse;
the old cleanup cleared the flag/handle anyway, losing its only retry capability.

**Root cause and silence.** Visible button state, two eventtap acquisitions and
their release capabilities were separate best-effort side effects. `pcall`
suppressed constructor, start, post and stop failures; there was no exact native
identity, generation fence, or cleanup-debt state.

**Fix.** The keyboard and side-specific taps are constructed and proven enabled
as one transaction before mouseDown is posted or held state is published.
Failure rolls both candidates back, retaining any refused stop as inert debt.
Release constructs the complete mouseUp batch before fencing state, preserves a
failed post for retry, and rejects a successor until prior exact cleanup settles.
The physical mouseUp path no longer depends on an unowned raw zero-delay timer.

**Regression tests.** `test_actions_click_acquisition_transaction.lua` drives
constructor refusal, start false/throw, partial rollback debt, stale callbacks,
mouseDown refusal and release retry for both sides. Its decisive precondition is
`posted mouseDown count == 0` until both taps are proven active. The neighboring
`test_actions_click_mouseup_construction_failure.lua` asserts that a failed
release-event constructor leaves the hold recoverable rather than clearing it.

### `HS-H-47` — Chainable `hs.timer` returns were mistaken for proof of native running state

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** the official
[`hs.timer` API contract](https://www.hammerspoon.org/docs/hs.timer.html) was
re-derived, then behaviorally reproduced with a faithful native double.
**Locations:**
`adapters/timer_scheduler.lua:69-282`;
`tests/unit/adapters/test_timer_scheduler.lua`.

**Reproduction.** Make `hs.timer:start()` return its timer object while
`running()` remains false. The prior adapter published `(handle, true)`, so every
consumer believed its deadline/poller/retry existed although no callback could
fire. Conversely, make `stop()` return the same truthy object while `running()`
remains true. `cancel()` cleared the only handle and removed it from the live
registry even though the native producer remained active.

**Root cause and silence.** Hammerspoon documents `hs.timer:start()` and
`hs.timer:stop()` as chainable methods returning the timer object; their return
is not the state assertion. `hs.timer:running()` is the boolean state probe. The
adapter interpreted generic truthiness as commitment, and the shared test stub
made truthy return and state mutation inseparable, so it could not express this
failure. No exception is required.

**Fix.** After a truthy start the adapter requires observable `running() == true`
before publishing commitment. After stop it requires `running() == false` before
settling the handle; a mismatched/throwing probe leaves the exact timer retained
and callback-inert for retry. Narrow legacy test doubles without the native
probe remain compatible, but the causal tests use the documented surface.

**Regression test.** `test_timer_scheduler.lua` includes two faithful doubles:
truthy start with `running()==false` must return `committed == false`, attempt
exact rollback and leave no live registry entry; truthy stop with
`running()==true` must return false, retain the same handle, suppress its queued
callback, and settle only when a later stop makes the probe false.

### `HS-H-48` — The KC ledger watcher and fallback poller were not one lifecycle transaction

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`modules/keylogger/kc_bridge.lua:421-648`;
`tests/unit/modules/keylogger/test_kc_bridge_lifecycle_transaction.lua`.

**Reproduction.** Load the always-on Karabiner physical-key bridge and let the
pathwatcher start, then make fallback-poller construction/start refuse. The old
code retained the first producer and continued initialization without a
transactional result. On teardown, make either `stop()` throw/refuse: the old
path discarded the handle anyway, so its callback could survive beside a retry.
Separately, stop the bridge, append KE records while it is stopped, and make the
enable-time `io.open`, seek or close used to discard that interval fail. The old
`start()` silently rearmed its producers; after I/O recovered, those old rows
could be logged with the current app and timestamp.

**Root cause and silence.** Two redundant producers were managed as independent
best-effort side effects, and resynchronization treated an unreadable cursor as
an optional optimization. Pathwatcher/timer callbacks are outside the initiating
stack, so a partial start or stale delivery need not raise at the user action or
reach the file logger.

**Fix.** Construction, exact-handle publication, native activation and reverse
rollback now form one transaction. Callbacks require the current committed
generation; refused cleanup remains inert exact debt and blocks a successor.
Restart refuses until open/seek/close prove the disabled interval's EOF. An
exact duplicate init succeeds only for the same dependency graph and committed
producer pair.

**Regression test.** `test_kc_bridge_lifecycle_transaction.lua` drives
constructor throw/nil, partial poller refusal, watcher rollback throw, sibling
stop debt, duplicate init, and the failed-EOF-resync sequence. Its decisive
assertions are zero second-producer acquisition after first failure, stale
callback count zero, retry of the identical handle, no producer rearm while EOF
is unknown, and offset advancement only after a successful retry.

### `HS-H-49` — Root keylogger timers could publish a live engine without their native producers

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** the native timer contract was re-derived and each
failure was behaviorally reproduced. **Locations:**
`modules/keylogger/init.lua:1450-2005`;
`tests/unit/modules/keylogger/test_root_recurring_owner_transaction.lua`.

**Reproduction.** Enable Metrics while a watchdog, idle, maintenance or initial
foreground timer returns its chainable object from `start()` but remains
stopped. The old root accepted it and could publish `is_enabled=true`; a later
eventtap timeout then had no watchdog, or initial secure/app context never
arrived. Conversely, turn Metrics OFF while `stop()` returns its timer object
but `running()` remains true: the old root cleared the handle while a queued
callback could restart work after OFF. A later sibling acquisition failure also
left earlier timers/watchers without all-sibling rollback.

**Root cause and silence.** The root duplicated raw timer lifecycle logic and
treated method truthiness as state. Its callbacks had no single runtime
generation, and the initial foreground capture was a deferred side effect rather
than a required startup capability. None of the mismatched-state cases throws.

**Fix.** Every root timer is published before start, committed only after
`running()==true`, generation-fenced, and cleared only after `running()==false`.
Startup rolls every acquired sibling back on failure and retains exact cleanup
debt. The foreground bootstrap is owned as a one-delivery capability: duplicate
native delivery can retry only its stop debt, never repeat AX publication.
Caffeinate watcher start/stop uses the documented exact-object contract.

**Regression test.** `test_root_recurring_owner_transaction.lua` drives truthy
start with stopped state, activate-then-throw, later-sibling failure, truthy stop
with running state, bootstrap stop refusal/duplicate delivery and bootstrap
activation refusal. It asserts `is_enabled == false` until the whole set commits,
zero work from stale generations, reverse sibling rollback and retry of the
same exact native timer.

### `HS-H-50` — WPM lifecycle refusal was hidden behind a checked menu preference

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`ui/wpm/wpm_menubar.lua:105-189`;
`ui/wpm/wpm_widget.lua:562-727`;
`ui/menu/menu_metrics.lua:109-690`.

**Reproduction.** Click the WPM menubar or floating-widget toggle and make its
timer acquisition throw/return uncommitted, or make the widget eventtap start
without becoming enabled. The old modules set `_running=true` after unchecked
native calls, while the menu had already persisted and displayed ON. On OFF,
make timer/eventtap stop refuse: the old code nulled the only handle even though
the producer remained live.

**Root cause and silence.** Timer, eventtap, module running state, durable
preference and menu checkmark were five independent publications. The caller
ignored every lifecycle return, so hardening only the modules would still have
left a transitive false success.

**Fix.** Both modules use transactional timer ownership; the widget additionally
requires `eventtap:isEnabled()==true`, rolls its timer back if tap activation
fails, generation-fences callbacks and retains exact stop debt. Every menu/build
call consumes literal lifecycle success. A rejected start compensates the
already-saved visibility preference to OFF; an incomplete stop keeps callbacks
fenced, reports failure and retries the retained owner on reconciliation.

**Regression tests.** `test_wpm_lifecycle_transactions.lua` drives timer and
eventtap construction/start/state/stop failures and stale delivery.
`test_menu_metrics_wpm_lifecycle_transaction.lua` invokes the real menu paths
with `false`, `nil` and thrown starts, asserts a compensating OFF save and zero
checked false success, then proves retained stop debt is surfaced while OFF
remains the truthful logical state.

### `HS-H-51` — Metrics dashboard timers could leave a blank window and mutate a successor

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** code-derived and behaviorally reproduced. **Locations:**
`ui/metrics_typing/init.lua:52-630`;
`tests/unit/ui/test_metrics_typing_timer_transaction.lua`.

**Reproduction.** Open Typing Metrics and make the first delayed-paint timer or
the JS request poller fail after the webview exists. The old `show()` returned
with a blank, apparently live window and could leave whichever timer had already
started orphaned. Close it, open a replacement, then deliver an old cache/retry,
live-update or poll callback: it read the module-global webview and could inject
old manifest/range state into the replacement.

**Root cause and silence.** Window creation, nested `doAfter` continuations and
the recurring poller had no aggregate commit or exact window generation. A Lua
webview reference remains non-nil even after its native object dies, and the
protected callback failures did not repair the missing UI output.

**Fix.** The window owns every delayed continuation and its request poller as
one generation. Any bootstrap/poller refusal invalidates callbacks, cancels all
exact handles, deletes the new window and returns false. Close/reopen cancels or
retains exact debt; every Lua and WebKit callback checks captured generation and
webview identity before each mutation.

**Regression test.** `test_metrics_typing_timer_transaction.lua` injects
throw/nil/uncommitted bootstrap, later poller refusal, queued delivery after
close and one-shot stop debt. It asserts deletion on every partial start, no JS
calls on the replacement, exact rollback of the first continuation and exactly
one committed first paint.

### `HS-H-52` — A stale Healthcheck WebKit completion could copy and close a replacement window

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** behaviorally reproduced. **Locations:**
`ui/healthcheck/core.lua:58-749`;
`tests/unit/ui/test_healthcheck_timer_transaction.lua`.

**Reproduction.** Open Healthcheck A and let its poller submit
`evaluateJavaScript`; before WebKit answers, close A and open B. Deliver A's
completion with `true`. The old entry-only check had already yielded to WebKit,
so the callback used module-global `_window`, copied A's report and deleted B.
The same owner also accepted partial poller/focus-timer acquisition and could
orphan callbacks on reopen.

**Root cause and silence.** Ownership was checked before an asynchronous API
that invokes a second callback, but not after that yield. Timer and webview
lifecycle were also separate best-effort operations. The completion is a valid
normal callback, so no exception exposes that it belongs to an obsolete window.

**Fix.** Poll/focus continuations are exact scheduler owners with retained stop
debt and a window generation. The outer timer callback and the inner WebKit
completion both recheck captured generation plus exact webview identity before
clipboard or delete side effects. Reopen/close invalidates first, then attempts
all sibling cleanup independently.

**Regression test.** `test_healthcheck_timer_transaction.lua` drives poller
throw/nil, uncommitted cleanup refusal, native-close stale delivery and the
two-window WebKit sequence. The last assertion requires zero clipboard writes,
zero deletes of B and B remaining the current owner after A completes.

### `HS-H-53` — Four raw recurring timers confused chainable method returns with native running state

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** behaviorally reproduced against faithful timer doubles
after independently re-reading each pre-fix owner. **Locations:**
`modules/keylogger/log_manager.lua:1266-1351,1663-1728`;
`modules/keymap/init.lua:1550-1725`;
`platform/remap/watchers.lua:80-81,311-352,997-1067`;
`infra/launcher_guard.lua:70,105-164,375-417`.

**Reproduction.** For each owner, make `timer:start()` return its normal
chainable timer object while `timer:running()` remains `false`, then request the
user-visible start: enable Metrics/keylogging, start the keyboard layer, start
the layout watcher, or boot under launcher supervision. The old code published
success although the ingest, tap watchdog, fallback layout poll, or
process-instance backstop was absent. Conversely, let `stop()` return the timer
while `running()` remains `true`, stop the feature, and deliver one already
queued callback. The owner discarded the only cleanup handle; the keymap
watchdog could re-enable taps after stop, and the other owners could keep
mutating state or coexist with a successor.

**Root cause and silence.** Hammerspoon timer lifecycle methods are chainable:
their truthy object return is not evidence that native state changed. These four
raw owners either treated truthiness/handle presence as commitment or cleared
the handle immediately after a non-throwing stop. No Lua exception is required;
a missing recurring callback looks like inactivity, while a late callback runs
on Hammerspoon's scheduler outside the file logger.

**Fix.** Every owner publishes the exact candidate before activation, requires
an observable `running() == true` before committing, and gates delivery by
identity plus a commit bit/generation. Stop fences delivery before crossing the
native boundary, requires `running() == false`, and retains the same handle as
cleanup debt on refusal. A successor cannot be allocated over that debt.

**Regression tests.** `test_log_manager_init_transaction.lua` asserts that a
chainable non-running start is rejected and a chainable still-running stop
retains one inert ingest timer for exact retry. `test_start_commit_transaction.lua`
delivers the retained watchdog callback after stop and requires zero tap
reactivation and reuse of the same handle. `test_watchers_teardown_retry.lua`
also fires the layout poll synchronously from `start()` before commitment, then
requires no read, no sibling and exact cleanup retry. `test_launcher_guard.lua`
requires the same false-start rejection and false-stop retention for the
early-boot backstop. Existing lifecycle tests were searched before promotion;
they covered throws, nils, and some retained identities, but none contradicted
these observable-state reproductions.

### `HS-H-54` — The always-on KC ledger bypassed the canonical Metrics-enable persistence gate

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** behaviorally reproduced. **Locations:**
`modules/keylogger/kc_bridge.lua:202-233,270-287`;
`modules/keylogger/init.lua:292-307,539-551`.

**Reproduction.** Enable Metrics, disable only the secure-field filter, turn
Metrics OFF, append one Karabiner KC row, and fire the still-intentional
always-on ledger drain. Before the fix the bridge persisted both the enabled
control row and the row typed while OFF. The disabled-period offset test had
started with no `LogManager`, so it proved cursor advancement but never drove
the reachable enable → OFF state with the retained manager.

**Root cause and silence.** KC reconstructed a partial policy from pause plus
`context_allows_logging()`. That helper deliberately excludes
`CoreState.is_enabled`; disabling the secure filter made it return true after
feature stop. Because KC must keep reading while OFF, producer liveness is not
permission to persist. The append was valid and raised no error, so the privacy
failure looked like ordinary keylogger data.

**Fix.** Root injects the canonical `M.may_persist()` predicate into KC during
module construction. The callback captures the declared module table, fails
closed until the public predicate exists, and KC contains predicate throws or
absence as discard decisions. While OFF it still advances the exact byte
cursor, but it cannot call the retained storage owner.

**Regression test.** `test_kc_bridge_offset_advances_while_disabled.lua`
drives enable, secure-filter OFF, feature stop, KC append and drain. It asserts
one persisted enabled row out of two total rows, exact cursor advancement over
both, and no replay after re-enable. Existing `test_root_recurring_owner_transaction.lua`
was inspected and did not contradict the claim: it asserted only that feature
OFF does not stop the KC producers.

### `HS-H-55` — A cold-start EOF read failure armed KC at byte zero and later replayed old input

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** behaviorally reproduced. **Locations:**
`modules/keylogger/kc_bridge.lua:70-78,430-456,527-607`;
`modules/keylogger/init.lua:1779-1792`.

**Reproduction.** Pre-populate the KC ledger, make its first cold-start
`io.open` fail transiently, then let init arm the path watcher/poller. Enable
Metrics before their first drain, restore reads, and append one new row. The
old `start()` returned immediately because producers were already active, so
offset zero caused both the historical and new row to be stamped with current
context. The earlier EOF test covered only `stop()` → `start()`, where
`_watchers_active` was false; it did not cover cold init with live producers.

**Root cause and silence.** Cursor position and producer activity were one
implicit state. Failed cold EOF discovery left `_file_offset = 0` without an
explicit untrusted state, and the idempotent-start shortcut skipped the later
proof. When I/O recovered, the bytes were syntactically valid and no error
distinguished them as historical.

**Fix.** `_cursor_trusted` is independent from watcher ownership. Exact
open/seek/close proof sets it; every persistence-enabling `start()` retries that
proof even when the two producers are already active. Failure keeps persistence
denied and returns false, while the always-on drain remains available for a
later exact retry.

**Regression test.** `test_kc_bridge_offset_advances_while_disabled.lua`
injects the cold EOF refusal, enables before first drain, restores the file and
appends a new row. It requires exactly the new row to persist. The neighboring
`test_kc_bridge_lifecycle_transaction.lua` retains its separate restart failure
matrix and passed all seven cases.

### `HS-H-56` — Scheduler-wide teardown invalidated a failed owner's retry capability while Hammerspoon stayed alive

**Status:** Fixed. **Severity:** High. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** behaviorally reproduced. **Locations:**
`infra/teardown_transaction.lua:100-130`; `init.lua:510-523`.

**Reproduction.** Request controlled reload/exit, let keymap's eventtap stop
remain unproven while its HID diagnostic mailbox timer remains owned, and let
the old independent `TimerScheduler.cancelAll()` step succeed. The root
teardown returned false, so `TerminationCoordinator` correctly refused the
terminal action and kept the same Lua VM alive; however, the global drain had
already killed the retained mailbox pump while a tap could remain live. A later
input error then had no diagnostic delivery capability, and the owning module
could not recover the globally discarded resource coherently.

**Root cause and silence.** A global finalizer was modeled as an independent
sibling cleanup step. Sibling-progress semantics are correct for independent
owners but wrong for a drain that destroys capabilities those owners still need
when another step refuses. The stop refusal is logged, but the secondary loss
occurs during nominal cleanup and does not throw.

**Fix.** `TeardownTransaction.run_with_finalizer()` validates the complete
descriptor set up front, runs/retries every independent owner first, and invokes
the global finalizer only after all owners commit. A refused finalizer remains
the sole unfinished step; settled owners are not repeated. Root passes
`TimerScheduler.cancelAll()` only through that dependent finalizer.

**Regression test.** `test_teardown_transaction.lua` drives owner refusal,
healthy sibling progress, owner recovery, finalizer refusal and finalizer retry;
it asserts zero early global calls and no repetition of settled owners.
`test_root_teardown_timer_finalizer.lua` pins the root wiring. The coordinator
tests confirm that a false teardown still withholds reload/exit.

### Medium

### `HS-M-01` — Mutable dynamic resolvers were evaluated once for preview and again for output

**Severity:** Medium. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `modules/dynamic_hotstrings/rules_engine.lua:53-103,125-174,517-537`.

**Reproduction.** Register a resolver whose value changes on each call, display
its row, then press the magic key. Calling it twice displays `value-1` and types
`value-2`.

**Root cause and silence.** “Same resolver” is not “same result”; time, profile,
clipboard or external state may change between calls.

**Implemented fix.** The provider stores the exact resolved value under an
opaque, single-use visible-action token. Dispatch uses it only if the bridge
still owns that exact token/buffer; without a committed lease it resolves a
fresh action and never claims the old row.

**Regression test.** `tests/unit/modules/dynamic_hotstrings/test_rules_engine_preview_snapshot.lua`
asserts one resolver call for a visible action and exact equality between shown
and injected strings; it also covers uncommitted fallback, composite trigger,
single-use consumption and failed preview revocation.

### `HS-M-02` — PersonalInfo's fixed post-injection delay dropped a legitimate next combo

**Severity:** Medium. **Confidence:** High. **Guarantees:** G2, G3.
**Locations:** `modules/dynamic_hotstrings/personal_info.lua:390-503,537-625`.

**Reproduction.** Expand `@n★` and immediately type `@e★`, without waiting for
the old fixed guard timer. The second physical `@` used to arrive while
`_replacing=true` and the collector ignored it.

**Root cause and silence.** A time window stood in for exact synthetic
ownership, blocking real input as well as echoes.

**Implemented fix.** PersonalInfo emits through the shared provenance
transaction and releases local replacement ownership synchronously in both
success and caught-failure paths.

**Regression test.** `tests/unit/modules/dynamic_hotstrings/test_personal_info_back_to_back.lua`
performs two combos without advancing timers, asserts two exact injections, and
then verifies a caught first failure does not blind the second combo.

### `HS-M-03` — French composite punctuation events were inconsistently recognized as the magic key

**Severity:** Medium. **Confidence:** High. **Guarantees:** G2, G5.
**Locations:** `_shared/lua/keymap/terminators.lua`;
`modules/dynamic_hotstrings/personal_info.lua:537-625`;
`modules/dynamic_hotstrings/rules_engine.lua:125-174`;
`modules/keymap/expander.lua:899-984`.

**Reproduction.** Configure `:` as the magic character under a French layout,
where Hammerspoon may deliver NBSP/NNBSP plus `:` as one event. Static
terminators accepted one shape while dynamic tags or repeat compared the whole
string to `":"`, leaving literal punctuation or failing to delete both
codepoints.

**Root cause and silence.** Sibling consumers each implemented a different
string comparison and delete count.

**Implemented fix.** All consumers use shared
`Terminators.matches_magic_event()` and the event's actual UTF-8/codepoint
length. Unknown multi-codepoint strings remain rejected.

**Regression test.** `tests/unit/modules/keymap/test_french_punctuation_terminators.lua`
asserts exact/NBSP/NNBSP acceptance and unrelated composite rejection.
`test_rules_engine_trigger_char_sync.lua`,
`test_personal_info_trigger_char_sync.lua`, and
`test_repeat_feature_arm_time.lua` drive each production sibling.

### `HS-M-04` — Visible-text no-op detection erased non-text key-token side effects

**Severity:** Medium. **Confidence:** High. **Guarantee:** G2.
**Locations:** `modules/keymap/expander.lua:287-315,627-693`.

**Reproduction.** Register a mapping whose plain visible replacement equals its
trigger but whose token stream includes `{Tab}`. Fire it. Comparing only plain
text labels the mapping a no-op and passes the key through, losing the Tab.

**Root cause and silence.** Equality of projected strings was treated as
equivalence of actions; token side effects were excluded from the comparison.

**Implemented fix.** No-op pass-through applies only when the complete action is
semantically inert. Tokenized key effects retain a synthetic transaction and
commit normally.

**Regression test.** `tests/unit/modules/keymap/test_noop_expansion_passthrough.lua`
keeps automatic/terminator identity controls as pass-through, then asserts the
`{Tab}` variant fires, consumes, returns tagged events, and preserves the
expected logical buffer.

### `HS-M-05` — Registry and menu mutations published partially applied hotstring state

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2, G3, G5.
**Locations:** `modules/keymap/registry_groups.lua:89-155,179-190,508-594`;
`modules/keymap/registry_index.lua:193-276`;
`ui/menu/keymap_lifecycle.lua:74-103`;
`ui/menu/menu_hotstrings.lua:146-253`.

**Reproduction.** Enable a group whose post-load hook throws after adding a
mapping, fail a settings write/read-back, or make the second section in “Disable
all” fail. A per-site implementation can leave half the registry changed while
the menu saves preferences and shows the requested checkmark.

**Root cause and silence.** The invariant was applied to individual calls, not
the transitive mutation. Menu publication accepted invocation rather than exact
commitment.

**Implemented fix.** Registry transactions snapshot mappings, groups, hooks,
delays, counters and derived indexes, and restore/rebuild them on non-true or
throw. Multi-group section changes share one snapshot and settings rollback.
The menu publishes state, persistence, success notification and rebuild only
after exact true; failure is user-visible.

**Regression test.** `tests/unit/modules/keymap/test_registry_mutation_transactions.lua`
asserts rollback after throwing hook, partial Lua load, parse failure and
ineffective/throwing settings writes. `tests/unit/ui/menu/test_hotstring_mutation_commit_gate.lua`
drives reachable category, custom-section and whole-tree callbacks with false,
nil and throw, asserting zero saves/checkmarks/success notices and one error.

### `HS-M-06` — Daily rotation did not re-run retention and housekeeping failures were unobservable

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `infra/logger.lua:214-237,262-312,329-382,385-487,583-614`.

**Reproduction.** Keep Hammerspoon alive across midnight until an old dated log
crosses the retention threshold, then write the first new-day line without
restarting. Current pre-fix rotation already moved that line to the new dated
sink, but retention was scheduled only by `init_log_path()`, so the newly stale
file survived until the next process start. Independently, allow the one-shot
timer to lose its only Lua reference, make its callback throw, or make one
`os.remove` return false: housekeeping could disappear or report a removal that
the OS refused.

**Root cause and silence.** The prompt's suspected startup-date rotation defect
was not present at the audited parent: `_ensure_log_file()` already recalculated
the calendar date on every write. The confirmed defect was that retention
ownership remained boot-only, the timer handle was not retained, callback
failure was swallowed by a bare `pcall`, and removal attempts were counted as
successes.

**Implemented fix.** The existing write-time rotation remains authoritative.
After the first successful new-day reopen it schedules exactly one purge using
the retained configured policy. Token-keyed strong references survive until
delivery; callback/timer failures reach the file logger; only OS-confirmed
deletions increment the success count. The errors-only sink and topical files
remain part of the same retention pass.

**Regression test.** `tests/unit/lib/test_logger_rollover_purge_integrity.lua`
crosses two synthetic dates. Its day-A/day-B assertion confirms the pre-existing
rotation backstop; the regression-specific assertions require one retained
new-day purge without restart, both unified/error stale files selected, refused
removal excluded from the success count, and callback/timer throw or nil made
visible.

### `HS-M-07` — Hotstring menu actions became clickable no-ops after a callback-schema change

**Severity:** Medium. **Confidence:** High. **Guarantee:** G2.
**Locations:** `ui/menu/builder.lua:410-414`;
`ui/menu/menu_hotstrings.lua:439-451`.

**Reproduction.** Open Hotstrings and click “Enable all” or “Disable all” when
the provider row carries `action` but the builder looks for `fn`. The row accepts
the click but an empty fallback callback changes nothing.

**Root cause and silence.** Producer and consumer used different field names;
the builder converted schema failure into a callable no-op.

**Implemented fix.** The builder uses the canonical callback field and the
whole-tree action now calls one transactional registry batch. Missing actions
fail visibly rather than becoming empty functions.

**Regression test.** `tests/unit/ui/menu/test_hotstring_bulk_actions_execute.lua`
builds the real menu, invokes both generated actions, and asserts all applicable
sections change with one persistence/update publication.

### `HS-M-08` — A timed winner could expire after resolution but before its tooltip paint

**Severity:** Medium. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `modules/keymap/llm_bridge.lua:723,787-885`.

**Reproduction.** Arrange a finite-delay literal as the prospective winner and
a star mapping as its dimmed fallback. Let the first clock read occur before the
literal deadline and the row-construction read just after it. The old bridge
disabled the expired literal but continued painting the already built ledger,
so the now-live star output appeared only as a dimmed action the UI claimed the
engine would not choose.

**Root cause and silence.** Resolution and canvas construction cross a clock
boundary. Expiry was checked per row but did not invalidate the arbitration
result that assigned `is_winner`; no exception occurs in this micro-race.

**Implemented fix.** If the resolved winner expires during row construction,
the bridge invalidates that preview generation, touches no canvas, and schedules
a zero-delay off-HID re-resolution. Generation and buffer checks reject stale
refreshes; inability to schedule resets the prospective surface instead of
painting an obsolete ledger.

**Regression test.** `tests/unit/modules/keymap/test_preview_winner_expiry_build_race.lua:21-190`
controls the two clock reads and real bridge scheduling. It requires at least
two resolver calls, exactly one canvas render, one surviving row, and the newly
live star action as the sole non-dimmed promise.

### `HS-M-09` — PersonalInfo transaction diagnostics could write private failure payloads to disk

**Severity:** Medium. **Confidence:** High. **Guarantee:** privacy/logging
invariant (collateral to G1/G2 diagnostics). **Locations:**
`modules/dynamic_hotstrings/personal_info.lua:198-251,313-318`.

**Reproduction.** Make the preview fence throw `PRIVATE-IBAN-SENTINEL`, or make
`os.rename` return that string as its error while saving a PersonalInfo value.
The transactional save correctly refused publication, but its first version
logged `tostring()` of fence, open/write/close/remove and rename failures.

**Root cause and silence.** The durability fix made failures visible without
classifying their payload. Callback and filesystem error objects are not a safe
diagnostic channel when the operation handles personal values and private paths.
This was sibling damage introduced by the otherwise correct transaction fix.

**Implemented fix.** The boundary still emits ERROR/WARNING records, but every
untrusted payload is replaced with a stable “failure content withheld” marker.
The control-flow result remains exact false, so privacy does not weaken
fail-fast behavior.

**Regression test.** `tests/unit/modules/dynamic_hotstrings/test_personal_info_save_transaction.lua:172-239`
injects the same private sentinel through preview and rename failures and asserts
it is absent from all captured diagnostics while disk and live state remain old.

### `HS-M-10` — Pcall-only regression assertions did not prove the intended lifecycle failure

**Severity:** Medium. **Confidence:** High. **Guarantee:** regression-proof
integrity for G1/G2/G3. **Locations:**
`tests/unit/adapters/test_action_listener_registration_transaction.lua:62-79`;
`tests/unit/adapters/test_hotkey_registrar.lua:300-311`;
`tests/unit/lib/test_logger_rollover_purge_integrity.lua:232-244`.

**Reproduction.** In the old action-listener test, throw an unrelated exception
before the intended third timer-constructor fault; `pcall` still returns false,
and because no capacity was consumed the later slot-count assertion can also
pass. Analogous wrappers around native hotkey delivery and logger initialization
made the surrounding harness, rather than the direct behavioral boundary, part
of the claimed evidence.

**Root cause and silence.** A boolean from `pcall` proves only “some exception
did/did not escape.” It does not identify the injected cause or, by itself,
prove rollback, fail-closed delivery or file-logger visibility.

**Implemented fix.** The allocation test asserts the exact injected failure
identity and then proves every capacity slot remains usable. Native delivery and
logger initialization are called directly, so any escaped exception fails the
test harness; their observable delivery fence and captured ERROR side effects
remain the required assertions.

**Regression test.** The three cited tests are the repaired guards themselves.
Their direct run passed `2/0`, `20/0` and `1/0` respectively; the
meaningful assertions are retained capacity, zero callback delivery, and a file
ERROR containing the injected timer-constructor failure.

### `HS-M-11` — Registry rollback diagnostics disclosed callback exception payloads

**Severity:** Medium. **Confidence:** High. **Guarantee:** privacy/logging
invariant (collateral to G1/G3 rollback). **Location:**
`modules/keymap/registry_groups.lua:91-157`.

**Reproduction.** Run `keymap.registry_transaction("private-registry-test", cb)`
where `cb` mutates the registry and then raises
`PRIVATE_REGISTRY_SENTINEL`. The registry correctly rolls back, but the first
transaction implementation interpolated the callback exception into its ERROR
record, making arbitrary trigger, replacement or personal-data text durable in
the unified log.

**Root cause and silence.** The rollback boundary treated an untrusted callback
payload as diagnostic metadata. Transactional state integrity therefore passed
while the privacy failure remained invisible unless the file sink itself was
inspected.

**Implemented fix.** The transaction log retains the controlled transaction
label and terminal Lua type, but withholds the callback payload. Snapshot restore
and exact-false propagation are unchanged, so redaction does not weaken
fail-fast or rollback behavior.

**Regression test.** `tests/unit/modules/keymap/test_registry_mutation_transactions.lua:55-74`
injects the sentinel through the real transaction callback, asserts the mutation
is rolled back and the transaction label remains visible, and asserts the
sentinel is absent from every captured diagnostic. The complete registry module
passed `7/0` in the direct final transaction run.

### `HS-M-12` — Keylogger rollover could treat a failed journal read as committed EOF

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `modules/keylogger/rotation.lua:203-278,291-303`;
`modules/keylogger/log_manager.lua:1092-1100,1230-1292`.

**Reproduction.** Leave un-ingested rows in `today.log`, trigger the midnight
rollover, and make open, seek, line read, final seek or close return a normal Lua
failure value. The former reader returned the same empty entry list used for
EOF. The drain loop could therefore decide it was empty, delete `today.log`,
reset its offset/context and permanently lose the only durable copy of those
metrics rows.

**Root cause and silence.** “No decoded entries” was used both as data and as a
terminal status. A protected call did not distinguish EOF from an I/O failure,
and successful reads were acknowledged before the handle's close result proved
the snapshot complete. The failure path need not throw, so the rollover could
look like a normal empty day.

**Implemented fix.** `read_new_entries()` now returns an explicit `batch`, `eof`
or `failed` status and advances no committed offset on any failed open/seek/read/
close or inconsistent size observation. `day_rollover()` loops until exact EOF,
also requires its data-SQL outbox durable, and passes that terminal proof into
`Rotation.rollover()`, which refuses every other value before deleting the
journal or resetting state.

**Fix commit.** `fdb2d628a` implements the exact EOF contract; `269ad7c4f` and
`5b6afd659` repair sibling harness ownership so the tests reach this boundary
instead of passing through an ignored `device.json` setup failure.

**Regression test.** `tests/unit/modules/keylogger/test_rotation_read_failure_preserves_journal.lua`
injects open/seek/read/close failures and asserts `failed`, zero journal removals,
zero resets and a false rollover; its exact-EOF control asserts one removal and
one reset only after successful close. `test_day_rollover_drain.lua`,
`test_rotation.lua`, `test_rotation_persistent_handle.lua` and
`test_data_sql_outbox.lua` cover batch draining, stalled offsets, direct rollover
refusal and the durable-outbox prerequisite.

### `HS-M-13` — Atomic-write failures lost their concrete reason before reaching the caller

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2.
**Locations:** `adapters/file_system.lua:687-875`;
`infra/config_paths.lua:304-325`.

**Reproduction.** Open the configuration-directory editor, choose a new target,
and make the `paths.toml` staging open fail with permission denied, its write
return `nil, "disk full"`, or its close return `nil, "I/O error"`. The disk and
in-memory path correctly remained old, but before the fix the action returned
only `false, "atomic write failed"`; the exact reason needed to distinguish
permissions, capacity and late flush failure never reached the caller.

**Root cause and silence.** The adapter wrapped the atomic body with
`local ok, result = pcall(...)`. Each inner branch returned `false, reason`, but
the second protected return was discarded, and `ConfigPaths.save_bootstrap()`
then manufactured one generic reason. The file logger could contain a deeper
line, so the transactional rollback looked healthy while the user-facing failure
contract was silently degraded.

**Implemented fix.** The atomic writer captures `result_err`, returns a concrete
reason from every resolution, reservation, open, write, close, source-check,
rename and unexpected-error branch, and retains a generic fallback only when no
detail exists. `ConfigPaths` forwards both `create_if_absent` detail and ordinary
write detail unchanged.

**Fix commit.** `0ee320489` preserves the atomic publication reason end-to-end.

**Regression test.** `tests/unit/lib/test_config_paths_write_transaction.lua:59-117`
drives the three normal Lua failure-return shapes through the real resolver and
asserts `changed == false`, the old directory remains active, and the returned
string contains respectively `permission denied`, `disk full` and `I/O error`.

### `HS-M-14` — The canonical `FileSystem.write` port exposed a third, private parameter

**Severity:** Medium. **Confidence:** High. **Guarantee:** G1 and shared-port
contract integrity. This is a production interface violation, not a demonstrated
keystroke-path failure.
**Locations:** `adapters/file_system.lua:687,859-875`;
`platform/remap/config.lua:569-573`;
`_shared/core/ports/contracts.json:85-92`.

**Reproduction.** Load `adapters.file_system` and inspect
`debug.getinfo(FileSystem.write, "u").nparams` against the generated shared port
contract. Before the fix it was `3` because remap compare-before-write had added
`expected_source` directly to `write`; the normative `FileSystem.write(path,
content)` contract requires `2`, so the adapter-compliance gate failed even
though ordinary Lua callers happened to tolerate the extra declaration.

**Root cause and silence.** A macOS-only concurrency extension was applied at
the shared public method instead of behind a separate extension. Lua does not
reject a two-argument call to a three-parameter function, so behavior-only write
tests stayed green and the cross-driver interface drift was visible only to the
arity-aware contract gate.

**Implemented fix.** The reviewed implementation is now private
`write_atomic(path, content, expected_source)`. Canonical `M.write(path, content)`
keeps stable arity two; explicit macOS `M.write_if_unchanged(...)` owns the
source precondition, and remap config selects that extension only when it holds
an observed source snapshot.

**Fix commit.** `b5d73a6f8` restores port arity without weakening the atomic
source-precondition invariant.

**Regression tests.** `tests/unit/test_adapter_compliance.lua:119-138` derives
the required arity from `contracts.json` and asserts `debug.getinfo(...).nparams`
for every required adapter method. `test_file_system_atomic_write.lua:1031-1047`
asserts the two-argument port still delegates to the same atomic writer, while
`test_config_corrupt_toml_write_guard.lua:156-271` behaviorally proves the remap
path carries its exact source through `write_if_unchanged` and only explicit
reset uses unconditional `write`.

### `HS-M-15` — Prefix-based test isolation let a shared stub poison 79 later failures

**Severity:** Medium. **Confidence:** High. **Guarantee:** audit/test integrity
(not a direct runtime G1–G5 claim).
**Locations:** `tests/run.lua:68,183-196`;
`tests/support/module_isolation.lua:14-71`;
`tests/unit/modules/keymap/test_start_commit_transaction.lua:21,179`;
`modules/keymap/terminators.lua:12,26`.

**Reproduction.** Run the aggregate suite in discovery order so
`test_start_commit_transaction.lua` loads first. It installs a permissive
`package.loaded["keymap.terminators"]` function stub. The former runner purged
only `modules.*`, `adapters.*`, `infra.*` and `ui.*`, so the shared `keymap.*`
entry survived. A later cold load of `modules.keymap.terminators` received that
stub and executed `ipairs(M.TERMINATOR_DEFS)` where `TERMINATOR_DEFS` was a
function; that one leaked identity surfaced as 79 cascading failures in the
late suite.

**Root cause and silence.** Module ownership was inferred from a manually
enumerated namespace prefix list even though production modules also live in the
bare shared Lua tree. `package.loaded` is process-global, and a permissive stub
can cause false positives as readily as false negatives. The resulting volume
looked like dozens of regressions and obscured the much smaller set of real
production/test-fixture defects.

**Implemented fix.** The runner now resolves every loaded module through
`package.searchpath` and evicts any production source located under either the
macOS driver root or `_shared/lua`, independent of namespace. Test infrastructure
and the process-identity shared logger remain intentional exceptions; logger
diagnostic state is reset explicitly.

**Fix commit.** `612000595` extracts and installs source-root module isolation.

**Regression test.** `tests/unit/meta/test_runner_shared_module_isolation.lua:19-40`
poisons shared `keymap.terminators`, shared `keymap.utils` and platform remap,
runs the real purge, asserts all production entries are gone while
`tests.helpers` retains identity, then requires the wrapper and asserts
`TERMINATOR_DEFS` is the real table. With this helper applied to the campaign
baseline the aggregate exposed `23` genuine residual failures instead of cache
pollution; exact `04e917cf` passed `4,881/4,881`. The current-baseline aggregate
is `803` modules / `5,218` passed / `0` failed at exact
`dafbcb591e073811c8c1e4b4f3bc39482ec1c4de`, as recorded in the evidence table.

### `HS-M-16` — Immediate acceptance could observe the row before deferred navigation committed

**Severity:** Medium. **Confidence:** High. **Guarantees:** G2, G3, G5.
**Locations:** `ui/tooltip/tooltip_llm.lua:445-475,642-699,1220-1275`.

**Reproduction.** With two LLM rows visible, press Down and immediately press
Enter before the zero-delay canvas/navigation callback runs. The physical Enter
classification could still see row one and either accept the wrong prediction or
pass through, even though Down had already been consumed as selection of row two.
A later arrow or token repaint could also invalidate an already consumed Tab or
Enter before its deferred action ran.

**Root cause and silence.** Expensive repaint and the small semantic cursor were
committed in the same deferred callback. Quartz can deliver the next physical key
before that callback, so event order and logical state order diverged without any
exception or invalid value.

**Implemented fix.** Arrow/Shift-Tab commits the bounded cursor and navigation
revision synchronously, then defers only AX/canvas rendering and semantic
notification. Accepted physical actions retain FIFO ownership; later navigation
cannot cancel them, and superseded renders coalesce to the newest revision.

**Regression test.** `tests/unit/ui/test_tooltip_watcher_reuse.lua:1515-1605`
asserts Down then immediate Enter accepts row two exactly once, a later arrow or
same-stream repaint cannot cancel an accepted action, and two rapid arrows emit
only the final navigation callback. `test_tooltip_nav_deferred.lua` retains the
structural guarantee that canvas work stays outside the eventtap.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-M-17` — ProcessLifecycle could publish failed native watcher ownership

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `adapters/process_lifecycle.lua:68-131,209-337`.

**Reproduction.** Make application-watcher `start()` fail once and succeed on the
next call, then call `ProcessLifecycle.start()` twice. In the old flow the first
constructed handle and aggregate running bit could be published before native
activation, making retry a no-op. Make `stop()` or window-filter
`unsubscribeAll()` fail and the inverse transition could discard the only exact
cleanup owner while callbacks remained native-live.

**Root cause and silence.** Handle construction was mistaken for operational
commitment and teardown flags changed before the result was known. False/nil
native results follow normal Lua control flow, while a discarded protected-call
result emitted no diagnostic.

**Implemented fix.** Start acquires each candidate transactionally, publishes
active state only after its native operation succeeds, and rolls back all handles
acquired by the failed attempt. Stop first generation-fences callbacks, retains
every refused exact handle as cleanup debt, attempts both sibling teardowns and
allows a later start/stop to retry that debt.

**Regression test.** `tests/unit/adapters/test_process_lifecycle_running_guard.lua:115-204`
drives start throw/false, stop throw/nil, filter subscription refusal, rollback
and cleanup retry and asserts exact handle counts after every transition.
`tests/unit/ui/test_menu_metrics_lifecycle_commit.lua:67-82` proves the caller
does not publish Metrics/WPM state when lifecycle start refuses.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-M-18` — Watcher and application fallbacks confused protected calls with operational success

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2.
**Locations:** `adapters/window_manager.lua:41-65`;
`platform/remap/watchers.lua:638-647,1038-1047,1156-1177`;
`modules/shortcuts/actions/apps.lua:275-289`.

**Reproduction.** Make `currentLayout()` return once and throw if invoked again;
the old watcher discarded the protected value and called it a second time
unprotected. Separately make bundle-ID activation return false and name fallback
return true, or make a running Finder object's `activate()` return false. The old
branches treated `pcall == true` as completed activation and suppressed the
successful fallback, so the user's switch/click did nothing.

**Root cause and silence.** Exception containment and API-level success were
collapsed into one boolean, and one layout branch redundantly called the native
getter. False is a documented result, not an exception. The historical proposed
fix also overgeneralized literal `true`: `hs.window:focus()` successfully returns
the window object for chaining.

**Implemented fix.** Each dangerous getter is invoked once and its value retained.
Boolean application launch/activation APIs require literal true and otherwise
fall through; window focus accepts any non-nil/non-false result and normalizes it
to the adapter's boolean contract.

**Regression test.** `tests/unit/adapters/test_activation_return_contract.lua:23-60`
drives false application/window results and the documented window-object success;
`73-113` proves false Finder activation reaches the path-open fallback.
`tests/unit/platform/remap/test_watcher_operational_results.lua:23-47` requires a
single protected layout read and result checks on every previous-app strategy.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-M-19` — Wake/unlock gesture recovery bypassed the global pause gate

**Severity:** Medium. **Confidence:** High. **Guarantees:** G1, G2, G3.
**Locations:** `modules/gestures/init.lua:657-685,797-815`.

**Reproduction.** Enable gestures, pause ErgoptiPlus, then deliver
`systemDidWake` followed by `screensDidUnlock`. The old sibling callback called
`kickstart_hid()` and recycled watchers despite pause, moving the cursor and
posting a synthetic scroll while the UI promised that every feature was off.

**Root cause and silence.** The pause invariant was duplicated by call site.
Some emergency timers checked only the gesture feature flag and the wake sibling
had no suspended-state gate. All native calls could succeed, so the visible
cursor jump had no error path.

**Implemented fix.** Every kickstart/recycle entry checks both
`CoreState.enabled` and `not CoreState.suspended` immediately before HID output.
The independently configurable script-control half of the historical claim is
already fenced by `HS-H-03`; only lifecycle pause/reload/quit actions remain
allowlisted there.

**Regression test.** `tests/unit/modules/gestures/test_kickstart_respects_pause.lua:18-129`
first rejects every feature-only guard, then captures the real registered wake
callback, suspends the production module, fires both events and asserts zero
cursor-write and scroll-post deltas.

**Fix status.** Committed in the exact executable baseline; covered by the final
portable replay.

### `HS-M-20` — The hot-path regression test structurally blesses the blocking logger sink

**Status:** Open. **Severity:** Medium. **Confidence:** High. **Guarantee:** G4
proof integrity. **Location:** `tests/unit/test_hot_path_costs.lua:40-82`;
contrasting behavior contract in
`tests/unit/lib/test_logger_file_sinks.lua:378-417`. **Introduced together:**
`30ed114fd` added both DEBUG batching and the source-shape guard that overstated
it as eventtap fsync removal.

**Reproduction.** Run the current hot-path test against the current logger. It
passes because it finds `immediate == false`, a call whose argument mentions
`LEVELS.DEBUG`, and `FLUSH_EVERY_N_DEBUG`. The same source still executes
`_ensure_log_file()`, `fh:write()`, console output and periodic `fh:flush()` in
the eventtap path. More adversarially, replace the sink body with a direct
`io.open(...):write(...)` while preserving those three strings: the test remains
green although the claimed guarantee is maximally false.

**Root cause and silence.** The guard scans one helper's source shape instead of
calling the user entry point and observing the forbidden effect. Its title says
“DEBUG lines do not fsync inside the eventtap,” but its assertions encode only a
weaker flush cadence. The behavioral sink test intentionally confirms the
cadence and therefore does not contradict `HS-H-34`; neither test models an
eventtap boundary.

**Proposed fix and required regression test.** Keep the durability assertions in
`test_logger_file_sinks.lua`, but replace the hot-path proxy with the behavioral
`test_eventtap_logger_side_effects.lua` described by `HS-H-34`. Its decisive
assertion is `io/console/notification calls before keyDown return == 0`, followed
by exact ordered delivery and ACK/retry ownership. Do not weaken or delete the
file-sink durability cases; prove both guarantees at their respective owners.

### `HS-M-21` — Sticky-modifier timer refusal could leave a modifier armed or revoke its successor

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantees:** G1,
G2, G3. **Provenance:** behaviorally reproduced. **Locations:**
`modules/gestures/sticky_modifiers.lua:33-128,147-215`.

**Reproduction.** Arm sticky Shift while the auto-cancel timer returns a retained
handle with `committed == false`; alternatively, arm a replacement generation
then deliver the old queued callback. The former state could remain armed
indefinitely and unexpectedly modify the next key; the latter could disarm the
new owner.

**Root cause and silence.** The caller used one-value timer truthiness and had no
generation or cleanup-debt fence. Neither path needs to throw, so the symptom is
an apparently random modifier state.

**Fix.** The modifier arm commits only after exact timer commitment, revokes
before cancel, retains refused cleanup, and validates the captured generation in
the callback.

**Regression test.** `tests/unit/modules/gestures/test_sticky_modifiers.lua`
injects uncommitted acquisition, throwing acquisition, stale delivery and stop
refusal. It asserts immediate disarm on refusal, successor isolation and exact
cleanup retry.

### `HS-M-22` — The recurring-timer inventory searched one spelling and certified an incomplete class

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantee:**
G1/G2/G3 proof integrity. **Locations:**
`tests/meta/test_recurring_timer_single_owner.lua`;
the missed owners are covered by `HS-H-43`, `HS-H-48`–`HS-H-52`.

**Reproduction.** Run the pre-fix guard against a production module containing
`local timer = require("hs.timer"); timer.new(...):start()`. Its whole-class
test enumerated direct `doEvery` references, so it stayed green while UI
restore, KC bridge, WPM, Metrics and Healthcheck owned raw repeating
`hs.timer.new` instances. A comment or diagnostic mentioning the expected text
could also satisfy simpler source checks without any executable owner.

**Root cause and silence.** The test encoded one constructor spelling rather
than the semantic class “native repeating timer acquisition.” Its title and
allowlist implied transitive coverage that its parser did not provide, hiding
the exact sibling-site failure mode documented in `PROJECT_MEMORY`.

**Fix.** The guard projects executable Lua by removing comments and literals,
retaining only the `hs.timer` module sentinel, detects direct calls, `pcall`
forms and local module aliases, requires a non-vacuous production-file floor,
and compares the complete result with a justified low-level-owner inventory.
The inventory is explicitly supplemental: every allowlisted owner still needs
a behavioral lifecycle test.

**Regression test.** `test_recurring_timer_single_owner.lua` supplies an aliased
`timer.new`, an indirect alias passed to `pcall`, and comment/log-string decoys.
It asserts both real snippets are detected, both decoys are rejected, no
production owner is outside the exact allowlist, and no stale allowlist entry
remains after migration.

### `HS-M-23` — The UI reload re-entrancy test proved a guard spelling while the queued callback was still lost

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantees:**
test integrity for G2 and G3. **Locations:**
`tests/unit/lib/test_ui_restore_defer_reentrancy.lua`;
`tests/unit/lib/test_ui_restore_timer_transaction.lua`.

**Reproduction.** Run the old test against the pre-fix implementation: it finds
`local _reload_in_flight`, a branch on that flag, and assignments before/after
the callback, so every assertion passes. Then behaviorally call
`defer_reload(outer)` with no UI open and have `outer` call
`defer_reload(inner)`. The inner function is stored while the flag is true, but
no poller or other future callback is armed; after `outer` returns, `inner` has
zero calls forever.

**Root cause and silence.** The meta-style test encoded local syntax rather than
the transitive promise “a re-entrant non-terminal request gets exactly one later
opportunity.” The implementation fixed double-fire but introduced missing
output, and the structural assertions could not distinguish those outcomes.

**Fix and regression test.** The old shape check remains only a supplemental
ratchet. `test_ui_restore_timer_transaction.lua` now drives the real module with
a re-entrant callback, asserts zero inner calls on the outer stack, one committed
one-shot owner, exactly one inner call after delivery, and no duplicate after a
stale second delivery. Scheduler refusal is separately driven so the test cannot
pass merely because the expected timer constructor string exists.

### `HS-M-24` — Metrics dashboards published windows before acquiring their live-ingest subscription

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantees:**
G1, G2. **Provenance:** behaviorally reproduced. **Locations:**
`modules/keylogger/log_manager.lua:696-705`;
`ui/metrics_typing/init.lua:37-68,516-529`;
`ui/metrics_apps/init.lua:218-239,838-867`.

**Reproduction.** Open either dashboard while `LogManager.on_ingest_done`
throws, returns nil, or is unavailable. Both old paths created/published the
WebView first; Typing then let the exception escape, while Apps did likewise.
The result was a partial or stale window with no future ingest refresh. Existing
timer tests always supplied a non-throwing subscription and therefore did not
contradict the reachable sequence.

**Root cause and silence.** The module-lifetime subscription was treated as an
incidental post-window side effect rather than a required producer capability.
`on_ingest_done` also had no explicit success contract, so callers could not
distinguish successful ownership from a non-throwing refusal.

**Fix.** `LogManager.on_ingest_done` validates the callback and returns exact
true only after insertion. Each dashboard acquires that capability under
`xpcall` before calling its WebView builder and refuses startup on anything but
literal true. The registered callback remains module-lifetime-owned, matching
the manager and dashboard Lua-state lifetimes.

**Regression tests.** `test_metrics_typing_timer_transaction.lua` injects throw
and nil and asserts zero WebView constructions, zero timer acquisitions and a
contained false result. `test_metrics_apps_live_update.lua` drives the sibling
boundary, then proves a healthy listener is acquired once and its callback
reaches the live refresh path.

### `HS-M-25` — Metrics OFF succeeded when the keylogger stop boundary was absent

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantees:**
G1, G2. **Provenance:** behaviorally reproduced. **Locations:**
`ui/menu/menu_metrics.lua:590-621,681-695`.

**Reproduction.** Start with Metrics enabled, make `require("modules.keylogger")`
return a table without `stop` (or make the require fail), then click the master
item OFF. The old branch tested failure only inside `if Keylogger and
type(Keylogger.stop) == "function"`; absence skipped the runtime transition and
still returned success with a saved unchecked item while capture could remain
active.

**Root cause and silence.** Optional-method syntax was applied to a required
security lifecycle boundary. No method call meant no exception or false result,
so the UI could not distinguish “stopped” from “never attempted.”

**Fix.** Before mutating memory or disk, the menu requires the exact `start` or
`stop` capability for the desired direction. Absence leaves the previous state
untouched, repaints, logs the missing boundary and returns false. Present
methods still require literal true after persistence.

**Regression test.** `test_menu_metrics_wpm_lifecycle_transaction.lua` injects
a keylogger module with `start` but no `stop`, clicks the real master callback,
and requires false, unchanged ON state, zero persistence calls and one repaint.

### `HS-M-26` — Metrics Apps continuations from a closed window mutated its replacement

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantees:**
G1, G2, G3. **Provenance:** behaviorally reproduced. **Locations:**
`ui/metrics_apps/init.lua:34-231,632-797,842-971`;
`tests/unit/modules/keylogger/test_metrics_apps_live_update.lua`.

**Reproduction.** Open Apps dashboard A, close it, and reopen B before A's
50/150/350/700 ms focus timers or data timer fire. Deliver A's callbacks: they
read module-global `M._wv`, so they focus or inject into B. Deliver A's old
`on_close` again and it can clear B. A WebKit probe from A can likewise finish
after the reopen and inject its stale manifest into B.

**Root cause and silence.** Every delayed focus, prefill, refresh and retry used
raw `hs.timer.doAfter` without retained ownership, while callbacks and
completions re-read the mutable global window rather than a captured exact
owner. Native close and WebKit are separate asynchronous yields; checking only
before either one cannot protect the mutation after it. All calls can succeed,
so the dashboard simply jumps, goes blank, or shows stale data without an error.

**Fix.** Every module continuation now uses `TimerScheduler.after` and is
retained until exact settlement. Startup acquires the complete timer set before
publishing the window and rolls back partial/reentrant creation. Generation plus
exact webview identity gate focus, bridge actions, live refresh, chooser/app
discovery, retries, native close and both sides of each WebKit yield. A refused
cancel remains inert cleanup debt and blocks conflicting publication until the
same handle settles.

**Regression test.** The behavioral `test_metrics_apps_live_update.lua`
encodes seven cases: subscription refusal, reentrant close, partial timer
acquisition, refused-close cleanup retry, stale focus/close, stale WebKit
completion and proof that live refresh uses the owned scheduler rather than raw
`doAfter`.

### `HS-M-27` — The Healthcheck nil-poller test could pass without reaching or rejecting a poller

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantee:**
G1/G2/G3 proof integrity. **Location:**
`tests/unit/ui/test_healthcheck_timer_transaction.lua:83-111`.

**Reproduction.** Delete the poller acquisition or accept its nil return while
keeping `show_window()` non-throwing. The old nil/throw subcase asserted only
that invoking the navigation callback under `pcall` did not raise, so either
broken implementation remained green. Neighboring cases covered retained
handles and stale generations but not this zero-handle refusal.

**Root cause and silence.** Exception containment was mistaken for behavioral
commitment. The test observed neither the acquisition boundary nor retryability.

**Fix and regression test.** The same real navigation callback now counts the
`TimerScheduler.every` call, requires exactly one attempted acquisition for both
throw and nil, invokes navigation again, and requires a second attempt. Thus nil
cannot be published as a live poller and removing the acquisition makes the
test red.

### `HS-M-28` — The shared canvas double let E2E pass while the renderer logged native-state failures

**Status:** Fixed. **Severity:** Medium. **Confidence:** High. **Guarantees:**
G1, G2 and G5 proof integrity. **Provenance:** behaviorally reproduced.
**Locations:** `tests/stubs/hs.lua:758-865`;
`tests/unit/ui/test_hs_canvas_stub_contract.lua`;
`tests/unit/ui/test_tooltip_llm_is_visible_after_render_crash.lua:25-65`.

**Reproduction.** Run `npm run test:hs:e2e` with the former shared stub and
exercise the virtual keyboard scenarios. The gate reports all `64/64` scenarios
as passed, but the same transcript repeatedly logs that tooltip visibility has
an invalid native status and that assigning element 7 indexes a function. Thus
the release gate is green while its shared renderer is observably failing.

**Root cause and silence.** The former `hs.canvas.new()` installed one catch-all
`__index` that returned a generic function for every key. A numeric lookup such
as `canvas[7]` was therefore a function rather than a mutable element, and
`canvas:isShowing()` returned the canvas table instead of a boolean. Production
renderer guards correctly caught and logged both failures, but the E2E runner
asserted only expansion output and did not fail on logger output. An older crash
regression also deliberately depended on this globally broken double as its
fault injector, making repair appear to weaken coverage.

**Fix and regression test.** The shared double now retains numeric elements,
geometry, visibility, callback and deletion state and returns the native-style
canvas/boolean shapes independently observable by the renderer. The intentional
render-crash test injects its failing renderer locally, so it still proves
fail-closed logical visibility without poisoning unrelated scenarios.
`test_hs_canvas_stub_contract.lua` asserts numeric element mutation, show/hide
read-back, frame read-back and numeric text measurement. Before the repair E2E
was green with renderer ERROR lines; after it E2E remains `64/64` with those
errors absent, and the full portable Lua replay passed `5,218/5,218`.

### Low

### `HS-L-01` — Public replacement API dereferenced injected state before `M.init()`

**Severity:** Low. **Confidence:** High. **Guarantee:** G1.
**Locations:** `modules/keymap/expander.lua` public replacement entry and
`tests/meta/test_require_state_pattern.lua`.

**Reproduction.** Load Expander in a cold/partial integration and call
`perform_text_replacement()` before `M.init()`. The prior public entry bypassed
the module's existing `require_state` guard and indexed nil state.

**Root cause and silence.** The guard invariant was checked by module presence,
not by enumerating public state-dependent functions; normal boot order hid it.

**Implemented fix.** The public method fails fast through `require_state` and
returns its neutral failure contract before dereference.

**Regression test.** `tests/unit/modules/keymap/test_expander.lua` cold-calls the
public API and asserts no unhandled throw plus the exact neutral result;
`tests/meta/test_require_state_pattern.lua` now guards the public class rather
than merely finding one `require_state` string in the file.

### `HS-L-02` — The integrity gate encoded the superseded direct-shutdown architecture

**Severity:** Low. **Confidence:** High. **Guarantee:** release-test integrity
for G1/G3. **Location:** `tools/test/test-hammerspoon-integrity.cjs:98-138`.

**Reproduction.** Run the integrity gate after adopting `M.stop(teardown)`, the
retryable local teardown transaction and exact-lease shutdown handoff. The old
regex required parameterless `M.stop()` and direct `keymap/gestures/shortcuts`
stops in `hs.shutdownCallback`, so it rejected the architecture that prevents a
missing-output window on native shutdown.

**Root cause and silence.** A structural test froze a call-site shape instead of
the transitive lifecycle guarantee. It became a false red after the production
owner moved one level up.

**Implemented fix and regression test.** The gate accepts explicit stop
parameters and now requires all four causal links: ordered controlled stops,
`TeardownTransaction.run`, `TerminationCoordinator` ownership, and the native
exact-lease handoff. Direct execution passed all 14 integrity assertions at this
baseline.

### `HS-L-03` — Four new preview regressions arrived with double-encoded source headers

**Severity:** Low. **Confidence:** High. **Guarantee:** release-test integrity.
**Locations:** the first line of
`tests/unit/modules/keymap/test_preview_cross_kind_winner.lua`,
`test_preview_respects_terminator_state.lua`,
`test_preview_star_requires_auto_expand.lua`, and
`test_preview_star_tail_casefold.lua`.

**Reproduction.** Run `node tools/test/test-source-encoding.cjs` on the first
versions of those four tests. Their path headers contained a UTF-8 em dash read
as CP1252 and encoded again, so the repository-wide encoding ratchet failed even
though the Lua behavior was otherwise valid.

**Root cause and silence.** The Windows text path transformed non-ASCII bytes in
new test files. Lua may still load such comments, so running only the behavioral
tests does not expose the release-gate corruption.

**Implemented fix and regression test.** The four headers were restored to valid
UTF-8 without changing test logic. `npm run test:source-encoding`
then scanned 2,947 text assets clean at that historical finding baseline. The
final post-reconciliation replay scanned 3,009 clean; that byte-level ratchet is
the non-regression test for this class.

### `HS-L-04` — Deferred dialog focus failure was invisible to the file log

**Status:** Fixed. **Severity:** Low. **Confidence:** High. **Guarantee:** G1
diagnostic/UX robustness. **Provenance:** behaviorally reproduced. **Location:**
`infra/dialog_util.lua:33-143`.

**Reproduction.** Open a menu-owned alert and make its deferred 100 ms focus
timer return uncommitted or throw. The alert itself still opens, but the focus
nudge never runs; the former protected call discarded the scheduling failure,
so exported logs contained no reason.

**Root cause and silence.** A best-effort cosmetic continuation had neither
explicit timer commitment nor retained cleanup/error reporting. The primary
dialog output survived, which is why this is Low rather than an output-loss High.

**Fix and regression test.** DialogUtil now owns the exact TimerScheduler result,
reports refusal/throw, fences the callback and retries cleanup debt without
hiding the alert. `tests/unit/lib/test_dialog_focus_is_async.lua` asserts the
alert remains visible, failure reaches the logger, and a refused timer is rolled
back rather than published.

---

## 3. Claims refuted or deliberately not promoted

Every row is itself a claim. The checked path/test is named so absence at the
wrong location is never laundered into a refutation.

| Candidate claim | Verdict and evidence |
| --- | --- |
| “The watchdog should kill every Karabiner process when Hammerspoon dies.” | **Refuted; that would be destructive.** `launcher/README.md:45-63`, `lease_contract.lua` and the whole-source isolation test establish token-scoped variable revocation. UI, Core Service/old grabber, console server, session agents, watchers/observers and VirtualHID are shared and remain user-managed. |
| “Killing the Karabiner UI is enough.” | **Refuted.** UI is neither the remapping authority nor an Ergopti-owned process. The effective rule is gated by the exact mode/tombstone variables; revoking those is both narrower and causally correct. |
| “A normal Lua shutdown callback covers Activity Monitor Force Quit.” | **Refuted.** `SIGKILL` cannot execute Lua cleanup. The independent launchd guardian and pipe/private-peer loss paths exist specifically for this case. Physical validation remains pending on macOS. |
| “Metrics OFF always caused KC backlog replay on the next ON.” | **Refuted as overbroad.** The 2026-07-21 `KcBridge.start()` EOF resync already discarded disabled-period bytes in the ordinary case. This does not dismiss three narrower reproduced failures: restart EOF refusal (`HS-H-48`), the partial persistence gate while secure filtering was OFF (`HS-H-54`), and cold-init untrusted EOF with already-live producers (`HS-H-55`). Their causal tests distinguish the absorbed control from each reachable failure. |
| “Terminal teardown never stopped the KC bridge before this pass.” | **Refuted.** The prior root path called keylogger `M.stop()`, which called `KcBridge.stop()`. Splitting feature `stop()` from process `shutdown()` preserves always-on cursor semantics and creates a clearer terminal owner; it is hardening, not a separate historical cleanup-absence finding. |
| Gesture teardown is safe once its taps stop | **Refuted unless held-click ownership is released first.** `modules/gestures/init.lua:828-835` invokes exact cleanup before disabling the subsystem; `test_gestures_stop_force_cleanup.lua` pins the matching mouse-up so quit/pause cannot leave a virtual button held. |
| “Disabling the ErgoptiPlus Karabiner menu may still start a guardian lease because stock Karabiner is installed.” | **Refuted at current source.** `test_menu_karabiner_disabled_isolation.lua` drives disabled state and asserts no lease/process side effect. Installation/presence is not ownership. |
| “There are no Hammerspoon logs, therefore prior measurements were fabricated.” | **Rejected as an invalid inference.** The resolved production directory and two fallback directories were checked and absent on this machine. The specifically inspected fallback files are harness artifacts. This proves only that no production artifact is available here. |
| “`D:/tmp/ErgoptiPlus_2026-08-13.log` is a production profile.” | **Refuted by opening it and its surrounding rows.** Injected fixture failures surround the profiler rows and the file continues to grow with the Windows test harness. Because it is mutable, earlier raw and de-duplicated counts are not frozen as final evidence. It is excluded from G4 measurement. |
| Logger still writes new-day entries to the startup-date file | **Refuted at final source.** `infra/logger.lua:583-614` recalculates the date before opening/appending; `test_logger_rollover_purge_integrity.lua` behaviorally separates day-A/day-B bytes. The same-class confirmed bug was missing new-day retention ownership, not rotation. |
| Tooltip still calculates an independent static hotstring match | **Refuted at final source.** `llm_bridge.lua` calls `Expander.resolve_magic_action()`; preview and dispatch consume its arbitration ledger. Expiry and native-hide ownership are separately covered by `HS-H-11`/`HS-M-08`, not a second matcher. |
| PersonalInfo preview may override a complete static trigger | **Refuted at final source.** `personal_info.lua` checks the engine's static claim and collecting state; `test_personal_preview_static_ownership.lua` compares rendered and emitted output for both owners. |
| A nil `io.open` handle proves `personal_info.toml` is absent | **Refuted.** It can also be permission denial or another read failure. Final `personal_info.lua:296-317` authorizes defaults only for exact `ENOENT`; the behavioral test preserves an unreadable existing file byte-for-byte (`HS-H-16`). |
| An `ENOENT`-looking final lookup proves any config pathname is safe to create | **Refuted.** The final name may sit behind a dangling link, an unreadable parent, a missing prefix or a component that is not a directory. `FileSystem.read_with_status()` requires an lstat-style component walk plus a successful parent listing that excludes the final basename; the multi-consumer matrix is `HS-H-17`. |
| Normalizing `link/../file` before resolving `link` is equivalent to POSIX pathname resolution | **Refuted behaviorally.** POSIX resolves the link first, so `..` applies to the link target. `test_file_system_atomic_write.lua:177-271,620-666` creates both possible targets, observes only the kernel-ordered one and proves the lexical foreign file remains untouched (`HS-H-18`). |
| Atomic rename alone prevents lost updates | **Refuted, and not fully repaired.** Rename prevents torn bytes, not a stale writer overwriting a newer complete file. The adapter's `{status, content}` recheck narrows the interval but cannot atomically bind the comparison to publication; `HS-H-18` remains open against non-cooperating writers. |
| A corrupt Karabiner config should silently reset so the menu remains usable | **Refuted as destructive.** Ordinary setters preserve and surface corrupt/unreadable bytes; only the explicit reset-to-defaults action is authorized to replace them. The absent, corrupt, unreadable and valid controls are enumerated under `HS-H-19`. |
| A protected `save_prefs()` call proves a menu preference committed | **Refuted.** `pcall` only proves no exception escaped; false and nil are ordinary failure results. Final menu callers require literal true, otherwise the boot-seeded state and represented runtimes roll back and success-only work is withheld (`HS-H-20`). |
| Provider/resolver failures require constructing one timer per failed event | **Refuted at final source.** Both producers enqueue numeric metadata into the bounded mailbox; one keymap-lifecycle pump owns all deferred delivery. `test_hid_diagnostic_mailbox.lua` asserts zero producer-side timer/logger/stringification work and no duplicate pump. |
| Any multi-codepoint string ending in `:` is a valid composite terminator | **Refuted.** Shared terminator tests accept only exact or known NBSP/NNBSP forms and reject unrelated prefixes/suffixes. |
| Input-source changes necessarily rebuild script-control during pause | **Refuted.** Pause/layout regeneration is serialized and the dedicated script-control tap remains the reachable lifecycle control. `test_regenerate_pause_guard.lua` drives paused regeneration refusal; script-control tests cover the reachable fallback. |
| Touchdevice should be activated before the first physical touch | **Refuted as contrary to the kernel gate.** The primer/first-touch wake model is intentional; no current production path was found that assumes pre-activation. |
| Ollama's historical `tmp_path` callback still binds a global nil | **Refuted at current source.** The local declaration precedes callbacks; `test_stream_tmpfile_declared_before_on_done.lua` pins declaration order rather than the mere presence of cleanup. |
| Every stale LLM callback is unguarded | **Refuted as overbroad, not used to dismiss exact races.** Action epochs and existing request generations already rejected many callbacks, while this reconciliation separately reproduced the missing tooltip session, remote-entry identity, live enable gate and MLX joined-waiter owners (`HS-H-23`–`HS-H-28`). A callback claim must name the precise producer identity and terminal mutation. |
| An ordinary HTTP health request A can always overwrite a newer request B | **Refuted for the transport owner.** `test_http_client_supersede_race.lua` already proves the shared client drops A after B supersedes it. `HS-H-25` is narrower and different: changing the selected remote entry without replacing every transport request required the entry generation/object identity too. |
| MLX warmup already ignores runtime disable | **Refuted as a current defect at the existing backend boundary.** `test_mlx_warmup_gated_on_disable.lua` proves the MLX warmup owner stops after disable. `HS-H-26` covered the sibling profile timer and model-switch completion that did not share that gate. |
| A model-request generation alone owns every model completion | **Refuted.** A backend selection is a sibling mutation that does not issue another model request. The final model switcher captures both identities and the behavioral test fires the old MLX callback after selecting API (`HS-H-21`). |
| Every raw `return value:gsub(...)` discovered in a recent fix is a current user-reachable bug | **Not promoted without a repro.** `1ee765fbd` parenthesizes `escape_toml_string()` so its API returns one value, and `tools/test/test-lua-gsub-single-return.cjs` causally guards the generic Lua foot-gun; the final replay passed all 50 return sites across 363 Lua files. However, both current callers already collapse the call to one value—one assigns to a local and one concatenates—so this audit found no reachable output change at the pre-fix site. It is caught recent-fix collateral, not a fabricated confirmed finding. |
| The late aggregate's `203` failures represented `203` product regressions | **Refuted by causal isolation and rerun at the prior baseline.** A shared `keymap.terminators` stub escaped the runner's prefix purge and generated 79 dependent errors (`HS-M-15`). After source-root isolation the late aggregate fell to `66`; production repairs plus fixture updates yielded `4,881/4,881` at exact `04e917cf`. That is not a current-working-tree total. The fixture-only commits `b314cc576`, `03f2aff84`, `c7814f39b`, `df8eb0a6f` and `76b9680ed` follow current guarded helpers, adapter ports, classified reads and lifecycle preconditions; none deletes an assertion or changes production. |
| An untracked personal shortcut or empty local directory proves driver-tree drift and should be normalized or deleted | **Refuted as a release-gate input bug.** The parity, source-tree and shared-LF guards now enumerate `git ls-files --cached`, which includes staged candidates but excludes unrelated local artifacts. `test-untracked-driver-artifacts-do-not-affect-gates.cjs` creates an untracked macOS tree with a CRLF Lua file and behaviorally requires all three gates to stay green. The user's `hammerspoon/personal_shortcuts.lua` and local empty directory were not modified, counted or used to raise a floor. |
| Updating the eventtap watchdog meta-test means watchdog recovery was removed | **Refuted.** `b314cc576` changes only the expected guarded shape: `pcall(hs.timer.new, ...)`, `eventtap_is_enabled(...)` and `start_eventtap(...)`. The production watchdog remains, while the test now observes the wrappers that report native failures instead of demanding their obsolete raw calls. |
| `utf8.offset`/`utf8.len` are used as guaranteed numbers on the audited keymap path | **Refuted for the inspected sites.** Calls are protected or nil-checked; `test_utf8_offset_pcall.lua` injects malformed input. This is bounded to inspected current sites, not a permanent whole-repo claim. |
| A deferred multi-token replacement can still be overtaken by the next physical input | **Superseded at the Quartz ordering boundary.** `SyntheticInput.claim_physical_fence()` at `adapters/synthetic_input.lua:2103-2140` adopts every older deferred payload, and `test_emit_tokens_multi_paste.lua:110-138` plus `test_action_epoch_reconciliation.lua:302-329` require those events before the physical key/click. This does not claim that the destination application synchronously acknowledges pasted text; that native timing remains runtime debt. |
| Hammerspoon and AHK word-boundary predicates must be made identical | **Deliberately rejected.** `PROJECT_MEMORY` records the intentional allowlist-versus-letter-denylist framing and its exotic-character-only divergence. The common preview/fire answer inside macOS is separately pinned by `test_would_fire_single_source.lua` and `test_preview_matches_engine.lua`; cross-driver alignment needs a concrete user requirement, not aesthetic symmetry. |
| Repeatable hotstrings must remain active in ignored/private windows | **Deliberately rejected.** Current `modules/keymap/init.lua:1030-1057` implements total pass-through before buffers, interceptors, preview or repeat dispatch. `test_ignored_window_deferred_buffer_snapshot.lua` drives that privacy contract. The surviving `_tc_is_ignored` local is dead cleanup, not authorization to reintroduce feature output in an ignored application. |
| `RulesEngine`'s byte-length suffix handling is a current Unicode user bug | **Not promoted: unreachable in production.** `modules/dynamic_hotstrings/rules_engine.lua:254` is byte-oriented, but every production rule registration is ASCII (`td`, `dt`, `date`) and no production caller adds a Unicode rule. This is latent API debt, not a reproduced user action. |
| A dynamic time/date preview necessarily diverges when midnight passes before fire | **Refuted for the current ownership model.** Mutable providers are snapshot-owned only after a visible action commits; without that exact lease dispatch resolves the live action. No cached second matcher or reproduced midnight divergence was found. |
| Every successful native operation must return literal `true` | **Refuted as an API-independent rule.** Application launch/activation and pasteboard writes are boolean contracts, but Hammerspoon documents `hs.window:focus()` as returning its window object. `test_activation_return_contract.lua:23-60` requires false to fail and the non-false object to succeed (`HS-M-18`). |
| The Karabiner menu still performs a synchronous shell status probe | **Superseded.** Current menu state derives from exact lease ownership; no `hs.execute` status probe remains in `menu_remap.lua`. This refutes the historical path, not every synchronous command elsewhere. |
| The production keyboard hook still silently loses every callback exception | **Not reproduced for the inspected wrapper.** The production `onEvent` boundary reports its guarded callback failures. This does not imply global async visibility: raw tasks and locally discarded `pcall` sites required the separate `HS-H-31`/`HS-H-32` fixes. |
| Batching DEBUG flushes proves the keyDown logger path is non-blocking | **Refuted by following the real call chain.** `tests/unit/test_hot_path_costs.lua:40-82` proves only that most DEBUG records skip `flush()`. `infra/logger.lua` still performs console output, `_ensure_log_file()`, `fh:write()`, topical routing and every fortieth flush before keyDown returns; WARNING/ERROR adds an immediate mirror and notification (`HS-H-34`, `HS-M-20`). |
| Installing timer runtime capture makes every async callback visible | **Refuted.** `infra/logger.lua` wraps `hs.timer.doAfter`, `hs.timer.new` and `hs.timer.delayed.new` only after installation. It does not cover raw `hs.task`, arbitrary watcher subscribers, pre-install callbacks or code that catches and discards its own error; `test_logger_runtime_capture.lua` pins the timer scope, while the other boundaries require local logged ownership (`HS-H-31`–`HS-H-33`). |
| The Swift guardian/native suite passed locally | **Not asserted.** It cannot run on this Windows host. Source-level inspection and CI wiring are not substitutes for a macOS result. |

---

## 4. Performance

### Provenance of runtime evidence

No production Hammerspoon profiler artifact was found under the resolved
`D:/Documents/GitHub/config/ergopti_plus/hammerspoon/logs/` path or the two
fallback locations. The specifically inspected `D:/tmp/ErgoptiPlus_2026-08-13.log`
and boot file are synthetic harness output.
Therefore this report contains **no production latency percentile, no production
slow-event count, and no measured boot duration**. G4 remains empirically open
until a macOS run supplies the real artifacts.

The cheapest check was performed before theorizing. The 2026-08-13 daily
fallback was still growing while the Windows harness ran, so its earlier size,
raw-match count and de-duplicated record count are deliberately not frozen here
as final evidence. The separately opened boot fallback had exactly zero `Slow`
matches. Neither file is promoted to user-performance evidence.

### Defensive eventtap/boot audit

| Path | Provenance | Result |
| --- | --- | --- |
| Synthetic classification/keymap/logger | Code-derived call graph: `onKeyDownRaw` shares one wall-clock read and provenance is in-memory, but accepted trigger and slow/error paths call `Logger` before `onKeyDown` returns. The real sink can synchronously reach console output, file open/write/routing and periodic or severity-driven flush/notification. The earlier logger-spy operation totals are omitted because no independently replayable artifact was retained. | **Open `HS-H-34`: the hot path is not non-blocking.** Native duration remains unmeasured; the finding is the reachable blocking call chain, not a fabricated operation or latency measurement. |
| Hotstring preview render | Code-derived: `llm_bridge.lua:914-1032` defers canvas/AX work through the timer scheduler and generation-fences it; the pre-paint expiry repair also re-resolves through a zero-delay timer at `859-885`. | Canvas construction is off the HID callback. Native scheduling/render cost unmeasured. |
| Provider/resolver diagnostics | Code-derived: `llm_bridge.lua:282-290` and `rules_engine.lua:159-160` enqueue numeric metadata into `hid_diagnostic_mailbox.lua`; capacity is 64 and the sole repeating pump interval is 250 ms. | Installed macOS HID producers allocate no timer, call no logger and do not stringify failure payloads. One lifecycle timer replaces per-failure timers; logger/cancel failures retain ownership for retry. This is a code/test complexity result, **not a measured 250 ms user-latency claim**. |
| Pause/remap transitions | Code-derived: script-control schedules native work after the callback and waits for exact ACK; remap generator/task work is asynchronous. | No audited pause path contains the old blocking kill loop. Portable whole-source guards passed in the final aggregate replay; native eventtap timing remains unmeasured. |
| Classified config I/O | Code-derived: `FileSystem.read_with_status()` walks O(path components + bounded symlink hops), and replacement revalidates pathname/source around one same-directory staging publication. Callers are boot, editors, menu actions and background storage—not the eventtap callback. | Stronger ownership adds bounded filesystem probes outside HID. Native APFS cost and permission-dialog behavior remain unmeasured. |
| Rejected menu preference rollback | Code-derived: rollback re-synchronizes represented modules and invalidates queued keylogger/LLM generations; hotstring group synchronization remains delta-only. | A failed user menu save may perform substantial recovery work, but no filesystem, AX or module resync occurs per keystroke. Recovery latency is unmeasured and requires a real AppKit failure-injection profile. |
| Keylogger midnight rollover | Code-derived: bounded batches drain until exact EOF and refuse deletion on any failed progress/outbox commitment. | Entered by a timer rather than eventtap, but still synchronous on Hammerspoon's main run loop; a large-journal duration and its effect on other callbacks remain unmeasured runtime debt. |
| Eventtap timeout recovery | Code-derived/native contract: Hammerspoon consumes disable notifications natively; keymap, keylogger and script-control retain watchdog restart backstops. | Source/test backstop present; actual `kCGEventTapDisabledByTimeout` injection not run here. |
| Boot/midnight log purge | Code-derived: `infra/logger.lua:286-320,379-382,611-612` defers purge and retains each one-shot timer. | Previously known synchronous boot cost remains off the boot critical path; new-day retention also stays deferred. No boot measurement. |
| MLX cleanup, dependency bootstrap and WebKit warmup | Code-derived: `init.lua:784-789`, `847-860` and `1251-1256` schedule these operations after the synchronous boot frame. `test_init_mlx_cleanup_after_taps.lua` and `test_init_deps_check_deferred.lua` pin the first two orderings. | Historical deferral remains in place; no synchronous return of these costs to the boot critical path was found. WebKit is scheduled after a 2-second delay; that delay is not the warmup cost. All three real costs remain unmeasured. |
| VS Code AX | Code-derived from current bridge and watch-list: 200 ms cache includes negative results; `test_vscode_bridge_ax_cache.lua` and `test_hot_path_costs_are_cached.lua` guard the cached path. | No uncached audited sibling found on the key path; runtime AX cost unmeasured. |

### Offensive optimizations implemented or reclassified

These are **code-derived complexity results**, not measured speedups. The logger
row is deliberately reclassified because adversarial replay disproved its prior
guard; the remaining rows have class guards in `tests/unit/test_hot_path_costs.lua`.

| Optimization | Prior/current complexity | Target now encoded | Regression risk |
| --- | --- | --- | --- |
| DEBUG log flushing | Prior: synchronous flush on every DEBUG line. Current: one synchronous write per accepted line plus a flush every 40 DEBUG lines, and immediate WARNING/ERROR work, all still reachable before keyDown returns. | **Target not met (`HS-H-34`).** Move persistence to one ACKed out-of-process writer; eventtap target is zero console/filesystem/notification calls. | Queue pressure, ordered fan-out, crash-tail durability, worker death and shutdown ACK ownership. The existing durability tests must remain. |
| Host architecture/version detection | Prior: `uname`/`sw_vers` subprocess probes on repeated calls, including boot. | One positive or negative memoized result per process (`_is_arm_cached`, `_macos_major_cached`). | Cache must remain process-scoped; OS/architecture cannot change in-process. |
| Gesture Spaces lookup | Prior: reload private binding and enumerate all Spaces on each gesture navigation. | Cache module and all-Spaces layout; read focused Space live. | Caching focused Space would break edge detection; tests explicitly require the live read. |
| Keydown clock | Prior: two wall-clock reads per key. | One `secondsSinceEpoch()` value shared by cache and inter-key calculations. | Callers must agree on the same event timestamp; no cross-event caching. |
| Magic-buffer allocation | Prior: concatenate `buffer .. magic` on every preview key even with no matching bucket. | Short-circuit allocation only when the star or bare-star tail bucket exists. | Bucket lookup must stay canonical and rebuild transactionally after registry changes. |

### Unmeasured optimization hypotheses

These are not findings and must not be implemented without a macOS profile:

- `tooltip_llm.lua` still performs styled-text sizing across reserved rows during
  streaming repaints. Hypothesis: cache session-invariant geometry and reduce
  repeated ObjC layout calls. Required evidence: `Tooltip.Render`/chunk profile,
  current versus target call count, and tests for localization, every selected
  row and font/color invalidation.
- keylogger rolling arrays still warrant a profile for head-removal behavior
  under a long session. Hypothesis: head indexes/deques reduce eviction from
  O(N) shift to O(1). Risk: WPM/backspace and midnight reset accounting.
- midnight journal draining currently performs up to the named bounded batch
  limit synchronously in one timer callback. Hypothesis: generation-fenced
  continuation timers could target O(one batch) main-loop occupancy per turn
  while retaining O(total rows) work. Risk: rows arriving between turns, date
  rollover ordering and deleting before exact EOF/outbox commitment; do not
  change this without a large-journal profile and the existing EOF tests.
- pause icon variants may benefit from pre-rendering both configured images.
  Required evidence: measured alternating-pause canvas/decode cost; risk is
  theme/logo/Retina invalidation.
- `ui/menu/menu_about.lua:239-244` synchronously runs `/bin/rm -rf` through
  `hs.execute` inside the asynchronous unzip completion. This is **code-derived
  and unmeasured**: it is outside eventtap, but still occupies Hammerspoon's main
  run loop. Hypothesis: move recursive cleanup to an owned asynchronous task.
  Required evidence: cleanup duration for realistic app backups; risk is reload
  racing cleanup or losing the exact temporary-directory owner.
- `platform/remap/onboarding.lua:85-89,553-568,642-669` polls every three seconds
  for up to 300 seconds: at most about 100 synchronous predicate rounds per
  wizard wait. This is a **code-derived complexity bound, not a measured cost**.
  Hypothesis: use a watcher or progressively back off only if a macOS profile
  shows meaningful main-loop occupancy. Risk: delayed permission detection,
  lost timer ownership and wizard steps firing after teardown.
- `platform/remap/watchers.lua:698-701,851-866` performs one synchronous
  `defaults read` at watcher start and another directly in the
  `hs.keycodes.inputSourceChanged` callback. This is a **code-derived call-count
  result (one child per seed/notification), not a measured lag or confirmed
  finding**. Hypothesis: reuse the existing generation-fenced
  `read_layout_async()` path for both sites, coalescing duplicate notifications
  and committing only the newest result. Target: zero synchronous subprocesses
  on Hammerspoon's main loop. Risk: Sequoia's stale TIS cache, startup's initial
  layout ownership, notification ordering and teardown of an in-flight read.

The next correct step is a real macOS boot plus multi-minute typing/tooltip
session, resolving `<config_dir>` first and running the cheap `Slow` count before
aggregation. Mean/max must be reported with the profiler's threshold censoring
and nested segments acknowledged.

---

## 5. `PROJECT_MEMORY` watch-list

| Watch-list invariant | Status at committed portable baseline `dafbcb591`; historical gate results remain attributed to their exact baseline |
| --- | --- |
| Closure references must be declared above async callbacks | **Fix in place** at the historical Ollama temporary-path site; retained as whole-class review rule. |
| `project_hs_synthetic_injection_choke_point` | **Fix strengthened.** One provenance transaction feeds keymap, keylogger, dynamic, gestures, shortcuts and LLM output. Whole-class interleaving tests present. |
| `project_suspend_pause_invariant` | **Same class found at two historical siblings and fixed.** Exact ACK transaction, rollback, paused action allowlist, keylogger sink and global-hotkey fences remain; keymap now discards text ownership on both pause edges (`HS-H-30`) and wake/unlock gesture kickstart checks suspension (`HS-M-19`). Native macOS runtime still pending. |
| `project_macos_eventtap_no_blocking` | **Regressed / same class found elsewhere (`HS-H-34`).** Preview/canvas and remap work leave the immediate callback, but the logger sink still performs synchronous console and filesystem work on keyDown. `doAfter(0)` is not a thread hop and is not an acceptable persistence fix. |
| `project_macos_script_control_tap_lifecycle` | **Fix in place.** Dedicated tap/watchdog and serialized layout regeneration remain. |
| Reload versus quit | **Fix in place.** One coordinator preserves the distinction and fences the exact lease before the terminal action. |
| `project_hs_karabiner_exact_lease_isolation` | **Architecture and memory aligned.** Ownership is the exact one-shot token, never a shared process family. The named `PROJECT_MEMORY` section records the independent launchd guardian, disabled-integration behavior, stock-process boundary and remaining native validation debt. |
| Abrupt host death | **Same class closed in source design.** Independent launchd guardian handles EOF/worker/launcher loss; physical macOS Force Quit remains a release test. |
| Logger midnight rotation and purge | **Same class resolved accurately.** Write-time rotation was already present; the added invariant is retained new-day purge ownership, confirmed-removal count and visible callback/timer failures. |
| Async callback errors must reach the file logger without blocking HID | **Visibility fixes are in place, but the sink half is open (`HS-H-34`).** `infra/logger.lua` wraps timers only after installation; raw tasks/watchers still need local boundaries. `ProcessLifecycle`, `TaskLifecycle` and gesture dispatch now report failures, while provider/resolver producers use the off-HID mailbox. The final Logger sink must stop doing its own I/O before eventtap return. |
| Startup must be one exact transaction | **Same class found and fixed across dynamic siblings.** PersonalInfo, RulesEngine, shared registry state and the root orchestrator use generation fencing, snapshot rollback and top-level fail-fast publication. |
| `project-macos-absence-needs-lstat-proof` | **Same class found across the late config surface; `HS-H-17` is fixed and `HS-H-18` is partial.** Component-order symlink resolution, final identity, create-only publication and cooperative source preconditions are centralized; consumers cannot infer absence from nil or local errno. The final check-to-rename interval remains open against non-cooperating writers. |
| Config mutation must commit disk before memory/UI/runtime | **Same class found in remap and menu siblings (`HS-H-19`, `HS-H-20`).** Remap setters publish detached candidates only after exact save; menu rollback is boot-seeded and invalidates deferred keylogger/LLM work. More than one hundred save sites are enumerated by the meta guard. |
| Keylogger rollover requires durable terminal proof | **Same class found and fixed (`HS-M-12`).** An empty batch is not EOF; read/seek/close failure preserves offset and `today.log`, and deletion additionally requires durable outbox state. |
| Callback errors may contain secrets | **Sibling damage fixed.** PersonalInfo save, dynamic startup/rollback and registry transaction diagnostics retain controlled labels/types while withholding callback payloads; the final privacy gate covers the value-carrying sink class. |
| Tooltip/engine single source of truth | **Fix and integrated follow-ups in place.** Resolver arbitration is unique; build-time expiry re-resolves, refused native hide retains the lease, and failed retry creation transfers cleanup to physical watchers. |
| Preview semantic mutations require revocation | **Fix in place.** Public writer class and dynamic writers are fenced; registry/menu transactions are exact. |
| `project_macos_llm_runtime_enable_gate` | **Same class found at later timer/completion boundaries and fixed (`HS-H-22`, `HS-H-24`, `HS-H-26`).** No Model is a committed empty runtime identity, and deferred warmup/unlock rechecks the live enable/pause gate. Profile/model restoration alone still does not authorize warmup. |
| Async completion identity must include sibling owners | **Same class found repeatedly and fixed (`HS-H-21`, `HS-H-23`, `HS-H-25`, `HS-H-28`).** Model requests include backend identity, tooltip frames include request session, remote callbacks include exact entry generation/object, and joined MLX waiters own both terminals. |
| Input-source rebuild during pause | **Fix in place.** Layout changes are serialized and do not destroy the lifecycle tap. |
| First-touch touchdevice primer | **Intentional.** Not “fixed” by pre-activation. |
| `project_hs_onboarding_config_schema` | **Existing fix retained.** This pass hardened config-directory durable commit; locale remains in `hs.settings`. |
| `project-ahk-unreadable-config-persists-defaults` | **Same class found across macOS and fixed (`HS-H-16`, `HS-H-17`, `HS-H-19`).** PersonalInfo and the central adapter distinguish proven absence from unreadable/corrupt/unowned paths; preferences, personal hotstrings/shortcuts, remap, app categories and device identity preserve existing bytes and publish no replacement. First-use runtimes such as device identity remain fenced until their own exact commitment. |
| AX frame cache | **Fix in place**, 200 ms including misses; no measured runtime claim. |
| Case-conform fast path / menubar dirty cache | **Fix in place** in inspected current paths; `test_case_conform.lua` and `test_hot_path_costs_are_cached.lua` guard the indexed/cache paths, while registry/menu rollback preserves their source state. |
| Clipboard publication requires exact all-type ownership | **Same class generalized and fixed (`HS-H-29`).** Every audited borrower distinguishes protected invocation from native commitment, owns the original UTI snapshot before mutation, arms restoration before Cmd+V and retains failed restoration for retry. |
| Native lifecycle/result contracts are API-specific | **Same class generalized and fixed (`HS-M-17`, `HS-M-18`, `HS-H-32`, `HS-H-33`, `HS-H-53`).** Process/task handles publish only after operational commitment; task and gesture callback errors reach the file logger; boolean APIs require true while `hs.window:focus()` accepts its documented object return. Chainable timer methods additionally require the independent native `running()` state verdict. |
| Recurring timer commitment is native state, not a chainable method return | **Same class found at four raw owners and fixed (`HS-H-53`, with inventory proof `HS-M-22`).** Keylogger, keymap, remap watcher and launcher guard publish only after `running() == true`, fence delivery, require `running() == false` on stop and retain refused cleanup debt. |
| KC producers, persistence authority and cursor trust are independent states | **Same class found and fixed (`HS-H-48`, `HS-H-54`, `HS-H-55`).** Ordinary Metrics OFF keeps the drain live while denying persistence and advancing the cursor; explicit terminal stop/restart and cold EOF failure remain untrusted until exact resynchronization commits. |
| Global teardown drains are dependent finalizers | **Same class found and fixed (`HS-H-56`).** Independent owners settle first; scheduler-wide cancellation cannot destroy a refusing owner's retry capability while the terminal action is still withheld. |
| Required runtime capabilities must commit before UI publication | **Same class found in Metrics and fixed (`HS-M-24`, `HS-M-25`).** Dashboards acquire the live-ingest subscription before WebView construction, and the master toggle cannot publish OFF without the required keylogger stop boundary. |
| Async UI identity must survive every native yield | **Same class found in Apps Metrics and fixed (`HS-M-26`).** Retained continuations capture generation plus exact WebView identity and recheck after WebKit yields, so a closed window cannot mutate its replacement. |
| Ignored/private applications are total pass-through | **Deliberate current contract.** No repeat, preview, keylogger or other Ergopti text feature runs there. The historical request to route repeat around the early return was rejected as a privacy/context regression. |
| Audit evidence reproducibility | **Applied.** Resolved paths are named, test logs are not production measurements, refutations cite their search surface, and native results are not claimed on Windows. |
| Test proof must be causal, not pcall-only | **Strengthened.** Pass 16 added the causal Healthcheck acquisition/retry assertions in `HS-M-27`; pass 17 replaced seven additional pcall-only lifecycle assertions with direct postconditions. The detector then reported zero pcall-only cases. |
| Shared native doubles must preserve independent state/read-back | **Same class found and fixed (`HS-M-28`).** The canvas double no longer maps elements and status methods to one generic function; intentional failures are local injections, and E2E output was checked for renderer errors as well as its exit status. |
| Shared port extensions must not change canonical method arity | **Same class found and fixed (`HS-M-14`).** Compare-before-write is an explicit macOS extension; canonical `FileSystem.write` remains the generated two-argument port. |
| Test-file isolation must follow source ownership, not namespace guesses | **Same class found and fixed (`HS-M-15`).** The runner evicts modules resolving under both production roots and behaviorally proves a leaked bare `keymap.*` stub cannot reach the next file. |
| Lua `gsub` returns both transformed text and replacement count | **Recent-fix collateral caught, not promoted as a runtime finding.** `1ee765fbd` restores the single-return API and the generic JS gate enumerates this class; current call sites already collapsed the value, so no user repro was claimed. |

---

## 6. Coverage register

Legend: **B** = audited and whitened within the stated boundary; **F** = finding
fixed above; **O** = confirmed open finding; **P** = partially fixed; **NC** =
not covered deeply/runtime enough for a safety claim.
“Dry” means a later source/refutation
pass found no new class; it does not mean every macOS scheduler interleaving was
executed.

| Zone | G1 robustness | G2 output | G3 race | G4 performance | G5 truth | Dry pass / limit |
| --- | --- | --- | --- | --- | --- | --- |
| Launcher, worker, launchd guardian, BLINDER | `HS-C-01` | `HS-C-01` | `HS-C-01` | Source-only B | N/A | Source-dry pass 5; Swift/runtime NC on Windows. |
| Karabiner lease contract/controller/generator/lifecycle | `HS-C-01`, `HS-H-02`, `HS-H-03`, `HS-H-19` | same | same | Source-only B | N/A | Lease source dry pass 5; remap-config transaction dry pass 10; no real Karabiner/launchd. |
| Stock Karabiner UI/Core/grabber/console/session/watchers/VirtualHID | B for non-ownership guard | B | B | N/A | N/A | Whole-source mutation guard dry pass 5; personal Karabiner runtime not started here. |
| SyntheticInput/EventProvenance/text sender | `HS-H-01`, `HS-H-08`, `HS-H-29` | `HS-H-01`, `HS-H-29` | `HS-H-01`, `HS-H-08`, `HS-H-29` | Code-shape B | N/A | Portable source/test dry pass 12; real CGEvent provenance NC. |
| Clipboard, ProcessLifecycle, TaskLifecycle and window adapters | `HS-H-29`, `HS-H-31`, `HS-H-32`, `HS-M-17`, `HS-M-18` | same | same except `HS-M-18` | Source/test contracts B; native timing NC | N/A | Whole-class source/test inventory and portable replay dry pass 12; native API failure injection NC. |
| TimerScheduler and native recurring-owner inventory | `HS-H-35`, `HS-H-47`, `HS-H-53`, `HS-M-22` | same | same | Source/test contract B; native scheduling NC | N/A | Adapter, raw-owner and inventory source/test dry pass 16; native scheduling remains NC. |
| Root boot/startup/teardown finalizer | `HS-H-36`, `HS-H-56` | same | same | Boot/teardown source audit only | N/A | Ordered startup rollback dry pass 15; dependent scheduler-wide finalizer source/test dry pass 16; real cold boot/terminal action NC. |
| Input-source broker and remap/keylogger subscribers | `HS-H-37` | `HS-H-37` | `HS-H-37` | Callback shape B | N/A | Whole-source setter inventory and broker behavior dry pass 15; native TIS delivery NC. |
| Keymap state/registry/utils/expander/terminators | `HS-H-07`, `HS-H-08`, `HS-H-12`, `HS-H-15`, `HS-H-29`, `HS-H-30`, `HS-H-34`, `HS-L-01` | `HS-H-01`, `HS-H-09`, `HS-H-12`, `HS-H-15`, `HS-H-29`, `HS-H-30`, `HS-H-34`, `HS-M-03`–`HS-M-05`, `HS-M-08` | `HS-H-01`, `HS-H-08`, `HS-H-12`, `HS-H-15`, `HS-H-29`, `HS-H-30`, `HS-M-03`–`HS-M-05`, `HS-M-08`, `HS-M-11` | **O: `HS-H-34`; native timing NC** | `HS-H-09`–`HS-H-12`, `HS-H-15`, `HS-H-30`, `HS-M-03`–`HS-M-05`, `HS-M-08` | Functional paths source/test dry pass 12; G4 reopened in pass 13 and is not dry. |
| Keylogger/context/privacy/storage/KC bridge | `HS-H-01`, `HS-H-03`, `HS-H-17`, `HS-H-31`, `HS-H-38`, `HS-H-39`, `HS-H-44`, `HS-H-45`, `HS-H-48`, `HS-H-49`, `HS-H-53`–`HS-H-55`, `HS-M-12`, `HS-M-17`, `HS-M-24` | same except `HS-H-03`, `HS-H-17`, `HS-M-17` | same except `HS-M-24` | Source/test B; native SQLite/FSEvents NC | N/A | Append/init/hardware/wake/KC persistence/cursor/root-owner and ingest-listener classes source/test dry pass 16; secure input and native SQLite/FSEvents NC. |
| Dynamic rules | `HS-H-10`, `HS-H-13`, `HS-H-15` | `HS-M-01`, `HS-M-03`, `HS-H-13`, `HS-H-15` | `HS-M-01`, `HS-H-13`, `HS-H-15` | Mailbox producer shape B; runtime NC | `HS-M-01`, `HS-H-10`, `HS-H-13`, `HS-H-15` | Transactional startup and resolver mailbox dry pass 7. |
| PersonalInfo | `HS-H-14`–`HS-H-16`, `HS-M-02` | `HS-H-14`–`HS-H-16`, `HS-M-02`, `HS-M-03` | `HS-H-14`, `HS-H-15`, `HS-M-02` | NC | Static/provider ownership, startup, read and save fences B | Unreadable/default transaction dry pass 8. |
| HID diagnostic mailbox | `HS-H-12`, `HS-H-13` | same | same | Producer/lifecycle complexity B; runtime scheduler NC | Diagnostic-only | Capacity, retry, overflow and timer ownership dry pass 7. |
| Tooltip facade/renderer/hotstring/LLM | `HS-H-05`, `HS-H-06`, `HS-H-11`, `HS-H-12`, `HS-H-23`, `HS-M-16` | same plus `HS-M-08` | same | Deferral shape B; canvas cost NC | `HS-H-05`, `HS-H-09`–`HS-H-12`, `HS-H-23`, `HS-M-08`, `HS-M-16` | Portable source/test dry pass 12; real canvas/AX NC. |
| LLM engine/backends/streaming/warmup/HTTP deadline | `HS-H-06`, `HS-H-08`, `HS-H-20`–`HS-H-28`, `HS-H-32`, `HS-H-42` | `HS-H-06`, `HS-H-20`–`HS-H-28`, `HS-H-42` | same plus `HS-H-32` | Network/boot source audit only | `HS-H-06`, `HS-H-20`–`HS-H-27` | Portable source/test dry pass 15; no live service/network campaign. |
| Pause/script control/shortcuts/global hotkeys | `HS-H-02`, `HS-H-03`, `HS-H-30`, `HS-H-41` | `HS-H-03`, `HS-H-30`, `HS-H-41` | same | Callback shape B; real tap NC | `HS-H-30` | Topology/start/rebind transactions source/test dry pass 15; real tap NC. |
| UI restore/deferred reload | `HS-H-43`, `HS-M-23` | same | same | Timer source/test B | N/A | Behavioral re-entry and lifecycle source/test dry pass 15; native AppKit reload NC. |
| Window/app filtering/VS Code bridge | `HS-H-07`, `HS-H-31`, `HS-M-17`, `HS-M-18` | same | same | AX cache source B, runtime NC | `HS-H-07` | Portable source/test dry pass 12; native AX/runtime NC. |
| Filesystem adapter/config paths/onboarding/path menu | `HS-H-04`, `HS-H-16`–`HS-H-18`, `HS-M-13`, `HS-M-14` | same | `HS-H-04`, `HS-H-17`, `HS-H-18` | Boot source B | N/A | General durable writes dry pass 3; PersonalInfo dry pass 8; absence/path class dry pass 9; cooperative CAS dry, but **P: `HS-H-18`** for non-cooperating check-to-rename writers; error/port contracts dry pass 11; real permission dialogs NC. |
| General menu preferences/runtime synchronization | `HS-H-20`, `HS-H-22`, `HS-H-24`–`HS-H-26`, `HS-H-50`, `HS-M-07`, `HS-M-17`, `HS-M-25` | same | same except `HS-M-25` | Delta-only group sync code guard B; runtime NC | `HS-H-20`, `HS-H-24`, `HS-H-25` | WPM transitive caller added in pass 15; required Metrics stop capability added in pass 16; AppKit and external service effects NC. |
| WPM widget/menubar | `HS-H-50` | `HS-H-50` | `HS-H-50` | Callback shape B; canvas runtime NC | N/A | Module plus menu caller source/test dry pass 15; real eventtap/canvas NC. |
| Typing Metrics dashboard | `HS-H-51`, `HS-M-24` | same | `HS-H-51` | Window/JS timing NC | N/A | Timer/window generation dry pass 15; required ingest subscription source/test dry pass 16; WebKit runtime NC. |
| Apps Metrics dashboard | `HS-M-24`, `HS-M-26` | same | `HS-M-26` | Window/JS timing NC | N/A | Required ingest subscription and exact window/generation continuation ownership source/test dry pass 16; WebKit runtime NC. |
| Healthcheck window | `HS-H-52`, `HS-M-27` proof integrity | same | same | Window/JS timing NC | N/A | Poller and double-yield ownership dry pass 15; nil-poller causal proof repaired pass 16; WebKit runtime NC. |
| Logger/hotpath/boot profiler | `HS-M-06`, `HS-H-12`, `HS-H-13`, `HS-H-31`–`HS-H-34` | same | `HS-H-12`, `HS-H-13`, `HS-H-31`–`HS-H-33` | **O: `HS-H-34`; no production artifact** | N/A | Retention dry pass 3 and mailbox ownership pass 7; callback capture inspected pass 12; sink performance reopened in pass 13 and is not dry; multi-day runtime NC. |
| Regression/meta/integrity/encoding/privacy gates | `HS-M-09`, `HS-M-10`, `HS-M-11`, `HS-M-15`, `HS-M-22`, `HS-M-23`, `HS-M-27`, `HS-M-28`, `HS-L-02`, `HS-L-03` as proof quality | same | same | **O: `HS-M-20` proof integrity** | `HS-M-28` | Timer/re-entry and canvas-double false greens repaired through pass 17; portable aggregate became dry on pass 18, while logger hot-path proof remains open. |
| Gestures/touchdevice | `HS-H-33`, `HS-H-40`, `HS-H-46`, `HS-M-19`, `HS-M-21` | same | same | Spaces cache B; gesture frame runtime NC | N/A | Primer/wake/sticky/click ownership source/test dry pass 15; hardware/first-touch NC. |
| Dialog utility | `HS-L-04` | Primary output B; cosmetic focus degraded only | `HS-L-04` | Native focus timing NC | N/A | Deferred focus ownership and visible failure source/test dry pass 16; real AppKit focus NC. |
| Updater, crash reporter, remaining file/menu watchers, i18n | Pattern/sibling B or NC by module | same | same | NC | N/A | Updater timer transaction covered by `HS-H-35`; remaining native runtime zones are explicitly NC. |

### Broken state × action cells proven, including open/partial boundaries

| State | Action | Pre-fix result | Guard now |
| --- | --- | --- | --- |
| Ergopti remap active; HS or launcher `SIGKILL` | Type | Ergopti mapping could remain after app disappearance | Independent exact-token guardian fence (`HS-C-01`). |
| Ergopti integration disabled; stock Karabiner active | Toggle/menu/quit | Broad ownership could stop user's Karabiner | No lease and stock isolation guard (`HS-C-01`). |
| Synthetic replacement pending | Physical exact char, `Cmd+V`, Backspace | Physical event drained owned expectation | Immutable provenance + physical fence (`HS-H-01`). |
| Quit/reload pending | Second terminal request / teardown failure | Premature exit or lost cleanup handle | Serialized coordinator + retry transaction (`HS-H-02`). |
| Pause/resume transition | Rapid reverse or subsystem failure | Split native/local state and false success UI | ACK-gated rollback transaction (`HS-H-03`). |
| Config destination unwritable | Confirm editor/onboarding | Reload/success with nondurable path | Atomic writer and exact result (`HS-H-04`, `HS-H-18`). |
| Native canvas show/hide fails | Press Escape/magic key | Invisible surface owns key or visible promise loses owner | Native read-back + retained lease (`HS-H-05`). |
| Headless E2E uses the shared canvas double | Render/hide/update tooltip while replaying keys | Expansion assertions pass while renderer ERROR lines expose function-valued elements and non-boolean visibility | Stateful native-shape double plus locally injected crash fixture (`HS-M-28`). |
| LLM callback late | Reset/pause/new physical action | Stale result repaints/mutates | Action epoch + request/UI owner (`HS-H-06`). |
| Focus unknown/ignored | First key before classification settles | Text context crosses applications | Window quarantine (`HS-H-07`). |
| Competing hotstring kinds | Observe row, press magic | Preview and engine choose different output | One arbitration ledger (`HS-H-09`). |
| Preview visible | Change trigger/delay/group/data | Old pixels promise new semantics | Mutation waits for preview revocation (`HS-H-10`). |
| Timed tooltip winner expires; native hide refuses | Retry cleanup | Old pixels lose their action lease or all cleanup ownership | Retained lease plus timer→physical-watcher handoff (`HS-H-11`). |
| Preview provider throws | Type matching buffer | Dynamic row silently vanishes; first diagnostic repair could leak its exception | One off-HID redacted report plus static fallback (`HS-H-12`). |
| Shared dynamic resolver throws | Preview/fire matching suffix | Failure looks like no-match and can suppress the feature | One off-HID redacted report; healthy sibling remains exact action (`HS-H-13`). |
| PersonalInfo save boundary fails | Submit editor | Live secret/disk/pixels/editor diverge | Preview-fenced staged publication and exact editor commit (`HS-H-14`). |
| Dynamic startup registrar appends then refuses/throws | First trigger, then retry start | Half-published callbacks/rules survive and duplicate the retry generation | Token-gated inert rollback, registry snapshot transaction and top-level fail-fast (`HS-H-15`). |
| Existing PersonalInfo file is unreadable; parent remains writable | Start dynamic hotstrings | Access failure looks absent; defaults can replace committed user data before callbacks start | Exact-`ENOENT` default gate, exact read/close and default publication before callbacks (`HS-H-16`). |
| Existing config path is dangling, a directory, unreadable or replaced during read | Boot/open editor/start keylogger | Unsafe path looks absent; defaults/new identity can replace or bypass user state | Component lstat + parent-listing absence proof, identity revalidation and create-only publication (`HS-H-17`). |
| Config pathname contains `link/../file`, retargets, or changes after staging | Save any TOML-backed edit | Wrong pathname or stale complete candidate overwrites foreign/newer bytes | POSIX-order resolution and cooperative pathname/source preconditions (`HS-H-18`); **partially fixed:** a non-cooperating writer can still publish in the final check-to-rename interval. |
| Hotstring menu is visible after callback-schema migration | Click enable/disable/delete | Clickable item silently does nothing | Builder consumes the returned callback table and the behavioral menu test invokes every action (`HS-M-07`). |
| PersonalInfo transaction callback throws with a secret-bearing payload | Save/start/rollback | File logger can persist private field values | Diagnostic boundary emits controlled labels/types only; privacy sink gate drives the failure (`HS-M-09`). |
| Remap config is corrupt or its writer refuses | Change tap/hold/combo/timeout or enable integration | Recoverable bytes overwritten, live setter diverges, or lease remains active without committed preference | Decoded source snapshot, detached candidate, READY/save/STOPPED transaction (`HS-H-19`). |
| First menu preference save fails | Toggle updater/LLM/keylogger/gesture/shortcut/global control | Runtime, hotkeys, queued work and menu advertise a value absent from disk | Boot-seeded in-place rollback, runtime re-sync, generations and exact-success caller class (`HS-H-20`). |
| MLX model requirements pending | Switch backend without another model request, then deliver old callback | Old MLX model commits into sibling backend or predictions stay locked | Request token + captured backend identity; backend invalidation releases abandoned lock (`HS-H-21`). |
| LLM disabled; preference or backend setup fails | Click Enable, then deliver late/double MLX completion | Backend work can outlive a rejected save, or a failed/stale setup can publish enabled state and duplicate side effects | Commit-before-setup, activation generation/backend identity, exactly-once settlement and durable compensation (`HS-H-22`). |
| Request A tooltip visible on row two | Deliver same-request token frame carrying row one, then Enter | Producer repaint silently undoes physical selection or engagement | Session-owned cursor and generation (`HS-H-23`). |
| Backend ready but No Model selected | Type prediction context | Old/first model can still warm, fetch or render behind the disabled-looking menu | Transactional empty runtime identity and non-empty model gate (`HS-H-24`). |
| Remote entry A request pending | Select B/No Model, then deliver A callback | A marks B ready or publishes/fails B's current request | Entry generation plus exact object identity (`HS-H-25`). |
| Deferred profile/model work queued while enabled | Disable/pause before callback | Old timer/completion warms or re-enables predictions | Live runtime gate at side-effect boundary (`HS-H-26`). |
| Stream has parseable partial text | Curl exits non-zero | Truncated output is published as a valid prediction | Transport success checked before residual parse (`HS-H-27`). |
| MLX startup has joined callers | Throw/fail before readiness | Primary unlocks but joined prediction locks remain forever | Two-terminal waiter drain and exact server teardown (`HS-H-28`). |
| Long replacement owns a non-text clipboard | Native write/restore returns false after mutation | Trigger is consumed with no output and original UTI data can be lost | Exact-result, all-type retained clipboard transaction (`HS-H-29`). |
| Keymap paused with a partial trigger | Type while paused, resume, continue | Unobserved text joins the old buffer and preview/fire lies about screen text | Discard text and boundary ownership on both pause edges (`HS-H-30`). |
| Keylogger has stale non-secure context | Activate private/password context and make refresh throw | Keys can persist while callback failure is absent from file log | Logged subscriber isolation, context-first update and secure fail-closed startup (`HS-H-31`). |
| Native task action starts | Constructor/start refuses or callback throws | Nil crash, permanent in-flight latch or Console-only failure | Whole-tree `TaskLifecycle` contract and lower-level `ShellRunner` owner (`HS-H-32`). |
| Keyboard-backed gesture recognized | Shared emitter returns false/throws | Gesture is consumed but emits nothing and logs nothing | Exact result raised into the existing logged action boundary (`HS-H-33`). |
| Keymap active; runtime logging accepts the record | Fire an expansion, hit a slow key, or trigger a callback error | Console/filesystem/notification work runs before keyDown returns and can stall or disable the tap | **Open:** move the complete sink behind an ACKed out-of-process writer; a timer-only pump is insufficient (`HS-H-34`, proof gap `HS-M-20`). |
| Timer acquisition partially activates | Start feature, then make rollback refuse | Truthy cleanup handle is published as an active timer or discarded | `(handle, committed)`, native state probe and retained exact debt (`HS-H-35`, `HS-H-47`). |
| Cold boot after one input subsystem committed | Make the next required subsystem refuse | Boot advertises a partial keyboard control plane | Ordered startup transaction and reverse rollback (`HS-H-36`). |
| Keylogger and remap both active | Switch input source | Last setter silently evicts the sibling listener | One broker multiplexes stable subscriber IDs (`HS-H-37`). |
| Keylogger init or append storage boundary refuses | Enable Metrics / type / stop | Enabled UI without ingest, or detached snapshot lost on normal Lua write failure | Init/append transactions and exact FIFO ownership (`HS-H-38`, `HS-H-39`). |
| Gesture primer/wake owner partially starts | Enable, sleep/wake, or stop | Gesture layer reports active with no primer, or stale wake output fires | Composite recurring-owner transaction (`HS-H-40`). |
| Shortcuts OFF, paused, or changing layout | Cold start/rebind/toggle | Script control disappears or disabled configurable hotkeys resurrect | Split persistent/feature topology plus transactional start/rebind (`HS-H-41`). |
| HTTP request ready to dispatch | Deadline acquisition refuses | Network work remains live forever without an owned timeout | Timeout commits before dispatch and blocks successor on debt (`HS-H-42`). |
| UI editor open/reload re-entered | Request reload/restore and refuse timer | Reload or restored window is silently lost | Exact timer owner plus one later re-entry opportunity (`HS-H-43`, `HS-M-23`). |
| Keylogger dependency/hardware startup partial | Enable Metrics | Keyboard tap runs without trusted context or only some sensors | Exact init propagation and reverse hardware rollback (`HS-H-44`). |
| Keylogger stopped after wake/unlock | Deliver queued AX continuation | Disabled feature recreates context work | Hardware generation owns and cancels the wake continuation (`HS-H-45`). |
| Click-hold requested | Make either release tap refuse | Synthetic mouseDown leaves macOS held with no recoverable release path | Both taps proven enabled before output; exact release debt retained (`HS-H-46`). |
| KC bridge after explicit terminal stop | Request restart, refuse EOF open/seek/close, then recover | Old physical rows are stamped as current app/time | Failed restart retains the stopped/inactive producer transaction until exact EOF resync commits; ordinary Metrics OFF intentionally leaves the drain producers live (`HS-H-48`). |
| Root keylogger timer state mismatches chainable result | Enable/OFF Metrics | Enabled engine lacks watchdog/context, or stopped engine has live callbacks | Running probes, runtime generation and all-sibling rollback (`HS-H-49`). |
| WPM menu preference saved ON | Timer/eventtap start refuses | Checked preference advertises a widget that cannot run | Module transaction plus caller-side compensating OFF save (`HS-H-50`). |
| Metrics window opens with timer refusal / stale callback | Open, close, reopen | Blank window or old JS state mutates replacement | Window-owned timers and exact generation (`HS-H-51`). |
| Healthcheck A has pending WebKit completion | Close A, open B, deliver A=`true` | A copies stale data and deletes B | Ownership rechecked inside the second async callback (`HS-H-52`). |
| Raw recurring timer starts/stops with a chainable object but unchanged native state | Enable/disable keylogger, keymap, remap watcher, or launcher guard | Missing producer is reported active, or a discarded live timer mutates after stop beside a successor | Independent `running()` proof, commit fence and retained exact cleanup debt (`HS-H-53`). |
| Metrics OFF while KC drain remains intentionally live | Disable secure filtering, disable Metrics, append and drain one KC row | Partial context gate persists disabled-period input | Root-injected canonical persistence predicate discards while advancing the exact cursor (`HS-H-54`). |
| Cold KC init cannot prove EOF while producers are already live | Enable Metrics, restore reads, append one new row, then drain | Byte-zero cursor replays historical rows with current context | Separate trusted-cursor state; every persistence-enabling start retries exact EOF proof even with live producers (`HS-H-55`). |
| Controlled terminal action with one refusing owner | Let a sibling settle while keymap refuses, then retry | Independent global timer drain destroys retry/diagnostic capability although Lua remains alive | Scheduler-wide drain is a dependent finalizer and runs only after every owner commits (`HS-H-56`). |
| Metrics dashboard ingest subscription refuses | Open Typing or Apps | A published window never receives future ingest refresh | Required lifetime subscription commits before any WebView construction (`HS-M-24`). |
| Metrics ON with required stop capability missing | Click master item OFF | Saved unchecked UI coexists with capture that was never stopped | Direction-specific start/stop capability is required before mutation or persistence (`HS-M-25`). |
| Apps dashboard A has deferred continuation | Close A, open B, then deliver A focus/close/WebKit callbacks | A mutates or clears replacement B | Retained timers plus exact generation/webview identity at every yield (`HS-M-26`). |
| Healthcheck poller acquisition returns nil | Invoke the real navigation callback twice | Test stays green even if no poller was acquired or retryable | Causal assertion counts both acquisition attempts and rejects nil publication (`HS-M-27`). |
| Alert is visible but deferred focus scheduling refuses | Open a menu-owned alert | Focus nudge disappears with no file-log reason | Exact scheduler result is retained/reported while the primary alert remains visible (`HS-L-04`). |
| Tooltip row one visible | Press Down then immediate Enter | Enter observes the pre-navigation row before deferred repaint | Synchronous cursor commit; deferred canvas only (`HS-M-16`). |
| Process lifecycle inactive | First start/stop/subscribe refuses, then retry | Failed handle is published or exact cleanup owner is lost | Transactional acquisition and retained cleanup debt (`HS-M-17`). |
| Previous-app/Finder fallback active | First activation API returns false | Protected-call success suppresses the next successful fallback | API-specific operational-result normalization (`HS-M-18`). |
| Gestures suspended | Deliver wake/unlock | Cursor moves and synthetic scroll posts during global pause | Enabled-and-not-suspended gate at every kickstart entry (`HS-M-19`). |
| Midnight keylogger journal read/close fails | Automatic rollover | Empty failure result is accepted as EOF; `today.log` is deleted with un-ingested rows | Explicit `batch`/`eof`/`failed` status and exact EOF plus durable-outbox gate (`HS-M-12`). |
| Configuration-directory publication fails | Confirm a new path | Rollback is correct but the caller receives only generic `atomic write failed` | Concrete adapter reason survives protected return and reaches the editor (`HS-M-13`). |
| Dynamic mutable resolver visible | Press magic | Second evaluation types different value | Single-use snapshot lease (`HS-M-01`). |
| Immediately after PersonalInfo expansion | Start next `@` combo | Fixed delay drops physical `@` | Synchronous provenance release (`HS-M-02`). |
| French layout composite punctuation | Fire dynamic/repeat/static | Sibling consumers disagree/delete wrong length | Shared composite matcher (`HS-M-03`). |
| Text-equal mapping with `{Tab}` | Fire | Token side effect erased as no-op | Semantic no-op check (`HS-M-04`). |
| Multi-section/group mutation fails midway | Click menu action | Partial registry plus false checkmark/save | Snapshot rollback + publish gate (`HS-M-05`). |
| Registry transaction callback throws private text | Mutate group/rules through a transactional action | State rolls back but private payload reaches disk log | Controlled label/type only; callback payload withheld (`HS-M-11`). |
| Process spans midnight | First new-day write/purge | Rotation works, but newly stale logs survive until restart and purge failures lie silently | Existing write-time rotation + retained new-day purge (`HS-M-06`). |
| Literal expires between resolve and paint | Observe tooltip | Fallback is live but still rendered dimmed | Abort generation and re-resolve before canvas (`HS-M-08`). |

### Explicit limitations and release evidence still required

- Run the Swift launcher package tests on macOS, including real process groups,
  launchd guardian registration/approval, worker EOF, parent/inner `SIGKILL`,
  bounded `karabiner_cli` timeout and stock sibling survival.
- Build the actual app and Force Quit (1) embedded Hammerspoon and (2) the outer
  launcher from Activity Monitor while typing. Verify Ergopti remaps disappear
  promptly and a separately configured stock Karabiner mapping continues.
- Repeat the Force Quit with Ergopti's Karabiner integration disabled. Verify no
  Ergopti guardian lease is created and no stock process is signaled/restarted.
- Run real `hs.eventtap`, `hs.canvas`, Accessibility, secure-input, sleep/wake,
  layout-switch, multiple-keyboard and first-touch gesture scenarios.
- Implement and behaviorally validate the `HS-H-34` out-of-process logger sink
  before claiming the eventtap path non-blocking. On macOS, inject slow/unwritable
  sinks, force worker loss and queue pressure, and verify exact ACK/retry order,
  zero pre-return side effects and watchdog-free continuous typing.
- Replay the classified-path/create-only/POSIX-order matrix on APFS with real
  `hs.fs.symlinkAttributes`, dangling links, permission denial and two processes
  racing publication. Include `SIGKILL` of a process holding the stable adjacent
  write-lock inode through `hs.fs.lock`, then require a second Hammerspoon
  process to acquire it within a bound. The Windows host's injected
  identities/lock owner are causal tests, not a native filesystem result.
- Failure-inject one real AppKit menu save after boot and verify runtime hotkeys,
  LLM/profile state, gesture registries and any queued keylogger start visibly
  return to the last committed values without a success notification.
- Capture real production hotpath and boot profiles from the resolved config
  path. Do not reuse `D:/tmp` harness output.
- Preserve the prior-baseline gate provenance separately: source encoding was
  re-derived at `04e917cfddda0e291b48fe513779ed60a7a623d8`, where the clean
  JavaScript aggregate passed `172/172` and portable Lua passed `4,881/4,881`.
  The current committed portable baseline is independently recorded above at
  `dafbcb591e073811c8c1e4b4f3bc39482ec1c4de`: JavaScript passed `173/173`,
  portable Lua passed `5,218/5,218`, and E2E passed `64/64` with one documented
  skip. Neither historical nor current portable gates substitute for native
  macOS runtime evidence.

The safe reading of this report is bounded: each promoted finding has a concrete
cause/reproduction and an implemented or required causal test; 86 are fixed in
the cited patchset, `HS-H-18` is only
partially fixed for the explicitly retained non-cooperating-writer race, and
`HS-H-34`/`HS-M-20` remain open rather than being hidden behind a timer-only
prototype. A
`B` cell means the named source/test boundary was audited, never that macOS
scheduling and hardware behavior were simulated perfectly on Windows.
