; tests/meta/test_roi_map_mutation_race.ahk

#Requires AutoHotkey v2.0

_RMMR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_RMMR_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_RMMR_AssertHalflifeTickAtomic() {
	Src := _RMMR_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Body := _RMMR_FuncBodyStripped(Src, "KL_Roi_HalflifeTick() {")
	Assert(Body != "", "KL_Roi_HalflifeTick must exist in keylogger_trigger_roi.ahk")
	
	CritOnIdx := InStr(Body, 'Critical("On")')
	Assert(CritOnIdx > 0, "KL_Roi_HalflifeTick must use Critical('On') (roi-map-mutation-during-enumeration-race)")
	
	SnapIdx := InStr(Body, "snapshot[trig] := last_tick")
	Assert(SnapIdx > CritOnIdx, "KL_Roi_HalflifeTick must copy to a snapshot under Critical (roi-map-mutation-during-enumeration-race)")
}

_RMMR_AssertProcessWordAtomic() {
	Src := _RMMR_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Body := _RMMR_FuncBodyStripped(Src, "KL_Roi_ProcessWord(word) {")
	Assert(Body != "", "KL_Roi_ProcessWord must exist in keylogger_trigger_roi.ahk")
	
	CritOnIdx := InStr(Body, 'Critical("On")')
	Assert(CritOnIdx > 0, "KL_Roi_ProcessWord must use Critical('On') for prune logic (roi-map-mutation-during-enumeration-race)")
}

Test("keylogger_trigger_roi: KL_Roi_HalflifeTick enumerates map atomically (roi-map-mutation-during-enumeration-race)", _RMMR_AssertHalflifeTickAtomic)
Test("keylogger_trigger_roi: KL_Roi_ProcessWord prunes map atomically (roi-map-mutation-during-enumeration-race)", _RMMR_AssertProcessWordAtomic)
