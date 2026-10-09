# llm (AHK)

## Purpose

Windows port of the LLM prediction subsystem. `llm_bridge.ahk` maintains a rolling typing-context buffer by intercepting printable keystrokes and backspace, then fires a debounced async request to the prediction engine. `prediction_engine.ahk` sends requests to Ollama (local) or a remote endpoint and streams tokens into a tooltip. `profiles.ahk` manages prompt profiles. `models.ahk` handles model listing and selection.

## Ports used (`_shared/core/ports/`)

| Port              | Usage                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| `KeyboardHook`    | Intercepting printable chars and buffer-reset keys (Escape, Enter, Tab) |
| `HttpClient`      | REST calls to `api_ollama.ahk`, `api_remote.ahk`                        |
| `TooltipRenderer` | Streaming token display during prediction                               |
| `TimerScheduler`  | Debounce timer between last keystroke and the LLM request               |
| `Storage`         | Reading and writing profile / model configuration                       |

## Domain module (`_shared/core/domain/`)

- `PromptBuilder.js` — `prediction_engine.ahk` builds prompts following this contract
- `ProfileSelector.js` — `profiles.ahk` manages profile selection following this contract

LLM output diff-coloring (`process_prediction`) lives in the shared Lua canon
`_shared/lua/llm/parser.lua`; the AHK port is `modules/llm/parser.ahk`, pinned to
the same `_shared/tests/corpus/llm/process_prediction_vectors.json` golden corpus.
Its rewrite mode (a `REWRITE:` answer) is the one prediction whose erasure the
accept path applies. `rewrite.ahk` ports `_shared/lua/llm/rewrite.lua` (the
sentence a rewrite prompt rewrites, its token budget) and `prompt_action.ahk`
ports `_shared/lua/llm/prompt_action.lua` (the `llm_prompt` value of the
`llm_prompt_prediction` action), each pinned to its shared corpus.
`tone.ahk` ports `_shared/lua/llm/tone.lua` (the tone ladder, pinned to
`tone_vectors.json`) and `tone_action.ahk` runs the `llm_tone_*` actions on it:
the selection is rewritten one register up or down, typed over itself and
selected again. `vision.ahk` ports `_shared/lua/llm/vision.lua` (the
`llm_vision` binding value, the vision model it resolves to, the request body of
each API dialect and the tagged-answer reader, pinned to `vision_vectors.json`)
and `vision_action.ahk` runs `llm_screen_region` / `llm_screen_full` /
`llm_screen_error` on it: a screenshot is transcribed by a vision model, then
the AI menu's backend drafts the answers offered as tooltip candidates (for
`llm_screen_error`, the `error_answers` of `vision.json`: the explanation, then
the fix). `translate.ahk` ports `_shared/lua/llm/translate.lua` (the
`llm_language` binding value, the target language, the prompt and the answer
reader, pinned to `translate_vectors.json`) and `translate_action.ahk` runs
`llm_translate_selection`: the selection is translated by the AI menu's backend
and offered as one candidate, which replaces the selection when accepted and
stays selected. `agent.ahk` ports `_shared/lua/llm/agent.lua` (the AI agent's prompts, the
System 1 triage, the validation of System 2's actions, the iCalendar and
mailto payloads and the threshold learning, pinned to `agent_vectors.json`);
`agent_action.ahk` runs `llm_agent_selection`, `llm_agent_command`,
`llm_agent_auto_toggle` and the automatic mode (`llm.agent_mode = "auto"`: a
typing pause, System 1, then System 2 above the threshold learned per
application and intent, kept in the Storage adapter), and offers each proposed
action as a tooltip candidate whose acceptance runs its connector in
`agent_connectors.ahk` (Outlook through COM, else an .ics file or a mailto:
link; the user's tools of `<config dir>/agent_tools/`). The tray's top-level
AI agent submenu is `ui/menu/menu_llm/menu_agent.ahk`.
`remote_formats.ahk` ports `_shared/lua/llm/remote_formats.lua` (pinned to
`remote_formats_vectors.json`): the request and answer shapes of the Backboard
provider (one assistant per key, then one message per request, key in
`X-API-Key`) and of the decisions providers (TypeSafe's Jev, typed questions
only, offered solely as the agent's System 1). `api_remote.ahk` sends both
through the same curl transport; neither format is a vision backend, and a
decisions provider is never sent a chat request.
`prediction_live.ahk` owns live mode
(`llm_live_prompt_toggle` and the AI menu's live mode submenu): while it is on,
the automatic typing trigger runs its prompt and count through the same
prompt-override request path, with the debounce and minimum word count of
`_shared/modules/llm/live.json`, so a rewrite prompt such as `translate_en`
shows the current sentence translated as it is typed.

## Public API

| Function                          | Description                                                          |
| --------------------------------- | -------------------------------------------------------------------- |
| `LLM_Bridge_Start(opts)`          | Initialize the bridge with a config `Map` and arm the keystroke hook |
| `LLM_Bridge_Stop()`               | Disarm the hook and cancel any pending request                       |
| `LLM_Engine_OnKeystroke(context)` | Feed a new context string and restart the debounce timer             |
| `LLM_Engine_Cancel()`             | Cancel the current in-flight request                                 |
| `LLM_SetProfile(name)`            | Switch the active prompt profile at runtime                          |

## Init pattern

```ahk
opts := Map("model", "mistral", "debounce_ms", 600)
LLM_Bridge_Start(opts)
; The bridge calls LLM_Engine_OnKeystroke() automatically on each relevant key
```

The bridge is non-blocking: the LLM call happens on a timer fire, never inside the keystroke hook itself. Context resets on Escape, Enter, and Tab to keep predictions relevant to the current editing context.
