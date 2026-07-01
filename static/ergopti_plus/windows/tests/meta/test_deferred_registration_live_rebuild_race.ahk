; tests/meta/test_deferred_registration_live_rebuild_race.ahk

#Requires AutoHotkey v2.0

; Reads modules/hotstrings.ahk (the orchestrator shim) concatenated with its
; modules/hotstrings/ sub-modules -- the god-file split (334b5c04a) moved
; RegisterEmojisSymbolsDeferred and friends out of the shim into
; hotstrings_helpers.ahk, so a plain FileRead of the shim alone no longer sees
; them even though the driver still loads both via #Include.
_DRLR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	Src := FileRead(Path)
	if (RelPath == "modules/hotstrings.ahk")
		Src .= _DriverDirConcat("modules/hotstrings")
	return Src
}

_DRLR_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_DRLR_AssertCancelOnLiveRebuild() {
	SrcHotstrings := _DRLR_ReadSource("modules/hotstrings.ahk")
	BodyRAH := _DRLR_FuncBodyStripped(SrcHotstrings, "RegisterAllHotstrings(DeferHeavy := false) {")
	Assert(BodyRAH != "", "RegisterAllHotstrings must exist in modules/hotstrings.ahk")
	
	CancelIdx1 := InStr(BodyRAH, "SetTimer(RegisterEmojisSymbolsDeferred, 0)")
	Assert(CancelIdx1 > 0, "RegisterAllHotstrings must cancel the deferred timer when DeferHeavy=false (deferred-queue-not-cancelled-on-live-rebuild)")

	BodyRHL := _DriverFuncBody("RebuildHotstringsLive")
	Assert(BodyRHL != "", "RebuildHotstringsLive must exist in the driver source")
	
	CancelIdx2 := InStr(BodyRHL, "SetTimer(RegisterEmojisSymbolsDeferred, 0)")
	Assert(CancelIdx2 > 0, "RebuildHotstringsLive must cancel the deferred timer before wiping registry (deferred-queue-not-cancelled-on-live-rebuild)")
}

_DRLR_AssertGuardInDeferred() {
	SrcHotstrings := _DRLR_ReadSource("modules/hotstrings.ahk")
	Body := _DRLR_FuncBodyStripped(SrcHotstrings, "RegisterEmojisSymbolsDeferred() {")
	Assert(Body != "", "RegisterEmojisSymbolsDeferred must exist in modules/hotstrings.ahk")
	
	GuardIdx := InStr(Body, 'HSE_RegistryByGroup.Has("emojis.emojis")')
	Assert(GuardIdx > 0, "RegisterEmojisSymbolsDeferred must guard against already-registered sections (deferred-queue-not-cancelled-on-live-rebuild)")
}

Test("hotstrings: live rebuild cancels deferred timer (deferred-queue-not-cancelled-on-live-rebuild)", _DRLR_AssertCancelOnLiveRebuild)
Test("hotstrings: deferred pass guards against concurrent live rebuild (deferred-queue-not-cancelled-on-live-rebuild)", _DRLR_AssertGuardInDeferred)
