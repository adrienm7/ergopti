# tooltip (shared spec + JS logic)

## Purpose

Cross-driver specification and pure-JavaScript implementation of the tooltip rendering contract. The shared JS modules (`tint.js`, `layout.js`, `dequeue.js`, `lifecycle.js`, `draw_calls.js`) define the visual and behavioural contract that both the AHK WebView2 tooltip and the Hammerspoon canvas tooltip must respect, expressed as DOM-free functions testable in Node.js.

## Key files

| File             | Description                                                                  |
| ---------------- | ---------------------------------------------------------------------------- |
| `SPEC.md`        | Normative description of tooltip layout, tinting rules, and lifecycle states  |
| `constants.toml` | Cross-driver visual constants (RGBA + hex colours, geometry, alpha values)   |
| `tint.js`        | Colour-tinting function mapping group names to RGB tuples                     |
| `layout.js`      | Slot-layout computation (position, size, visibility rules)                    |
| `dequeue.js`     | Token-dequeue logic for streaming LLM output into display slots               |
| `lifecycle.js`   | Show/hide state machine (idle → showing → hiding)                             |
| `draw_calls.js`  | Produces a declarative draw-call list from state, consumed by each driver    |

## Driver implementations

| Driver   | Implementation path                            |
| -------- | ---------------------------------------------- |
| Windows  | `windows/ui/tooltip/` (AHK + WebView2 canvas)  |
| macOS    | `macos/ui/tooltip/` (Lua + `hs.canvas`)         |

Both implementations must produce identical visual output for the same input state; the shared JS suite verifies this with snapshot tests.
