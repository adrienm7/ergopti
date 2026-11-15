; tests/meta/modules/hotstrings/catalogue/test_deferred_registration_live_rebuild_race.ahk

#Requires AutoHotkey v2.0

; Symbol-based reads retain the invariant across owner moves and optional parameters.
_DRLR_AssertCancelOnLiveRebuild() {
	BodyRAH := _DriverFuncBody("RegisterAllHotstrings")
	Assert(BodyRAH != "", "RegisterAllHotstrings must exist in the driver source")
	
	CancelIdx1 := InStr(BodyRAH, "HSE_DeferredRegistrationCancel()")
	Assert(CancelIdx1 > 0, "RegisterAllHotstrings must cancel the deferred job when DeferHeavy=false (deferred-queue-not-cancelled-on-live-rebuild)")

	BodyRHL := _DriverFuncBody("_RebuildHotstringsLiveOnce")
	Assert(BodyRHL != "", "the serialized live-rebuild pass must exist in the driver source")
	
	CancelIdx2 := InStr(BodyRHL, "HSE_DeferredRegistrationCancel()")
	Assert(CancelIdx2 > 0 and CancelIdx2 < InStr(BodyRHL, "HSE_RegistryClear()"),
		"RebuildHotstringsLive must cancel the deferred job before wiping registry (deferred-queue-not-cancelled-on-live-rebuild)")
}

; The behaviour is pinned by (hotstring-deferred-rank): a slice after a registry
; clear registers nothing. This keeps the guard on the slice itself.
_DRLR_AssertGuardInDeferred() {
	Body := _DriverFuncBody("HSE_DeferredRegistrationSlice")
	Assert(Body != "", "HSE_DeferredRegistrationSlice must exist in the driver source")
	
	GuardIdx := InStr(Body, "HSE_SeqReservationCurrent(Job.Reservation)")
	Assert(GuardIdx > 0 and GuardIdx < InStr(Body, "HSE_SeqReservationOpen("),
		"a deferred slice must refuse a block a live rebuild's registry clear dropped (deferred-queue-not-cancelled-on-live-rebuild)")
}

Test("hotstrings: live rebuild cancels deferred timer (deferred-queue-not-cancelled-on-live-rebuild)", _DRLR_AssertCancelOnLiveRebuild)
Test("hotstrings: deferred pass guards against concurrent live rebuild (deferred-queue-not-cancelled-on-live-rebuild)", _DRLR_AssertGuardInDeferred)
