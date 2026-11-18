; hotstrings/engine/matcher/prefix_watcher.ahk

; ==============================================================================
; MODULE: Hotstring Prefix Watcher (shim)
; DESCRIPTION:
; Entry-point for the prefix-watcher subsystem: the live tooltip that previews
; the expansion while the user types characters prefixing a registered trigger.
;
; Sub-modules loaded in order:
;   inputhook.ahk — globals, public API, InputHook callbacks.
;   registry.ahk  — TOML / cache-driven prefix-index construction.
;   preview_switches.ahk    — the four preview-bubble switches and the family rule.
;   ../catalogue/personal_info_mask.ahk    — the shared masking policy, ported.
;   ../catalogue/personal_info_preview.ahk — the @-trigger candidate source.
;
; The personal-info pair is loaded from here rather than from the entry point so
; the provider is registered wherever the watcher is: the headless test harness
; includes this shim and would otherwise exercise a collector with no providers
; in it, which is precisely the state the missing @ preview was.
; ==============================================================================

#Include inputhook.ahk
#Include registry.ahk
#Include preview_switches.ahk
#Include ../catalogue/personal_info_mask.ahk
#Include ../catalogue/personal_info_preview.ahk
