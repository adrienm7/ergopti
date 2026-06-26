; tests/meta/test_av_warmup_cancellable.ahk

; ==============================================================================
; MODULE: KL_AV Warm-up Cancellable + Guarded Meta Test
; DESCRIPTION:
; Static source guard for finding av-warmup-cancellable (F-L07).
;
; KL_AV_Start armed its 3 s warm-up volume poll as a bare anonymous closure
; (SetTimer(() => KL_AV_PollVolume(), -3000)) stored in no field, targeting the
; UNGUARDED worker KL_AV_PollVolume directly. KL_AV_Stop cancels fast_fn/slow_fn by
; stored reference but had no handle to the warm-up, so it could not cancel it: the
; orphaned one-shot still ran a winmm volume DllCall ~3 s after Stop, violating the
; clean-shutdown invariant the sibling KLNet/KLSensors warm-ups honour (they store
; their starter BoundFunc in a field). The fix stores the warm-up in KLAVState.warmup_fn,
; routes it through the GUARDED tick KL_AV_FastTick, and cancels it in KL_AV_Stop.
;
; Meta-static because modules/keylogger is not in the headless runner's include graph.
; ==============================================================================

#Requires AutoHotkey v2.0


_AVWC_AssertCancellable() {
	Start := _DriverFuncBody("KL_AV_Start")
	Assert(Start != "", "KL_AV_Start must exist")
	Assert(InStr(Start, "KLAVState.warmup_fn :=") > 0,
		"KL_AV_Start must store the warm-up in KLAVState.warmup_fn so KL_AV_Stop can cancel it (av-warmup-cancellable)")
	Assert(!RegExMatch(Start, "SetTimer\(\(\) =>"),
		"KL_AV_Start warm-up must not be a bare anonymous closure — it would be uncancellable (av-warmup-cancellable)")
	Assert(!RegExMatch(Start, "SetTimer\([^)]*KL_AV_PollVolume"),
		"KL_AV_Start warm-up must route through the guarded KL_AV_FastTick, not the unguarded KL_AV_PollVolume directly (av-warmup-cancellable)")

	Stop := _DriverFuncBody("KL_AV_Stop")
	Assert(Stop != "", "KL_AV_Stop must exist")
	Assert(InStr(Stop, "warmup_fn") > 0,
		"KL_AV_Stop must cancel KLAVState.warmup_fn so the orphaned warm-up cannot fire after stop (av-warmup-cancellable)")
}
Test("keylogger: AV-state warm-up is cancellable + guarded (av-warmup-cancellable)", _AVWC_AssertCancellable)
