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
    Src := _TSC_DriverFuncBody("GestureScreenshotRegion")
    PollSrc := _TSC_DriverFuncBody("GestureRegionCapturePoll")
    SaveStartSrc := _TSC_DriverFuncBody("GestureRegionCaptureStartSaveWorker")
    SaveDoneSrc := _TSC_DriverFuncBody("GestureRegionSaveWorkerDone")
    FinishSrc := _TSC_DriverFuncBody("GestureRegionCaptureFinish")
	SequenceAdapterSrc := _TSC_DriverFuncBody("CB_GetSequenceNumber")
	ImageAdapterSrc := _TSC_DriverFuncBody("CB_HasImage")
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
	Assert(InStr(FinishSrc, "OwnedSequence != 0 && CB_GetSequenceNumber() = OwnedSequence") > 0,
		"cleanup must restore only if its transaction still owns the clipboard sequence, preserving a later user copy")
	Assert(InStr(SequenceAdapterSrc, 'DllCall("GetClipboardSequenceNumber"') > 0,
		"the clipboard adapter must own the Win32 clipboard sequence probe")
	Assert(InStr(ImageAdapterSrc, "IsClipboardFormatAvailable") > 0,
		"the clipboard adapter must own the Win32 image-format probe")
    Assert(InStr(Src, "CB_BeginOwnedTransaction") > 0 && InStr(Src, "CB_ExpectOwnedChange") > 0,
        "the external Snipping Tool write must carry shared clipboard ownership")
    Assert(InStr(FinishSrc, "CB_RestoreAll(State[") > 0,
        "owned cleanup must restore the all-format snapshot through the clipboard adapter")
    Assert(InStr(FinishSrc, "CB_EndOwnedTransaction") > 0,
        "every region-capture terminal path must release shared clipboard ownership")
    Quote := Chr(34)
    Assert(InStr(FinishSrc, "_GestureRegionCapture[" . Quote . "epoch" . Quote . "] != Epoch") > 0, "stale callbacks must not restore a newer capture's clipboard")
}

; Keep this regression test independent from the runner's private source-scan
; helpers.  It must remain warning-free when parsed by itself as well as when
; included by run_all.ahk.
_TSC_DriverFuncBody(Name) {
    SplitPath(A_ScriptDir, , &TestsDir)
    SplitPath(TestsDir, , &Root)
    Source := ""
    Loop Files, Root . "\*.ahk", "FR" {
        Path := StrReplace(A_LoopFileFullPath, "\", "/")
        if (InStr(Path, "/tests/") or InStr(Path, "/vendor/") or InStr(Path, "/_generated/"))
            continue
        try Source .= "`n" . FileRead(A_LoopFileFullPath)
    }
    if !RegExMatch(Source, "m)^[ \t]*" . Name . "\([^\r\n]*\)\s*\{", &Match)
        return ""
    Start := Match.Pos
    OpenBrace := InStr(Source, "{", , Start)
    if (!OpenBrace)
        return ""
    Depth := 0
    Position := OpenBrace
    Length := StrLen(Source)
    while (Position <= Length) {
        Character := SubStr(Source, Position, 1)
        if (Character == "{")
            Depth += 1
        else if (Character == "}") {
            Depth -= 1
            if (Depth == 0)
                return SubStr(Source, Start, Position - Start + 1)
        }
        Position += 1
    }
    return ""
}

Test("Gestures: screenshot region preserves clipboard", _TSC_Check)
