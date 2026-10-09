; tests/unit/test_http_orphan_liveness.ahk

; ==============================================================================
; MODULE: HTTP Orphan Liveness Tests
; DESCRIPTION: Artifact age cannot override a live process's cleanup ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

_HOL_AgeCannotRevokeOwnership() {
	_KLRDC_Reset()
	try {
		Root := RTrim(_KLRDC_Root(), "\")
		LivePid := ProcessExist()
		DeadPid := 2147483647
		AssertEqual(0, ProcessExist(DeadPid))
		Old := DateAdd(A_Now, -2, "Days")
		Keep := []
		Remove := []
		for Extension in ["conf", "body", "headers"] {
			for OwnerPid in [LivePid, DeadPid] {
				for Sequence in [1, 2] {
					Path := Root . "\ergopti_http_" . OwnerPid . "_" . Sequence . "." . Extension
					AssertTrue(FSWriteCreateDurable(Path, "synthetic HTTP artifact") != 0)
					if Sequence = 1 {
						FileSetTime(Old, Path, "M")
						AssertTrue(DateDiff(A_Now, FileGetTime(Path, "M"), "Seconds") > 86400,
							"the native file must cross the former age threshold")
					}
					(OwnerPid = LivePid ? Keep : Remove).Push(Path)
				}
			}
		}
		_HTTP_CurlSweepOrphans(Root)
		AssertEqual(LivePid, ProcessExist(LivePid), "the fixture owner must remain demonstrably alive")
		for Path in Keep
			AssertEqual("synthetic HTTP artifact", FileRead(Path, "UTF-8"),
				"old and recent files remain owned while their process is alive")
		for Path in Remove
			AssertFalse(FSExists(Path), "dead-owner cleanup must still work at either age")
	} finally _KLRDC_Cleanup()
}
Test("HTTP cleanup: live owners retain old configuration and response files (http-orphan-liveness)",
	_KLRDC_CheckTeardown.Bind(_HOL_AgeCannotRevokeOwnership))
