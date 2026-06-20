; tests/meta/test_updater_download_timeout.ahk

; ==============================================================================
; MODULE: Updater Download Timeout Meta-Test
; DESCRIPTION:
; Structural regression for the download poll ceiling fix in lib/updater.ahk.
;
; Before the fix, _Updater_PollDownloadAsync() capped the total wait at
; 120 000 ms (2 minutes):
;   MaxPolls := 120000 / UPDATER_ASYNC_POLL_MS
; On slow or metered connections large release assets (10-50 MB) routinely
; exceed 2 minutes. When MaxPolls was hit the download was aborted and marked
; failed even though the underlying XHR request was still in progress, leaving
; the user with no update and no useful error.
;
; The fix raises the ceiling to 600 000 ms (10 minutes), matching the headroom
; expected for a 50 MB asset on a 1 Mbit/s connection.
;
; This test inspects updater.ahk source and asserts:
;   1. 600000 is the numerator in the MaxPolls expression (not 120000).
;   2. 120000 is no longer used as the download timeout ceiling.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================================
; ===========================================================
; ======= 1/ Source-inspection helpers =======================
; ===========================================================
; ===========================================================

_UDTO_ReadSource() {
	return FileRead(A_ScriptDir . "\..\lib\updater.ahk", "UTF-8")
}


_UDTO_FindPollBlock(src) {
	pos := InStr(src, "_Updater_PollDownloadAsync(")
	if (!pos)
		return ""
	return SubStr(src, pos, 800)
}




; ===========================================================
; ===========================================================
; ======= 2/ Assertions =====================================
; ===========================================================
; ===========================================================

_UDTO_600SecCeiling() {
	block := _UDTO_FindPollBlock(_UDTO_ReadSource())
	Assert(InStr(block, "600000") > 0,
		"updater.ahk: _Updater_PollDownloadAsync must use 600000 ms as the download timeout ceiling")
}
Test("Updater: download poll ceiling raised to 600000 ms (updater-download-timeout)", _UDTO_600SecCeiling)


_UDTO_No120SecCeiling() {
	block := _UDTO_FindPollBlock(_UDTO_ReadSource())
	; The MaxPolls expression must not still divide 120000.
	posMax := InStr(block, "MaxPolls := 120000")
	Assert(posMax = 0,
		"updater.ahk: download timeout ceiling must not be 120000 ms — it was raised to 600000 ms")
}
Test("Updater: 120000 ms ceiling removed from _Updater_PollDownloadAsync (updater-download-timeout)", _UDTO_No120SecCeiling)
