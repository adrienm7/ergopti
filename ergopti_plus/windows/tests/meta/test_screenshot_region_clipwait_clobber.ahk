; tests/meta/test_screenshot_region_clipwait_clobber.ahk

; ==============================================================================
; MODULE: Screenshot Region Clipwait Clobber Meta Test
; DESCRIPTION:
; Static source guard for the "screenshot-region-clipwait-clobber" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

; This meta test is also parsed directly by the repository validation pass.
; The normal include is deduplicated when run_all.ahk loaded the framework first.
#Include ..\test_framework.ahk

_TSC_Check() {
	; Move-resilient: extract GestureScreenshotRegion()'s body by name via the
	; framework helper instead of a pinned modules/gestures.ahk read. Scoping to the
	; function (rather than the whole file) keeps the clipboard backup/restore
	; assertions tied to the region-screenshot path they actually guard.
    Src := _DriverFuncBody("GestureScreenshotRegion")
    PollSrc := _DriverFuncBody("GestureRegionCapturePoll")
    SaveStartSrc := _DriverFuncBody("GestureRegionCaptureStartSaveWorker")
    SaveDoneSrc := _DriverFuncBody("GestureRegionSaveWorkerDone")
    FinishSrc := _DriverFuncBody("GestureRegionCaptureFinish")
	SequenceAdapterSrc := _DriverFuncBody("CB_GetSequenceNumber")
	ImageAdapterSrc := _DriverFuncBody("CB_HasImage")
    Assert(Src != "", "GestureScreenshotRegion must exist in modules/gestures.ahk")
    Assert(PollSrc != "" && SaveStartSrc != "" && SaveDoneSrc != "" && FinishSrc != "",
        "region saving must use explicit selection, worker, publication, and cleanup lifecycle")
    Assert(InStr(Src, "OldClip := CB_SaveAll()") > 0,
        "region transaction must snapshot all clipboard formats through the owned adapter")
    Assert(InStr(Src, "if A_IsSuspended") > 0, "region capture must refuse to start while the driver is suspended")
    Assert(InStr(Src, "SetTimer(GestureRegionCapturePoll.Bind(Epoch)") > 0, "region selection must be deferred to an epoch-bound timer")
    Assert(InStr(PollSrc, "if A_IsSuspended") > 0, "the deferred region poll must cancel rather than save while suspended")
    Assert(InStr(PollSrc, "ClipWait(GESTURE_REGION_CLIPWAIT_PROBE_SEC") > 0
        && InStr(PollSrc, "GESTURE_REGION_CLIPWAIT_IMAGE_MODE") > 0,
        "timer must probe for an image with the named bounded ClipWait policy")
	Assert(InStr(PollSrc, "CB_HasImage()") > 0,
		"any-data ClipWait is insufficient: region capture must require an image clipboard format before starting a save through the clipboard adapter")
	Assert(InStr(PollSrc, 'State["clipboard_sequence"] := CB_GetSequenceNumber()') > 0,
		"the accepted Snipping Tool image must publish the clipboard sequence owned by this transaction")
	Assert(InStr(SaveStartSrc, '_GestureScreenshotCreateWorker("region_save"') > 0,
		"region save must retain the PowerShell process in the shared worker registry")
	Assert(InStr(SaveDoneSrc, "_GestureScreenshotPublishFile") > 0,
		"region save may publish the final path only from its current worker completion")
	Assert(InStr(FinishSrc, "CB_RestoreOwnedAllEventually") > 0
		and InStr(FinishSrc, "OwnedSequence") > 0,
		"cleanup must delegate its exact sequence and snapshot to the retrying restore coordinator")
	Assert(InStr(SequenceAdapterSrc, 'DllCall("GetClipboardSequenceNumber"') > 0,
		"the clipboard adapter must own the Win32 clipboard sequence probe")
	Assert(InStr(ImageAdapterSrc, "IsClipboardFormatAvailable") > 0,
		"the clipboard adapter must own the Win32 image-format probe")
    Assert(InStr(Src, "CB_TryBeginOwnedTransaction") > 0 && InStr(Src, "CB_ExpectOwnedChange") > 0,
        "the external Snipping Tool write must carry shared clipboard ownership")
    Assert(InStr(FinishSrc, "CB_RestoreOwnedAllEventually(State[") > 0,
        "owned cleanup must retain the all-format snapshot until the adapter restores it")
    Assert(InStr(FinishSrc, 'State.Get("owner_token"') > 0,
        "every region-capture terminal path must transfer its exact shared owner")
    Quote := Chr(34)
    Assert(InStr(FinishSrc, "_GestureRegionCapture[" . Quote . "epoch" . Quote . "] != Epoch") > 0, "stale callbacks must not restore a newer capture's clipboard")
}

Test("Gestures: screenshot region preserves clipboard (screenshot-source-cost)", _TSC_Check)

_TSC_SharedSourceGuard() {
	; Inspect this test's own body, not a pinned production path. Keep the
	; assertion outside that body so it cannot satisfy its own search.
	Source := FileRead(A_LineFile, "UTF-8")
	Body := _DriverExtractFunctionBody(&Source, "_TSC_Check")
	Assert(Body != "", "the clipboard guard must remain extractable")
	Body := _StripFullLineComments(Body)
	Assert(!InStr(Body, "_TSC_DriverFuncBody("),
		"clipboard checks must not repeat the private recursive source scan")
	Assert(RegExMatch(Body, "(?<![\w])_DriverFuncBody\("),
		"clipboard checks must use the shared indexed source extractor")
}
Test("Gestures: clipboard guard reuses the shared source index (screenshot-shared-source-index)",
	_TSC_SharedSourceGuard)
