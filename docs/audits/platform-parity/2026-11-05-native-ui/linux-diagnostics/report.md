# Linux diagnostics, healthcheck and snapshot export audit

Date: 2026-11-05. Audited SHA: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`.
Exclusive source: `/workspace/worktrees/parity-2026-11-05/linux-runtime`.
Scope: `linux-diagnostics`; schema 1. The previous `linux-runtime` deliverable was not edited.

Three confirmed roots: **LDG-001 medium/high confidence**, incorrect selected AI backend and probe target; **LDG-002 low/high**, known AI-off state becomes unknown; **LDG-003 medium/high**, native timer refusal leaves the local configuration check pending. G5 is applied here to truthful diagnostics display/export; the direct property is **diagnostic fact truthfulness**. LDG-003 violates G2's effect-or-explicit-failure requirement at the diagnostic action boundary.

The audit used synthetic public query inputs, canary text, private helper executables and owned temporary files only. No real user logs/configuration/secrets, clipboard, services, network or GUI were touched. Production files and registered tests are unchanged; no install, commit, push, npm install or broad JavaScript suite ran. Native checks ran as `uid=1000(agent)`, so the real unprivileged permission controls were applicable. Evidence and scripts live only under this scope's artifact directory; native-source socket fixtures use short automatically removed `/tmp` names because AF_UNIX limits reject the long artifact path.

## Replay and final results

```sh
python3 /workspace/scratch/parity-native-ui/linux-diagnostics/probes/run.py \
  --source-root /workspace/worktrees/parity-2026-11-05/linux-runtime \
  --pass-id root-replay
```

All source-sensitive proofs require the explicit root through that CLI and `ERGOPTI_AUDIT_SOURCE_ROOT`; the runner asserts the audited SHA. It runs each registered module in an isolated interpreter and each native probe with owned environment paths. Exact argv and summaries are retained in `logs/final-dry1-results.json` and `logs/final-dry2-results.json`.

Both final full bounded sweeps pass **32 executions**: **21 registered module invocations / 516 cases**, actual bridge/share/page-model probes, native HTTP controls, actual timer-scheduler fault controls, **26 native diagnostic-source cases**, and **7 native export-save cases**. The two consecutive sweeps were after the last retained root, LDG-003; no additional confirmed root appeared. Earlier discovery/setup attempts do not count as dry sweeps. No finding quota was used.

The focused Node replay executes only the shipped shared `model.js` under a VM; it is not a browser, DOM, native UI or driver-suite run. The report never promotes that observation into installed-page or driver-suite qualification.

## LDG-001 — API state is diagnosed as Ollama

**Medium severity, high confidence. Diagnostic fact truthfulness / G5.**

This caller state is reachable. `prediction_engine.lua:261` declares `BACKENDS = { ollama=true, api=true }`; `get_backend()` reads the selected backend and `set_backend()` publishes that supported choice. `get_base_url()` still returns the local profile's Ollama URL. The real manager gives the diagnostics bridge the daemon state, including that prediction owner. `healthcheck.actions` accepts refresh/extensive for Linux without a backend exclusion, and bridge `start_probes` starts the real probe module. Shared schema AI rows have no Linux/API exclusion. The shared labels are **Backend**, **Enabled**, and **Backend answers**.

The collector at `linux/ui/healthcheck/bridge.lua:346` does not read that backend. It hardcodes `ai_backend="ollama"`, preceded by the obsolete comment “Ollama is the only backend this driver has.” The probe module likewise hardcodes `AI_BACKEND="ollama"`, then requests `llm.get_base_url() .. config.paths.ollama` whenever AI is on. An API-selected user sees the wrong backend and an unrelated local service's result. A failed local Ollama request can suggest a problem with functioning remote AI; a successful local answer can appear as the selected backend answering.

`ai-projection.lua` executes actual `build_snapshot`, closed share projection and canonical schema over explicit public LLM query inputs. It records zero calls to `get_backend`, snapshot/export `ollama` for input `api`, and a healthy Ollama control. `page-model.cjs` renders the actual output through the shipped field formatter. `partial-http.lua` in API mode executes the actual `http_client → managed_http → curl_http_client` stack and actual native child IO, using a tiny private program in place of curl. It records the request target and result; no connection occurs.

```text
ADVERSE backend input=api snapshot=ollama export=ollama get_backend_calls=0
HEALTHY backend input=ollama snapshot=ollama
ADVERSE actual_page enabled=false renders=unknown/muted; api renders=ollama
ADVERSE AI_TARGET input_backend=api actual_target=http://127.0.0.1:11435/api/version state=ok
```

The probe's “ok” asserts only that the private synthetic local endpoint answered; it does not establish remote API health or actual inference. The defect is attribution to the wrong selected backend, not the status-versus-body completeness distinction discussed below.

Visibility: no collector exception occurs, the wrong enum is allowed by the shared schema, and the typed export faithfully preserves that wrong input. Existing system/feature tests do not assert the selected API backend. This is a Linux-specific missing query, not an intentional lack of Linux remote AI capability.

Regression intent: actual collector, actual shared model/export and actual probe dispatcher over API and Ollama owner inputs. Require backend `api` in the API snapshot and an explicitly unsupported API health check until a qualified API check exists; preserve local Ollama's version probe and absent/disabled controls. Do not use an arbitrary local answer to certify a different backend.

## LDG-002 — Known disabled becomes unknown

**Low severity, high confidence. Diagnostic fact truthfulness / G5.**

With the LLM loaded and switched off, `is_enabled()` returns false. Collector line 350 computes `type(llm.is_enabled)=="function" and llm.is_enabled()==true or nil`; Lua's `or nil` erases false. The features collector in the same snapshot preserves `llm=false`, and the developer collector correctly lists it as disabled, which explains why those existing tests pass.

The actual shared page's `model.js:152` returns no value for an absent field, while its boolean branch renders false as `healthcheck.value.no`. `fieldDisplay:223` therefore displays **unknown/muted** for this known-off value. Actual `healthcheck.share` omits the field from the JSON export. A genuinely absent LLM is indistinguishable in that row.

```text
ADVERSE enabled input=false ai_field=nil export_field=nil feature_field=false
ADVERSE actual_page enabled=false renders=unknown/muted; api renders=ollama
HEALTHY actual_page preserved_false renders=no/value
REFUSAL actual_page absent_llm renders=unknown/muted
```

Visibility: no exception or warning; the collector produced a valid empty field. The effect is a misleading diagnostics row and missing known fact, not loss of the underlying AI switch. Severity is low because the other sections still report disabled correctly.

Regression intent: true, false, absent method and absent owner through the actual AI collector and actual page/share models. Preserve boolean false rather than guessing off for an unavailable owner. Check the AI section itself, not only the feature/developer section.

## LDG-003 — Unarmed timer leaves a check pending

**Medium severity, high confidence. G2.**

Diagnostics starts the local configuration probe even without extensive opt-in. `healthcheck.snapshot.pending_probes` initially marks that row pending. `ui/healthcheck/probes.lua` schedules the work through `timer_scheduler.after`; the configuration and CPU timer sites only retain the returned handle for cancellation. They never test admission.

The scheduler has an explicit nonthrowing refusal contract: `after()` creates `{fired=false,armed=false,...}`; when `luv.new_timer` fails or relative `timer_start` is refused, it logs the error, marks the handle fired and returns it unarmed. `start_probe` sees a normally returning body, and has no independent watchdog. No `done` is called, so the page's pending row has no remaining completion path.

`timer-admission.lua` executes the actual scheduler, probe, pending-state constructor, bridge configuration context and configuration reducer. Only the individual native return is faulted: `new_timer=nil/ENOMEM`, or `timer_start=nil/EINVAL`. The latter allocates a real timer that the actual scheduler closes. `uv.run()` returns with no native handles alive. A healthy real timer completes once. Configuration file reads use the probe's documented synthetic reader/path/manifest inputs, never user configuration.

```text
ADVERSE native_timer=refused callbacks=0 live_handles=0 configuration_terminal=missing snapshot=pending
ADVERSE native_timer=start-refused callbacks=0 live_handles=0 configuration_terminal=missing snapshot=pending
HEALTHY native_timer callbacks=1 configuration=ok live_handles=0
```

Visibility is not total silence: the lower scheduler logs `after(): timer allocation/start failed`. The missing effect is the diagnostic terminal result itself; no error/timeout replaces pending. A two-second elapsed wait is unnecessary to prove liveness loss once the event loop has no handles and neither scheduling site retained a watchdog. Existing tests cover unsupported async capability, normal timer callbacks, a slow reader's post-hoc deadline, and cancellation, but not a returned unarmed scheduler handle.

The native seam is faithful about return arity and ownership. It does not manufacture a completed timer or replace the business callback. This is fault injection of real fallible allocation/start receipts, not a claim that actual kernel ENOMEM occurred during this run.

Regression intent: require exactly one classified failure terminal and no successful sections after nil/false timer allocation/start receipts. Preserve healthy native completion and cancelled late-publication suppression. Cover CPU sampling's immediate sibling site under the same rule. macOS explicitly checks its timer adapter's separate committed receipt before running a probe; no identical cross-OS native timer API is asserted.

## Entry points, status meaning and end-to-end coverage

| Surface/flow                    | Actual owners inspected/exercised                                                                                                                                  | Evidence and bounds                                                                                                                                                                                                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Menu/window entry               | Debug diagnostics/open-healthcheck action → `ui.healthcheck.bridge.open` → manager show → ready → phase A → local probes                                           | Native window creation replaced by faithful manager ports in registered bridge tests. Actual manager route checks source epochs before dispatch; direct stale callbacks cannot be inferred from bypassing it.                                                                          |
| Initial/refresh snapshot        | Bridge phase A collectors, schema field check, paths, module/feature states, issues, permissions, native system facts                                              | Public native/system providers controlled for the finding probes. Actual shared page projection confirms visible fields. OS/process facts exercised separately by native-source gate.                                                                                                  |
| Configuration check             | Actual shared configuration reducer; declared file/setting inventory; timer dispatch; slow-reader timeout                                                          | Registered tests plus LDG-003 healthy/refusal native controls. A timeout is a reducer deadline observation; deferred start alone is not proof of completion.                                                                                                                           |
| Extensive checks                | GitHub, local AI, PAC/gsettings, df, CPU samples                                                                                                                   | Dedicated registered probe tests; native private helper HTTP controls. No real network, PAC, service or GUI. API/Ollama attribution is LDG-001.                                                                                                                                        |
| Status authority                | Schema pending/not_run, result state, closed typed share, page-check observations                                                                                  | Ordinary local/extensive probe facts are separate from actual driver suites. Share document explicitly says `driver-suites: not_run`; installed page records are `installed_page_reported (unqualified)` and schema-owned. No test success was relabeled as native application effect. |
| Cancel/refresh/close/reopen     | Run.cancel cancels timers/HTTP/children, sticky cancellation gate; bridge session identity, action revision/token/snapshot/epoch; manager source-epoch gate        | Registered bridge/error/report cancellation, completion and reentry cases pass. No real GTK lifecycle or process-wide reload driven.                                                                                                                                                   |
| Export preview/copy/save/report | Actions validates text/name/id; host recomputes Share.document; exact preview equality; runner checks owner before and after native effects; reveal before browser | Actual action/report corpus plus native save gate. Clipboard/openers replaced by recording ports or private native programs; no real clipboard/browser/file-manager effect.                                                                                                            |
| Export write receipts           | Linux default save → actual filesystem write/close; typed English report; quoted literal target path                                                               | Seven real uid1000 cases: normal literal path, synthetic redaction, buffered close failure, zero-byte close failure, immediate write failure, read-only existing file, unwritable directory. All pass; refused saves never reveal or claim success.                                    |
| Snapshot source                 | `infra.diagnostic_snapshot`, regular-file reader, build stamp/git pointer/HEAD classification                                                                      | 26 actual native cases: regular/link/FIFO/peer/directory/socket/missing combinations plus own-process pid and nonprivate system facts. Source paths explicitly controlled.                                                                                                             |
| Error window                    | Central logger observer → shared policy → deferred open/fold → actual retained snapshot report → local redacted init → shared export runner                        | Registered real policy/core/bridge tests include owner changes, async completion and reentrant cancellation. No speculative stale-message issue: manager rejects old native epochs before bridge.                                                                                      |
| Crash diagnostics               | Actual crash reporter, canonical JSON/retention, admitted sink redactor/currentness, exclusive regular writer, write/close and path-image receipts, failure notice | 28 privacy cases plus reporter/contract corpus pass. No raw fallback asserted. Notifications and sink dependencies controlled by registered fixtures. Retention never treats arbitrary user files as reports.                                                                          |
| Day log                         | Opt-in shared collector/host, cap, complete read/close, retained per-snapshot redacted text, attachment file                                                       | Shared corpus and report tests cover missing versus denied, over-cap, copy refusal, untick/refresh/foreign-snapshot refusal. Never read actual daily logs.                                                                                                                             |

Privacy controls: the finding probe supplies `CANARY_PRIVATE_MODEL_729` as model text; actual closed export excludes it. Corpus tests replay path, account, token-like credential and error-text canaries, including unknown-field exclusion. Native save controls assert the synthetic `/private-owner` and `privateowner` do not enter approved output. These are bounded tests of the declared policy, not a universal claim that every possible free text is scrubbed. No new plaintext-log finding is retained.

## Cross-platform capability and intention

| Capability                   | Linux                                                              | macOS                                                                                    | Windows                                                                      | Interpretation                                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Diagnostics snapshot/export  | Driver collectors and bridge; shared typed English policy and page | Driver helpers/core/bridge; shared policy/page                                           | Native AHK snapshot/helper/share port and shared page                        | Same product intent; native seams differ. Linux LDG-001/002 are actual missing facts, not legitimate platform limitations.              |
| Selected backend             | Hardcoded Ollama in collector/probe                                | `helpers.collect_ai` calls actual backend; probe checks schema path for selected backend | Helpers read actual backend; AI probe rejects non-Ollama/unsupported backend | API health is explicitly unsupported where no schema route exists. Linux has no documented intent to substitute local Ollama for API.   |
| Known AI off                 | AI field absent despite features false                             | Collector's protected reader preserves false                                             | Helper writes actual boolean false                                           | Direct truthful-state parity; no OS constraint causes Linux's nil conversion.                                                           |
| Timer ownership              | One timer handle with armed field, currently ignored by probes     | Scheduler returns committed receipt; probe explicitly rejects unarmed watchdog           | Native SetTimer/poll deadlines                                               | Equivalent terminal-result goal, different native APIs. Only Linux seam replayed here.                                                  |
| Guided diagnostic collection | `diagnostic_collection=false` in init capabilities                 | Driver-specific checks and page observations                                             | Guided native collection capability exists                                   | Explicit Linux host restriction, not a missing hidden button. Page model checks remain unqualified observations.                        |
| Running applications         | Detailed opt-in on X11; Wayland field omitted with log explanation | Native app/window listing                                                                | Native app listing                                                           | Explicit Wayland enumeration limitation; unknown is correct, an empty fabricated list would not be.                                     |
| Unavailable-feature reasons  | Not collected here                                                 | Manifest-derived section collected/rendered                                              | Existing backlog                                                             | Already TODO item for Windows/Linux, not a new duplicate finding.                                                                       |
| Reveal/save/share            | Linux reveals containing directory through desktop opener          | Native reveal implementation                                                             | Native launcher/reveal                                                       | Explicit lack of portable “select file” on Linux; opener confirmation proves helper outcome, not proof a particular GUI became visible. |

## Refuted hypotheses and test honesty

- **HTTP 200 with curl exit 18 necessarily makes `Backend answers=ok` a defect:** not retained. The full actual managed/native transcript proves `ok=false`, `status=200`, body discarded, while diagnostics shows `ok`; lower HTTP error logs explicitly name exit18. However the UI says **Backend answers**, and GitHub is a reachability probe with optional rate-limit detail. Status200 proves a response even when its body is incomplete; sibling probes accept the status similarly. Without a stronger completeness contract, treating this as false readiness would overclaim. `http-partial`, `http-healthy`, and `http-refused` logs preserve the distinction: 503 is error and all child handles close. This does not qualify model inference or a full valid version body.
- **Error bridge accepts stale native page messages because its own on_message lacks an epoch check:** refuted by the actual manager's route gate (`webview_manager.route_message`, source_epoch versus current epoch, before dispatch). Directly invoking an old bridge message would bypass the owner and is insufficient evidence.
- **Native admission means a report save succeeded:** refuted by seven native save receipts; refused write/close cases produce false and zero reveal. Existing async opener tests also wait for actual receipts and reject cancellation/successor callbacks.
- **Arbitrary page text or paths become exported/opened authority:** shared Actions allows known ids and safe report names; Share recomputes host-approved content; stale/forged previews refuse. Snapshot raw local detail and closed shared projection have different roles. No arbitrary URL/path export issue established.
- **Closed page checks are native driver tests:** refuted by schema and export text. Checks report modeled/installed-page observations with unqualified source and driver suites remain not_run. No native action qualification was inferred from JavaScript formatting tests.
- **A returned timer handle proves it was scheduled:** disproved by LDG-003 with the actual scheduler; refusal returns a normal unarmed handle and lower logs. Passing HAS_ASYNC and ordinary callback tests do not cover it.

The false-green scan is within baseline (`logs/false-greens.log`). This only establishes its mechanical ratchet. Human review notes that the existing AI snapshot tests assert feature/developer disabled state rather than `sections.ai.ai_enabled`; existing timer/probe fixtures enqueue every requested callback and therefore never model actual returned-unarmed admission. The retained proofs invoke actual business owners and assert effect/state values, not pcall success or current spelling.

Discovery setup corrections: the first AI probe lacked a complete explicit source-layout provider; its retained version supplies the source mapping. The first complete harness tried to chown to nobody despite already running unprivileged; it now runs native save directly as uid1000. The first source gate placed UNIX sockets under a path longer than AF_UNIX permits; its retained invocation uses a short automatically removed owned `/tmp` fixture. Failed discovery logs remain provenance; only final dry sweeps count as full passing evidence.

## Performance, memory and coverage gaps

No G4 or memory-leak finding. Phase A reads synchronous local facts, and day-log collection/redaction/preview is synchronous up to its declared cap; their user-visible latency and peak allocation were not measured here. Case execution times are harness times, not keyboard-path performance.

Watch list: one cached config document set, current snapshot/session, cleanup-history metadata, action request/token, callback listeners, timer handles, weak-key day-log retained text and capped redaction buffers. Native source/save/HTTP controls prove the exercised handles/files settle and writes are acknowledged. They do not prove long-session RSS stability or physical cleanup of every cancelled extensive provider; cleanup history on Linux is metadata and is not evidence of native retirement.

Not exercised: real GTK/WebKit window/DOM rendering, real desktop opener handoff or clipboard, live configuration/log files, deployed package paths, genuine GitHub/API/PAC requests, corporate proxy credentials, real AI model readiness/inference, native device permissions, ARM64 host behavior, actual OS allocation exhaustion, and cross-OS native hosts. Native failure controls inject documented return shapes rather than inducing system-wide resource failure. Cross-platform comparisons are source/intent checks; sibling audits own their native claims.

The repository `workflow.cjs validate-report` expects repository-owned legacy audit locations/scopes and refuses this requested scratch path before schema validation. Its exact rejection is retained; it is not claimed green. The artifact validator checks schema1, LDG ids, enums, required evidence and paths independently, pending root campaign integration/replay.

## Integration boundary

Audited source: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. Canonical confirmed IDs: `LDG-001`, `LDG-002`, `LDG-003`. The submitted manifest is retained separately; canonical classification and counterchecks in the campaign report take precedence. No native three-platform certification is claimed.
