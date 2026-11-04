# Deep parity audit: macOS × LLM execution, streams and actions

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`.
Date: 2026-11-04. Read-only audit; Windows audit artifacts preserved unchanged.
Paths below are relative to `static/ergopti_plus/`, unless marked otherwise.

## Result and scope

Two bounded passes covered macOS request planning/batching/retries, local/remote/MLX
stream callbacks, cancellation and identity, prediction acceptance and agent
connector boundaries. One new behavior defect is confirmed by execution of the
real Lua production composition: the request-scoped cumulative thinking filter
rejects valid new streams from later sequential variants and retries. Final
predictions still arrive; token-by-token display silently degrades after the first
independent stream, with a warning in the log.

This is real Lua 5.4.8 execution over repository Hammerspoon/transport doubles,
not a live Mac/native API claim. No provider credentials, model process, Quartz
input, AppleEvents, Mail/Calendar/Reminders or Shortcuts were invoked. Existing
Linux retry/refill gap and Windows retry-owner correction from
`docs/audits/platform-parity/2026-11-04/llm.md` are not new findings here.

## ML-001 — Sequential local streams share an incompatible cumulative filter

Severity: medium. Confidence: high; reproduced using real production fetch strategy
and real streaming handler, with recording transport/UI ports.

Conditions: enable token streaming and streaming-multi display; request at least
two candidates from a non-batch profile on MLX or Ollama. The first variant emits
one completion; the second variant starts another completion with a different
prefix, as independent generations normally do. The same fault occurs when a
failed stream has already emitted a partial and a retry starts another completion.

Evidence and complete producer/consumer chain:

- `macos/modules/llm/prediction_engine.lua:2083` creates one callback set for the
  entire requested generation; `:2192` passes it to core dispatch.
- `macos/modules/llm/init.lua:2136` uses the shared batching plan; non-batch profiles
  reach sequential/parallel strategies. Both local backends' parallel entry points
  delegate to sequential, so changing the sequential-mode toggle does not avoid it.
- `macos/modules/llm/api_mlx_fetch.lua:224` keeps `variant_partial = on_partial`;
  `:228` selects a new streaming dispatch for each independent variant;
  `:261` passes the same callback to every stream. Ollama has the same production
  logic at `api_ollama.lua:2291/:2295/:2322`.
- `macos/modules/llm/streaming_handler.lua:297` creates one thinking filter and one
  `partial_raw_seen` for the whole callback set. At `:310` it demands every later
  snapshot begin with the complete previous stream's raw text. On the normal
  second independent response it sets `partial_stream_valid = false`, logs
  “Streaming partial broke the cumulative-prefix contract — suppressing interim
  output.” and suppresses every following partial for the request.
- `streaming_handler.lua:432` only settles the filter at the final generation
  callback. Intermediate per-variant successes do not reset or replace it.
- Local quick retries also still choose streaming from the original `streaming`
  flag: MLX `api_mlx_fetch.lua:248–261`, Ollama `api_ollama.lua:2309–2322`, despite
  the adjacent explicit comment saying retries do not stream partial updates.
  Consequently retry restarts can hit the same poisoned filter even for one
  requested candidate. This is the same defect family, not counted twice.

Executed reproducer: `repro-sequential-stream-filter.lua` loads the production
`api_mlx_fetch` and `streaming_handler`, retains the real shared thinking filter,
and puts fakes only at transport/UI and parser-record seams. The parser seam
returns valid prediction records, isolating stream ownership from model grammar.

Observed, normal two-stream case (`repro-sequential-stream-filter.log`):

```
interim render: first independent completion
warning: Streaming partial broke the cumulative-prefix contract — suppressing interim output.
transport streams=2 interim renders=1 final candidate render=second independent completion
```

Executed retry mode (`repro-sequential-stream-retry.log`) emits a partial then
fails the first transport and succeeds on the retry: same warning, only one
interim render. Executed same-prefix control (`...-control.log`) makes the second
snapshot extend the first: two interim renders and zero warnings. This proves
that the failure is cumulative-prefix lifetime across independent streams, rather
than unavailable streaming, a parser failure, stale request or refused UI commit.
Ollama's identical dispatch path was independently exercised by
`repro-retry-dispatch.lua`: it dispatches a second streaming attempt and forwards
both partials. The full handler composition reproducer specifically uses MLX;
no live native Ollama/MLX process was launched.

User effect: later alternatives stop visibly filling token by token; after a
failed partial, even retry output stays frozen until completion. Final candidates
still render, which makes this easy to misread as ordinary slow model behavior.

Fix direction: carry an explicit stream/variant/attempt identity and create/reset
the thinking filter only at an admitted new stream boundary. Preserve the prefix
invariant **within** one stream; do not blindly reset whenever malformed snapshots
break prefix, which would weaken thinking-tag suppression. Decide and enforce
whether a retry is nonstreaming as the existing comments require. Regression:
compose real strategy and handler for two independent successful streams plus
partial-failure/retry, check interim renders for every intended stream, final pool,
and no thinking leakage. Keep same-stream malformed-prefix rejection and same-
prefix cumulative controls. Windows retry already uses a plain dispatch and local
partials have a per-slot callback (`prediction_exec.ahk:982/:1021`); admitted Windows
token display remains disabled, as previously documented. Linux streaming logic
is independent; no unexecuted claim of identical safety is made.

## Pass 1 — forward coverage register

| Surface                   | Audited path / conclusion                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Admission → plan          | `prediction_engine.lua:1657` perform_check captures request ownership; `:1948` advances request/fetch identities; `:2083` creates callbacks; `init.lua:2136` uses shared batching. Shared transcript tests execute real engine/core/remote/parser on timer/HTTP/tooltip fakes. No new absent core action family established.                                                        |
| Configuration identity    | `init.lua:1430` profile changes, `:1735` backend changes and model mutation fences; `api_remote.lua:2603` rejects changed remote identity/entry before parsing. Runtime/core identity and prebuilt-entry behavioral tests pass.                                                                                                                                                     |
| Local/remote/MLX dispatch | `api_ollama.lua:1989/:2244`, `api_remote.lua:3392/:3440`, `api_mlx_fetch.lua:97/:174`. Batch token budget uses shared TokenBudget.for_call; all three consume shared extra-token/temp-step retry policy.                                                                                                                                                                            |
| Retry/dedup               | Each backend fills unique result pool with bounded outer variants and an inner failure retry; dedicated request-fence tests pass for all three backends, stale completion and retry. Executed all-failure transcript records four network attempts for count=1 and multiplier=2 on all three macOS backends; see policy difference below.                                           |
| Streaming                 | Local/MLX execute independent streaming requests, all sharing one callback/filter; ML-001. Remote fetch ignores streaming argument by design. UI render guards, final watchdog cancellation, terminal receipt and payload-retirement tests pass.                                                                                                                                    |
| Pause/cancel              | `prediction_engine.lua:2770` reset revokes authority before external cleanup; tracks each timer/UI/backend stage and returns explicit cleanup_committed Boolean; `:3131` stop_timer cancels backend independently of current streaming setting. Native cancellation/refusal ownership is exercised through faithful fake handle start/stop/settled state, not native Mac processes. |
| Acceptance/text output    | `prediction_engine.lua:2912` consume fences and removes candidate before cleanup; `keymap/llm_bridge.lua:1684` dispatches ordinary/own acceptance; `:1754` preserves already accepted text despite incomplete native cleanup, suppresses chain and schedules cleanup retry; expander is single text transaction owner. Behavioral choke-point and own-acceptance tests pass.        |
| Agent actions/connectors  | `agent_runner.lua:531` runs connector only after acceptance; `:576` binds one handler per candidate; `agent_connectors.lua:185` process adapter ownership, `:303` dispatch to native app script or Shortcuts. End-to-end and connector tests execute generated argv/scripts on fake process/AppleScript boundaries, not native applications.                                        |
| Accounting                | Remote response classification extracts usage/cost (`api_remote.lua:2656/:2713`) and logs request outcomes; streaming handler logs visible successful pools at `streaming_handler.lua:442`; `keystats/init.lua:1700` projects log rows. Generation log granularity differs from Windows aggregate-final event; no dashboard count equivalence is asserted by this audit.            |

## Pass 2 — adversarial candidates and refutations

1. **Refuted as a general defect: accepting after reset=false.**
   `prediction_engine.consume` intentionally commits the logical acceptance before
   native teardown. Ordinary text path explicitly preserves accepted text when
   cleanup returns false (`llm_bridge.lua:1754`), stops chaining and retries cleanup.
   `test_apply_prediction_arms_guard.lua:113` pins false/nil/contained-throw behavior.
   `engine.reset` returns a real Boolean `cleanup_committed`, not a conventional
   nil success; `reset_predictions_impl` requires true and converts failures to false.
   A broad demand to cancel every explicitly accepted action after incomplete
   cleanup would contradict this existing product contract.
2. **Not promoted: own handler after runtime quarantine in reset.**
   `apply_own_acceptance` logs a refused reset and still calls `pred.on_accept`;
   unlike ordinary text, it has no new output transaction guard. The saved
   `repro-own-accept-after-quarantine.lua/.log` proves that a fixture which closes
   runtime quarantine _inside its fake engine.reset_ still reaches the handler.
   However a production reset → global-pause/action-epoch reentry causing that
   exact transition was not established. Mere artificial fixture mutation is not
   proof of native reachability. Excluded from findings.json. A future audit should
   start from a real reset external boundary if pursuing this candidate.
3. **Refuted: stale sequential retry dispatch.**
   Nine real strategy cases prove each backend consults request identity before
   retry and rejects completed stale variants, both streaming and nonstreaming.
4. **Refuted: backend switch lets remote completion publish.**
   `api_remote` identity-generation tests and prebuilt-entry tests prove old entries,
   modified token references and changed provider identity reject stale callbacks;
   current chat requests retain their own selected producer scope.
5. **Refuted: disabling streaming before reset skips old stream cancellation.**
   `prediction_engine.lua:2869` cancellation is unconditional; the code explicitly
   explains the live flag cannot own a previously dispatched stream. Retirement
   tests exercise failed stop/start settlement and old callbacks.
6. **Confirmed: request-local thinking filter is wrong scope for independent local
   streams.** Successful final completion and passing stale-fence tests do not
   protect interim stream state. ML-001 covers it with controls and actual composed
   production owners, rather than a source-only assertion.
7. **Accounting candidate bounded, not a new finding:** backend request logging plus
   handler pool logging can produce multiple generation records for a single UI
   request. Current instrumentation has no request-ID discriminator in log_llm's
   record projection; expected log granularity and downstream metric interpretation
   were not proven in this scope. Do not assert doubled dashboard counts.

## Intentional and unresolved differences

| Behavior                               | Provenance / rationale                                                                                                                                                                                                                                    | User impact / equivalent on other OS                                                                                                                                                                                                                          |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MLX on Apple Silicon, macOS 14+        | Explicit detector/module contract: `backend_detector.lua:8/:50/:138/:159`; committed wheel/runtime support determines architecture/OS floor.                                                                                                              | Supported Macs get native MLX; Intel Macs use Ollama/API. Windows/Linux use Ollama/local OpenAI-compatible servers/cloud, with no MLX feature claim. This is a runtime/platform restriction, not a missing generic local-AI action.                           |
| Parallel API aliases sequential        | Explicit `api_remote.lua:3520`: provider throttling, order and rate-floor coordination. MLX `api_mlx_fetch.lua:143` explains unstable model output under parallel fan-out; Ollama `api_ollama.lua:2226` delegates too without equally specific rationale. | Multiple requested variants may take sequential network latency even when menu mode is not “sequential”. Windows/Linux also serialize their ordinary variant loops; exact transport overlap timing is not native-tested.                                      |
| Remote token display not implemented   | Explicit remote fetch signatures ignore `_streaming`, `_on_partial`; code comments explain nonstream remote transport path.                                                                                                                               | Cloud/remote candidates arrive complete/progressively by candidate; capable local macOS backends can show tokens. Windows display streaming remains unvalidated/disabled; Linux remote implementation is separate, not assumed equivalent.                    |
| Accepted text survives cleanup refusal | Explicit source rationale at `keymap/llm_bridge.lua:1754`, tested false/nil/throw outcomes.                                                                                                                                                               | User's already accepted text is preserved, chaining held until cleanup settles. This is not an exemption from output admission/pause rules. Windows uses TextSender's separate atomic admission/journal transaction; Linux uses its own acceptance owner.     |
| MLX / managed Ollama enable gate       | Explicit routed memory `project-macos-llm-runtime-enable-gate` and core warmup guards.                                                                                                                                                                    | Restoring model/profile config with AI off must not start/load a model. All drivers have enabled/disabled AI scope; native lifecycle machinery differs.                                                                                                       |
| Apple application agent integrations   | Actual owners generate Calendar/Reminders/Mail AppleScripts and Shortcuts argv. Native-service choice is explicit code; reason for portability asymmetry is **inferred**, not a documented product decision.                                              | Native calendar/reminder creation and Mail drafts; drafts are reviewed, never auto-sent. Windows uses Outlook or import/mailto and script tools; Linux desktop import/email and executables. Family exists everywhere; application behavior is not identical. |
| Retry outer/inner accounting           | Executed actual macOS strategies: count=1, multiplier=2, all failures dispatch 4 requests. Windows counts actual attempts inside multiplier, yielding 2 for same policy; prior report proved retry exists, not equal maximum calls.                       | Different time-to-failure and potentially provider consumption. **Intent unresolved**; no explicit rationale or guarantee establishes which budget is desired, so not classified as intentional or a new Windows/macOS bug.                                   |
| Retry keeps streaming                  | Actual local strategy dispatch, despite explicit comment saying retries do not stream.                                                                                                                                                                    | A failed partial can poison request filter and suppress retry previews (ML-001). **Not intentional**; comment and execution disagree.                                                                                                                         |
| Inline automatic insertion             | Existing explicit manifest platform restriction; Windows-only completed-response insertion.                                                                                                                                                               | macOS/Linux use bubble then acceptance. Windows forces one candidate and withholds erase-bearing corrections from auto-typing. Why not ported to other OSes is not established as a native impossibility.                                                     |

## Executed validation and artifacts

Toolchain: real Lua 5.4.8, lfs 1.8 and luv 1.50 loaded from parent-owned scratch
build/extracted packages. Hammerspoon APIs remain repository stubs. Custom launcher
`run-targeted.lua` uses real repository helpers and exact selected test modules;
it does not claim full runner discovery or native Hammerspoon behavior.

Final targeted results: **198 passed, 0 remaining failures** across 20 selected
modules. Initial attempt had 4 source-scanning failures because luv was absent;
after the real luv module became available all 4 were re-run and passed. Logs:

- `targeted-tests.log`: first group, 90 pass + original four dependency failures.
- `retry-policy-and-fence-tests.log`: four source-scan checks plus nine request
  fence cases, all 13 pass; supersedes the missing-luv failures.
- `accept-stream-agent-tests.log`: 72 pass, including UI commit gates, agent
  end-to-end/connectors, own acceptance and accepted text/cleanup policy.
- `identity-tests.log`: 23 pass, covering runtime/action epoch, prebuilt entry
  ownership and MLX effective-model chain.
- `repro-sequential-stream-filter.lua` / `.log`: reproduced ML-001.
- `repro-sequential-stream-retry.log`: same owner composition, failed-partial retry.
- `repro-sequential-stream-control.log`: same-prefix control succeeds.
- `repro-retry-dispatch.lua/.log`: actual three backend strategy methods record
  stream/plain selection, token increase, four-attempt all-failure budget.
- `repro-own-accept-after-quarantine.lua/.log`: exploratory candidate; **not a
  confirmed product bug**; production quarantine reentry not established.

No native Mac tests, live model/provider requests, model download/bootstrap,
AppleEvent permissions or actual document output were run. No repo edit, commit
or push was performed. The completed Windows artifact directory was not changed.

This bounded audit cannot prove total feature exhaustiveness from declarations.
Inventory should expose token display as partial under sequential local variants
until ML-001 is fixed, and distinguish declared support, known restrictions,
behavioral transcript checks and native validation.
