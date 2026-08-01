; infra/hotstrings/hotstring_prefix_watcher.ahk

; ==============================================================================
; MODULE: Hotstring Prefix Watcher (shim)
; DESCRIPTION:
; Entry-point for the prefix-watcher subsystem: the live tooltip that previews
; the expansion while the user types characters prefixing a registered trigger.
;
; Sub-modules loaded in order:
;   hotstring_inputhook.ahk — globals, public API, InputHook callbacks.
;   hotstring_registry.ahk  — TOML / cache-driven prefix-index construction.
; ==============================================================================

#Include hotstring_inputhook.ahk
#Include hotstring_registry.ahk
