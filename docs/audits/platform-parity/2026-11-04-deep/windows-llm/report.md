> Integration correction: WL-001 is NOT retained as a confirmed defect. The author [self-countercheck](peer-validation.md) supersedes the original certainty classification; acceptance-retirement policy remains unresolved.

# Deep parity audit: Windows × LLM prediction execution and actions

Audited SHA: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`.
Date: 2026-11-04. Read-only runtime/source audit; no repository changes.
All production paths below are relative to `static/ergopti_plus/` unless stated otherwise.

## Result and proof boundary

Two bounded source passes traced Windows prediction/action admission, request identity,
retry/stream/dedup, cache, acceptance/output accounting and pause/cancellation.
One new confirmed source defect concerns a queued AI-agent acceptance callback after
pause or AI switch-off. It has a deterministic extracted-owner AHK reproducer, but
that reproducer was **not executed**: this Linux workspace has neither AutoHotkey
nor Wine. “Confirmed” here means the complete producer-to-consumer source path is
present and the consumer violates the explicit pause invariant; it is not a live
Windows reproduction claim. No live providers, hooks, clipboard or app connectors
were exercised.

The previously reported Linux sequential retry gap and Windows retry implementation
are not new findings and are not duplicated in findings.json. Earlier report:
`docs/audits/platform-parity/2026-11-04/llm.md` (it audits an older SHA).

## WL-001 — Accepted agent action can execute after pause or AI switch-off

Severity: medium. Confidence: high (complete source trace; native execution pending).
User effect: a calendar/task/mail/personal-tool connector already queued on acceptance
can start after Ergopti+ has been paused or its AI has been switched off. The UI has
already considered the offer accepted, so retirement does not cancel that work.
This does not imply that an unaccepted model proposal runs automatically.

Producer and consumer:

- `windows/modules/keymap/llm_bridge.ahk:2021`: `LLM_Bridge_OnAccept` obtains an
  agent slot handler, completes the accepted-offer lifecycle, then calls
  `SetTimer(Handler, -1)` at line 2025. This callback is neither registered with
  the agent scheduler nor retained by its cancellation owner.
- `windows/modules/llm/agent_action.ahk:598`: `_LLM_Agent_Show` binds the original
  `Flow` and `Action` to `_LLM_Agent_Accept`.
- `agent_action.ahk:622`: `_LLM_Agent_Accept` proceeds to `Connector.Call` at line
  628 without checking `A_IsSuspended`, `LLM_Menu_AiEnabled()` or
  `_LLM_Agent_IsCurrent(Flow)`; logging and completion notices are also unconditional.
- `agent_action.ahk:1093`: `LLM_Agent_OnSuspend` retires through `_LLM_Agent_Withdraw`.
  AI switch-off does the same at line 1104. `_LLM_Agent_Withdraw` increments the
  generation at line 1116 and cancels the automatic typing pause; neither action
  invalidates the bound acceptance callback at its actual side-effect boundary.
- Explicit contract: `docs/memory/windows-ahk.md:443`, “Every such callback that can
  type, display UI, record activity, or start network work must explicitly honor
  A_IsSuspended.” Native Suspend does not disarm SetTimer callbacks.

Deterministic schedule: offer an action, accept it, intercept its queued one-shot
before it runs, pause/switch AI off (generation advances), then release the queued
callback. It still calls the connector. The already accepted action is the only
one reproduced; ordinary text acceptance uses TextSender admission and does not
follow this unguarded branch.

Artifact `repro-retired-agent-accept.ahk` contains the verbatim production
`_LLM_Agent_Accept` body with only logger/connector/notice seams stubbed. It captures
an old flow, sets a newer global generation, pauses, invokes the saved callback,
and exits nonzero if a connector runs. Run with AutoHotkey v2 `/ErrorStdOut` on
Windows; current source is expected to print `connector calls ...: 1` and exit 1.
This expectation is source-derived, **not** a reported execution result.

Existing tests cover accepted action execution and retirement of a typing pause,
not this boundary: `windows/tests/unit/modules/llm/actions/test_llm_agent.ahk:670`
invokes the handler immediately; `test_llm_agent_ai_off.ahk:175` exercises an armed
System 1 typing timer under pause. A useful regression must queue the genuine
accepted handler through the bridge, retire it on pause and AI-off independently,
release it and require zero connector/learning/notice calls; keep the active-flow
success control. Guard/recheck immediately before connector dispatch, not only when
the offer is painted. A tracked cancellation owner should settle queued callbacks.

Narrow comparison: Linux `linux/modules/llm/prediction_engine.lua:3060` calls the
candidate handler synchronously inside acceptance; there is no matching untracked
SetTimer interval. macOS `macos/modules/keymap/llm_bridge.lua:1657` applies the
slot's own acceptance handler through `xpcall`, and
`macos/modules/llm/agent_runner.lua:531` starts its connector there. That proves
absence of this particular Windows detached-timer handoff, not immunity to every
possible reentrant callback on those OSes.

## Coverage register — pass 1: forward behavior trace

| Boundary                | Audited owners and conclusion                                                                                                                                                                                                                                                                                                                                                                                                            |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Menu/config → request   | `windows/ui/menu/menu_llm/menu_settings.ahk:960` manual refusal, `:982` ordinary trigger, `:1133` chosen profile; `prediction_engine.ahk:432` initialization and `:500` enabled transition. Shared prompt/action defaults are generated and tested. Explicit actions retain their own count/profile without mutating global options.                                                                                                     |
| Privacy admission       | `prediction_exec.ahk:274` fire rejects suspended/disabled/empty; secure-field gate at `:332`, app exclusions at `:376`; `_LLM_Engine_ShouldSuppressForDisabledApps:211` detaches policy and fails closed for missing/invalid app identity. No new missing privacy gate established in this prediction path.                                                                                                                              |
| Prompt/request identity | `prediction_engine.ahk:347` semantic refresh stops generation before publication; `:378` request signature binds resolved profile, its content, override count and live-mode marker. `prediction_exec.ahk:436` resolves application or explicit profile before cache. Translation target becomes resolved profile content, so it is not absent from the effective signature.                                                             |
| Dispatch/pacing         | `prediction_exec.ahk:392` owned warmup retry, `:569` shared-plan rate-floor decision, explicit override bypass, `:603` inline single-candidate rule, `:642` remote and `:659` local transport closures. Retry timers retain source/profile arguments and are cancelled through stored pending_timer.                                                                                                                                     |
| Retry/stream/dedup      | `prediction_exec.ahk:123` shared retry budget adjustment; `:922` sequential loop bounds attempts and stops when enough unique slots; `:982` retry never streams; `:1042` success aggregates metadata and exact-case dedup; `:1100` failure disables streaming fallback and arms retry. Windows production streaming is capability-disabled, so streaming callbacks are defensive/tested infrastructure, not an available product option. |
| Batch/parse             | `prediction_exec.ahk:680` batch state and separate dispatch; `:1290` `_LLM_Engine_ParseSlots` records erasure/display metadata. Existing previous report establishes core action presence, so batch dispatch is not re-counted as a new feature.                                                                                                                                                                                         |
| Cache                   | `prediction_exec.ahk:507` exact and `:530` prefix probes require semantic ownership; `:1252` every erase-bearing slot disables caching, including ordinary correction slots. Prefix slicing is case-sensitive.                                                                                                                                                                                                                           |
| Render                  | `prediction_exec.ahk:1396` final inline path guards pause, identity and TextSender admission; ordinary render rechecks identity after focus/display lookups at `:1478`, enforces hotstring priority and publishes source/lifecycle via one surface owner at `:1496`.                                                                                                                                                                     |
| Acceptance              | `windows/modules/keymap/llm_bridge.ahk:672` canonical claim transaction; `:2004` stop/invalidate generation before output; `:192` admission binds HWND, control, physical/content/context generations and request ID, and rejects pause; `:374` hands this predicate to TextSender. Agent handler branch is WL-001.                                                                                                                      |
| Metrics/output          | `llm_bridge.ahk:387` prepares canonical output journal with original source HWND, predictions, selected index and deletion metadata; includes suggested denominator for inline/unoffered output. `:2077` completion owns exact presentation teardown/claim release. `prediction_exec.ahk:1204` generation logs aggregate token usage/cost. This is a source trace, not proof that native SendInput/clipboard output arrived.             |
| Action owners           | `tone_action.ahk:156/:279/:367`, `translate_action.ahk:80/:249`, `vision_action.ahk:171/:558/:785`, `agent_action.ahk:393/:573/:702`: explicit refusal and auxiliary/current-generation fences are present. Connector implementations themselves were compared only to classify platform integration, not exhaustively audited.                                                                                                          |

## Coverage register — pass 2: reverse ownership and adversarial candidates

- Superseded callbacks: `_LLM_Engine_IsCurrent` at `prediction_exec.ahk:1135`
  requires both request ID and semantic signature. Dispatch, partial, success,
  failure, finalize and last render boundaries check it. No newly confirmed stale
  ordinary prediction output was found in this bounded traversal.
- Pause/disable/navigation: `prediction_keystats.ahk:232` StopGeneration cancels
  pending timer/transports, bumps ID and clears both signatures/cache/display
  metadata; `:275` CancelInflight only retires callbacks/transports and intentionally
  preserves cache/debounce ownership for typing. `LLM_Agent_OnSuspend` separately
  retires the agent generation. The untracked accepted handler escapes that owner.
- Acceptance replay: `LLM_Bridge_OnAccept` retires prediction generation before
  TextSend, with exact record/lifecycle completion and deferred claim release.
  Agent side effects bypass TextSend and therefore require their own fence.
- Candidate refuted: correction-cache loses erasure and appends the corrected word.
  Finalize explicitly clears the cache for **any** nonempty rewrite_edits map at
  `prediction_exec.ahk:1252`, not only rewrite profiles. Earlier guard at fire alone
  is not the complete cache writer.
- Candidate refuted: translation override target omitted from cache signature.
  `prediction_exec.ahk:439` resolves a target-specific profile before
  `_LLM_Engine_RequestSemanticSignature`, which signs that profile's contents.
- Candidate refuted: `tokens || call_tokens` coerces the actual token budget to 1.
  AutoHotkey v2 logical OR returns its first truthy operand, unlike some other
  languages. Upstream v2 language reference `Variables.htm#or` was retrieved from
  AutoHotkeyDocs/v2 and checked; normal/retry budgets remain values. Native
  dispatch tests remain necessary and were not substituted with JavaScript semantics.
- Candidate bounded: generation and failed-generation events read current app ID
  at logging time (`prediction_exec.ahk:1171/:1208`) while output attribution uses
  request-owned source HWND. Whether generation telemetry should attribute the
  original app is not settled here; not promoted to an actionable parity defect.
- New comparison detail, not an intentional-difference claim: Windows counts each
  failed/empty dispatch inside `max_attempts = n * max_multiplier`. macOS remote
  `api_remote.lua:3448/:3490` additionally allows a second inner attempt with more
  tokens for each outer variant. Thus an all-failure transcript can spend 2N versus
  4N HTTP attempts respectively for multiplier 2. The previous report established
  retry existence, not identical maximum-call semantics. Shared naming alone does
  not decide the intended budget, so this is an unresolved policy asymmetry, not
  a second confirmed Windows defect.

## Intentional and policy-dependent behavior register

| Behavior                                             | Status / rationale                                                                                                                                                                                                                      | User effect                                                                                                                                                                                                                          | Other OS equivalent                                                                                                                                                                                                                                                              |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows inline auto-type                             | Explicit platform restriction: feature manifest `llm.trigger.inline_autotype`, reason `platform_reason.inline_autotype_is_windows`; implementation rationale `prediction_exec.ahk:1400`: only final render to avoid racing live typing. | Final continuation is injected automatically; erasing rewrites/corrections remain offered for acceptance. Exactly one alternative dispatched at `:603`. This is completed-response insertion, not token-by-token document streaming. | macOS/Linux display bubble and require acceptance. Why this mode has not been ported is not stated beyond the restriction; do not invent an OS impossibility.                                                                                                                    |
| Windows token-display streaming disabled             | Explicit validation restriction: shared menu reason `platform_reason.token_streaming_unvalidated_on_windows`; `prediction_engine.ahk:127` capability drives menu and runtime together.                                                  | Windows never enables token-by-token tooltip display through admitted production settings, despite callback/transport infrastructure.                                                                                                | macOS/Linux can use their capable backend's partial frames. This is pending Windows validation, not an intentional permanent absence.                                                                                                                                            |
| Windows avoids aborting stacked WinHTTP on each fire | Explicit implementation comment at `prediction_exec.ahk:585`: stacked Ollama /api/chat Abort returned empty content; old callbacks still rejected by identity.                                                                          | Old local nonstream request may finish while a new request queues; typing/cancel/stop has a separate cancellation owner.                                                                                                             | macOS-style stream cancellation is referenced; exact local transport queue equivalence was not live-tested.                                                                                                                                                                      |
| Explicit API test survives typing cancellation       | Explicit comments at `prediction_keystats.ahk:258/:288`; cancel-all exempts LLM_REMOTE_KIND_API_TEST. Routed memory says test deliberately bypasses engine to avoid producing accept-able document text.                                | Typing should not silently kill an explicit provider diagnostic. This does not allow automatic predictions during pause.                                                                                                             | Shared test_request catalogue is checked across drivers; native diagnostic cancellation scopes not fully replayed.                                                                                                                                                               |
| Agent connectors                                     | Platform-specific implementation, rationale inferred from native services, not an explicit portability decision. Windows Outlook or import/mailto; personal .ps1/.cmd/.ahk.                                                             | Integration strength/application launch behavior depends on host applications.                                                                                                                                                       | macOS Calendar/Reminders/Mail/Shortcuts; Linux desktop calendar/task import, xdg-email/mailto and executable personal tools. Not equivalent native application APIs, all are action families. Previously documented; included to make intentional/inferred distinction explicit. |
| Automatic model-profile following                    | Known policy asymmetry from previous audit, not newly independently exhaustively replayed.                                                                                                                                              | Windows/Linux can follow model profile automatically; macOS offers recommendation to apply manually.                                                                                                                                 | Document as product policy with its prior evidence; intent is not inferred merely from different code.                                                                                                                                                                           |
| Accepted-agent deferred timer                        | Bug WL-001; no documented intentional exemption from pause.                                                                                                                                                                             | Connector may run after retirement.                                                                                                                                                                                                  | Synchronous other-OS acceptance is the narrowly inspected counterpart.                                                                                                                                                                                                           |
| Retry attempt accounting                             | Unresolved policy asymmetry, not documented intent.                                                                                                                                                                                     | All-failure provider request counts/billing and time-to-failure can differ Windows/macOS.                                                                                                                                            | Linux's previously known absence of refill/retry is separate.                                                                                                                                                                                                                    |

## Executed verification

- `node tools/test/test-windows-llm-accept-injection.cjs`: PASS, 15 source checks.
- `node tools/test/test-llm-prompt-actions-single-source.cjs`: PASS, 324 checks.
- `node tools/test/test-llm-test-request-single-source.cjs`: PASS.
- `node tools/test/test-llm-no-prompt-content-in-logs.cjs`: PASS, 2664 logger lines
  across 242 files. This pins normal logger call sites, not keystats privacy policy.
- Source probe/extracted-owner fixture generation: PASS; output in source-probe.txt.
- Native AHK reproducer and full AHK unit suite: NOT RUN (no AutoHotkey/Wine).
- macOS Hammerspoon/Linux Lua runtime and provider integration: NOT RUN.
- Repo source edits: none. No feature implementation/policy changes were made.

## Boundaries remaining

This is a two-pass Windows execution/actions audit, not an exhaustive proof of all
LLM provider parsers, model lifecycle, secret stores, connector COM/process code,
request cancellation under every native desktop timing or every feature on every
OS. A generated inventory should represent source availability, intentional
restriction, test status and unverified native support separately. The detached
agent timer bug is invisible to a declaration-only inventory.
