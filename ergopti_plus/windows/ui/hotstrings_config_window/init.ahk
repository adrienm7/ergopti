; ui/hotstrings_config_window/init.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window — Entry point shim
; DESCRIPTION:
; Thin shim that composes the hotstrings config window from its two focused
; sub-modules. All implementation lives in:
;   - hcw_helpers.ahk   read-only helpers, UI builders, selection getters
;   - hcw_mutations.ahk write-path handlers, override dispatch, TOML patcher
; ==============================================================================

#Include hcw_helpers.ahk
#Include hcw_mutations.ahk
