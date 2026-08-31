; tests/unit/test_keylogger_today_fh_flush.ahk

; ==============================================================================
; MODULE: today.log Flush Regression (keylogger-today-fh-flush-is-a-no-op)
; DESCRIPTION:
; AHK v2's File object has no Flush() method. Both keylogger call sites called
; fh.Flush() inside a bare try, so the MethodError was discarded with no log
; line and the writer's buffer was never pushed to the OS. The line right after
; one of them read new_offset := fh.Pos, and KL_SaveState persisted that as
; today_log_offset -- so the durable bookmark routinely named bytes that existed
; only inside this process. The ingest reader opens its own handle and could not
; see the tail it had just claimed to consume, and any exit that skips
; KL_CloseTodayFh (hard crash, power loss, taskkill, #SingleInstance
; replacement) lost that tail while state.json recorded it as ingested.
;
; ROOT CAUSE ENCODED: the flush primitive must actually move bytes to disk, and
; the driver must use that primitive at every site instead of a method that does
; not exist.
;
; The behavioural half proves the primitive; the source half proves the driver
; uses it. It has to be split that way because the headless harness does not
; load modules/keylogger/keylogger.ahk (it registers live hooks at load), so
; KL_FlushTodayFh cannot be called from here -- naming it in a call would be a
; load-time "nonexistent function" error for the whole suite.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ The primitive really flushes =======
; ===============================================
; ===============================================

_KLTF_HandleReadFlushesTheWriteBuffer() {
	Path := A_Temp . "\ergopti_flush_probe_" . A_TickCount . ".log"
	try FileDelete(Path)

	Fh := FileOpen(Path, "a", "UTF-8")
	Assert(IsObject(Fh), "the probe file must open for append")
	try {
		Loop 200
			Fh.Write("line-" . A_Index . "-padpadpadpadpadpadpadpad`n")

		; The premise: there is nothing to call. A driver-side fh.Flush() raises
		; 'This value of type "File" has no method named "Flush".' and a bare try
		; turns that into a silent no-op.
		Assert(!HasMethod(Fh, "Flush"),
			"AHK v2's File object exposes no Flush() -- any fh.Flush() in the driver is a "
			. "swallowed MethodError, never a flush")

		; Without this, the test could not observe the defect it guards: fh.Pos
		; must genuinely run ahead of the file for the flush to be meaningful.
		Assert(Fh.Pos > FileGetSize(Path),
			"the probe must actually buffer -- fh.Pos must run ahead of the on-disk size "
			. "before the flush, otherwise this test proves nothing")

		; The idiom KL_FlushTodayFh uses: reading Handle forces AHK to commit its
		; own buffer before it can hand out the raw OS handle.
		_ := Fh.Handle

		Assert(FileGetSize(Path) = Fh.Pos,
			"after reading Handle the on-disk size must equal fh.Pos -- today_log_offset is "
			. "persisted FROM fh.Pos, so a shorter file means the committed offset names a "
			. "byte that exists only in this process")

		Reader := FileOpen(Path, "r", "UTF-8")
		try {
			Assert(Reader.Length = Fh.Pos,
				"and an independent reader handle -- exactly what KL_ReadNewTodayLog opens -- "
				. "must see every byte the writer accounted for")
		} finally {
			Reader.Close()
		}
	} finally {
		Fh.Close()
		try FileDelete(Path)
	}
}

Test("keylogger: reading File.Handle is what actually flushes the today.log writer (keylogger-today-fh-flush-is-a-no-op)",
	_KLTF_HandleReadFlushesTheWriteBuffer)





; =================================================
; =================================================
; ======= 2/ The driver uses that primitive =======
; =================================================
; =================================================

; Class-wide, not site-wide: no file under modules/keylogger may call a method
; that does not exist, whichever site a future edit adds it to.
_KLTF_NoFileFlushCallsRemain() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	Assert(Src != "", "the keylogger module source must be locatable")
	Assert(InStr(Src, ".Flush()") = 0,
		"no File.Flush() call may remain under modules/keylogger -- the method does not exist "
		. "in AHK v2, so every such call is a MethodError the surrounding bare try discards, "
		. "leaving the write buffer unflushed while fh.Pos is committed as today_log_offset")
	Assert(InStr(Src, "RawWriteFlush") = 0,
		"the RawWriteFlush marker assignment must go too -- it is a throw-and-swallow on a "
		. "property the File object does not have either")
}

; Both producers of a today_log_offset must flush through the same helper, so a
; future edit cannot fix one site and leave the other counting buffered bytes.
_KLTF_BothOffsetSitesFlushThroughTheHelper() {
	Helper := _DriverFuncBody("KL_FlushTodayFh")
	Assert(Helper != "",
		"KL_FlushTodayFh must exist -- one shared implementation is what stops the two call "
		. "sites diverging again")
	Assert(InStr(Helper, ".Handle") > 0,
		"KL_FlushTodayFh must read the Handle property to expose AHK's buffered bytes before the stable-storage flush")

	Reader := _DriverFuncBody("KL_ReadNewTodayLog")
	Assert(InStr(Reader, "KL_FlushTodayFh(") > 0,
		"KL_ReadNewTodayLog must flush the writer through KL_FlushTodayFh before opening its "
		. "own handle -- a second handle can only ever see what the OS actually holds")

	Ingest := _DriverFuncBody("KL_IngestOnce")
	PosAt := InStr(Ingest, "new_offset := fh.Pos")
	Assert(PosAt > 0,
		"prerequisite: KL_IngestOnce still publishes the append handle's position as the "
		. "commit point")
	Assert(InStr(SubStr(Ingest, 1, PosAt), "KL_FlushTodayFh(") > 0,
		"KL_IngestOnce must flush BEFORE reading fh.Pos -- the position it commits as "
		. "today_log_offset must never name a byte that is still only in the write buffer")
}

Test("keylogger: no File.Flush() call survives under modules/keylogger (keylogger-today-fh-flush-is-a-no-op)",
	_KLTF_NoFileFlushCallsRemain)
Test("keylogger: both today_log_offset producers flush through KL_FlushTodayFh (keylogger-today-fh-flush-is-a-no-op)",
	_KLTF_BothOffsetSitesFlushThroughTheHelper)


_KLTF_FlushBoundaryReachesStableStorage() {
	Helper := _DriverFuncBody("KL_FlushTodayFh")
	Assert(Helper != "", "KL_FlushTodayFh must exist")
	HandlePos := InStr(Helper, ".Handle")
	StablePos := InStr(Helper, "FSFlushFileBuffers", true, HandlePos)
	Assert(HandlePos > 0 && StablePos > HandlePos,
		"the keylogger handoff must first expose AHK's write buffer, then require the real FlushFileBuffers result before releasing RAM ownership")
}
Test("keylogger: journal ownership requires stable storage (AHK-062)",
	_KLTF_FlushBoundaryReachesStableStorage)

_KLTF_DataSqlDurabilityPrecedesCheckpoint() {
	Helper := _DriverFuncBody("KL_AppendDataSqlDurable")
	Assert(Helper != "",
		"data.sql needs an owned append helper with a stable-storage receipt")
	Assert(InStr(Helper, "FSFlushFileBuffers") > 0,
		"the data.sql append must reach FlushFileBuffers before reporting success")
	Assert(InStr(Helper, "OriginalLength := Fh.Length") > 0,
		"the append must capture its rollback boundary before writing any SQL bytes")
	RollbackPos := InStr(Helper, "KL_RollbackDataSqlAppend(")
	ShortWritePos := InStr(Helper, "data.sql append was incomplete")
	StableFailurePos := InStr(Helper, "data.sql stable-storage flush failed")
	Assert(RollbackPos > ShortWritePos && RollbackPos > StableFailurePos,
		"short writes and failed stable-storage receipts must both truncate data.sql back to its pre-append boundary before the batch can be retried")

	Rollback := _DriverFuncBody("KL_RollbackDataSqlAppend")
	Assert(InStr(Rollback, "SetEndOfFile") > 0,
		"rollback must truncate the partial append instead of merely moving the file pointer")
	Assert(InStr(Rollback, "FSFlushFileBuffers") > 0,
		"the restored length must itself cross the stable-storage boundary before retry ownership returns")

	Ingest := _DriverFuncBody("KL_IngestOnce")
	AppendPos := InStr(Ingest, "KL_AppendDataSqlDurable(")
	CheckpointPos := InStr(Ingest, "old_offset := Keylogger.today_log_offset",
		true, AppendPos)
	Assert(AppendPos > 0 && CheckpointPos > AppendPos,
		"the durable data.sql receipt must precede every offset checkpoint")
}

Test("keylogger: failed durable appends restore their original boundary before retry (AHK-075)",
	_KLTF_DataSqlDurabilityPrecedesCheckpoint)
