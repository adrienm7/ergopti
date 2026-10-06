; tests/meta/test_deferred_registration_live_rebuild_race.ahk

#Requires AutoHotkey v2.0

; Symbol-based reads retain the invariant across owner moves and optional parameters.
_DRLR_AssertCancelOnLiveRebuild() {
	BodyRAH := _DriverFuncBody("RegisterAllHotstrings")
	Assert(BodyRAH != "", "RegisterAllHotstrings must exist in the driver source")
	
	CancelIdx1 := InStr(BodyRAH, "SetTimer(RegisterEmojisSymbolsDeferred, 0)")
	Assert(CancelIdx1 > 0, "RegisterAllHotstrings must cancel the deferred timer when DeferHeavy=false (deferred-queue-not-cancelled-on-live-rebuild)")

	BodyRHL := _DriverFuncBody("_RebuildHotstringsLiveOnce")
	Assert(BodyRHL != "", "the serialized live-rebuild pass must exist in the driver source")
	
	CancelIdx2 := InStr(BodyRHL, "SetTimer(RegisterEmojisSymbolsDeferred, 0)")
	Assert(CancelIdx2 > 0, "RebuildHotstringsLive must cancel the deferred timer before wiping registry (deferred-queue-not-cancelled-on-live-rebuild)")
}

_DRLR_AssertGuardInDeferred() {
	Body := _DriverFuncBody("RegisterEmojisSymbolsDeferred")
	Assert(Body != "", "RegisterEmojisSymbolsDeferred must exist in the driver source")
	
	GuardIdx := InStr(Body, 'HSE_RegistryByGroup.Has("emojis.emojis")')
	Assert(GuardIdx > 0, "RegisterEmojisSymbolsDeferred must guard against already-registered sections (deferred-queue-not-cancelled-on-live-rebuild)")
}

Test("hotstrings: live rebuild cancels deferred timer (deferred-queue-not-cancelled-on-live-rebuild)", _DRLR_AssertCancelOnLiveRebuild)
Test("hotstrings: deferred pass guards against concurrent live rebuild (deferred-queue-not-cancelled-on-live-rebuild)", _DRLR_AssertGuardInDeferred)
