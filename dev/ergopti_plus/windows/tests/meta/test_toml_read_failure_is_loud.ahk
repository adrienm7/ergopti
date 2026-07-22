; tests/meta/test_toml_read_failure_is_loud.ahk

; ==============================================================================
; MODULE: Regression — an unreadable TOML must never read as an empty one
; DESCRIPTION:
; Two readers swallowed their FileRead with a bare `try` and no catch, so a
; file that could not be opened produced exactly what a genuinely empty file
; produces. Nothing distinguished them, nothing was logged, and the callers had
; no way to ask.
;
; ROOT CAUSE ENCODED:
;
; 1. ParseTomlFile returned an empty Map on a failed read, and TOML_BatchWrite
;    seeds its rewrite from that Map — it serializes what it holds and moves the
;    result over the original. So "I could not read your config" silently became
;    "your config was empty", and the next tray toggle wrote a config.toml
;    containing one section and one key. Strict canonicalization re-inflates
;    most of it from the in-memory Features tree, but it is SKIPPED for
;    boot-phase writes, so the loss is real and permanent exactly when the user
;    is least able to notice.
;
; 2. ReadTomlFile cached the empty string under the file's path, so one
;    transient lock at boot hid a whole hotstring file for the entire session —
;    every consumer saw zero entries and the menu showed a count of 0, with the
;    load logged at DONE level, indistinguishable from success.
;
; A read that FAILED must be distinguishable from a file that is genuinely
; empty. The fix keeps both functions non-throwing — the fuzz corpus requires
; ParseTomlFile never to raise — and signals failure out of band instead.
;
; SCOPE: behavioural where the failure can be provoked, source introspection
; for the write-abort wiring.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ A failed read is never memoised =======
; ==================================================
; ==================================================

; A missing file and an unreadable one are different facts. Caching the empty
; result for either means the very first failure is permanent for the session;
; only a successful read may be remembered.
_TRF_FailedReadIsNotCached() {
	Path := A_Temp . "\ergopti_test_toml_absent_" . A_TickCount . ".toml"
	try FileDelete(Path)

	First := ReadTomlFile(Path)
	Assert(First == "", "a missing file must read as empty")

	; The file appears after the first read. If the miss had been memoised the
	; content would stay invisible for the rest of the session — which is
	; exactly how a boot-time lock used to hide a whole hotstring file.
	FileAppend("[s]`nk = 1`n", Path, "UTF-8")
	Second := ReadTomlFile(Path)
	try FileDelete(Path)

	Assert(InStr(Second, "k = 1") > 0,
		"a read that returned nothing must NOT be cached — the file became readable and its content must now be visible, but the memoised empty string hid it for the whole session")
}

; The read must still be memoised once it succeeds, or every consumer re-reads
; the file from disk and the loader's whole purpose is gone.
_TRF_SuccessfulReadIsStillCached() {
	Path := A_Temp . "\ergopti_test_toml_cached_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[s]`nk = 1`n", Path, "UTF-8")

	First := ReadTomlFile(Path)
	Assert(InStr(First, "k = 1") > 0, "the file must read back")

	; Deleting it must not change what a cached read returns.
	try FileDelete(Path)
	Second := ReadTomlFile(Path)
	Assert(Second == First,
		"a successful read must stay memoised — dropping the cache entirely would make every consumer hit the disk again")
}





; =============================================================
; =============================================================
; ======= 2/ A write never rebuilds from an unread file =======
; =============================================================
; =============================================================

; The dangerous step is not the failed read, it is the write that follows it.
; TOML_BatchWrite seeds its rewrite from ParseTomlFile and then moves the result
; over the original, so it must be able to tell "empty" from "unreadable" and
; refuse in the second case.
_TRF_BatchWriteRefusesToRewriteAnUnreadFile() {
	Body := _DriverFuncBody("TOML_BatchWrite")
	Assert(Body != "", "TOML_BatchWrite() must exist")
	Assert(InStr(Body, "ReadFailed") > 0,
		"TOML_BatchWrite must ask whether the seed parse actually read the file — it serializes only what that parse returned and then moves the result over the original, so an unreadable config would be rewritten as a one-key file")

	FailPos := InStr(Body, "ReadFailed")
	MovePos := InStr(Body, "FileMove")
	Assert(MovePos == 0 or FailPos < MovePos,
		"the refusal must come BEFORE the file is replaced")
}

; ParseTomlFile must stay non-throwing: the fuzz corpus asserts it never raises,
; so the failure has to be signalled out of band rather than by an exception.
_TRF_ParseStaysNonThrowing() {
	Body := _DriverFuncBody("ParseTomlFile")
	Assert(Body != "", "ParseTomlFile() must exist")
	Assert(InStr(Body, "catch") > 0,
		"the FileRead must be caught explicitly rather than swallowed by a bare try — a bare try discards the OSError with no log and no signal")
	Assert(InStr(Body, "LoggerError") > 0,
		"a failed read must be logged at ERROR — it was previously indistinguishable from an empty file at every level")

	Path := A_Temp . "\ergopti_test_toml_missing_" . A_TickCount . ".toml"
	try FileDelete(Path)
	Threw := false
	try ParseTomlFile(Path)
	catch
		Threw := true
	Assert(!Threw,
		"ParseTomlFile must not throw on an unreadable or missing path — tests/meta/test_corpus_toml_fuzz.ahk requires this, so the read failure has to be reported out of band")
}


Test("meta toml: a failed read is not memoised", _TRF_FailedReadIsNotCached)
Test("meta toml: a successful read is still memoised", _TRF_SuccessfulReadIsStillCached)
Test("meta toml: a write refuses to rebuild from an unread file", _TRF_BatchWriteRefusesToRewriteAnUnreadFile)
Test("meta toml: the parser stays non-throwing", _TRF_ParseStaysNonThrowing)
