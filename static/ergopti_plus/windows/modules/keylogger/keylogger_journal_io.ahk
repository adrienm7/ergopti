; modules/keylogger/keylogger_journal_io.ahk

; ==============================================================================
; MODULE: Keylogger Journal File Lifecycle
; DESCRIPTION:
; Owns the persistent UTF-8 journal handle and its durable flush boundary.
; Definitions stay hook-free so native file failures can be exercised directly.
; ==============================================================================

#Include keylogger_journal.ahk

KL_OpenTodayFh(Token := 0) {
	Scope := _KL_JournalEnter(Token)
	if !IsObject(Scope)
		throw Error("Journal is busy or awaiting compensation.")
	try {
	    ; Open today.log for append with shared-read mode so a tail -f / git diff
	    ; can inspect the file without blocking us. The handle stays open until
	    ; the script exits or the day rolls over.
	    today := KL_Today()
	    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh)
	        && Keylogger._today_fh_date = today
	        return Keylogger._today_fh
	    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
	        if !KL_CloseTodayFh(Scope.Token)
	            throw Error("Cannot replace the active journal file handle.")
	    }
	    fh := FileOpen(Keylogger.today_log_path, "a", "UTF-8-RAW")
		if fh.Encoding != "UTF-8" {
			fh.Close()
			throw ValueError("Journal append requires UTF-8 encoding.")
		}
	    Keylogger._today_fh      := fh
	    Keylogger._today_fh_date := today
	    return fh
	} finally {
		_KL_JournalLeave(Scope)
	}
}

; Native writes already have checked byte receipts; flush proves durability.
KL_FlushTodayFh(fh) {
    if !IsObject(fh)
		return false
    try {
		if !FSFlushFileBuffers(fh) {
			try LoggerWarn("Keylogger", "today.log stable-storage flush failed.")
			return false
		}
		return true
	}
    catch as err {
        try LoggerWarn("Keylogger", "today.log flush failed: {1}.", err.Message)
		return false
    }
}

KL_CloseTodayFh(Token := 0) {
	Scope := _KL_JournalEnter(Token)
	if !IsObject(Scope)
		return false
	try {
	    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
			try Keylogger._today_fh.Close()
			catch as Err {
				try LoggerError("Keylogger", "Cannot close today.log: {1}.", Err.Message)
				return false
			}
	        Keylogger._today_fh := unset
	        Keylogger._today_fh_date := ""
	    }
		return true
	} finally {
		_KL_JournalLeave(Scope)
	}
}
