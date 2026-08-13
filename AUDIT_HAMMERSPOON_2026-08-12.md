# Adversarial audit and hardening report — Hammerspoon macOS driver — 2026-08-12

## 1. Executive summary

**Scope.** This report covers `static/ergopti_plus/macos/`, its launcher/BLINDER
boundary, and the `static/ergopti_plus/_shared/` data and Lua consumed by the
macOS driver. The final source baseline is
`04e917cfddda0e291b48fe513779ed60a7a623d8`; all production changes through
that revision were opened and re-derived directly.

This was an audit-and-fix campaign, not a read-only review. Each promoted issue
below has a reachable action/state sequence, a root-cause explanation, and a
named regression test that drives the affected production boundary. At this
baseline the ledger contains **41 confirmed findings: 40 fully fixed and one
(`HS-H-18`) only partially fixed: 1 Critical, 22 High, 15 Medium and 3 Low**. A
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

**Verdict.** The source and portable Lua tests establish materially stronger G1,
G2, G3 and G5 invariants than the pre-audit revision. The global claim “no user
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
    fixtures through a final zero-failure aggregate run.

### Evidence baseline

| Artifact | Re-derived result |
| --- | --- |
| Source baseline | `04e917cfddda0e291b48fe513779ed60a7a623d8` (final audited production and test content; 60 commits after the campaign baseline `54d7051f4`). |
| Prior report | `AUDIT_HAMMERSPOON_2026-08-08.md` was used only as a candidate ledger. Claims below were rechecked against current source/tests; unresolved old prose was not copied as current fact. |
| Config path | `C:/Users/admin/AppData/Roaming/Ergopti/paths.toml` currently resolves `ConfigDirPath` to `D:/Documents/GitHub/config/ergopti_plus/`. |
| Production Hammerspoon log target | Code and config resolve it to `D:/Documents/GitHub/config/ergopti_plus/hammerspoon/logs/`. That directory was absent on this host. The fallback paths `C:/Users/admin/.config/ergopti_plus/hammerspoon/logs/` and `C:/Users/admin/.hammerspoon/logs/` were also absent. This is not a claim that the driver has never logged. |
| `D:/tmp/ErgoptiPlus_*.log` | Present, but inspection shows test-worktree paths, deliberate canvas failures, console tee duplication, and synthetic `Slow keydown … (a)` probes. These are harness artifacts, not a production user session, and no latency claim below is derived from them. |
| Boot artifact | `D:/tmp/ErgoptiPlus_boot.log` had no `Slow` match when checked, but it is likewise a test/fallback artifact and cannot prove production boot cost. |
| Final mailbox/lifecycle Lua tests | Direct final-source runs passed `50/0`: mailbox `10`, provider `1`, resolver `1`, keymap start `22`, TimerScheduler `16`. |
| Final dynamic-transaction Lua tests | Direct final-source runs passed `17/0`: RulesEngine start `5`, root orchestrator start `3`, trigger synchronization `2`, registry transactions `7`. |
| PersonalInfo read/start transaction | Behavioral red/green artifact: before the fix, the module was `2 passed / 2 failed`; at final source the same four-test module is `4 passed / 0 failed` (`4/4`). The final module was also re-run directly in this reconciliation. |
| Late filesystem/remap/preferences/LLM matrices | Through `04e917cfd`, the production branches and exact assertions in `test_file_system_atomic_write.lua`, remap's three config/lease modules, `test_preferences_save_transaction.lua`, `test_llm_activation_save_gate.lua`, `test_menu_preference_calls_fail_closed.lua`, the keylogger identity/rollover modules, the model-backend guard and their named sibling tests were opened and reconciled line-by-line. |
| Late LLM behavioral replay | Direct final-source runs passed `3/0`: backend-switch invalidation `1`, recommended-profile refuse/accept decisions `2`. The earlier filtered aggregate attempt timed out during discovery and is not counted as a run result. |
| Final aggregate Lua gate | Fresh POSIX checkout at exact `04e917cf`, Lua `5.4.6` plus LuaFileSystem `1.9.0`: **751 modules, 4,881 passed, 0 failed, exit 0**. Stderr contained only the deliberately injected fixture command `ls /no/such/dir`. This is portable Lua evidence, not a real Hammerspoon/macOS runtime result. |
| Comparative suite archaeology | With the corrected source-root isolation helper applied to the campaign baseline, the aggregate was `729` modules / `4,713` pass / `23` fail. On late current code before the runner fix, cross-file pollution inflated the result to `203` failures; purging the leaked shared modules reduced it to `66`, and causal production/fixture repairs brought the exact final checkout to `0`. These are test-run counts, not user-runtime measurements. |
| Hammerspoon E2E | `npm run test:hs:e2e` passed `64/64`; one explicitly driver-specific corpus vector was skipped. This is the portable virtual-keyboard harness, not real macOS eventtap/canvas evidence. |
| Repository gates | `npm run lint:conventions:strict` passed; `npm run test:hs-integrity` passed `14/0`; a final-baseline replay of `npm run test:source-encoding` scanned 2,947 text assets clean; `npm run test:find-false-greens` reported `0`; the privacy gate judged 18 Windows trigger-carrying sinks and 12 Lua value-carrying sinks, with 8 Lua sinks reduced/redacted. |
| Aggregate JavaScript gate | A clean third `npm run test:js` at exact final source exited `0` in `545.4 s`: **`All 172 JS check(s) passed.`** The earlier `170/172` and `169/172` runs were contaminated by an empty untracked runtime artifact at `static/ergopti_plus/macos/hammerspoon/` recreated by a concurrent Windows-Lua replay; the second also encountered a Linux build-copy failure. The artifact was verified inside the integration worktree, the concurrent runner was stopped, the artifact was absent for the clean run, and isolated driver-parity/source-scan reproductions had already passed. Those two runs are chronology, not the verdict. |
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

Karabiner/lease source became dry on pass 5 for the inspected ownership class;
keymap/provenance and pause became dry on pass 4; the reconciled tooltip/G5
follow-ups became dry on pass 6; config-path persistence and logger retention
became dry on pass 3; off-HID diagnostics and dynamic startup became source/test
dry on pass 7; PersonalInfo read/default publication became source/test dry on
pass 8; central filesystem/config ownership became source/test dry on pass 9;
the remap-config and represented menu-preference transaction classes became
source/test dry on pass 10; the inspected model/backend completion identity also
became source/test dry on pass 10; aggregate runner isolation and residual
classification became dry on pass 11. LLM service integration, actual
Accessibility/canvas behavior, touch hardware, multi-day runtime and native
launchd scheduling remain runtime coverage debt.

---

## 2. Confirmed findings and implemented fixes

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
ordering and cleanup were independent. Async callback throws normally escape to
the Hammerspoon console, while non-true UI/timer returns are not throws at all.

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
`write_if_unchanged()` now take the same stable adjacent non-blocking
`hs.fs.lock` before staging, comparison and rename. That closes the gap among
cooperating Ergopti replacement writers, including unconditional reset, while
contention fails visibly and no stale lock is reclaimed: Darwin releases the
process-associated `fcntl` lock on process death and the empty lock inode stays
in place. Behavioral tests inject a second conditional writer and an
unconditional sibling precisely inside the former compare/rename gap, assert
zero loser renames, verify lock-before-read-before-release ordering, and prove a
rename failure does not strand the next writer. The non-cooperating-writer and
native crash/APFS limits above remain.

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
pollution; the exact final checkout passes `4,881/4,881`.

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
then scanned 2,947 text assets clean at the final baseline; that byte-level ratchet is the
non-regression test for this class.

---

## 3. Claims refuted or deliberately not promoted

Every row is itself a claim. The checked path/test is named so absence at the
wrong location is never laundered into a refutation.

| Candidate claim | Verdict and evidence |
| --- | --- |
| “The watchdog should kill every Karabiner process when Hammerspoon dies.” | **Refuted; that would be destructive.** `launcher/README.md:45-63`, `lease_contract.lua` and the whole-source isolation test establish token-scoped variable revocation. UI, Core Service/old grabber, console server, session agents, watchers/observers and VirtualHID are shared and remain user-managed. |
| “Killing the Karabiner UI is enough.” | **Refuted.** UI is neither the remapping authority nor an Ergopti-owned process. The effective rule is gated by the exact mode/tombstone variables; revoking those is both narrower and causally correct. |
| “A normal Lua shutdown callback covers Activity Monitor Force Quit.” | **Refuted.** `SIGKILL` cannot execute Lua cleanup. The independent launchd guardian and pipe/private-peer loss paths exist specifically for this case. Physical validation remains pending on macOS. |
| “Disabling the ErgoptiPlus Karabiner menu may still start a guardian lease because stock Karabiner is installed.” | **Refuted at current source.** `test_menu_karabiner_disabled_isolation.lua` drives disabled state and asserts no lease/process side effect. Installation/presence is not ownership. |
| “There are no Hammerspoon logs, therefore prior measurements were fabricated.” | **Rejected as an invalid inference.** The resolved production directory and two fallback directories were checked and absent on this machine. `D:/tmp` contains test artifacts. This proves only that no production artifact is available here. |
| “`D:/tmp/ErgoptiPlus_2026-08-12.log` is a production profile.” | **Refuted by opening it.** It contains synthetic canvas failures, worktree paths, repeated console tee rows and deliberate `Slow keydown … (a)` test probes. It is excluded from G4 measurement. |
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
| Input-source changes necessarily rebuild script-control during pause | **Refuted.** Pause/layout regeneration is serialized and the dedicated script-control tap remains the reachable lifecycle control. Tests cover paused fallback and layout-settle transitions. |
| Touchdevice should be activated before the first physical touch | **Refuted as contrary to the kernel gate.** The primer/first-touch wake model is intentional; no current production path was found that assumes pre-activation. |
| Ollama's historical `tmp_path` callback still binds a global nil | **Refuted at current source.** The local declaration precedes callbacks; declaration-order remains a watch-list invariant. |
| Every stale LLM callback is unguarded | **Refuted as overbroad.** Action epochs, request generations and streaming ownership reject the covered late callbacks. A new claim must identify the exact identity change missing from those guards and reproduce it. |
| A model-request generation alone owns every model completion | **Refuted.** A backend selection is a sibling mutation that does not issue another model request. The final model switcher captures both identities and the behavioral test fires the old MLX callback after selecting API (`HS-H-21`). |
| Every raw `return value:gsub(...)` discovered in a recent fix is a current user-reachable bug | **Not promoted without a repro.** `1ee765fbd` parenthesizes `escape_toml_string()` so its API returns one value, and `tools/test/test-lua-gsub-single-return.cjs` causally guards the generic Lua foot-gun; the final replay passed all 50 return sites across 363 Lua files. However, both current callers already collapse the call to one value—one assigns to a local and one concatenates—so this audit found no reachable output change at the pre-fix site. It is caught recent-fix collateral, not a fabricated confirmed finding. |
| The late aggregate's `203` failures represented `203` product regressions | **Refuted by causal isolation and rerun.** A shared `keymap.terminators` stub escaped the runner's prefix purge and generated 79 dependent errors (`HS-M-15`). After source-root isolation the late aggregate fell to `66`; production repairs plus fixture updates yielded `4,881/4,881`. The fixture-only commits `b314cc576`, `03f2aff84`, `c7814f39b`, `df8eb0a6f` and `76b9680ed` through `04e917cfd` follow current guarded helpers, adapter ports, classified reads and lifecycle preconditions; none deletes an assertion or changes production. |
| Updating the eventtap watchdog meta-test means watchdog recovery was removed | **Refuted.** `b314cc576` changes only the expected guarded shape: `pcall(hs.timer.new, ...)`, `eventtap_is_enabled(...)` and `start_eventtap(...)`. The production watchdog remains, while the test now observes the wrappers that report native failures instead of demanding their obsolete raw calls. |
| `utf8.offset`/`utf8.len` are used as guaranteed numbers on the audited keymap path | **Refuted for the inspected sites.** Calls are protected or nil-checked, with malformed-input tests. This is bounded to inspected current sites, not a permanent whole-repo claim. |
| The Swift guardian/native suite passed locally | **Not asserted.** It cannot run on this Windows host. Source-level inspection and CI wiring are not substitutes for a macOS result. |

---

## 4. Performance

### Provenance of runtime evidence

No production Hammerspoon profiler artifact was found under the resolved
`D:/Documents/GitHub/config/ergopti_plus/hammerspoon/logs/` path or the two
fallback locations. The non-empty `D:/tmp` files are synthetic harness output.
Therefore this report contains **no production latency percentile, no production
slow-event count, and no measured boot duration**. G4 remains empirically open
until a macOS run supplies the real artifacts.

The cheapest check was performed before theorizing: the current `D:/tmp` daily
file contains `Slow` strings, but opening the matching rows shows deliberate
`[HotPath] Slow keydown: … (a)` test probes, console duplication and test
worktree failures. The boot fallback had no `Slow` match at check time. Neither
result is promoted to user-performance evidence.

### Defensive eventtap/boot audit

| Path | Provenance | Result |
| --- | --- | --- |
| Synthetic classification/keymap | Code-derived: `onKeyDownRaw` reads one clock at `modules/keymap/init.lua:1017`; provenance is in-memory and no shell/AX call is introduced. | Audited hot-path shape is non-blocking; real eventtap duration remains unmeasured. |
| Hotstring preview render | Code-derived: `llm_bridge.lua:914-1032` defers canvas/AX work through the timer scheduler and generation-fences it; the pre-paint expiry repair also re-resolves through a zero-delay timer at `859-885`. | Canvas construction is off the HID callback. Native scheduling/render cost unmeasured. |
| Provider/resolver diagnostics | Code-derived: `llm_bridge.lua:282-290` and `rules_engine.lua:159-160` enqueue numeric metadata into `hid_diagnostic_mailbox.lua`; capacity is 64 and the sole repeating pump interval is 250 ms. | Installed macOS HID producers allocate no timer, call no logger and do not stringify failure payloads. One lifecycle timer replaces per-failure timers; logger/cancel failures retain ownership for retry. This is a code/test complexity result, **not a measured 250 ms user-latency claim**. |
| Pause/remap transitions | Code-derived: script-control schedules native work after the callback and waits for exact ACK; remap generator/task work is asynchronous. | No audited pause path contains the old blocking kill loop. Whole-source/final-gate scan still required. |
| Classified config I/O | Code-derived: `FileSystem.read_with_status()` walks O(path components + bounded symlink hops), and replacement revalidates pathname/source around one same-directory staging publication. Callers are boot, editors, menu actions and background storage—not the eventtap callback. | Stronger ownership adds bounded filesystem probes outside HID. Native APFS cost and permission-dialog behavior remain unmeasured. |
| Rejected menu preference rollback | Code-derived: rollback re-synchronizes represented modules and invalidates queued keylogger/LLM generations; hotstring group synchronization remains delta-only. | A failed user menu save may perform substantial recovery work, but no filesystem, AX or module resync occurs per keystroke. Recovery latency is unmeasured and requires a real AppKit failure-injection profile. |
| Keylogger midnight rollover | Code-derived: bounded batches drain until exact EOF and refuse deletion on any failed progress/outbox commitment. | Entered by a timer rather than eventtap, but still synchronous on Hammerspoon's main run loop; a large-journal duration and its effect on other callbacks remain unmeasured runtime debt. |
| Eventtap timeout recovery | Code-derived/native contract: Hammerspoon consumes disable notifications natively; keymap, keylogger and script-control retain watchdog restart backstops. | Source/test backstop present; actual `kCGEventTapDisabledByTimeout` injection not run here. |
| Boot/midnight log purge | Code-derived: `logger.lua:286-320,379-382,611-612` defers purge and retains each one-shot timer. | Previously known synchronous boot cost remains off the boot critical path; new-day retention also stays deferred. No boot measurement. |
| VS Code AX | Code-derived from current bridge and watch-list: 200 ms cache includes negative results. | No uncached audited sibling found on the key path; runtime AX cost unmeasured. |

### Offensive optimizations implemented

These optimizations are **code-derived complexity reductions**, not measured
speedups. Each has a class guard in `tests/unit/test_hot_path_costs.lua`.

| Optimization | Prior/current complexity | Target now encoded | Regression risk |
| --- | --- | --- | --- |
| DEBUG log flushing | Prior: synchronous flush on every DEBUG line, including per-key logs. | Flush INFO+ immediately; batch DEBUG with `FLUSH_EVERY_N_DEBUG = 40`, bounding the crash tail while removing one synchronous flush per key. | A crash can lose at most the bounded DEBUG tail; INFO/error durability must remain immediate. |
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

The next correct step is a real macOS boot plus multi-minute typing/tooltip
session, resolving `<config_dir>` first and running the cheap `Slow` count before
aggregation. Mean/max must be reported with the profiler's threshold censoring
and nested segments acknowledged.

---

## 5. `PROJECT_MEMORY` watch-list

| Watch-list invariant | Status at `04e917cfddda0e291b48fe513779ed60a7a623d8` |
| --- | --- |
| Closure references must be declared above async callbacks | **Fix in place** at the historical Ollama temporary-path site; retained as whole-class review rule. |
| `project_hs_synthetic_injection_choke_point` | **Fix strengthened.** One provenance transaction feeds keymap, keylogger, dynamic, gestures, shortcuts and LLM output. Whole-class interleaving tests present. |
| `project_suspend_pause_invariant` | **Fix in place for audited owners.** Exact ACK transaction, rollback, paused action allowlist, keylogger sink and global-hotkey fences are tested. Native macOS runtime still pending. |
| `project_macos_eventtap_no_blocking` | **Fix in place for audited paths; empirically unproven.** Preview/canvas and remap work are deferred. Final whole-source gate and real profiler still required. |
| `project_macos_script_control_tap_lifecycle` | **Fix in place.** Dedicated tap/watchdog and serialized layout regeneration remain. |
| Reload versus quit | **Fix in place.** One coordinator preserves the distinction and fences the exact lease before the terminal action. |
| `project_hs_karabiner_exact_lease_isolation` | **Architecture and memory aligned.** Ownership is the exact one-shot token, never a shared process family. `PROJECT_MEMORY.md:2120-2136` now records the independent launchd guardian, disabled-integration behavior, stock-process boundary and remaining native validation debt. |
| Abrupt host death | **Same class closed in source design.** Independent launchd guardian handles EOF/worker/launcher loss; physical macOS Force Quit remains a release test. |
| Logger midnight rotation and purge | **Same class resolved accurately.** Write-time rotation was already present; the added invariant is retained new-day purge ownership, confirmed-removal count and visible callback/timer failures. |
| Async callback errors must reach the file logger without blocking HID | **Same class found and fixed elsewhere.** Provider and resolver failures use a bounded 64-record numeric mailbox and one lifecycle-owned 250 ms pump; exact retry/overflow/start/stop ownership is behaviorally covered. |
| Startup must be one exact transaction | **Same class found and fixed across dynamic siblings.** PersonalInfo, RulesEngine, shared registry state and the root orchestrator use generation fencing, snapshot rollback and top-level fail-fast publication. |
| `project-macos-absence-needs-lstat-proof` | **Same class found across the late config surface and fixed (`HS-H-17`, `HS-H-18`).** Component-order symlink resolution, final identity, create-only publication and source preconditions are centralized; consumers cannot infer absence from nil or local errno. |
| Config mutation must commit disk before memory/UI/runtime | **Same class found in remap and menu siblings (`HS-H-19`, `HS-H-20`).** Remap setters publish detached candidates only after exact save; menu rollback is boot-seeded and invalidates deferred keylogger/LLM work. More than one hundred save sites are enumerated by the meta guard. |
| Keylogger rollover requires durable terminal proof | **Same class found and fixed (`HS-M-12`).** An empty batch is not EOF; read/seek/close failure preserves offset and `today.log`, and deletion additionally requires durable outbox state. |
| Callback errors may contain secrets | **Sibling damage fixed.** PersonalInfo save, dynamic startup/rollback and registry transaction diagnostics retain controlled labels/types while withholding callback payloads; the final privacy gate covers the value-carrying sink class. |
| Tooltip/engine single source of truth | **Fix and integrated follow-ups in place.** Resolver arbitration is unique; build-time expiry re-resolves, refused native hide retains the lease, and failed retry creation transfers cleanup to physical watchers. |
| Preview semantic mutations require revocation | **Fix in place.** Public writer class and dynamic writers are fenced; registry/menu transactions are exact. |
| `project_macos_llm_runtime_enable_gate` | **Same class found at the menu activation boundary and fixed (`HS-H-22`).** Runtime enable commits before backend setup; setup failure compensates durably, and stale/double MLX completions are fenced. No profile/model restoration-only warmup finding was promoted. |
| Async completion identity must include sibling owners | **Same class found in model selection and fixed (`HS-H-21`).** The request generation alone was insufficient because backend selection is independent; callbacks now check backend identity and abandon/release the captured MLX lock. |
| Input-source rebuild during pause | **Fix in place.** Layout changes are serialized and do not destroy the lifecycle tap. |
| First-touch touchdevice primer | **Intentional.** Not “fixed” by pre-activation. |
| `project_hs_onboarding_config_schema` | **Existing fix retained.** This pass hardened config-directory durable commit; locale remains in `hs.settings`. |
| `project-ahk-unreadable-config-persists-defaults` | **Same class found across macOS and fixed (`HS-H-16`, `HS-H-17`, `HS-H-19`).** PersonalInfo and the central adapter distinguish proven absence from unreadable/corrupt/unowned paths; preferences, personal hotstrings/shortcuts, remap, app categories and device identity preserve existing bytes and publish no replacement. First-use runtimes such as device identity remain fenced until their own exact commitment. |
| AX frame cache | **Fix in place**, 200 ms including misses; no measured runtime claim. |
| Case-conform fast path / menubar dirty cache | **Fix in place** in inspected current paths; registry/menu rollback now preserves their source state. |
| Audit evidence reproducibility | **Applied.** Resolved paths are named, test logs are not production measurements, refutations cite their search surface, and native results are not claimed on Windows. |
| Test proof must be causal, not pcall-only | **Strengthened.** Three lifecycle tests now assert injected identity or direct behavioral effects; encoding and lifecycle-integrity gates were replayed after the repairs. |
| Shared port extensions must not change canonical method arity | **Same class found and fixed (`HS-M-14`).** Compare-before-write is an explicit macOS extension; canonical `FileSystem.write` remains the generated two-argument port. |
| Test-file isolation must follow source ownership, not namespace guesses | **Same class found and fixed (`HS-M-15`).** The runner evicts modules resolving under both production roots and behaviorally proves a leaked bare `keymap.*` stub cannot reach the next file. |
| Lua `gsub` returns both transformed text and replacement count | **Recent-fix collateral caught, not promoted as a runtime finding.** `1ee765fbd` restores the single-return API and the generic JS gate enumerates this class; current call sites already collapsed the value, so no user repro was claimed. |

---

## 6. Coverage register

Legend: **B** = audited and whitened within the stated boundary; **F** = finding
fixed above; **NC** = not covered deeply/runtime enough for a safety claim.
“Dry” means a later source/refutation
pass found no new class; it does not mean every macOS scheduler interleaving was
executed.

| Zone | G1 robustness | G2 output | G3 race | G4 performance | G5 truth | Dry pass / limit |
| --- | --- | --- | --- | --- | --- | --- |
| Launcher, worker, launchd guardian, BLINDER | `HS-C-01` | `HS-C-01` | `HS-C-01` | Source-only B | N/A | Source-dry pass 5; Swift/runtime NC on Windows. |
| Karabiner lease contract/controller/generator/lifecycle | `HS-C-01`, `HS-H-02`, `HS-H-03`, `HS-H-19` | same | same | Source-only B | N/A | Lease source dry pass 5; remap-config transaction dry pass 10; no real Karabiner/launchd. |
| Stock Karabiner UI/Core/grabber/console/session/watchers/VirtualHID | B for non-ownership guard | B | B | N/A | N/A | Whole-source mutation guard dry pass 5; personal Karabiner runtime not started here. |
| SyntheticInput/EventProvenance/text sender | `HS-H-01`, `HS-H-08` | `HS-H-01` | `HS-H-01`, `HS-H-08` | Code-shape B | N/A | Dry pass 4; real CGEvent provenance NC. |
| Keymap state/registry/utils/expander/terminators | `HS-H-07`, `HS-H-08`, `HS-H-12`, `HS-H-15`, `HS-L-01` | `HS-H-01`, `HS-H-09`, `HS-H-12`, `HS-H-15`, `HS-M-03`–`HS-M-05`, `HS-M-08` | same plus `HS-M-11` | Complexity guards B; runtime NC | `HS-H-09`–`HS-H-12`, `HS-H-15`, `HS-M-03`–`HS-M-05`, `HS-M-08` | Final transaction/mailbox source/test dry pass 7; real eventtap/canvas NC. |
| Keylogger/context/privacy/storage | `HS-H-01`, `HS-H-03`, `HS-H-17`, `HS-M-12` | `HS-H-01`, `HS-M-12` | `HS-H-01`, `HS-H-07`, `HS-H-17`, `HS-M-12` | NC | N/A | Input/context source dry pass 4; identity/journal ownership dry pass 9; secure-input/SQLite runtime NC. |
| Dynamic rules | `HS-H-10`, `HS-H-13`, `HS-H-15` | `HS-M-01`, `HS-M-03`, `HS-H-13`, `HS-H-15` | `HS-M-01`, `HS-H-13`, `HS-H-15` | Mailbox producer shape B; runtime NC | `HS-M-01`, `HS-H-10`, `HS-H-13`, `HS-H-15` | Transactional startup and resolver mailbox dry pass 7. |
| PersonalInfo | `HS-H-14`–`HS-H-16`, `HS-M-02` | `HS-H-14`–`HS-H-16`, `HS-M-02`, `HS-M-03` | `HS-H-14`, `HS-H-15`, `HS-M-02` | NC | Static/provider ownership, startup, read and save fences B | Unreadable/default transaction dry pass 8. |
| HID diagnostic mailbox | `HS-H-12`, `HS-H-13` | same | same | Producer/lifecycle complexity B; runtime scheduler NC | Diagnostic-only | Capacity, retry, overflow and timer ownership dry pass 7. |
| Tooltip facade/renderer/hotstring/LLM | `HS-H-05`, `HS-H-06`, `HS-H-11`, `HS-H-12` | same plus `HS-M-08` | same | Deferral shape B; canvas cost NC | `HS-H-05`, `HS-H-09`–`HS-H-12`, `HS-M-08` | Reconciled follow-ups dry pass 6; real canvas/AX NC. |
| LLM engine/backends/streaming/warmup | `HS-H-06`, `HS-H-08`, `HS-H-20`–`HS-H-22` | `HS-H-06`, `HS-H-20`–`HS-H-22` | `HS-H-06`, `HS-H-20`–`HS-H-22` | Network/boot source audit only | `HS-H-06`, `HS-H-20`, `HS-H-21` | Async output ownership dry pass 4; preference/warmup/model/backend activation ownership dry passes 10–11; no live service/network campaign. |
| Pause/script control/shortcuts/global hotkeys | `HS-H-02`, `HS-H-03` | `HS-H-03` | `HS-H-03` | Callback shape B; real tap NC | N/A | Dry pass 4. |
| Window/app filtering/VS Code bridge | `HS-H-07` | `HS-H-07` | `HS-H-07` | AX cache source B, runtime NC | `HS-H-07` | Dry pass 3. |
| Filesystem adapter/config paths/onboarding/path menu | `HS-H-04`, `HS-H-16`–`HS-H-18`, `HS-M-13`, `HS-M-14` | same | `HS-H-04`, `HS-H-17`, `HS-H-18` | Boot source B | N/A | General durable writes dry pass 3; PersonalInfo dry pass 8; absence/path/CAS class dry pass 9; error/port contracts dry pass 11; real permission dialogs NC. |
| General menu preferences/runtime synchronization | `HS-H-20`, `HS-H-22` | same | same | Delta-only group sync code guard B; runtime NC | `HS-H-20` | Represented state/runtime transaction dry pass 10; activation/rollback sibling damage dry pass 11; AppKit and external service effects NC. |
| Logger/hotpath/boot profiler | `HS-M-06`, `HS-H-12`, `HS-H-13` | same | same | No production artifact | N/A | Retention dry pass 3; mailbox logger ownership dry pass 7; multi-day runtime NC. |
| Regression/meta/integrity/encoding/privacy gates | `HS-M-10`, `HS-M-11`, `HS-M-15`, `HS-L-02`, `HS-L-03` as proof quality | same | same | N/A | N/A | Targeted, E2E, lint, integrity, false-green and privacy gates replayed pass 7; PersonalInfo transaction `4/4` replayed pass 8; late causal matrices inspected pass 10; source-root isolation and final aggregate Lua `4,881/4,881` dry pass 11; clean final JavaScript aggregate `172/172`, exit `0`. |
| Gestures/touchdevice | B for inspected action injection/lifecycle | B | B source-only | Spaces cache B; gesture frame runtime NC | N/A | One focused pass; hardware/first-touch NC, not globally dry. |
| Updater, healthcheck, crash reporter, remaining file/menu watchers, i18n | NC | NC | NC | NC | N/A | Pattern/sibling checks only; explicitly not dry. |

### Broken state × action cells proven and fixed

| State | Action | Pre-fix result | Guard now |
| --- | --- | --- | --- |
| Ergopti remap active; HS or launcher `SIGKILL` | Type | Ergopti mapping could remain after app disappearance | Independent exact-token guardian fence (`HS-C-01`). |
| Ergopti integration disabled; stock Karabiner active | Toggle/menu/quit | Broad ownership could stop user's Karabiner | No lease and stock isolation guard (`HS-C-01`). |
| Synthetic replacement pending | Physical exact char, `Cmd+V`, Backspace | Physical event drained owned expectation | Immutable provenance + physical fence (`HS-H-01`). |
| Quit/reload pending | Second terminal request / teardown failure | Premature exit or lost cleanup handle | Serialized coordinator + retry transaction (`HS-H-02`). |
| Pause/resume transition | Rapid reverse or subsystem failure | Split native/local state and false success UI | ACK-gated rollback transaction (`HS-H-03`). |
| Config destination unwritable | Confirm editor/onboarding | Reload/success with nondurable path | Atomic writer and exact result (`HS-H-04`, `HS-H-18`). |
| Native canvas show/hide fails | Press Escape/magic key | Invisible surface owns key or visible promise loses owner | Native read-back + retained lease (`HS-H-05`). |
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
| Config pathname contains `link/../file`, retargets, or changes after staging | Save any TOML-backed edit | Wrong pathname or stale complete candidate overwrites foreign/newer bytes | POSIX-order resolution plus pathname/source preconditions around rename (`HS-H-18`). |
| Remap config is corrupt or its writer refuses | Change tap/hold/combo/timeout or enable integration | Recoverable bytes overwritten, live setter diverges, or lease remains active without committed preference | Decoded source snapshot, detached candidate, READY/save/STOPPED transaction (`HS-H-19`). |
| First menu preference save fails | Toggle updater/LLM/keylogger/gesture/shortcut/global control | Runtime, hotkeys, queued work and menu advertise a value absent from disk | Boot-seeded in-place rollback, runtime re-sync, generations and exact-success caller class (`HS-H-20`). |
| MLX model requirements pending | Switch backend without another model request, then deliver old callback | Old MLX model commits into sibling backend or predictions stay locked | Request token + captured backend identity; backend invalidation releases abandoned lock (`HS-H-21`). |
| LLM disabled; preference or backend setup fails | Click Enable, then deliver late/double MLX completion | Backend work can outlive a rejected save, or a failed/stale setup can publish enabled state and duplicate side effects | Commit-before-setup, activation generation/backend identity, exactly-once settlement and durable compensation (`HS-H-22`). |
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
- Replay the classified-path/create-only/POSIX-order matrix on APFS with real
  `hs.fs.symlinkAttributes`, dangling links, permission denial and two processes
  racing publication. Include `SIGKILL` of a process holding the new stable
  `hs.fs.lock`, then require a second Hammerspoon process to acquire it within a
  bound. The Windows host's injected identities/lock owner are causal tests, not
  a native filesystem result.
- Failure-inject one real AppKit menu save after boot and verify runtime hotkeys,
  LLM/profile state, gesture registries and any queued keylogger start visibly
  return to the last committed values without a success notification.
- Capture real production hotpath and boot profiles from the resolved config
  path. Do not reuse `D:/tmp` harness output.
- Preserve the final gate provenance separately: source encoding was re-derived
  at `04e917cfddda0e291b48fe513779ed60a7a623d8`, the clean JavaScript aggregate
  passed `172/172`, and the portable Lua aggregate passed `4,881/4,881`. None of
  those substitutes for the native macOS runtime evidence still required above.

The safe reading of this report is bounded: each promoted finding has a concrete
cause/reproduction/test and is fixed in the cited patchset; a `B` cell means the
named source/test boundary was audited, never that macOS scheduling and hardware
behavior were simulated perfectly on Windows.
