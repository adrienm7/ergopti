; static/ergopti_plus/windows/tests/meta/test_menu_gestures_actions_separator.ahk

; ==============================================================================
; MODULE: Gestures/Actions Globales Separator Regression
; DESCRIPTION:
; Regression guard for the missing horizontal separator between the last
; feature-toggle section (Gestures) and the "Actions globales" tail in the
; AHK tray menu. menu_manifest.json's top_level array declares a "---" entry
; immediately before "global_actions", but MenuManifest_LoadTopLevelTail()
; used to start its slice AT "global_actions", silently dropping that
; separator — so _MI_AppendTail() never rendered it. Exercises the real
; production loader (not a source-scan) against the real shared manifest.
; ==============================================================================

_MGAS_CheckLeadingSeparator() {
	MenuManifest_InvalidateCache()
	Tail := MenuManifest_LoadTopLevelTail()
	Assert(Tail.Length > 1, "MenuManifest_LoadTopLevelTail() must return at least two items")
	Assert(Tail[1]["id"] == "---",
		"MenuManifest_LoadTopLevelTail() must lead with the '---' separator declared in menu_manifest.json before 'global_actions' -- got '" . Tail[1]["id"] . "'")
	Assert(Tail[2]["id"] == "global_actions",
		"MenuManifest_LoadTopLevelTail()[2] must be 'global_actions' right after the leading separator -- got '" . Tail[2]["id"] . "'")
}

Test("menu: MenuManifest_LoadTopLevelTail() includes the separator before Actions globales (gestures-actions-separator)",
	_MGAS_CheckLeadingSeparator)
