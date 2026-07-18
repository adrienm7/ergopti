; tests/meta/test_screenshot_region_clipwait_clobber.ahk

; ==============================================================================
; MODULE: Screenshot Region Clipwait Clobber Meta Test
; DESCRIPTION:
; Static source guard for the "screenshot-region-clipwait-clobber" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSC_Check() {
	; Move-resilient: extract GestureScreenshotRegion()'s body by name via the
	; framework helper instead of a pinned modules/gestures.ahk read. Scoping to the
	; function (rather than the whole file) keeps the clipboard backup/restore
	; assertions tied to the region-screenshot path they actually guard.
    Src := _DriverFuncBody("GestureScreenshotRegion")
    PollSrc := _DriverFuncBody("GestureRegionCapturePoll")
    FinishSrc := _DriverFuncBody("GestureRegionCaptureFinish")
    Assert(Src != "", "GestureScreenshotRegion must exist in modules/gestures.ahk")
    Assert(PollSrc != "" && FinishSrc != "", "region saving must use explicit async poll and cleanup lifecycle")
    Assert(InStr(Src, "OldClip := ClipboardAll()") > 0, "region transaction must snapshot the clipboard before invoking Snipping Tool")
    Assert(InStr(Src, "SetTimer(GestureRegionCapturePoll.Bind(Epoch)") > 0, "region selection must be deferred to an epoch-bound timer")
    Assert(InStr(PollSrc, "ClipWait(0.001, 2)") > 0, "timer must probe for an image without a long ClipWait")
    Assert(InStr(FinishSrc, "A_Clipboard := State[") > 0, "cleanup must restore the snapshot")
    Assert(InStr(FinishSrc, "_GestureRegionCapture[\"epoch\"] != Epoch") > 0, "stale callbacks must not restore a newer capture's clipboard")
}

Test("Gestures: screenshot region preserves clipboard", _TSC_Check)
