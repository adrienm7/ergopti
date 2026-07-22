; tests/meta/test_space_tap_dispatch.ahk

#Requires AutoHotkey v2.0

_ST_AssertSpaceTapAtomic() {
	; Move-resilient: locate _SpaceTap() across the whole driver source via the
	; framework helper instead of a pinned modules path
	Body := _DriverFuncBody("_SpaceTap")
	Assert(Body != "", "_SpaceTap must exist in modules/tap_holds/space.ahk")
	
	CritOnIdx := InStr(Body, 'Critical("On")')
	if !CritOnIdx
		CritOnIdx := InStr(Body, 'Critical("On")')
	
	Assert(CritOnIdx > 0, "_SpaceTap must use Critical('On') to prevent mid-dispatch races (space-tap-dispatch-not-critical)")
	
	DispatchIdx := InStr(Body, "HSE_DispatchMatch")
	PressIdx := InStr(Body, 'TextPressKey("Space"')
	
	Assert(PressIdx > DispatchIdx, "Literal space emission must occur AFTER the expansion decision, so it isn't sent if a match fires (space-tap-dispatch-not-critical)")
}

Test("tap_holds: _SpaceTap uses Critical('On') and correct emission order (space-tap-dispatch-not-critical)", _ST_AssertSpaceTapAtomic)
