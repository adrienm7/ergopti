; tests/meta/test_gesturepickcolor_clipboard_clobber.ahk

; ==============================================================================
; MODULE: GesturePastePlain Clipboard-Restore Meta Test
; DESCRIPTION:
; Static source guard for the gesturepickcolor-clipboard-clobber finding.
;
; GesturePastePlain coerces the clipboard to plain text with the self-assign
; A_Clipboard := A_Clipboard before pasting. That round-trip keeps only the text
; form and silently drops any image/HTML/RTF the user may still want. The fix
; snapshots the FULL clipboard through CB_SaveAll() before the coercion and
; restores it on a negative-delay SetTimer after the synthetic ^v has settled,
; mirroring SendInstant's save/paste/deferred-restore guarantee.
;
; This is a meta-static test (scans source text) because GesturePastePlain calls
; WinActive / SendFinalResult / mutates the clipboard and cannot be exercised on
; the headless runner. If the CB_SaveAll() snapshot or the deferred restore is
; removed, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.




; ==================================================
; ==================================================
; ======= 2/ Clipboard-restore assertions ==========
; ==================================================
; ==================================================

_GPCC_PastePlainSnapshotsFullClipboard() {
	Seg := _DriverFuncBody("GesturePastePlain")
	Assert(Seg != "", "GesturePastePlain() declaration must exist in gestures.ahk")
	Assert(InStr(Seg, "CB_SaveAll()") > 0,
		"GesturePastePlain must snapshot the full clipboard through CB_SaveAll() before coercing to plain text — the self-assign drops non-text formats the user may still want")
}
Test("gestures: GesturePastePlain snapshots full clipboard before coercion (gesturepickcolor-clipboard-clobber)", _GPCC_PastePlainSnapshotsFullClipboard)

_GPCC_PastePlainDefersRestore() {
	Seg := _DriverFuncBody("GesturePastePlain")
	Assert(Seg != "", "GesturePastePlain() declaration must exist in gestures.ahk")
	Assert(InStr(Seg, "_GesturePastePlainRestore") > 0,
		"GesturePastePlain must restore the original clipboard via the deferred _GesturePastePlainRestore helper so the user's non-text payload survives the paste")
	Assert(InStr(Seg, "SetTimer") > 0,
		"GesturePastePlain must defer the clipboard restore on a SetTimer so the synthetic ^v consumes the coerced text before the original is put back")
}
Test("gestures: GesturePastePlain defers clipboard restore after paste settles (gesturepickcolor-clipboard-clobber)", _GPCC_PastePlainDefersRestore)
