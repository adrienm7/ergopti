; modules/keylogger/keylogger_sql_append.ahk

; ==============================================================================
; MODULE: Keylogger Durable SQL Append
; DESCRIPTION:
; Owns SQL file append and compensation without installing runtime hooks, so the
; same production boundary can be exercised by headless native filesystem tests.
; ==============================================================================

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
	ResolvedOpen := HasMethod(OpenFn, "Call") ? OpenFn : FileOpen
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	Fh := 0
	try {
		Fh := ResolvedOpen.Call(Path, "a", "UTF-8-RAW")
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
			if !KL_RollbackDataSqlAppend(Fh, OriginalLength, ResolvedFlush)
				throw Error("data.sql append rollback failed after: " . Err.Message)
			throw
		}
		Fh.Close()
		Fh := 0
		return true
	} finally {
		if IsObject(Fh)
			try Fh.Close()
	}
}
