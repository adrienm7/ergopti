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
;   ../personal_info_mask.ahk    — the shared masking policy, ported.
;   ../personal_info_preview.ahk — the @-trigger candidate source.
;
; The personal-info pair is loaded from here rather than from the entry point so
; the provider is registered wherever the watcher is: the headless test harness
; includes this shim and would otherwise exercise a collector with no providers
; in it, which is precisely the state the missing @ preview was.
; ==============================================================================

#Include hotstring_inputhook.ahk
#Include hotstring_registry.ahk
#Include ../personal_info_mask.ahk
#Include ../personal_info_preview.ahk
