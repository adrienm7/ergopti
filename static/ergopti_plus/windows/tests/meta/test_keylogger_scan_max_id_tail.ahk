; tests/meta/test_keylogger_scan_max_id_tail.ahk

; ==============================================================================
; MODULE: Keylogger Scan-Max-ID Tail Read Meta Test
; DESCRIPTION:
; Static source guard for the "keylogger-scan-max-id-performance" audit finding.
;
; ROOT CAUSE ENCODED:
; KL_Init called FileRead(Keylogger.data_sql_path, "UTF-8") which reads the
; ENTIRE data.sql file into memory (100+ MB after months of use), then passed
; the full string to KL_ScanMaxEventId which forward-scanned every byte. This
; made startup I/O proportional to file size — O(N) — producing multi-second
; freezes on large files.
;
; The fix reads only the TAIL of the file (64 KB) using FileOpen + Seek from
; the end, reducing startup I/O to O(1) regardless of total file size.
; DATA_SQL_SCAN_TAIL_BYTES in KeylogConst is the single source of truth.
;
; This test verifies:
;   1. DATA_SQL_SCAN_TAIL_BYTES is declared in KeylogConst.
;   2. KL_Init no longer uses FileRead for scanning data.sql.
;   3. KL_Init uses FileOpen + fh.Seek for the tail-read pattern.
;   4. KL_ScanMaxEventId remains a pure function with no disk I/O.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ DATA_SQL_SCAN_TAIL_BYTES constant =======
; ====================================================
; ====================================================

_KLSM_ConstantDeclared() {
	Src := _DriverDirConcat("modules/keylogger")

	Assert(InStr(Src, "DATA_SQL_SCAN_TAIL_BYTES") > 0,
		"KeylogConst must declare DATA_SQL_SCAN_TAIL_BYTES (keylogger-scan-max-id-performance)")

	; Constant must be at least 32 KB — smaller values risk missing recent events
	Assert(RegExMatch(Src, "DATA_SQL_SCAN_TAIL_BYTES\s*:=\s*(\d+)", &m) && Integer(m[1]) >= 32768,
		"DATA_SQL_SCAN_TAIL_BYTES must be at least 32768 bytes (keylogger-scan-max-id-performance)")
}
Test("keylogger: KeylogConst.DATA_SQL_SCAN_TAIL_BYTES is declared and >= 32 KB (keylogger-scan-max-id-performance)", _KLSM_ConstantDeclared)





; ============================================================
; ============================================================
; ======= 2/ KL_Init uses tail-read, not full FileRead =======
; ============================================================
; ============================================================

_KLSM_InitUsesTailRead() {
	; Move-resilient: locate KL_Init() across the whole driver source via the
	; framework helper instead of a pinned modules path
	Body := _DriverFuncBody("KL_Init")
	Assert(Body != "", "KL_Init must exist in the driver source")

	; The old O(N) pattern must be gone: FileRead on the full data_sql_path
	Assert(!RegExMatch(Body, "FileRead\([^)]*data_sql_path[^)]*\)"),
		"KL_Init must NOT call FileRead(data_sql_path) for scanning — use tail-read (keylogger-scan-max-id-performance)")

	; The new O(1) pattern must be present: FileOpen + Seek
	Assert(InStr(Body, "FileOpen") > 0 && InStr(Body, "fh.Seek") > 0,
		"KL_Init must use FileOpen + fh.Seek for the tail-read (keylogger-scan-max-id-performance)")

	; DATA_SQL_SCAN_TAIL_BYTES must be referenced in the tail-read
	Assert(InStr(Body, "DATA_SQL_SCAN_TAIL_BYTES") > 0,
		"KL_Init must reference DATA_SQL_SCAN_TAIL_BYTES when seeking (keylogger-scan-max-id-performance)")

	; KL_ScanMaxEventId must still be called
	Assert(InStr(Body, "KL_ScanMaxEventId") > 0,
		"KL_Init must still call KL_ScanMaxEventId after the tail-read (keylogger-scan-max-id-performance)")
}
Test("keylogger: KL_Init uses FileOpen+Seek tail-read, not full FileRead (keylogger-scan-max-id-performance)", _KLSM_InitUsesTailRead)





; =======================================================
; =======================================================
; ======= 3/ KL_ScanMaxEventId is a pure function =======
; =======================================================
; =======================================================

_KLSM_ScanFunctionPure() {
	; Move-resilient: locate KL_ScanMaxEventId() across the whole driver source.
	Body := _DriverFuncBody("KL_ScanMaxEventId")

	; KL_ScanMaxEventId must still exist and accept text + device params
	Assert(InStr(Body, "KL_ScanMaxEventId(sql_text, device_id_lit)") > 0,
		"KL_ScanMaxEventId(sql_text, device_id_lit) must remain a pure function (keylogger-scan-max-id-performance)")

	; Must NOT call FileRead / FileOpen internally (pure = no disk I/O)
	Assert(!InStr(Body, "FileRead") && !InStr(Body, "FileOpen"),
		"KL_ScanMaxEventId must remain pure (no disk I/O) — I/O is the caller's responsibility (keylogger-scan-max-id-performance)")
}
Test("keylogger: KL_ScanMaxEventId remains a pure function with no disk I/O (keylogger-scan-max-id-performance)", _KLSM_ScanFunctionPure)
