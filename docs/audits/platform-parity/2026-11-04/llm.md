# Ergopti+ LLM / AI parity source audit

Audit date: 2026-11-04. Revision inspected: c2fa6197b2be521df5bd0bfa71ee2a3805e9838d.
Read-only audit; no repository source, documentation or generated artifact edited.

## Result

The core AI action families have production implementations on all three OSes: text prediction, chosen/built-in prompt actions, live mode, rewrite, translation of context and selection, tone ladder, screenshot reading/answers, and the two-stage agent with learning and connectors. File naming differs substantially. In particular Linux's large prediction_engine.lua owns operations split across numerous Windows/macOS modules. There is one newly identified behavioural parity gap: Linux does not recover failed/empty/deduplicated sequential predictions using the retry budget and expanded token budget implemented on Windows/macOS. There is also one demonstrably stale existing TODO claiming the Windows retry implementation is missing.

This is source-level coverage of the named feature families, not a claim that every model/provider works live. No native driver or live cloud/local model was executed in this environment.

## NEW: Linux lacks sequential prediction recovery / retry policy

User-visible effect: for a requested set of three non-batch predictions, Linux stops after three successful transport completions even when all completions parse to the same candidate; only one candidate is offered. A failed HTTP request stops the remaining sequence immediately. An empty or invalid completion spends one of the fixed calls without the extra token/temperature retry. Windows/macOS can spend additional attempts to fill the requested results and increase the per-call budget when a response is unusable.

This conclusion does not rely on the stale “both drivers” comment in inference.json:

- Actual shared policy values are `_shared/modules/llm/inference.json:20`: max_multiplier=2, retry_temperature_step=0.18, retry_extra_tokens=5.
- Linux loads that JSON in `linux/modules/llm/inference.lua:30`, but its only public runtime policy API is `variant_temperature` at line 61. It validates/consumes `diversity_temperature`; it exposes no retry policy.
- `linux/modules/llm/prediction_engine.lua:896` gets the number of calls from shared batching, not an attempt budget based on retry.max_multiplier.
- Linux's actual production request dispatch at lines 1021-1040 passes ordinary variant temperature and ordinary token budget. There is no failed-attempt state or retry adjustment.
- The completion callback at line 1057 sets `_predicting=false` and returns on a transport error, rather than proceeding through bounded retry recovery.
- Lines 1065-1079 parse/deduplicate results then continue only while `request_index < batching.calls`. They do not compare the number of accepted candidates to the requested number for recovery.
- Existing BEHAVIOURAL test `linux/tests/unit/modules/llm/prediction/test_prompt_prediction.lua:216` is particularly useful evidence: it drives the real engine, registry, builder, parser and remote client with faked HTTP. Lines 229-232 answer all three calls identically and assert exactly three HTTP posts and only one offered rewrite. This already pins the current dedup-without-refill behaviour.
- By comparison macOS `macos/modules/llm/api_remote.lua:3448` computes max attempts from requested_predictions and retry policy, and line 3471 stops only once the requested results are filled or the attempt budget is spent. Lines 3501-3506 add `_R_EXTRA_TOKENS` and `_R_TEMP_STEP` for a failed variant. The actual Ollama branch does the same at `macos/modules/llm/api_ollama.lua:2309`.
- Windows `windows/modules/llm/prediction_exec.ahk:1281` computes a max-attempt budget from `LLM_ApiCommon_GetRetryPolicy()`. `_LLM_Engine_ArmRetry` at line 123 stores extra token and temperature values. Line 942 consumes that stored retry; line 1081 arms it for empty parsing, and line 1119 arms it for a failed request. This is called production code, not merely a declared configuration setting.

Suggested TODO: “Linux: apply the shared bounded retry policy to sequential predictions, including failed/empty/invalid completions and refill after deduplication; preserve request ownership, cancellation, pacing, aggregate usage and streaming semantics. Add a cross-driver scripted-transcript regression for request count, resulting slots, token and temperature budgets.”

Do not implement an unconditional retry of every failure: ownership/cancellation and provider accounting make this a separate behavioural change requiring proper regression tests. This audit task only documents the gap.

## Refutation: Windows retry_extra_tokens is already implemented

`TODO.md:388` currently says “retry_extra_tokens has no Windows owner, so the corpus retry rows are not replayed there.” This is stale at the inspected revision:

- `windows/modules/llm/api_common.ahk:247` returns all three shared retry numbers.
- `windows/modules/llm/prediction_exec.ahk:123` arms the policy and line 942 passes the retry token count into actual dispatch.
- `windows/tests/unit/modules/llm/prediction/test_llm_prediction_engine_state.ahk:696` registers the test “a retried attempt gets the policy's extra tokens and temperature”.
- The adjacent regression at lines 702-726 verifies the retry does not stream and that the next normal variant streams again.
- `windows/tests/meta/corpus/test_corpus_llm_small_families.ahk:94` now routes retry-token corpus rows to `_LLM_Engine_RetryTokenBudget`.

Remove/update that specific stale sentence; do not mark its unrelated live IBM/Google validation completed.

## Coverage and positive implementation evidence

Paths below are relative to `static/ergopti_plus/`.

### Predictions, prompts, profiles and settings

- Windows runtime: `windows/modules/llm/prediction_engine.ahk`, `prediction_exec.ahk`, `prediction_live.ahk`, `prompt_action.ahk`, `profiles.ahk`. Chosen prompt action comes through the actual gesture dispatcher rather than requiring a macOS-style shortcut dialog.
- macOS runtime: `macos/modules/llm/prediction_engine.lua`, `streaming_handler.lua`, `profiles.lua`, `prompt_builder.lua`; native bridges at `macos/modules/keymap/llm_bridge.lua`.
- Linux action registration is explicit at `linux/modules/llm/prediction_engine.lua:1322`: ordinary trigger, chosen prompt, context translation, live mode and one preset per built-in profile. The handlers call actual engine functions.
- Linux custom profile persistence uses shared registry codec at `linux/modules/llm/profile_settings.lua:18`, decoding at line 201, encoding on mutation at lines 537 and 581. There is no evidence that user-created profiles are absent there.
- Linux production composition is `linux/ergopti_hotstrings.lua:1685`: prediction injection, selected-text reading/replacement, exact focus identity, agent command dialog and screenshot capture are all supplied to the engine. They are not test-only seams.
- Linux generation menu exists: `linux/ui/menu/menu_llm.lua:842` constructs prediction count, min/max words, temperature, context, auto temperature and reset-navigation controls through settings modules.
- Existing known asymmetries remain: Windows token streaming display disabled/unvalidated; direct inline streaming insertion Windows-only; persistent model-to-profile automatic following Windows/Linux, recommended-profile application on request on macOS; MLX Apple Silicon only. No new missing family found here.

### Tone, translation, vision

- Windows tone action registration: `windows/modules/llm/tone_action.ahk:75`; real Ollama dispatch line 222. Translation orchestration: `translate_action.ahk`; vision mode mapping `vision_action.ahk:86` and chat transport line 590 onward.
- macOS actual gesture registrations: `macos/modules/gestures/actions.lua:1295` (tone), 1315 (three screen actions), 1340 (context translation), 1345 (selection translation). The keymap imports the real implementation modules at `macos/modules/keymap/llm_bridge.lua:39` and exports screen/translation bridges at lines 2068 and 2082.
- Linux registers all three screen actions, translation and tone handlers in `linux/modules/llm/prediction_engine.lua:1337`. `vision_request.lua` builds real local/remote requests, `translation.lua` loads the shared prompts/language list, and engine production selection/capture dependencies are supplied at `linux/ergopti_hotstrings.lua:1703` and 1741.
- All use shared tone/translate/vision data and algorithms, with platform-specific native capture/selection orchestration. Linux screenshot capture depends on the session's available desktop tools (`linux/adapters/screen_capture.lua:11` onward). Do not promote the presence of that adapter into a guarantee for every Wayland desktop.
- Existing behavioural tests include Linux `tests/unit/modules/llm/features/test_tone_selection.lua`, `test_translate_selection.lua`, `test_screen_answers.lua`; macOS `tests/unit/modules/llm/features/test_tone_rewrite_end_to_end.lua`, `test_selection_translation_end_to_end.lua`; Windows `tests/unit/modules/llm/actions/test_llm_tone.ahk`, `test_llm_translate.ahk`, `test_llm_vision.ahk`. They were inspected/discovered, not executed here.

### Agent, learning, connectors

- Actual action wiring: Linux `linux/modules/llm/prediction_engine.lua:1340` through 1342; macOS `macos/modules/gestures/actions.lua:1364` through 1366; Windows `windows/modules/llm/agent_action.ahk:280`, 343, 362 implements automatic toggle, selection and typed-command entry points.
- All use shared `agent.json` intent/action schema and shared planning/learning logic (Lua or Windows port). Linux learning persistence has explicit behavioural tests `linux/tests/unit/modules/llm/agent/test_agent_learning_store.lua` and `test_agent_learning_source.lua`; macOS learning store has its own tests.
- macOS creates Calendar/Reminders entries and Mail drafts using AppleScript (`macos/modules/llm/agent_connectors.lua:96`, 131, 151) and runs Shortcuts via argv (line 267).
- Windows uses Outlook where available, otherwise calendar/task import and mailto, and personal `.ps1`, `.cmd`, `.ahk` files (`windows/modules/llm/agent_connectors.ahk:112`, 153, 185).
- Linux hands events/tasks to desktop calendar import and drafts to xdg-email/mailto (`linux/modules/llm/agent_connectors.lua:324`, 369) and runs executable personal tools. These are platform-specific connector integrations, not missing agent features. Their stronger native-application integration is not identical and could be displayed separately if desired.
- Automatic agent and app-specific prompts inherit the driver's native focus/app-identification limits. Linux compositor-specific restrictions are already tracked by the root audit and should be cross-linked, not counted again as absent AI actions.

### Local/remote models, providers and secrets

- The three remote clients read canonical `api_providers.json`, rather than having independent provider lists: Windows `windows/modules/llm/api_remote.ahk:2544`; macOS `macos/modules/llm/api_remote.lua:209`; Linux `linux/modules/llm/api_remote.lua:231`. All support generic chat requests (Linux actual exported chat at line 1163).
- All have local-server discovery integration using shared local_servers.json and managed Ollama setup/model lifecycle; macOS adds its intentional MLX runtime. Linux has actual model download/delete/warmup and managed runtime owners; no missing model lifecycle family was established.
- Routed memory explicitly records Perplexity Agent API on all drivers and catalogue-driven cloud providers. Live provider validation is distinct from static wiring parity. No available API keys/models were used.
- Secret storage/native HTTP/process mechanics differ. This audit does not call those separate missing product features, and did not attempt a cryptographic or security audit.

## Verification performed

Passed, executed directly:

```
node tools/test/test-llm-prompt-actions-single-source.cjs
# [OK] one prompt action per built-in profile, ordered, generated and labelled (324 checks).
node tools/test/test-linux-llm-defaults-single-source.cjs
# [OK] Linux LLM defaults single-sourced; owned port, temp, context, keep_alive.
```

Reproducible source probes:

```
rg -n 'retry_extra_tokens|get_retry_policy|GetRetryPolicy|ArmRetry|retry_call' static/ergopti_plus/{windows,macos,linux}/modules/llm
rg -n 'request_index < batching.calls|if err then|max_tokens =|temperature =' static/ergopti_plus/linux/modules/llm/prediction_engine.lua
sed -n '216,233p' static/ergopti_plus/linux/tests/unit/modules/llm/prediction/test_prompt_prediction.lua
sed -n '3448,3510p' static/ergopti_plus/macos/modules/llm/api_remote.lua
sed -n '690,728p' static/ergopti_plus/windows/tests/unit/modules/llm/prediction/test_llm_prediction_engine_state.ahk
```

`command -v lua` and `command -v luajit` found neither interpreter. Windows AHK/native and macOS Hammerspoon execution unavailable. Thus the native regression tests above are evidence of test intent/current asserted contract, not claimed green executions.

## Inventory automation implication

The new Linux retry gap is invisible to a manifest-only “setting is declared on OS” inventory: all OSes expose prediction count, but recovery semantics differ. Keep separate machine-readable capability rows for runtime behaviours (for example sequential_prediction_retry) with source evidence and tests. A generated feature list must distinguish declaration parity from behaviour verified by transcript/hardware tests. Neither a directory scan nor generated menu rows can prove completely exhaustive runtime parity on their own.
