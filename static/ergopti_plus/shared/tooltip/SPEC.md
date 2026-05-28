# Ergopti+ — Tooltip Engine Specification (cross-driver)

This folder is the **single source of truth** for the tooltip visual contract
shared by all Ergopti+ drivers. Every driver implementation MUST conform to
the constants, algorithms, and draw_calls[] IR defined here.

---

## 1. Folder Contents

```
static/ergopti_plus/shared/tooltip/
├── SPEC.md          ← This file — canonical contract
├── constants.toml   ← All numeric and color constants (canonical source)
├── tint.js          ← Pure HSL tint-mixing algorithm + test vectors
├── layout.js        ← Pure position resolution + canvas geometry + test vectors
└── draw_calls.js    ← draw_calls[] IR type definitions and composer functions
```

Driver-side files that MUST stay in sync with this spec:

| Driver | Constants file | Renderer |
|---|---|---|
| AHK | `lib/ui_style.ahk` | `lib/tooltip.ahk`, `ui/tooltip_llm.ahk` |
| Hammerspoon | `ui/tooltip/config.lua` | `ui/tooltip/renderer.lua`, `ui/tooltip/tooltip_llm.lua` |
| Future | Read `constants.toml` at boot or codegen from it | Implement the draw_calls[] adapter |

---

## 2. Visual Design

The Ergopti+ tooltip is a **dark, semi-transparent, rounded-rectangle overlay**
that appears near the text insertion point. It shows:

- **Stacked rows** (hotstring tooltip): one row per expansion candidate, each
  with a colored background tint matching its group (★ red, autocorrect green,
  personal blue), a right-column trigger label (★ ↵), and optional dimmed rows
  for non-firing alternates.
- **Prediction panel** (LLM tooltip): one block per AI prediction, with diff
  coloring (green = corrected text, orange = inserted words), a navigation hint
  line, and a timing/model info bar.

### 2.1 Shared visual parameters

All values are defined in `constants.toml`. This table summarises the most
important ones — refer to the TOML file for the full list.

| Parameter | Value | Notes |
|---|---|---|
| Background | `#1A1A1A` (dark near-black) | Tinted per group via HSL mixing |
| Corner radius | 7 layout units | GDI diameter = 14 on AHK |
| Horizontal padding | 14 lu | Each side |
| Vertical padding | 7 lu | Above and below each content row |
| Border | white, alpha 0.25 (AHK) / 0.13 (HS) | 1 px stroke ring |
| Separator | white, alpha 0.25 (AHK) / 0.09 (HS) | 1 px horizontal rule |
| Main font (AHK) | Segoe UI, 11 pt | Windows system UI font |
| Main font (HS) | .AppleSystemUIFont, 14 pt | macOS system UI font |
| Hint font size | 11 lu | Trigger label, navigation hint |
| Info font size | 10 lu | Model + timing bar (HS only) |

> **Why different border alphas?** macOS compositing blends layers differently
> than Windows DWM. The AHK value (0.25) is applied to a pre-multiplied DIB
> drawn via UpdateLayeredWindow; the HS value (0.13) is a canvas strokeColor
> alpha. Perceptual results are equivalent on each OS.

### 2.2 Dimmed (non-firing) rows

Rows that will not fire (alternates in the same group beyond the selected one)
are shown with:
- Gray text (`white = 0.55` / `#8C8C8C`)
- Strikethrough style
- Dimmer label color (`white = 0.45, alpha = 0.55`)

This communicates "this option exists but is not active" without hiding it.

---

## 3. Tint Mixing Algorithm

The canonical algorithm is implemented in `tint.js:mixTint()`. Every driver
MUST use this exact formula. Test coverage is provided via
`macos/tests/unit/ui/test_tooltip_tint_contract.lua` on the Hammerspoon side;
the reference vectors live in `tint.js:tintTestVectors()`.

### Algorithm

Given an accent color `{r, g, b}` in [0.0, 1.0]:

1. Extract the **hue** from the accent color (discard lightness and saturation).
2. Reconstruct an HSL color at fixed `lightness = 0.10`, `saturation = 0.40`.
3. Convert back to RGB — this is the tinted background color.
4. If the accent is achromatic (max − min < 0.0001), return the default background
   (`#1A1A1A`) without any tint.

### Driver Implementations

| Driver | Function | File |
|---|---|---|
| AHK | `_TooltipMixTintHex(AccentHex)` | `lib/tooltip.ahk` |
| Hammerspoon | `M.apply_tint(requested_tint)` | `ui/tooltip/renderer.lua` |
| Reference | `mixTint(accent)` | `_shared/tooltip/tint.js` |

The AHK function accepts and returns hex strings (`"RRGGBB"`). The HS function
accepts and returns `{red, green, blue, alpha}` tables. The JS reference module
works with normalized `{r, g, b}` objects. All three produce the same color.

---

## 4. Position Resolution

The canonical algorithm is implemented in `layout.js:resolvePosition()`.

### Anchor Cascade

Each driver queries for an anchor in this priority order:

| Priority | Source | Condition |
|---|---|---|
| 1 | Platform caret API | CaretGetPos (AHK) / AXBoundsForRange (HS) |
| 2 | Accessibility element bounds | UIA.GetFocusedElement (AHK) / AXFrame (HS) |
| 3 | Active window frame (bottom-centre) | Always available |
| 4 | Screen centre-bottom | Fallback of last resort (never fails) |

AHK adds a step between 3 and 4: mouse cursor coordinates.
HS adds VSCode Bridge before step 1.

### Anchor Types and Tooltip Placement

| Anchor type | Placement |
|---|---|
| `"caret"` | Below-right: `x = anchor.x + 15`, `y = anchor.y + anchor.h + 18` |
| `"input_box"` | Below, horizontally centred; flips above if bottom overflow |
| `"window"` | Same as `input_box` |
| `null` | Screen centre-bottom |

### Screen-Edge Clamping

After computing the candidate position, both coordinates are clamped:

```
x = clamp(x, screen.x + margin, screen.x + screen.w − canvas.w − margin)
y = clamp(y, screen.y + margin, screen.y + screen.h − canvas.h − margin)
```

Where `margin = 5` layout units (from `constants.toml [positioning].screen_margin`).

---

## 5. Draw-Calls Intermediate Representation

The draw_calls[] IR is defined in `draw_calls.js`. It is a flat, ordered array
of platform-agnostic drawing primitives.

### 5.1 Primitive Types

#### `"rect"` — Rounded rectangle

```js
{
  type:          "rect",
  id:            string,          // stable ID for partial updates
  frame:         { x, y, w, h }, // relative to canvas origin (layout units)
  fill_color:    { r, g, b, a } | null,
  stroke_color:  { r, g, b, a } | null,
  stroke_width:  number,          // layout units
  corner_radius: number,          // layout units
}
```

#### `"text"` — Text block

```js
{
  type:      "text",
  id:        string,
  frame:     { x, y, w, h },
  text:      string,              // plain text content
  font_name: string | null,       // null when `styled` is used
  font_size: number | null,
  color:     { r, g, b, a },
  alignment: "left" | "center" | "right",
  styled:    any | null,          // driver-opaque styled text (hs.styledtext etc.)
                                  // null on drivers that don't support styled text
  is_dimmed: boolean | undefined, // true → driver applies strikethrough
}
```

When `styled` is not null, drivers that support it SHOULD use it and ignore
`text`, `font_name`, `font_size`, and `color`. Drivers without styled text
support fall back to those plain fields.

#### `"separator"` — Horizontal rule

```js
{
  type:       "separator",
  id:         string,
  frame:      { x, y, w, h },   // h is always 1
  fill_color: { r, g, b, a },
}
```

### 5.2 Element Ordering Convention

Draw calls MUST be ordered from back to front (painter's algorithm):

1. Canvas background (`id = "bg"`)
2. Per-row backgrounds (`id = "row_bg_0"`, `"row_bg_1"`, …)
3. Per-row text (`id = "row_text_0"`, …) and labels (`id = "row_label_0"`, …)
4. Separators (`id = "sep_0"`, `"sep_1"`, …)
5. Predictions block (`id = "preds"`)
6. Separator above hint/info (`id = "sep"`)
7. Hint block (`id = "hint"`) or combined (`id = "hint_info"`)
8. Info bar (`id = "info"`)
9. Border overlay — ALWAYS LAST (`id = "border"`)

### 5.3 Partial Updates (Streaming)

During LLM token streaming, only the predictions text changes. Drivers that
support indexed element mutation can update a single element without a full
redraw:

```
patch = findDrawCall(drawCalls, "preds")
patch.text = new_text
patch.styled = new_styled_text
driver.update_element(patch)
```

The `patchDrawCall(drawCalls, id, replacement)` helper returns a new array
with the replacement applied immutably.

---

## 6. Canvas Geometry

### 6.1 Stacked hotstring tooltip

Computed by `layout.computeStackedGeometry(rows, opts)`:

```
canvas_w = pad_x + max_text_w + label_zone + pad_x
row_h    = pad_y + text_h + pad_y
canvas_h = sum(row_h) + (row_count − 1) × separator_h
```

Where `label_zone = label_gap + max_label_w` if any row has a label, else 0.

### 6.2 LLM prediction tooltip

Computed by `layout.computeLlmGeometry(blocks, opts)`:

```
canvas_w = max(preds_w, fixed_width) + pad_x × 2
canvas_h = pad_y + preds_h + line_spacing
         + [separator line + line_spacing]
         + [hint_h + hint_spacing]
         + [info_h + line_spacing]
         + pad_y
```

When hint and info fit on a single combined row (`combined_w ≤ max_w`), both
are rendered as one element and `hint_h + hint_spacing + info_h` is replaced
by `combined_h`.

---

## 7. Timing and Auto-Dismiss

From `constants.toml [timing]`:

| Parameter | Value |
|---|---|
| Hotstring timeout | 2.5 s |
| LLM timeout | 12.0 s |
| Safety cap (duration = 0) | 3.0 s |
| Timeout decrement | 0.15 s |
| Timeout floor | 0.05 s |

The **effective duration** is computed as:

```
if caller_duration <= 0:
    arm safety timer at safety_timeout_sec
else:
    effective = max(timeout_floor_sec, caller_duration - timeout_decrement_sec)
    arm timer at effective
```

The decrement ensures the tooltip vanishes slightly before the expansion window
closes, preventing the user from seeing the preview and pressing the magic key
just past the deadline.

WARNING and ERROR log lines from the logger trigger an immediate forced flush
(see `_shared/logger/SPEC.md`). Similarly, any unhandled exception in the
rendering path MUST call `TooltipHide()` / `M.hide()` immediately so no ghost
tooltip lingers on screen.

---

## 8. Driver Compliance Checklist

A driver is considered compliant with this spec when:

- [ ] All constants match `constants.toml` (verified by code review or codegen).
- [ ] Tint output matches `tint.js:tintTestVectors()` within ±1 per channel.
- [ ] Position output matches `layout.js:layoutTestVectors()` exactly.
- [ ] draw_calls[] IDs match the ordering in § 5.2.
- [ ] Partial update path uses stable IDs (`"preds"`, `"info"`, `"model_info"`).
- [ ] Auto-dismiss follows the timing formula in § 7.
- [ ] Any rendering exception falls back to hide (no ghost tooltips).

---

## 9. References

- Constants: [`constants.toml`](./constants.toml)
- Tint algorithm: [`tint.js`](./tint.js)
- Layout engine: [`layout.js`](./layout.js)
- Draw-call IR: [`draw_calls.js`](./draw_calls.js)
- AHK implementation: [`lib/tooltip.ahk`](../../windows/lib/tooltip.ahk),
  [`ui/tooltip_llm.ahk`](../../windows/ui/tooltip_llm.ahk),
  [`lib/ui_style.ahk`](../../windows/lib/ui_style.ahk)
- HS implementation: [`ui/tooltip/renderer.lua`](../../macos/ui/tooltip/renderer.lua),
  [`ui/tooltip/config.lua`](../../macos/ui/tooltip/config.lua),
  [`ui/tooltip/tooltip_llm.lua`](../../macos/ui/tooltip/tooltip_llm.lua)
