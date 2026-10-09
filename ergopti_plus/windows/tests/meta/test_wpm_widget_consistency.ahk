; tests/meta/test_wpm_widget_consistency.ahk

; ==============================================================================
; MODULE: Regression — the WPM widget must fail loudly and follow the override
;         pipeline (wpm-widget-consistency)
; DESCRIPTION:
; Two defects in the same widget, both of which leave it quietly showing the
; wrong thing.
;
; ROOT CAUSE ENCODED:
;   * The tick has two branches. Compact mode catches a render failure, LOGS it
;     and rebuilds; graph mode caught it, dropped the GUI handle and said
;     nothing — so the widget stayed dead until the user happened to toggle the
;     mode by hand, with no trace anywhere that a render had thrown. Two halves
;     of one tick behaving differently, which nobody chose.
;   * The category colour was read straight from the TOML file, deliberately
;     bypassing the config layer. That bypass also bypassed _HotstringsOverrides,
;     where the config window's colour edits live — so changing a colour
;     repainted the tooltip immediately and left the widget on the old one until
;     the next reload, from the same edit.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ Both tick branches report a render failure ============
; ==================================================================
; ==================================================================

; A render throw must be logged and recovered from, in BOTH modes. The compact
; branch always did; the graph branch is the sibling that did not.
_WWC_BothTickBranchesLogAndRebuild() {
	Body := _DriverFuncBody("WPMWidget_Tick")
	if (Body == "")
		Body := _StripFullLineComments(_DriverDirConcat("ui/wpm"))
	Assert(Body != "", "the WPM widget tick must be locatable")

	Bare := 0
	Pos := 1
	while (F := RegExMatch(Body, "}\s*catch\s*\{", &M, Pos)) {
		Pos := F + M.Len
		Bare += 1
	}
	Assert(Bare == 0,
		"a tick branch still swallows its render failure with a bare catch (found " . Bare . "). The widget then stays dead until the user toggles the mode by hand, and nothing anywhere says a render threw")

	Assert(InStr(Body, "Graph mode tick threw") > 0,
		"the graph branch must log the failure, exactly as the compact branch does")
	Assert(InStr(Body, "Compact mode tick threw") > 0,
		"and the compact branch must keep doing so — the point is that the two agree")
}

; Logging is only half of it: the sibling also REBUILDS, so the widget comes
; back on the next tick instead of waiting for a manual toggle.
_WWC_GraphBranchRebuilds() {
	Body := _DriverFuncBody("WPMWidget_Tick")
	if (Body == "")
		Body := _StripFullLineComments(_DriverDirConcat("ui/wpm"))

	At := InStr(Body, "Graph mode tick threw")
	Assert(At > 0, "the graph branch must log its failure")
	Window := SubStr(Body, At, 300)
	Assert(InStr(Window, "WPMWidget_BuildGraph") > 0,
		"the graph branch must rebuild after a failure. Clearing the handle alone leaves the widget dead until something else happens to rebuild it — which is what made this silent rather than merely noisy")
}




; ==================================================================
; ==================================================================
; ======= 2/ The colour follows the override pipeline ==============
; ==================================================================
; ==================================================================

; The widget must ask the override-aware resolver before falling back to the
; raw TOML read.
_WWC_ColourGoesThroughTheResolver() {
	Body := _DriverFuncBody("_WPMWidget_ReadTomlColor")
	Assert(Body != "", "the widget colour resolver must exist")

	Assert(InStr(Body, "HotstringsResolve(") > 0,
		"the widget must resolve through HotstringsResolve, which owns the full cascade including _HotstringsOverrides. Reading the TOML directly sees only what is on disk, so a colour changed in the config window repainted the tooltip and left the widget on the old one until reload")

	ResolveAt := InStr(Body, "HotstringsResolve(")
	FileAt    := InStr(Body, "FileRead(")
	Assert(FileAt > 0,
		"the direct TOML read must remain as the fallback — it is the case the bypass was written for, when _SharedDir is not yet resolved during early init")
	Assert(ResolveAt < FileAt,
		"and the resolver must be consulted FIRST, or the override is only reached when the file happens to have no colour at all")
}

; An override can change at any moment, so the resolved value must not be frozen
; in the widget's own memo — that would re-create the staleness being fixed.
_WWC_OverrideIsNotMemoisedByTheWidget() {
	Body := _DriverFuncBody("_WPMWidget_ReadTomlColor")
	At := InStr(Body, "HotstringsResolve(")
	Assert(At > 0, "the resolver call must exist")

	; The guarantee is that the RESOLVER'S answer is never frozen in the widget's
	; own memo — the fallback file read may be, and must be, or the ~100 ms tick
	; re-reads the category TOML dozens of times a second.
	;
	; This used to be checked by scanning the 400 characters after the resolver
	; call for "_color_cache[". That only worked while the resolver sat BELOW the
	; cache logic; moving it above — so a fallback answer taken during early init
	; can no longer be cached and short-circuit the resolver forever — put the
	; legitimate fallback memo inside the window and failed a strictly better
	; arrangement. Assert the relationship instead of the layout.
	Assert(!RegExMatch(Body, "i)_color_cache\[[^\]]*\]\s*:=\s*Resolved"),
		"the resolved colour must not be written into the widget's static cache. That cache is flushed only on an explicit TOML-save invalidation, so caching an override there would keep the widget stale for exactly the edits this fix is about")
	Assert(RegExMatch(Body, "i)return\s+Resolved\.Color"),
		"the resolver's answer must be returned directly, so an override that changes between two ticks is seen on the next one")
}


Test("meta wpm-widget-consistency: both tick branches log and rebuild on a render failure",
	_WWC_BothTickBranchesLogAndRebuild)
Test("meta wpm-widget-consistency: the graph branch rebuilds after logging",
	_WWC_GraphBranchRebuilds)
Test("meta wpm-widget-consistency: the widget colour goes through the override resolver",
	_WWC_ColourGoesThroughTheResolver)
Test("meta wpm-widget-consistency: a resolved override is not frozen in the widget cache",
	_WWC_OverrideIsNotMemoisedByTheWidget)
