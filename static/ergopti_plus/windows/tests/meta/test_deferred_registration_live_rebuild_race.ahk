; tests/meta/test_deferred_registration_live_rebuild_race.ahk

#Requires AutoHotkey v2.0

_DRLR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_DRLR_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	return Rest
}

_DRLR_AssertCancelOnLiveRebuild() {
	SrcHotstrings := _DRLR_ReadSource("modules/hotstrings.ahk")
	BodyRAH := _DRLR_FuncBodyStripped(SrcHotstrings, "RegisterAllHotstrings(DeferHeavy := false) {")
	Assert(BodyRAH != "", "RegisterAllHotstrings must exist in modules/hotstrings.ahk")
	
	CancelIdx1 := InStr(BodyRAH, "SetTimer(RegisterEmojisSymbolsDeferred, 0)")
	Assert(CancelIdx1 > 0, "RegisterAllHotstrings must cancel the deferred timer when DeferHeavy=false (deferred-queue-not-cancelled-on-live-rebuild)")

	SrcTray := _DRLR_ReadSource("ui/tray_menu.ahk")
	BodyRHL := _DRLR_FuncBodyStripped(SrcTray, "RebuildHotstringsLive() {")
	Assert(BodyRHL != "", "RebuildHotstringsLive must exist in ui/tray_menu.ahk")
	
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
