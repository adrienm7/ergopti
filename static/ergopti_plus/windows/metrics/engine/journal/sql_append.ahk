; metrics/engine/journal/sql_append.ahk

; ==============================================================================
; MODULE: Keystats Durable SQL Append
; DESCRIPTION:
; Owns SQL file append and compensation without installing runtime hooks, so the
; same production boundary can be exercised by headless native filesystem tests.
; ==============================================================================

global _KL_SQL_APPEND_DEBTS := Map()
global _KL_SQL_APPEND_OWNERS := Map()
global _KL_SQL_ACTIVE_APPENDS := 0
global _KL_SQL_APPEND_RECEIPTS := Map()

; The durable boundary of the last acknowledged append to Path: the file's
; identity and its length. state.json stores it beside the journal offset, so
; the two describe one instant, and an empty answer means none is known.
KL_DataSqlAckReceipt(Path) {
	global _KL_SQL_APPEND_RECEIPTS
	return _KL_SQL_APPEND_RECEIPTS.Get(StrLower(Path), 0)
}

_KL_DataSqlReceiptValid(Receipt) {
	if !(Receipt is Map)
		return false
	for Name in ["volume", "index_high", "index_low", "end"]
		if !(Receipt.Get(Name, -1) is Integer) || Receipt.Get(Name, -1) < 0
			return false
	return true
}

; A process that dies inside an append leaves bytes past the last boundary
; state.json acknowledged. They can stop inside a literal, and everything
; appended behind them would then read as that literal's text while its journal
; offset is acknowledged. Those bytes are unacknowledged by construction: the
; journal offset beside the receipt still covers them, so ingest writes them
; again. Reading only the receipt keeps this O(1) on any ledger size; the
; lexical frontier would need the whole history. A file with another identity
; is a ledger the receipt never described (a migration published it, a backup
; restored it) and its bytes are not ours to cut.
; @returns {Integer} The discarded byte count.
KL_DataSqlRepairTail(Path, Receipt, FlushFn := 0) {
	Fh := FileOpen(Path, "a-w", "UTF-8-RAW")
	if !IsObject(Fh)
		throw Error("data.sql could not be opened for tail repair")
	try {
		if !(Receipt is Map)
			return 0
		Snapshot := FSHandleSnapshot(Fh.Handle)
		if !Snapshot.Get("ok", false)
			throw Error("data.sql identity is unavailable")
		for Name in ["volume", "index_high", "index_low"]
			if Snapshot[Name] != Receipt[Name]
				return 0
		Excess := Fh.Length - Receipt["end"]
		if Excess <= 0 {
			if Excess
				try LoggerWarn("Keystats",
					"data.sql is {1} byte(s) shorter than its last acknowledged append.", -Excess)
			return 0
		}
		if !KL_RollbackDataSqlAppend(Fh, Receipt["end"], FlushFn)
			throw Error("data.sql tail repair could not cut the unacknowledged bytes")
		return Excess
	} finally {
		Fh.Close()
	}
}

; Boot admission of a ledger that already exists: it must be writable, and it
; must end at the boundary the loaded state acknowledged.
KL_AdmitExistingDataSql() {
	try {
		Discarded := KL_DataSqlRepairTail(Keystats.data_sql_path, Keystats.data_sql_receipt)
		if Discarded
			try LoggerWarn("Keystats",
				"Discarded {1} byte(s) of an interrupted data.sql append; the journal replays them.",
				Discarded)
		return true
	} catch as Err {
		try LoggerError("Keystats", "data.sql is not writable: {1}.", Err.Message)
		return false
	}
}

; A failed compensation retains the native writer, not just its pathname. A
; replacement file must never inherit a truncate boundary from the old owner.
_KL_RepairDataSqlAppend(Path, FlushFn := 0) {
	global _KL_SQL_APPEND_DEBTS
	Key := StrLower(Path)
	PreviousCritical := Critical("On")
	try {
		if !_KL_SQL_APPEND_DEBTS.Has(Key)
			return true
		Debt := _KL_SQL_APPEND_DEBTS[Key]
		if Debt.Repairing
			return false
		Debt.Repairing := true
	} finally {
		Critical(PreviousCritical)
	}
	RepairCritical := Critical("Off")
	try {
		if !KL_RollbackDataSqlAppend(Debt.File, Debt.Boundary, FlushFn)
			return false
		Debt.File.Close()
		PreviousCritical := Critical("On")
		try _KL_SQL_APPEND_DEBTS.Delete(Key)
		finally Critical(PreviousCritical)
		return true
	} finally {
		Debt.Repairing := false
		Critical(RepairCritical)
	}
}

; Shutdown must repair even when no new SQL batch is waiting. Claim the entire
; finite pass so reentrant shutdown cannot acknowledge a half-repaired file.
KL_DataSqlShutdownReady() {
	global _KL_SQL_APPEND_DEBTS, _KL_SQL_ACTIVE_APPENDS
	PreviousCritical := Critical("On")
	try {
		if _KL_SQL_ACTIVE_APPENDS
			return false
		Paths := []
		for Path in _KL_SQL_APPEND_DEBTS
			Paths.Push(Path)
		_KL_SQL_ACTIVE_APPENDS += 1
	} finally {
		Critical(PreviousCritical)
	}
	try {
		for Path in Paths {
			if !_KL_RepairDataSqlAppend(Path)
				return false
		}
		return _KL_SQL_APPEND_DEBTS.Count = 0
	} finally {
		PreviousCritical := Critical("On")
		try _KL_SQL_ACTIVE_APPENDS -= 1
		finally Critical(PreviousCritical)
	}
}

; Appends one complete SQL batch and does not acknowledge it until both the
; native write and the Windows cache have crossed the stable-storage boundary.
; The offset checkpoint is published only after this receipt, so a hard power
; fault can leave either a replayable old offset or a durable transaction, but
; never a durable checkpoint that skips missing SQL bytes.
KL_RollbackDataSqlAppend(Fh, OriginalLength, FlushFn := 0) {
	if !IsObject(Fh) || !IsInteger(OriginalLength) || OriginalLength < 0
		return false
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	try {
		; Rewind the same native owner and retract its unacknowledged prefix.
		Handle := Fh.Handle
		NewPosition := 0
		if !DllCall("kernel32\SetFilePointerEx", "Ptr", Handle,
			"Int64", OriginalLength, "Int64*", &NewPosition, "UInt", 0, "Int")
			return false
		if (NewPosition != OriginalLength)
			return false
		if !DllCall("kernel32\SetEndOfFile", "Ptr", Handle, "Int")
			return false
		return ResolvedFlush.Call(Fh) == true
	} catch {
		return false
	}
}

KL_AppendDataSqlDurable(Path, Body, OpenFn := 0, FlushFn := 0, WriteFn := 0) {
	global _KL_SQL_APPEND_DEBTS, _KL_SQL_APPEND_OWNERS, _KL_SQL_ACTIVE_APPENDS, _KL_SQL_APPEND_RECEIPTS
	ResolvedOpen := HasMethod(OpenFn, "Call") ? OpenFn : FileOpen
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	Fh := 0
	Key := StrLower(Path)
	PreviousCritical := Critical("On")
	try {
		; Native sharing protects file identity; this lease also protects a path
		; replaced while its original writer still owns unpublished compensation.
		if _KL_SQL_APPEND_OWNERS.Has(Key)
			throw Error("data.sql append already has an active owner")
		_KL_SQL_APPEND_OWNERS[Key] := true
		_KL_SQL_ACTIVE_APPENDS += 1
	} finally {
		Critical(PreviousCritical)
	}
	try {
		if !_KL_RepairDataSqlAppend(Path, ResolvedFlush)
			throw Error("data.sql append repair is still pending")
		; Compensation must never retract a competing writer's acknowledged bytes
		Fh := ResolvedOpen.Call(Path, "a-w", "UTF-8-RAW")
		if !IsObject(Fh)
			throw Error("data.sql could not be opened for append")
		OriginalLength := Fh.Length
		try {
			; A new-file BOM belongs to this same checked write and rollback, not
			; an implicit FileOpen buffer whose failed flush could be ignored.
			Payload := (OriginalLength = 0 ? Chr(0xFEFF) : "") . Body
			if !_FSWriteUtf8Bytes(Fh, Payload, WriteFn)
				throw Error("data.sql append was incomplete")
			if (ResolvedFlush.Call(Fh) != true)
				throw Error("data.sql stable-storage flush failed")
		} catch as Err {
			if !KL_RollbackDataSqlAppend(Fh, OriginalLength, ResolvedFlush) {
				PreviousCritical := Critical("On")
				try {
					_KL_SQL_APPEND_DEBTS[Key] := {
						File: Fh, Boundary: OriginalLength, Repairing: false}
					Fh := 0
				} finally {
					Critical(PreviousCritical)
				}
				throw Error("data.sql append rollback failed after: " . Err.Message)
			}
			throw
		}
		Snapshot := FSHandleSnapshot(Fh.Handle)
		_KL_SQL_APPEND_RECEIPTS[Key] := !Snapshot.Get("ok", false) ? 0 : Map(
			"volume", Snapshot["volume"], "index_high", Snapshot["index_high"],
			"index_low", Snapshot["index_low"], "end", Fh.Length)
		Fh.Close()
		Fh := 0
		return true
	} finally {
		if IsObject(Fh)
			try Fh.Close()
		PreviousCritical := Critical("On")
		try {
			_KL_SQL_APPEND_OWNERS.Delete(Key)
			_KL_SQL_ACTIVE_APPENDS -= 1
		} finally {
			Critical(PreviousCritical)
		}
	}
}
