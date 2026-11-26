; tests/meta/modules/keystats/test_keystats_deferred_write.ahk

#Requires AutoHotkey v2.0

_KDW_AssertDeferredWrite() {
	AppendBody := _DriverFuncBody("KL_AppendLog")

	InlineWriteIdx := InStr(AppendBody, "fh.Write(")
	Assert(!InlineWriteIdx, "KL_AppendLog must NOT call fh.Write() inline (kl-synchronous-disk-write-on-keystroke)")
	Assert(InStr(AppendBody, "_KL_JournalAppendDefault(") = 0,
		"KL_AppendLog must not call the receipt-validating journal writer inline")

	IngestBody := _DriverFuncBody("KL_IngestOnce")

	DeferredWriteIdx := InStr(IngestBody, "_KL_JournalAppendDefault(fh, line)")
	Assert(DeferredWriteIdx > 0,
		"KL_IngestOnce must write pending_snapshot through the counted, rollback-safe journal writer off the hot path")
}

Test("keystats: Keystroke log writes are deferred off the hot path (kl-synchronous-disk-write-on-keystroke)", _KDW_AssertDeferredWrite)

;
; F-19  KL_AppCat_DeferredSave returned bare while paused, but that one-shot IS
; the only write path: its sole other arm site registers the app key
; BEFORE arming, so once the key exists that branch is unreachable for the
; same app, and there is no periodic save and no KL_AppCat_Stop. The paused
; re-arm is called under a real Suspend in
; tests/unit/modules/keystats/test_keystats_app_category_deferred_pause.ahk;
; this scan keeps the reason it is mandatory.
_A0720B3_DeferredSaveReArmsWhilePaused() {
	; The other arm site cannot fire again for the same app.
	Get := _DriverFuncBody("KL_AppCat_Get")
	Assert(Get != "", "KL_AppCat_Get must exist")
	InsertIdx := InStr(Get, "KLAppCat.categories[key] :=")
	ArmIdx := InStr(Get, "_KL_AppCat_ScheduleDeferredSave()")
	Assert(InsertIdx > 0 and ArmIdx > 0 and InsertIdx < ArmIdx,
		"KL_AppCat_Get registers the app key BEFORE arming the one-shot, so it can never re-arm for that same app — which is exactly why the suspended branch has to re-arm itself")
}
Test("keystats: the category lookup cannot re-arm a known app's deferred save (F-19)",
	_A0720B3_DeferredSaveReArmsWhilePaused)
