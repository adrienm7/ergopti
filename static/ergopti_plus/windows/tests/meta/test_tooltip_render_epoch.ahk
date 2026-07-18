; tests/meta/test_tooltip_render_epoch.ahk
#Requires AutoHotkey v2.0

Test_TooltipRenderUsesImmutableGeneration() {
	Body := _DriverFuncBody("TooltipShow")
	Assert(InStr(Body, "RenderGeneration := _TooltipGeneration") > 0,
		"TooltipShow must capture the generation it owns before rendering")
	Assert(InStr(Body, "if (RenderGeneration != _TooltipGeneration)") > 0,
		"TooltipShow must abandon a render superseded by a re-entrant show/hide")
	Assert(InStr(Body, "if (RenderGeneration == _TooltipGeneration)`n            TooltipHide") > 0,
		"a failed stale render must not hide the newer tooltip surface")

	ResolvePos := InStr(Body, "Pos := _TooltipResolvePosition()")
	ResolveGuard := InStr(Body, "if (RenderGeneration != _TooltipGeneration)", false, ResolvePos)
	Present := InStr(Body, "_TooltipPresentStack")
	Assert(ResolvePos > 0 and ResolveGuard > ResolvePos and Present > ResolveGuard,
		"TooltipShow must recheck ownership after position resolution before presenting")
}

Test("tooltip: a re-entrant render cannot present or hide a newer generation", Test_TooltipRenderUsesImmutableGeneration)
