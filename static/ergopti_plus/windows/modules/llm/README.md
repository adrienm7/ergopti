# llm (AHK)

## Purpose

Windows port of the LLM prediction subsystem. `llm_bridge.ahk` maintains a rolling typing-context buffer by intercepting printable keystrokes and backspace, then fires a debounced async request to the prediction engine. `prediction_engine.ahk` sends requests to Ollama (local) or a remote endpoint and streams tokens into a tooltip. `profiles.ahk` manages prompt profiles. `models.ahk` handles model listing and selection.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | Intercepting printable chars and buffer-reset keys (Escape, Enter, Tab) |
| `HttpClient` | REST calls to `api_ollama.ahk`, `api_remote.ahk` |
| `TooltipRenderer` | Streaming token display during prediction |
| `TimerScheduler` | Debounce timer between last keystroke and the LLM request |
| `Storage` | Reading and writing profile / model configuration |

## Domain module (`_shared/domain/`)

- `PromptBuilder.js` — `prediction_engine.ahk` builds prompts following this contract
- `TokenParser.js` — streaming token parsing from Ollama/remote JSON responses
- `ProfileSelector.js` — `profiles.ahk` manages profile selection following this contract

## Public API

| Function | Description |
|---|---|
| `LLM_Bridge_Start(opts)` | Initialize the bridge with a config `Map` and arm the keystroke hook |
| `LLM_Bridge_Stop()` | Disarm the hook and cancel any pending request |
| `LLM_Engine_OnKeystroke(context)` | Feed a new context string and restart the debounce timer |
| `LLM_Engine_Cancel()` | Cancel the current in-flight request |
| `LLM_SetProfile(name)` | Switch the active prompt profile at runtime |

## Init pattern

```ahk
opts := Map("model", "mistral", "debounce_ms", 600)
LLM_Bridge_Start(opts)
; The bridge calls LLM_Engine_OnKeystroke() automatically on each relevant key
```

The bridge is non-blocking: the LLM call happens on a timer fire, never inside the keystroke hook itself. Context resets on Escape, Enter, and Tab to keep predictions relevant to the current editing context.
