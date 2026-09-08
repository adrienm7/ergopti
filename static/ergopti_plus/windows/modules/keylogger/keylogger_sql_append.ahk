; modules/keylogger/keylogger_sql_append.ahk

; ==============================================================================
; MODULE: Keylogger Durable SQL Append
; DESCRIPTION:
; Owns SQL file append and compensation without installing runtime hooks, so the
; same production boundary can be exercised by headless native filesystem tests.
; ==============================================================================

global _KL_SQL_APPEND_DEBTS := Map()
global _KL_SQL_APPEND_OWNERS := Map()
global _KL_SQL_ACTIVE_APPENDS := 0

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
	global _KL_SQL_APPEND_DEBTS, _KL_SQL_APPEND_OWNERS, _KL_SQL_ACTIVE_APPENDS
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
