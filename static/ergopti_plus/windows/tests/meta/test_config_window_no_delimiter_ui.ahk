; tests/meta/test_config_window_no_delimiter_ui.ahk

; ==============================================================================
; MODULE: Config-Window No-Delimiter-UI Meta Test
; DESCRIPTION:
; Static source guard for the "config-window-duplicate-delimiter-editor" cleanup.
;
; ROOT CAUSE ENCODED:
; The hotstrings config window (the _HCW_* namespace) grew a second, redundant
; "Word delimiters" editor — a checkbox grid plus reset button — even though the
; tray Hotstrings submenu (_HS_BuildDelimiterSubMenu in ui/menu/menu_hotstrings.ahk)
; already owns delimiter management end to end (toggle, add/remove custom, reset).
; Two editors for the same setting is a duplication trap: a future change to one
; silently drifts from the other. Delimiters belong to exactly ONE surface — the
; tray submenu — so the config window must not rebuild that UI.
;
; This meta-static test pins the removal: if any _HCW_* delimiter-editor function
; reappears, or the config window starts mutating the delimiter string directly,
; the guard fails. A positive cross-check asserts the tray submenu still owns the
; feature, so the test also fails if delimiter management is deleted outright.
;
; Meta-static (scans source text) because hotstrings_config_window.ahk builds a
; native Gui at top level and is NOT in the headless run_all include graph.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Config window owns no delimiter UI ====
; ==================================================
; ==================================================

; The five _HCW_* helpers that built the redundant delimiter editor. None may
; exist anywhere in the driver source — they were the duplicate surface.
_CWND_REMOVED_HELPERS := [
	"_HCW_DELIMITER_DEFS",
	"_HCW_BuildDelimiterCheckboxes",
	"_HCW_LoadDelimiterCheckboxes",
	"_HCW_OnDelimiterChanged",
	"_HCW_ResetDelimiters",
]

_CWND_NoDelimiterEditorHelpers() {
	global _CWND_REMOVED_HELPERS
	Src := _DriverSourceConcat()
	for _, Name in _CWND_REMOVED_HELPERS {
		Assert(!InStr(Src, Name),
			"The config window must not define '" . Name . "' — delimiter editing belongs to the tray submenu only (config-window-duplicate-delimiter-editor)")
	}
}
Test("hs_config: config window defines no _HCW_* delimiter-editor helper (config-window-duplicate-delimiter-editor)", _CWND_NoDelimiterEditorHelpers)

; The config window must not reference the locale strings that only the removed
; delimiter editor used. If they reappear the editor came back with them.
_CWND_NoOrphanedDelimiterLabels() {
	Src := _DriverSourceConcat()
	for _, Key in ["hs_config.label_delimiters", "hs_config.delimiters_hint", "hs_config.delimiters_reset"] {
		Assert(!InStr(Src, Key),
			"No driver code may reference '" . Key . "' — it was removed with the duplicate config-window delimiter editor (config-window-duplicate-delimiter-editor)")
	}
}
Test("hs_config: removed delimiter-editor locale keys are not referenced (config-window-duplicate-delimiter-editor)", _CWND_NoOrphanedDelimiterLabels)

; Positive cross-check: delimiter management still lives in the tray submenu, so
; this guard also fails if the feature was deleted instead of de-duplicated.
_CWND_TraySubmenuStillOwnsDelimiters() {
	; Renamed on 2026-08-06 when the submenu became a manifest `list` provider:
	; it returns ROWS now instead of assembling a Menu, so the shared renderer
	; materialises them. The invariant is unchanged and is the reason this test
	; exists — the tray is the single owner of delimiter management, and the
	; config window must not grow a second editor for it.
	Body := _DriverFuncBody("_HS_WordExpanderRows")
	Assert(Body != "",
		"_HS_WordExpanderRows must exist — the tray submenu is the single owner of delimiter management")
	; The rows it returns are what proves it still MANAGES them rather than
	; merely listing them: without these the feature could have been deleted and
	; the symbol kept.
	for _, Needle in ["_HS_DelimSetAll", "_HS_DelimReset", "_HS_DelimAddCustom", "_HS_DelimRemoveCustom"] {
		Assert(InStr(Body, Needle) > 0,
			"_HS_WordExpanderRows must still offer '" . Needle . "' — delimiter management moved to the renderer's row shape, it was not removed")
	}
}
Test("hs_config: tray submenu still owns delimiter management (config-window-duplicate-delimiter-editor)", _CWND_TraySubmenuStillOwnsDelimiters)
