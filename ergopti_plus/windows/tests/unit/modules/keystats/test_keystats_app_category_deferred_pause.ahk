; tests/unit/modules/keystats/test_keystats_app_category_deferred_pause.ahk

; ==============================================================================
; MODULE: Deferred App-Category Save Under Pause
; DESCRIPTION:
; KL_AppCat_DeferredSave is the one-shot that persists a newly discovered app
; category, and SetTimer callbacks keep firing under native Suspend. A paused
; tick must not write, and must re-arm itself rather than return bare: its only
; other arm site registers the app key first, so a dropped tick strands
; KLAppCat.dirty for the session (F-19). The retry delay is shortened and the
; save callback replaced by a recorder, so the re-arm is observed without any
; file being written.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLACDP_PausedSaveRearmsWithoutWriting() {
	Fired := []
	HadSaveFn := KLAppCat.HasOwnProp("save_fn")
	SavedSaveFn := HadSaveFn ? KLAppCat.save_fn : 0
	SavedDirty := KLAppCat.dirty
	SavedPath := KLAppCat.file_path
	SavedDelay := KLAppCatConst.DEFERRED_SAVE_RETRY_MS
	WasSuspended := A_IsSuspended
	Recorder := (*) => Fired.Push(A_IsSuspended)
	try {
		; No store path: an unguarded save would find nothing to write to.
		KLAppCat.file_path := ""
		KLAppCat.save_fn := Recorder
		KLAppCatConst.DEFERRED_SAVE_RETRY_MS := 10
		KLAppCat.dirty := true
		Suspend(true)
		KL_AppCat_DeferredSave()
		AssertTrue(KLAppCat.dirty, "a paused deferred save must keep its pending category")
		Started := A_TickCount
		while Fired.Length == 0 && A_TickCount - Started < 2000
			Sleep(10)
		AssertEqual(1, Fired.Length, "a paused deferred save must re-arm its own one-shot (F-19)")
	} finally {
		SetTimer(Recorder, 0)
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		KLAppCatConst.DEFERRED_SAVE_RETRY_MS := SavedDelay
		KLAppCat.file_path := SavedPath
		KLAppCat.dirty := SavedDirty
		if HadSaveFn
			KLAppCat.save_fn := SavedSaveFn
		else
			KLAppCat.DeleteProp("save_fn")
	}
}
Test("keystats app categories: a paused deferred save re-arms without writing (F-19)",
	_KLACDP_PausedSaveRearmsWithoutWriting)
