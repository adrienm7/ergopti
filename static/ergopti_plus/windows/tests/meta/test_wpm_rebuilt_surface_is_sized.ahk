; tests/meta/test_wpm_rebuilt_surface_is_sized.ahk

; ==============================================================================
; MODULE: Regression — a rebuilt WPM surface must be re-sized and re-positioned
;         (wpm-rebuilt-surface-is-sized)
; DESCRIPTION:
; WPMWidget_Tick catches a render failure, logs it and rebuilds the widget Gui.
; The builders only CONSTRUCT — geometry (`Show("Hide NoActivate x… y… w… h…")`)
; lived inline in WPMWidget_Show and in WPMWidget_PrewarmGraph. So the recovery
; path produced a window in a state the render path cannot use: a Gui that was
; constructed but never Shown has a 0x0 client rect, GR_DrawBitmap early-returns
; on `if (W <= 0 or H <= 0)`, UpdateLayeredWindow is never called again, and the
; graph stays blank for the rest of the session — exactly the "dead until the
; user toggles the mode by hand" outcome the logging+rebuild was added to remove,
; only now with one ERROR line to show for it. The compact branch had the milder
; form of the same shape: the next tick reveals it with a bare Show("NoActivate")
; at the OS default position instead of the user's saved corner.
;
; ROOT CAUSE ENCODED: geometry had no owner. The fix is one positioner
; (_WPMWidget_ApplySurfaceGeometry) called by every path that must produce a
; usable surface, so no future caller can construct one and forget to size it.
;
; SCOPE: source-level — ui/wpm builds Guis at call time and is outside the
; headless include graph.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Both recovery branches re-apply the geometry ==========
; ==================================================================
; ==================================================================

_WRSS_RebuildBranchesReapplyGeometry() {
	Body := _DriverFuncBody("WPMWidget_Tick")
	Assert(Body != "", "WPMWidget_Tick must exist in the driver source")

	for Marker in ["Graph mode tick threw", "Compact mode tick threw"] {
		At := InStr(Body, Marker)
		Assert(At > 0, "prerequisite: the '" . Marker . "' recovery branch must still exist and log")
		Window := SubStr(Body, At, 500)
		Assert(InStr(Window, "_WPMWidget_ApplySurfaceGeometry") > 0,
			"the '" . Marker . "' branch rebuilds the widget Gui but never re-applies its geometry. A freshly constructed, never-Shown Gui has a 0x0 client rect: GR_DrawBitmap returns at its `if (W <= 0 or H <= 0)` guard, the layered graph never receives another UpdateLayeredWindow, and the widget silently paints nothing until the user toggles the mode by hand or restarts")
	}
}
Test("meta wpm-rebuilt-surface-is-sized: both tick recovery branches re-apply the geometry",
	_WRSS_RebuildBranchesReapplyGeometry)





; ==================================================================
; ==================================================================
; ======= 2/ The geometry has exactly one owner ====================
; ==================================================================
; ==================================================================

; Three callers, one positioner. The moment a second copy of the Show call exists,
; the next path added forgets one of them — which is how the rebuild branch came
; to produce an unusable surface in the first place.
_WRSS_GeometryHasOneOwner() {
	Owner := _DriverFuncBody("_WPMWidget_ApplySurfaceGeometry")
	Assert(Owner != "",
		"_WPMWidget_ApplySurfaceGeometry must exist — the positioner every surface path shares")
	Assert(InStr(Owner, 'Show("Hide') > 0,
		"the positioner must be the one that applies size and position while the window is hidden")
	Assert(InStr(Owner, "WPMWidget_ShowPos(") > 0,
		"the positioner must derive the mode's top-left from the shared compact anchor, or graph mode lands somewhere else than the user left it")

	for FuncName in ["WPMWidget_Show", "WPMWidget_PrewarmGraph"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist in the driver source")
		Assert(InStr(Body, "_WPMWidget_ApplySurfaceGeometry") > 0,
			FuncName . " must go through the shared positioner")
		Assert(InStr(Body, 'Show("Hide') == 0,
			FuncName . " must not re-implement the geometry inline. Two copies of a rule is how the recovery path ended up with none of them")
	}
}
Test("meta wpm-rebuilt-surface-is-sized: one positioner owns the widget geometry",
	_WRSS_GeometryHasOneOwner)
