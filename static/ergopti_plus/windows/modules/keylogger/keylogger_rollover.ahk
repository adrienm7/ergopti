; modules/keylogger/keylogger_rollover.ahk

; ==============================================================================
; MODULE: Keylogger Day Rollover
; DESCRIPTION: Owns journal drain, rotation and durable day checkpoint publication.
; ==============================================================================

; A malformed receipt must fence journal admission, never authorize deletion.
_KL_RolloverReceiptValid(Receipt, Offset) {
	if !(Receipt is Map) || !(Receipt.Get("version", 0) is Integer) || Receipt.Get("version", 0) != 1
		return false
	Date := Receipt.Get("date", 0)
	if !(Date is String) || !RegExMatch(Date, "^\d{4}-\d{2}-\d{2}$")
		return false
	try DateAdd(StrReplace(Date, "-"), 0, "Days")
	catch
		return false
	Snapshot := Receipt.Get("snapshot", 0)
	if !(Snapshot is Map) || !(Offset is Integer) || Offset < 0
		return false
	Present := Snapshot.Get("present", -1)
	if !(Present is Integer) || (Present != 0 && Present != 1)
		return false
	if !Present
		return Offset = 0
	for Name in ["volume", "index_high", "index_low", "write_high", "write_low"] {
		Value := Snapshot.Get(Name, -1)
		if !(Value is Integer) || Value < 0 || Value > 0xFFFFFFFF
			return false
	}
	Size := Snapshot.Get("size", -1)
	return Size is Integer && Size = Offset
}

; Preparation publishes consumption evidence before the first destructive step.
_KL_RolloverPrepare(Token, Date) {
	_KL_JournalOwnerFor().Require(Token)
	if _KL_RolloverPending()
		return false
	Reader := 0
	try {
		if !KL_CloseTodayFh(Token)
			return false
		Snapshot := Map("present", 0)
		if FileExist(Keylogger.today_log_path) {
			Reader := FileOpen(Keylogger.today_log_path, "r-w", "UTF-8")
			Snapshot := FSHandleSnapshot(Reader.Handle)
			if !Snapshot.Get("ok", false)
				throw Error("Cannot identify consumed journal.")
			Snapshot["present"] := 1
		}
		Receipt := Map("version", 1, "date", Date, "snapshot", Snapshot)
		if !_KL_RolloverReceiptValid(Receipt, Keylogger.today_log_offset)
			throw Error("Consumed checkpoint does not match rollover journal.")
		Keylogger.rollover_pending := Receipt
		if !KL_SaveState() {
			Keylogger.rollover_pending := 0
			return false
		}
		return true
	} catch as Err {
		try LoggerError("Keylogger", "Rollover preparation refused ({1}).", Type(Err))
		return false
	} finally {
		if IsObject(Reader)
			Reader.Close()
	}
}

; Called under journal ownership at startup and before a new writer is admitted.
; A missing file is recoverable only after a durable pending receipt exists.
_KL_RolloverResume(Token) {
	_KL_JournalOwnerFor().Require(Token)
	Receipt := _KL_RolloverPending()
	if !Receipt
		return true
	Reader := 0
	try {
		if !_KL_RolloverReceiptValid(Receipt, Keylogger.today_log_offset)
			throw Error("Invalid pending rollover receipt.")
		if !KL_CloseTodayFh(Token)
			return false
		if FileExist(Keylogger.today_log_path) {
			Reader := FileOpen(Keylogger.today_log_path, "r-w", "UTF-8")
			Current := FSHandleSnapshot(Reader.Handle)
			Expected := Receipt["snapshot"]
			if !Expected["present"] || !Current.Get("ok", false)
				throw Error("Pending rollover journal identity changed.")
			for Name in ["volume", "index_high", "index_low", "write_high", "write_low", "size"]
				if Current[Name] != Expected[Name]
					throw Error("Pending rollover journal identity changed.")
			FileDelete(Keylogger.today_log_path)
			Reader.Close()
			Reader := 0
		}
		OldDate := Keylogger.today_log_date
		OldOffset := Keylogger.today_log_offset
		OldContext := KLW.ctx
		OldBatch := KLW.batch
		Published := false
		try {
			Keylogger.today_log_date := Receipt["date"]
			Keylogger.today_log_offset := 0
			Keylogger.rollover_pending := 0
			KLW_DayRolloverReset()
			Published := KL_SaveState()
			return Published
		} finally {
			if !Published {
				Keylogger.today_log_date := OldDate
				Keylogger.today_log_offset := OldOffset
				Keylogger.rollover_pending := Receipt
				KLW.ctx := OldContext
				KLW.batch := OldBatch
			}
		}
	} catch as Err {
		try LoggerError("Keylogger", "Pending rollover recovery refused ({1}).", Type(Err))
		return false
	} finally {
		if IsObject(Reader)
			Reader.Close()
	}
}

KL_DayRollover(Token := 0) {
	if !Keylogger.initialized
		return Map("ok", false, "reason", "not_initialized")
	if Keylogger.rollover_in_progress
		return Map("ok", false, "reason", "already_running")
	if A_IsSuspended && !Keylogger._shutting_down
		return Map("ok", false, "reason", "suspended")
	Scope := _KL_JournalEnter(Token)
	if !IsObject(Scope)
		return Map("ok", false, "eof", false, "reason", "journal_unavailable")
	try {
	    if !Keylogger.initialized
	        return Map("ok", false, "reason", "not_initialized")
	    if Keylogger.rollover_in_progress
	        return Map("ok", false, "reason", "already_running")
	    if A_IsSuspended && !Keylogger._shutting_down
	        return Map("ok", false, "reason", "suspended")

	    Keylogger.rollover_in_progress := true
	    try {
	        old_date := Keylogger.today_log_date
	        new_date := KL_Today()
	        if (old_date = "") {
	            Keylogger.today_log_date := new_date
	            if !KL_SaveState()
	                return Map("ok", false, "reason", "state_failed")
	            return Map("ok", true, "reason", "initialised")
	        }
	        if (old_date = new_date)
	            return Map("ok", true, "reason", "already_current")

	        ; Force every bounded batch through the durable SQL + state commit.
	        ; The delete is unreachable until the reader reports EOF from a
	        ; successful ingest; a failed append/read/save leaves today.log intact.
	        loop {
	            ingest_result := KL_IngestOnce(true, true, Scope.Token)
	            if !ingest_result["ok"]
	                return Map("ok", false, "reason", ingest_result["reason"])
	            if ingest_result["eof"]
	                break
	        }

	        try FileAppend(
	            "`n-- === day rollover " . old_date . " -> " . new_date . " ===`n",
	            Keylogger.data_sql_path, "UTF-8")
	        catch as err {
	            try LoggerError("Keylogger", "Cannot write day rollover marker: {1}.",
					err.Message)
	            return Map("ok", false, "reason", "marker_failed")
	        }

	        if !_KL_RolloverPrepare(Scope.Token, new_date)
	            return Map("ok", false, "reason", "state_failed")
	        if !_KL_RolloverResume(Scope.Token)
	            return Map("ok", false, "reason", "rollover_pending")
	        return Map("ok", true, "reason", "rotated")
	    } finally {
	        Keylogger.rollover_in_progress := false
	    }
	} finally {
		_KL_JournalLeave(Scope)
	}
}
