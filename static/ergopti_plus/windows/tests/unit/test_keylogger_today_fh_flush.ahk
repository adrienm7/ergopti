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
; Native receipt behavior is covered by test_keylogger_journal_native_write.
; These cases protect the durable flush boundary and its production callers.
; ==============================================================================

#Requires AutoHotkey v2.0

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
	Assert(InStr(Helper, "FSFlushFileBuffers(") > 0,
		"KL_FlushTodayFh must reach the OS durability boundary")

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
	Path := _FSWL_Path()
	Fh := 0
	try {
		Fh := FileOpen(Path, "a", "UTF-8-RAW")
		AssertTrue(_KL_JournalAppendDefault(Fh, '{"type":"probe"}'))
		AssertTrue(KL_FlushTodayFh(Fh))
		AssertEqual('{"type":"probe"}' . "`n", FileRead(Path, "UTF-8"))
		ClosedFile := Fh
		Fh.Close()
		Fh := 0
		AssertFalse(KL_FlushTodayFh(ClosedFile),
			"a closed native handle must not provide a durable receipt")
	} finally {
		if IsObject(Fh)
			Fh.Close()
		if FileExist(Path)
			FileDelete(Path)
	}
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
