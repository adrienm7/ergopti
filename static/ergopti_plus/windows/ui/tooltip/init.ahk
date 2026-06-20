; ui/tooltip/init.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip
; DESCRIPTION:
; Floating, frameless tooltip used to preview the expansion of an in-progress
; hotstring trigger while the user is still inside the activation window.
; Mirrors the Hammerspoon tooltip both in look (per-group tinted background)
; and in lifecycle (auto-hide after a configurable duration, hide on click).
;
; FEATURES & RATIONALE:
; 1. Single reused Gui v2 — created on first show, then mutated on subsequent
;    calls. Reduces flicker and keeps allocations bounded for high-frequency
;    updates while the user is still typing the trigger.
;    Rounded-corner DllCalls fire on every Gui rebuild (required since the
;    window handle changes each time the Gui is destroyed and recreated).
; 2. Click-through via WS_EX_TRANSPARENT (E0x20) so the tooltip never steals
;    focus from the editor underneath, and never blocks selection.
; 3. Caret-anchored positioning via CaretGetPos with a fallback to the mouse
;    cursor when the foreground app does not expose its caret position
;    (common in Electron / web UIs without an accessible caret).
; 4. Foreground color computed from background luminance so dark and light
;    group colors both stay readable without the caller doing the math.
; ==============================================================================

; INDEX: this file declares nothing itself; it #Include-s the tooltip
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant; the order mirrors the call graph.
;   tooltip/core.ahk    -- Engine state, timers, styles + public API.
;   tooltip/helpers.ahk -- Internal rendering helpers (GUI build, border, etc.).
;   tooltip/llm.ahk     -- LLM multi-slot prediction tooltip.

#Include core.ahk
#Include helpers.ahk
#Include llm.ahk
