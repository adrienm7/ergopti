# Ergopti+ — Domain Modules Specification (Hexagonal Architecture — Step 2)

This folder contains the **pure domain module** specifications and reference
implementations for Ergopti+. Domain modules contain business logic that is
completely platform-agnostic — no OS API calls, no driver-specific imports.

---

## 1. Motivation

Domain logic currently lives inside driver files mixed with OS calls. This
makes unit testing impossible (you cannot run AHK or Hammerspoon in CI) and
cross-driver divergence inevitable (two drivers, two implementations, two bugs).

By extracting pure domain logic into this folder:

- JS reference implementations can be unit-tested in CI without any OS.
- Driver implementations are validated against shared test vectors.
- A future Linux or web driver implements the same logic without re-deriving it.

---

## 2. Folder Contents

```
static/ergopti_plus/shared/domain/
├── SPEC.md                  ← This file
├── Registry.spec.js         ← Hotstring data model + lookup contract
├── Expander.spec.js         ← Expansion decision contract
├── Terminators.spec.js      ← Terminator catalogue + enable/disable contract
├── TokenParser.js           ← Reference implementation: LLM output diff coloring
├── PromptBuilder.js         ← Reference implementation: LLM prompt construction
├── ProfileSelector.js       ← Reference implementation: profile resolve + prompt inject
└── GestureRecognizer.spec.js ← Gesture detection contract
```

Files named `*.spec.js` define a **contract + test vectors** only; the
reference implementation lives in the driver. Files named `*.js` (no `.spec`)
are **canonical reference implementations** — driver adapters are expected to
port them faithfully and validate against their test vectors.

---

## 3. Architecture

```
Ports (OS adapters)       Domain modules             Shared assets
────────────────────      ──────────────────         ─────────────
KeyboardHook ──────────▶  Registry                   _shared/llm/profiles.json
TextSender   ◀──────────  Expander ──────────────▶   _shared/llm/inference.json
TooltipRenderer ◀───────  TokenParser (ref impl)
HttpClient   ◀──────────  PromptBuilder (ref impl)
TimerScheduler ◀────────  ProfileSelector (ref impl)
Notifier     ◀──────────  Terminators (catalogue)
TrayMenu     ◀──────────  GestureRecognizer (spec)
```

Domain modules:
- **MUST NOT** import from `static/ergopti_plus/windows/` or `static/ergopti_plus/macos/`.
- **MUST NOT** call any OS API directly.
- **MAY** import from `static/ergopti_plus/shared/` (tooltip, ports, llm JSON files).

---

## 4. Module Summary

| Module | Type | What it owns |
|---|---|---|
| Registry | Spec | Hotstring data model, O(1) tail-char bucket lookup, group lifecycle |
| Expander | Spec | Match decision pipeline, backspace count, replacement emit |
| Terminators | Spec | Terminator catalogue, enabled state, O(1) char lookup |
| TokenParser | Impl | Diff coloring: green = correction, orange = new words, gray = unchanged |
| PromptBuilder | Impl | Context truncation, tail extraction, token budget, temperature formula |
| ProfileSelector | Impl | Profile registry, active selection, template variable injection |
| GestureRecognizer | Spec | Frame centroid, direction locking, threshold constants |

---

## 5. Driver Compliance

| Module | AHK adapter | HS adapter |
|---|---|---|
| Registry | `lib/hotstrings/hotstring_engine.ahk` | `modules/keymap/registry.lua` |
| Expander | `modules/hotstrings.ahk` + `hotstring_engine.ahk` | `modules/keymap/expander.lua` |
| Terminators | `lib/hotstrings/hotstring_prefix_watcher.ahk` | `modules/keymap/terminators.lua` |
| TokenParser | `ui/tooltip_llm.ahk` (partial) | `modules/llm/parser.lua` |
| PromptBuilder | `modules/llm/api_common.ahk` | `modules/llm/prompt_builder.lua` |
| ProfileSelector | `modules/llm/profiles.ahk` | `modules/llm/profiles.lua` |
| GestureRecognizer | `modules/gestures.ahk` (registry-only) | `modules/gestures/engine.lua` |

---

## 6. References

- [Registry.spec.js](./Registry.spec.js)
- [Expander.spec.js](./Expander.spec.js)
- [Terminators.spec.js](./Terminators.spec.js)
- [TokenParser.js](./TokenParser.js) — canonical reference
- [PromptBuilder.js](./PromptBuilder.js) — canonical reference
- [ProfileSelector.js](./ProfileSelector.js) — canonical reference
- [GestureRecognizer.spec.js](./GestureRecognizer.spec.js)
- [Ports specification](../ports/SPEC.md)
- [LLM profiles JSON](../llm/profiles.json)
- [LLM inference JSON](../llm/inference.json)
