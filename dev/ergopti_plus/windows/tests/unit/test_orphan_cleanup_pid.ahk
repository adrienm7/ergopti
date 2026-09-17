; tests/unit/test_orphan_cleanup_pid.ahk

; ==============================================================================
; MODULE: Orphan Cleanup PID Tests
; DESCRIPTION: Malformed process identities cannot authorize private-file deletion.
; ==============================================================================

#Requires AutoHotkey v2.0

_OCP_InvalidOwner(Surface, PidText) {
	_KLRDC_Reset()
	try {
		Root := RTrim(_KLRDC_Root(), "\")
		Prefix := Root . (Surface = "range" ? "\ergopti_metrics_range_typing.stage." : "\ergopti_http_")
		Suffix := Surface = "range" ? "." . KLPF_NewOwnerId() . ".1.json" : "_1.body"
		Malformed := Prefix . PidText . Suffix
		Live := Prefix . KLPFWorker.process_id . Suffix
		DeadPid := 2147483647
		AssertEqual(0, ProcessExist(DeadPid))
		Dead := Prefix . DeadPid . Suffix
		for Path in [Malformed, Live, Dead]
			AssertTrue(FSWriteCreateDurable(Path, "synthetic range") != 0)
		if Surface = "range"
			AssertTrue(KLPF_ReapOrphanRangeStages(Root), "an unrepresentable owner must not abort startup cleanup")
		else
			_HTTP_CurlSweepOrphans(Root)
		AssertEqual("synthetic range", FileRead(Malformed, "UTF-8"), "an invalid PID is not proof of a dead owner")
		AssertEqual("synthetic range", FileRead(Live, "UTF-8"), "a live owner must remain untouched")
		AssertFalse(FSExists(Dead), "valid dead owners must still be reaped")
	} finally _KLRDC_Cleanup()
}
for Surface in ["range", "http"]
	for PidText in ["0", "4294967296", "18446744073709551616"]
		Test("Orphan cleanup: " . Surface . " invalid PID " . PidText . " remains unowned (orphan-cleanup-pid)",
			_KLRDC_CheckTeardown.Bind(_OCP_InvalidOwner.Bind(Surface, PidText)))
