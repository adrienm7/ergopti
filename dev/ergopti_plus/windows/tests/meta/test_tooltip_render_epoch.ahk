; tests/meta/test_tooltip_render_epoch.ahk
#Requires AutoHotkey v2.0

Test_TooltipRenderUsesImmutableGeneration() {
	Body := _DriverFuncBody("_TooltipShowNow")
	Assert(InStr(Body, "RenderGeneration := _TooltipGeneration") > 0,
		"_TooltipShowNow must capture the generation it owns before rendering")
	Assert(InStr(Body, "if (RenderGeneration != _TooltipGeneration)") > 0,
		"_TooltipShowNow must abandon a render superseded by a re-entrant show/hide")
	Assert(InStr(Body, "if (RenderGeneration == _TooltipGeneration)`n            TooltipHide") > 0,
		"a failed stale render must not hide the newer tooltip surface")

	ResolvePos := InStr(Body, "Pos := _TooltipResolvePosition()")
	ResolveGuard := InStr(Body, "if (RenderGeneration != _TooltipGeneration)", false, ResolvePos)
	Present := InStr(Body, "_TooltipPresentStack")
	Assert(ResolvePos > 0 and ResolveGuard > ResolvePos and Present > ResolveGuard,
		"_TooltipShowNow must recheck ownership after position resolution before presenting")
}

Test("tooltip: a re-entrant render cannot present or hide a newer generation", Test_TooltipRenderUsesImmutableGeneration)

Test_TooltipShowDebouncesHeavyRenderWork() {
	Entry := _DriverFuncBody("TooltipShow")
	; The literal is asserted deliberately, and the assertion below now says why.
	; It reads like a mechanism check — "defer via a timer" would be the obvious
	; weaker form — but the exact delay IS the guarantee here: the preview render
	; must land _PREFIX_RENDER_DEBOUNCE_MS + TOOLTIP_RENDER_DEBOUNCE_MS after the
	; last character in order to clear TOOLTIP_UIA_IDLE_REQUIRED_MS, and a
	; computed delay satisfies "defer via a timer" while breaking that. The
	; relationship itself is pinned by test_tooltip_debounce_is_load_bearing.ahk.
	Assert(InStr(Entry, "SetTimer(_TooltipDeferredShowFn, -TOOLTIP_RENDER_DEBOUNCE_MS)") > 0,
		"TooltipShow must hand rendering to a timer armed with TOOLTIP_RENDER_DEBOUNCE_MS itself, so that GUI/UIA work never runs in the prefix-watcher callback AND the render lands late enough to clear the UIA idle gate. A shorter or computed delay leaves every constant untouched while making stage 2 of the position cascade unreachable")
	Assert(InStr(Entry, "_TooltipBuildGui(") = 0 and InStr(Entry, "_TooltipResolvePosition(") = 0,
		"TooltipShow must not build a Gui or resolve UIA position synchronously on the keyboard path")
	Resolve := _DriverFuncBody("_TooltipResolvePosition")
	CachePos := InStr(Resolve, "_TooltipPositionCache")
	UiaPos := InStr(Resolve, "UIA.GetFocusedElement")
	Assert(CachePos > 0 and UiaPos > CachePos,
		"_TooltipResolvePosition must consult its HWND-fenced position cache before the UIA COM call")
}
Test("tooltip: prefix-path show debounces GUI/UIA work and caches non-caret position", Test_TooltipShowDebouncesHeavyRenderWork)
