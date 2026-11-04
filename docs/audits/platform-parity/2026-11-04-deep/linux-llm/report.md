# Deep audit: Linux × LLM

Audited commit: **89b0b774c8c960c7ad458ac3cb98d5c97598e518**. Date: 2026-11-04 UTC. Scope: Linux local/remote transports, prediction sequencing/stream/cancellation/pause, prompt profiles, tone, translation, vision, agent dispatch, identity and output admission. No repository changes. Previous hotstring audit artifacts are preserved separately.

Two new confirmed actionable findings were reproduced. The previously documented lack of bounded prediction retry/refill is retained as known scope and is **not** counted again. No inference request was sent to a real provider and no desktop or native input was driven.

## Confirmed findings

### LL-001 — An interrupted Ollama chat can overwrite a successor admitted by its cancellation callback

Severity: **medium**. Confidence: **high**. Guarantees: G1 robustness, G2 missing result, G3 callback ownership race.

The backend explicitly delivers terminal cancellation to its caller. If that terminal callback starts a successor request, the older interrupted `chat` call resumes and replaces the new request owner. The successor can have been dispatched successfully but never receives a result or cancellation. This violates the backend's terminal-callback ownership contract.

Exact production evidence, paths relative to `static/ergopti_plus/`:

- `linux/modules/llm/api_ollama.lua:235` (`M.chat`) captures a runtime response owner.
- `api_ollama.lua:246` calls `M.cancel()` when a request is active, then continues without proving that cancellation did not admit a successor.
- `api_ollama.lua:365` (`M.cancel`) invokes `finish_request(request, "cancelled")` at `:371`.
- `api_ollama.lua:165` (`finish_request`) clears the active slot and invokes the original public terminal callback at `:172`. That callback is expressly allowed to reenter the API.
- The interrupted `chat` then increments the epoch at `:247` and assigns `_active_request = request` at `:293`, overwriting the reentrant successor. The successor's later `request_current` tests at `:157` fail and suppress both content and terminal publication.
- Existing `linux/tests/unit/modules/llm/ollama/test_api_ollama_terminal_receipt.lua:179` covers a successor started from a **chunk** observer, but does not cover a terminal cancellation observer admitting a successor while a different `chat` caller is suspended in cancellation.
- The same repository's remote owner illustrates the missing guard: `linux/modules/llm/api_remote.lua:914` (`cancel_exchange`) compares the original epoch after native cancellation, and `:941`–`:942` (`open_exchange`) refuses the interrupted admission if a successor owns it. This is a specific internal comparator; no untested assertion is made that every macOS/Windows cancellation route is correct.

Reproduction: `probe-ollama.lua` loads the **real Ollama module**, with a stable runtime-receipt owner and a scripted asynchronous HTTP boundary. Start A; make A's cancellation terminal callback start C; start B, which cancels A. Both C and B dispatch. Completing C's actual registered transport callbacks produces no terminal callback; completing B works. Exact output:

```text
REENTRY A  cancelled
REENTRY B B-result nil
```

The probe asserts three dispatches and zero C terminal callbacks after independently completing C. Stable runtime ownership rules out a stale-runtime refusal as the explanation. No native HTTP process or desktop was executed.

Silent failure: C receives neither result nor terminal cancellation, although its `chat` returned success. A caller waiting on its callback can retain loading state or simply lose output.

Regression test: use the real backend and a scripted transport; from an original request's terminal cancellation callback admit a successor, then resume the interrupted competing `chat`. Assert a clear winner, no successor overwrite, exactly one terminal result per admitted request, and no stale content. Cover native-cancel callback reentry as a separate boundary.

### LL-002 — A refused translation dispatch leaves a permanent loading offer

Severity: **medium**. Confidence: **high**. Guarantees: G1 robustness, G2 missing result.

A mashed translation action can encounter a refusal to terminate the previous transport. The new translation opens a loading offer and gets `false` from the real remote backend, but ignores that refusal. Even when the previous request finishes, the new offer remains loading and `is_predicting()` remains true; it owns no dispatched response that could settle it. Another explicit cancel/action can recover, but waiting cannot.

Exact production evidence:

- `linux/modules/llm/prediction_engine.lua:1632` (`open_offer`) marks `_predicting = true` and advances `_request_epoch` before dispatch.
- `prediction_engine.lua:2186` (the `M.translate_selection` send closure) ignores the result of `backend.chat(...)`.
- `linux/modules/llm/api_remote.lua:941`–`:942` (`open_exchange`) legitimately refuses without a completion when the previous owner cannot be cancelled. Public `M.chat` returns `false` at `:1169` when no epoch was acquired.
- `prediction_engine.lua:2967` (`M.dismiss`) logs a failed backend cancellation but has already retired the old offer and request epoch. Thus the eventual old translation callback is correctly stale; it cannot finish the newly created loading offer.
- The ordinary prediction path already handles this exact port contract: `prediction_engine.lua:1088`–`:1097` checks a false dispatch with no terminal callback and retires loading. The translation path lacks that handling. This rules out treating `false` as impossible or intentionally meaning an eventual response.
- Related one-off paths (`request_screen_answers :1781`, `system1_transport :2316`, `send_system2 :2342`) also ignore their chat return, but their complete end-to-end behavior under refusal was not independently reproduced here. They are review targets, not additional confirmed findings.

Reproduction: `probe-translation.lua` extracts the existing translation scenario constructor (unchanged) from the test file and uses the real engine, settings, profile registry, translation builders/parser and **real remote client**. The scenario scripts only the actual native boundaries. Start translation A, make the injected HTTP cancellation return false, press translation again. No new HTTP request is accepted. Finish A's response. Exact result:

```text
REFUSED_TRANSLATION posts=1 predicting=true loading=true offers=0
```

The test asserts this state after original physical-response settlement. It does not fake a backend that merely returns false; the real remote `open_exchange` refuses on its native cancellation contract.

Silent failure: an empty spinner stays on screen with no pending new response; automatic prediction admission continues to see `_predicting=true`. Cancellation refusal is logged, but the new translation workflow incorrectly reports accepted and never settles.

Regression test: drive the real engine and real remote backend through translation A, refused cancellation on repeated action B, then eventual A completion. Assert B either refuses before opening loading or retires its own loading state exactly once, without allowing A to publish stale text or disturbing a successor. Reuse the ordinary prediction's false-dispatch contract and include synchronous-completion controls.

## Two bounded passes and coverage register

Pass 1 followed production routes from daemon initialization/action handlers through configuration, backend target resolution, transport, callback publication and output. Pass 2 challenged candidate defects with callback reentry, actual cancellation-refusal transcripts, existing regression tests, native-dependency reruns and explicit alternate-path checks. Two confirmed defects remain; the report makes no claim of exhaustive provider, native desktop, latency or race-space coverage.

| Surface                                      | Evidence and checks                                                                                                                                                               | Result                                                                                          |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Production composition                       | Daemon `ergopti_hotstrings.lua:1685` onward supplies focus, retained selection, screen capture, command dialog and output ports; engine `M.init :607` captures owner capabilities | Source traced; no missing core action wiring                                                    |
| Local target/runtime identity                | `M.capture_runtime_response :3350`, `runtime_response_current :3375`, Ollama captured engine methods `api_ollama.lua:24` and `runtime_current :143`                               | Source traced; local response owner checks present                                              |
| Ollama NDJSON framing                        | `consume_line :182`, `consume_chunk :204`; terminal marker required, trailing records refused, split UTF-8 retained                                                               | 22 terminal + 32 stream cases passed                                                            |
| Ollama cancellation and successor ownership  | `M.cancel`, `finish_request`, `M.chat`; dedicated A/C/B transcript                                                                                                                | New LL-001 reproduced                                                                           |
| Remote provider families                     | Catalogue reader, formats, body builder, error classification, thinking-field retry, access token gates                                                                           | Source traced; 38 callback cases passed                                                         |
| Remote scopes                                | `_inference` vs `_probe`, exchange owners, model listing/capability owners                                                                                                        | 20 nonchat/probe isolation cases passed                                                         |
| Remote streaming                             | Generic remote body explicitly nonstreaming; canonical display policy disallows Linux API streaming                                                                               | Explicit documented choice, listed below                                                        |
| Prediction batching/temperature/token budget | `M.predict :832`, shared batching/token budget, parse/dedup/usage, ordinary false-dispatch guard                                                                                  | 17 prompt cases passed                                                                          |
| Retry/refill                                 | Fixed sequential dispatch loop vs shared retry policy                                                                                                                             | Existing known gap, not new                                                                     |
| Stream display and progressive variants      | `DisplaySettings`, `streaming_multi`, `publish`, acceptance revokes epoch before native cancellation                                                                              | Source traced + existing stream/prompt cases passed; no native rendering claim                  |
| Manual/chosen prompts                        | `run_manual :1133`, `trigger_prompt :1186`, generated built-in handlers                                                                                                           | Source traced; prompt cases passed                                                              |
| Profiles and app-specific overrides          | Shared registry envelope, exact profile IDs, model-following policy, app resolution                                                                                               | 7 app-override cases passed                                                                     |
| Typed AI context                             | `context.lua`, `_buffer_focus`, secure/reset/edit observation                                                                                                                     | 30 context cases passed                                                                         |
| Live mode / pause / off                      | `schedule`, `start_live`, `on_pause_change`, `withdraw`, `cancel`, `dismiss`                                                                                                      | 28 live-mode cases passed                                                                       |
| Tone ladder                                  | Capture epoch/generation, original-source ladder memory, current focus, retained selected-range replacement and physical ACK                                                      | 41 tone cases passed                                                                            |
| Selection translation                        | Originating epoch, capture authorization, retained selection receipt, focus/privacy completion checks, physical ACK                                                               | 50 existing translation cases passed; new LL-002 reproduced                                     |
| Context translation                          | `action_handlers :1326` routes through the shared translation prompt and ordinary prediction orchestration                                                                        | Source traced                                                                                   |
| Vision target / image / answers              | `vision_request`, capture script, private file deletion, transcription tags, sequential answer offer; flow generation                                                             | 30 screen cases passed; native capture unavailable                                              |
| Vision scope separation                      | Vision OWNER differs from prediction and control requests                                                                                                                         | Source traced; no unintended prediction cancellation inferred                                   |
| Agent command/selection                      | `run_agent`, `system2_payload`, parsed schema, offered actions and explicit acceptance                                                                                            | 39 agent-flow cases passed                                                                      |
| Automatic System 1 / System 2                | Owned chat targets, pause timer, privacy/app exclusion, learned intent thresholds, waits on busy backend                                                                          | 25 auto-agent cases passed                                                                      |
| Connector lifecycle                          | Validated args, tool allowlist, bounded native tool process, desktop handoff, shutdown debt                                                                                       | 38 connector-lifecycle cases passed with native luv loaded; no actual desktop connector invoked |
| Learning persistence                         | Shared policy and source-aware store; auto-agent acceptance/dismissal tests                                                                                                       | Auto-agent persistence test passed after native dependencies available                          |
| Configuration transitions                    | Runtime source generation, owned acquisitions, quiesce, pause/shutdown, receipt checks                                                                                            | Source traced, not a full bootstrap/install audit                                               |

## Refutations and bounded hypotheses

- **Remote token streaming is not an accidental missing Linux call.** `_shared/lua/llm/display_policy.lua:51` allows progressive tokens on macOS and Linux Ollama, not Linux API. macOS remote-client header `macos/modules/llm/api_remote.lua:22` explicitly explains that remote streaming is intentionally off because the codecs differ and short completions offer limited gain. Linux `api_remote.lua:839` also sends `stream=false`, with a whole-text chunk notification. This belongs in the intentional feature matrix, not a newly claimed runtime defect.
- **An arbitrary fake `postStream=false` is insufficient to establish an additional production bug.** It can leave the Ollama private active slot set if no callback follows, but many real HTTP preflight refusals synchronously invoke a terminal callback (`adapters/http_client.lua:67`, `:130`). The final confirmed translation probe therefore uses real remote cancellation refusal, not that weaker artificial port behavior. No third finding is promoted from this hypothesis.
- **Partial local text before a terminal marker is deliberate progressive display.** Existing terminal-protocol tests reject malformed completion and fence stale callbacks; the engine permits accepting a displayed partial and revokes callbacks first (`prediction_engine.lua:2997`). The audit does not classify a progressive row as an already verified final response.
- **Missing agent/tone/vision implementations refuted.** Real action handlers exist at `prediction_engine.lua:1322`–`:1342`, and production ports are supplied by the daemon. Executed functional cases use these real action orchestrators, rather than just checking filenames.
- **Secure-focus absence is not treated as unrestricted authorization.** Resident privacy and scope checks are present on prediction/selection/output paths. The native accessibility/session behavior remains outside the executable checks here.
- **Local vision runtime identity, capture cancellation settlement and late account changes remain bounded runtime questions.** They require a complete native/controller transition transcript before making a new defect claim; source differences alone are insufficient.

## Intentional OS differences and constraints

The classifications below distinguish a documented design, a platform/native constraint and an implementation distinction whose product intent is not established.

| Difference                                      | Classification and justification                                                                                                                                                     | User-visible behavior and OS equivalent                                                                                                                                                                                                                                       |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Remote token streaming off                      | Explicit documented design: macOS remote client header `:22`–`:29`; generic Linux request also uses `stream=false`; shared `display_policy.lua:51` advertises supported combinations | Linux/macOS API completions arrive whole; local Ollama can update the bubble progressively. Windows token display is explicitly disabled/unvalidated in existing parity documentation; do not conflate it with inline insertion.                                              |
| Direct insertion while generation arrives       | Explicit existing platform restriction (`platform_reason.inline_autotype_is_windows`; engine `M.is_auto_inject :4083` returns false on Linux)                                        | Linux/macOS display an offer to accept; Windows provides the separate inline insertion mode.                                                                                                                                                                                  |
| Screenshot tools and desktop/session support    | Native constraint, not universal Linux support: `adapters/screen_capture.lua:65`–`:94` chooses grim/slurp, GNOME, Spectacle or maim; scaling depends on ImageMagick                  | Vision action availability depends on the installed tool and compositor. Windows/macOS have their native capture adapters; a shared vision action does not prove every session supports capture.                                                                              |
| Agent calendar/task/mail                        | Intentional native integration strategy documented by connector ownership: Linux `agent_connectors.lua:324` uses calendar imports; `:369` uses xdg-email or mailto                   | Linux hands an import/draft to the configured desktop app. macOS creates native Calendar/Reminders records and Mail drafts via AppleScript; Windows uses Outlook where available or import/mailto fallback. Handoff success is not proof the user imported the calendar item. |
| Personal agent tools                            | Platform implementation distinction; no source-backed claim that isolation semantics are identical                                                                                   | Linux executes a named executable from its allowlisted tools directory; macOS invokes Shortcuts; Windows supports its script tools. Shared agent action intent exists across hosts, while tool files and execution runtimes are not portable.                                 |
| MLX local runtime                               | Platform hardware/runtime constraint, already documented                                                                                                                             | Apple Silicon/macOS has MLX; Linux provides Ollama/local-server routes. This audit did not test hardware/model availability.                                                                                                                                                  |
| Model-to-profile following                      | Existing behavior distinction, documented prior audit; canonical recommendation policy exists on Linux `model_profile.lua` and profile setting resolver                              | Linux/Windows support persistent model-following; macOS applies the recommendation on request. Do not infer a missing profile system.                                                                                                                                         |
| External same-address local service replacement | Explicit observability limit in `prediction_engine.lua:3374`                                                                                                                         | Managed runtime identities can be fenced; replacing an unrelated external server behind the identical URL cannot be established solely from the driver's runtime receipt. Not claimed as a newly found parity bug.                                                            |

## Executed verification and limitations

Toolchain: Lua 5.4.8 with dynamic module loading, real lfs 1.8 and luv 1.50 supplied from `/workspace/scratch/parity-toolchain/`. Environment:

```sh
PATH=/workspace/scratch/parity-toolchain/bin:$PATH
LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu
LUA_CPATH='/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;'
```

- `python docs/audits/platform-parity/2026-11-04-deep/linux-llm/run-tests.py`: **417 passed, 0 failed**, across 14 focused existing test modules. Exact per-module counts and raw logs are in `test-results.json` and adjacent `*.log` files.
- `probe-ollama.lua`: real backend/callback ownership reproduction passed with only runtime-receipt and transport boundaries controlled.
- `probe-translation.lua`: actual existing scenario constructor plus real engine/remote backend reproduction passed; native HTTP cancel boundary scripted.
- Initial focused runs before the expanded native module path had missing-luv/file/modal/persistence fixture failures. Those were not promoted into product findings. After loading real native dependencies, all 14 selected modules passed; retained final logs reflect that complete rerun.

The test runner isolates the driver's home and uses scenario-owned fake boundaries; native process/file dependency presence does not turn simulated desktop/HTTP/keyboard scenarios into hardware validation. No cloud keys, local model, native GTK/AT-SPI desktop, compositor, real clipboard/selection insertion, live screenshot, real mail/calendar program or Windows/macOS execution was used. No latency/rate claim is made from these unit timings. The full repository/CI/LuaJIT suite was not run for this read-only audit.
