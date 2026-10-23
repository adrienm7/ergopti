; adapters/clipboard.ahk

; ==============================================================================
; MODULE: Clipboard Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Clipboard port contract. Wraps the AHK v2
; built-in A_Clipboard variable behind four stable functions so domain modules
; can read, write, snapshot, and restore clipboard content without coupling to
; AHK-specific global variable syntax.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   read()            → CB_Read()
;   write(text)       → CB_Write(Text)
;   save()            → CB_Save()      — text only
;   restore(data)     → CB_Restore(Saved)
;   save_all()        → CB_SaveAll()   — all formats (ClipboardAll)
;   restore_all(data) → CB_RestoreAll(Saved)
;
; SENTINEL VALUE:
; AHK v2 has no null type. The empty string serves as the null/empty
; sentinel for the text-only pair (CB_Read/CB_Save/CB_Restore): CB_Read
; returns "" for a non-text or empty clipboard, and CB_Restore("") explicitly
; clears the clipboard.
; CB_Save uses the distinct error sentinel "__CB_SAVE_ERROR__" when the clipboard
; is locked or otherwise inaccessible, so callers can distinguish a genuine
; read failure from a legitimately empty clipboard.
; CB_SaveAll/CB_RestoreAll use ClipboardAll() which round-trips ALL formats
; (CF_BITMAP, CF_HDROP, HTML, RTF). Use these whenever the caller may hold
; non-text content that must survive the snapshot/restore cycle.
;
; FAIL-SAFE:
; All A_Clipboard assignments are wrapped in try/catch. Any clipboard-access
; failure (locked clipboard, restricted context) returns false rather than throwing.
; Bitmap files are published through CB_WriteBitmapFile(), which transfers one
; Win32 HBITMAP to the clipboard only after its caller has validated ownership.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ Ownership Registry =======
; =====================================
; =====================================

; Clipboard notifications are delivered after the assignment which caused
; them, often after the producer has already returned (and, for clipboard
; paste transports, after a deferred restore).  Keyboard synthetic markers
; therefore cannot identify this traffic.  Keep the mutation ownership at the
; clipboard boundary itself: every adapter assignment reserves one FIFO
; notification record before touching the OS, and an explicit transaction can
; keep synthetic Ctrl+V owned until its delayed restore finishes.
class CBClipboardOwner {
	static generation := 0
	static mutation_id := 0
	static active := Map()
	static pending := []
	static paste_transaction := 0
	static restore_debt := 0
	static observer_active := false
	; Test seam: production never observes the internal settlement boundary.
	static settle_hook := 0
}
global CB_RESTORE_RETRY_MS := 50
; Readers such as the Windows clipboard history open the clipboard right after
; each change. AutoHotkey's own clipboard calls wait for them up to their default
; ClipboardTimeout of one second; raw native locks wait for the same bound.
global CB_NATIVE_OPEN_TIMEOUT_MS := 1000
global CB_NATIVE_OPEN_RETRY_MS := 10

; Claims the one process-wide temporary paste slot before its caller performs
; any blocking clipboard snapshot. The returned token is also the regular
; clipboard provenance owner, so one exact identity governs admission, paste
; suppression, and terminal release.
_CB_TryBeginOwnedTransaction(Source, SuppressPaste, PreserveProvenance,
		ClaimPasteSlot) {
	if !(Source is String) or (Trim(Source) == "")
		throw ValueError("A clipboard transaction source is required.")
	PreviousCritical := Critical("On")
	try {
		if CBClipboardOwner.active.Count or CBClipboardOwner.paste_transaction
				or CBClipboardOwner.restore_debt
			return 0
		Token := ++CBClipboardOwner.generation
		CBClipboardOwner.active[Token] := Map(
			"source", Source,
			"suppress_paste", SuppressPaste ? true : false,
			"preserve_provenance", PreserveProvenance ? true : false)
		if ClaimPasteSlot
			CBClipboardOwner.paste_transaction := Token
		return Token
	} finally {
		Critical(PreviousCritical)
	}
}

CB_TryBeginPasteTransaction(Source) {
	return _CB_TryBeginOwnedTransaction(Source, true, true, true)
}

CB_IsPasteTransactionActive() {
	PreviousCritical := Critical("On")
	try {
		Token := CBClipboardOwner.paste_transaction
		if !Token
			return false
		if !CBClipboardOwner.active.Has(Token)
			throw Error("Clipboard paste transaction ownership is inconsistent.")
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; Tries to start an out-of-order-safe clipboard transaction. PreserveProvenance is
; true for temporary save/write/paste/restore dances: their intermediate
; payloads must not replace the keystats's last genuine user-copy metadata.
; SuppressPaste is restricted to transactions which inject Ctrl+V; selection
; capture and screenshots do not hide unrelated physical paste actions merely
; because they also happen to own a clipboard snapshot. All snapshot-owning
; producers share this one admission authority so no caller can snapshot a
; synthetic payload from another family and later restore it as user content.
CB_TryBeginOwnedTransaction(Source, SuppressPaste := false,
		PreserveProvenance := true) {
	return _CB_TryBeginOwnedTransaction(Source, SuppressPaste,
		PreserveProvenance, false)
}

; Releases exactly the token returned by a successful begin operation. A Map of
; live tokens, rather than a single boolean, makes nested and out-of-order
; deferred completions safe.
CB_EndOwnedTransaction(Token) {
	PreviousCritical := Critical("On")
	try {
		if !CBClipboardOwner.active.Has(Token)
			return false
		CBClipboardOwner.active.Delete(Token)
		if (CBClipboardOwner.paste_transaction == Token)
			CBClipboardOwner.paste_transaction := 0
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; Does OwnerToken still own a snapshot whose OS restore is pending? Consumers
; with their own FIFO completion delay use this to retain their exact owner
; until the clipboard lock clears.
CB_HasRestoreDebtForOwner(OwnerToken) {
	PreviousCritical := Critical("On")
	try {
		Debt := CBClipboardOwner.restore_debt
		return Debt is Map and Debt["owner_token"] == OwnerToken
	} finally {
		Critical(PreviousCritical)
	}
}

; Registers the snapshot before attempting the fallible OS assignment. A failed
; restore therefore keeps both the opaque ClipboardAll value and its exact
; transaction owner alive. New adapter mutations are refused until a retry
; succeeds or the clipboard sequence proves that a newer user copy must win.
CB_RestoreOwnedAllEventually(Saved, ExpectedSequence, OwnerToken, Source,
		ReleaseOwner := true, Force := false, RestoreFn := 0, SequenceFn := 0) {
	if !(Source is String) or Trim(Source) == ""
		throw ValueError("A clipboard restore-debt source is required.")
	if !IsObject(RestoreFn)
		RestoreFn := CB_RestoreAll
	if !IsObject(SequenceFn)
		SequenceFn := CB_GetSequenceNumber
	if (Type(Saved) == "String" and Saved == "__CB_SAVE_ERROR__") {
		if ReleaseOwner and OwnerToken
			CB_EndOwnedTransaction(OwnerToken)
		try LoggerError("Clipboard",
			"Restore debt from {1} rejected an invalid snapshot sentinel.", Source)
		return false
	}
	PreviousCritical := Critical("On")
	try {
		if CBClipboardOwner.restore_debt
			throw Error("A clipboard restore debt is already active.")
		if OwnerToken and !CBClipboardOwner.active.Has(OwnerToken)
			throw Error("Clipboard restore debt requires a live transaction owner.")
		CBClipboardOwner.restore_debt := Map(
			"saved", Saved,
			"expected_sequence", ExpectedSequence,
			"owner_token", OwnerToken,
			"source", Source,
			"release_owner", ReleaseOwner ? true : false,
			"force", Force ? true : false,
			"restore_fn", RestoreFn,
			"sequence_fn", SequenceFn,
			"attempting", false,
			"attempts", 0)
	} finally {
		Critical(PreviousCritical)
	}
	return CB_RetryRestoreDebt()
}

_CB_SettleRestoreDebt(Debt) {
	PreviousCritical := Critical("On")
	try {
		if !(CBClipboardOwner.restore_debt is Map)
			or CBClipboardOwner.restore_debt != Debt
			return false
		if Debt["release_owner"] and Debt["owner_token"] {
			OwnerToken := Debt["owner_token"]
			if !CBClipboardOwner.active.Has(OwnerToken)
				throw Error("Clipboard restore debt lost its transaction owner.")
			CBClipboardOwner.active.Delete(OwnerToken)
			if (CBClipboardOwner.paste_transaction == OwnerToken)
				CBClipboardOwner.paste_transaction := 0
		}
		CBClipboardOwner.restore_debt := 0
		try SetTimer(CB_RetryRestoreDebt, 0)
		if IsObject(CBClipboardOwner.settle_hook)
			CBClipboardOwner.settle_hook.Call()
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

; One retry attempt. The debt remains published while the OS call can yield, so
; no producer can snapshot or publish over the temporary payload meanwhile.
CB_RetryRestoreDebt(ExpectedDebt := 0, *) {
	PreviousCritical := Critical("On")
	try {
		Debt := CBClipboardOwner.restore_debt
		if !(Debt is Map)
			return true
		; New exact handoffs must not borrow a successor after Critical restores.
		; Timers and all existing callers retain the default global retry service.
		if ExpectedDebt is Map && Debt != ExpectedDebt
			return false
		NativePlain := Debt.Get("kind", "") == "plain_native"
		if !NativePlain {
			if Debt["attempting"]
				return false
			Debt["attempting"] := true
			Debt["attempts"] += 1
		}
	} finally {
		Critical(PreviousCritical)
	}
	if NativePlain
		return _CB_PlainRetryDebt(Debt)

	Settled := false
	; Critical excludes another script thread using the same native HWND. The
	; native lease excludes other processes until ClipboardAll closes its setter.
	RestoreLock := {Opened: false, Released: false, PreviousCritical: Critical("On")}
	try {
		; A same-HWND reopen is accepted by Windows, but a skipped attempt must
		; not close a lease borrowed from its caller. Only that caller may release it.
		if DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd
			return false
		try RestoreLock.Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
		catch as Err {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			try LoggerWarn("Clipboard", "Restore debt from {1} could not acquire its native lock: {2}.",
				Debt["source"], Err.Message)
			return false
		}
		if !RestoreLock.Opened {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			if (Debt["attempts"] == 1 or Mod(Debt["attempts"], 20) == 0)
				try LoggerWarn("Clipboard",
					"Restore debt from {1} is still blocked after attempt {2}; retrying.",
					Debt["source"], Debt["attempts"])
			return false
		}
		try CurrentSequence := Debt["sequence_fn"].Call()
		catch as Err {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			try LoggerWarn("Clipboard",
				"Restore debt from {1} could not read clipboard ownership: {2}.",
				Debt["source"], Err.Message)
			return false
		}
		if CBClipboardOwner.restore_debt != Debt
			return false
		; Without a recorded sequence, even the first rollback cannot prove that
		; observable clipboard content still belongs to this producer. A positive
		; sequence therefore wins before any restore attempt. The existing forced
		; zero-sequence path remains unfenced and provides no ownership guarantee.
		if (!Debt["expected_sequence"] and Debt["force"]
				and CurrentSequence) {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			try LoggerWarn("Clipboard",
				"Unfenced restore debt from {1} yielded to observable clipboard content.",
				Debt["source"])
			Settled := _CB_SettleRestoreDebt(Debt)
			return Settled
		}
		if (Debt["expected_sequence"] and CurrentSequence
				and CurrentSequence != Debt["expected_sequence"]) {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			try LoggerDebug("Clipboard",
				"Restore debt from {1} retired because a newer clipboard sequence won.",
				Debt["source"])
			Settled := _CB_SettleRestoreDebt(Debt)
			return Settled
		}
		if (Debt["expected_sequence"] and !CurrentSequence)
			return false
		if (!Debt["expected_sequence"] and !Debt["force"]) {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			Settled := _CB_SettleRestoreDebt(Debt)
			return Settled
		}
		RestoreOk := false
		try RestoreOk := Debt["restore_fn"].Call(Debt["saved"])
		catch as Err {
			if !_CB_ReleaseRestoreLock(RestoreLock)
				return false
			try LoggerWarn("Clipboard", "Restore debt from {1} threw: {2}.",
				Debt["source"], Err.Message)
		}
		if !_CB_ReleaseRestoreLock(RestoreLock)
			return false
		; Do not sample a post-setter sequence as ownership. Its internal close
		; admits later user copies, which must survive this exact debt's retirement.
		if RestoreOk {
			Settled := _CB_SettleRestoreDebt(Debt)
			return Settled
		}
		if (Debt["attempts"] == 1 or Mod(Debt["attempts"], 20) == 0)
			try LoggerWarn("Clipboard",
				"Restore debt from {1} is still blocked after attempt {2}; retrying.",
				Debt["source"], Debt["attempts"])
		return false
	} finally {
		_CB_ReleaseRestoreLock(RestoreLock)
		if !Settled {
			PreviousCritical := Critical("On")
			try {
				if (CBClipboardOwner.restore_debt is Map)
						and CBClipboardOwner.restore_debt == Debt {
					Debt["attempting"] := false
					try SetTimer(CB_RetryRestoreDebt, -CB_RESTORE_RETRY_MS)
				}
			} finally {
				Critical(PreviousCritical)
			}
		}
	}
}

; The real ClipboardAll setter closes its internal open before returning.
; Never close a later foreign process's lease, or log while our lease remains.
_CB_ReleaseRestoreLock(Lock) {
	if Lock.Released
		return true
	Critical("On")
	try {
		if Lock.Opened && DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd
			if !DllCall("User32\CloseClipboard", "Int")
				return false
		Lock.Opened := false
		Lock.Released := true
		return true
	} catch {
		return false
	} finally Critical(Lock.PreviousCritical)
}

; Binds one genuine opaque snapshot to its clipboard generation. A render or
; foreign copy during ClipboardAll is a refusal, never a reason to bless the
; older snapshot with a newer sequence. Callers may use the native paste path.
CB_SavePlainSnapshot(OwnerToken, &Capture) {
	Capture := 0
	PreviousCritical := Critical("On")
	try {
		if !OwnerToken || CBClipboardOwner.paste_transaction != OwnerToken
			|| !CBClipboardOwner.active.Has(OwnerToken) || CBClipboardOwner.restore_debt
			return false
		Before := DllCall("User32\GetClipboardSequenceNumber", "UInt")
		Mutation := CBClipboardOwner.mutation_id
		Source := CBClipboardOwner.active[OwnerToken]["source"]
	} finally Critical(PreviousCritical)
	if !Before
		return false
	Saved := CB_SaveAll()
	if Saved is String && Saved == "__CB_SAVE_ERROR__"
		return false
	PreviousCritical := Critical("On")
	try {
		if CBClipboardOwner.paste_transaction != OwnerToken || !CBClipboardOwner.active.Has(OwnerToken)
			|| CBClipboardOwner.restore_debt || CBClipboardOwner.mutation_id != Mutation
			|| DllCall("User32\GetClipboardSequenceNumber", "UInt") != Before
			return false
		Capture := Map("saved", Saved, "sequence", Before, "mutation_id", Mutation,
			"owner_token", OwnerToken, "source", Source)
		return true
	} finally Critical(PreviousCritical)
}

_CB_PlainRecordCurrent(Record) {
	return CBClipboardOwner.restore_debt == Record
		&& CBClipboardOwner.paste_transaction == Record["owner_token"]
		&& CBClipboardOwner.active.Has(Record["owner_token"])
}

; Every field used after EmptyClipboard already exists here. The one registry
; root retains the opaque snapshot and exact transaction through all failures;
; no timer closure points back at this record.
_CB_PlainRetain(Capture) {
	Record := Map("kind", "plain_native", "phase", "preparing", "saved", Capture["saved"],
		"owner_token", Capture["owner_token"], "source", Capture["source"], "release_owner", true,
		"expected_sequence", 0, "force", false, "restore_fn", CB_RestoreAll, "sequence_fn", CB_GetSequenceNumber,
		"attempting", false, "attempts", 0, "capture_sequence", Capture["sequence"],
		"capture_mutation", Capture["mutation_id"], "mutation_id", 0, "mutation_sequence", 0,
		"allocation", 0, "allocation_locked", false, "allocation_unknown", false, "expected_handle", 0, "bytes", 0,
		"changed", false, "published", false, "lease_unknown", false, "restoration_right", true,
		"auth_sequence", 0, "failure", 0, "retry_failure", 0)
	PreviousCritical := Critical("On")
	try {
		if CBClipboardOwner.restore_debt || !CBClipboardOwner.active.Has(Capture["owner_token"])
			|| CBClipboardOwner.paste_transaction != Capture["owner_token"]
			|| CBClipboardOwner.mutation_id != Capture["mutation_id"]
			return 0
		CBClipboardOwner.restore_debt := Record
		return Record
	} finally Critical(PreviousCritical)
}

_CB_PlainFailure(Record, Failure) {
	if !IsObject(Record["failure"])
		Record["failure"] := Failure
}

; This native allocation is still ours. A transferred SetClipboardData handle
; is removed from allocation before any later operation and is never freed here.
_CB_PlainFreeAllocation(Record) {
	Handle := Record["allocation"]
	if Record["allocation_unknown"]
		return false
	if !Handle
		return true
	if Record["allocation_locked"] {
		DllCall("Kernel32\SetLastError", "UInt", 0)
		Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Handle, "Int")
		NativeError := A_LastError
		if !Unlocked && NativeError
			throw OSError(NativeError, A_ThisFunc)
		Record["allocation_locked"] := false
	}
	Remaining := DllCall("Kernel32\GlobalFree", "Ptr", Handle, "Ptr")
	NativeError := A_LastError
	if Remaining
		throw OSError(NativeError, A_ThisFunc)
	Record["allocation"] := 0
	return true
}

; The return is a real unlocked publisher boundary. It restores its inherited
; Critical before authentication, allowing an external copy to win there. No
; AHK clipboard getter/setter, callback, wait or logger runs inside the lease.
_CB_PlainNativeMutationCAS(Record, Text) {
	Opened := false, PreviousCritical := 0, InCritical := false
	try {
		Record["bytes"] := (StrLen(Text) + 1) * 2
		Record["allocation"] := DllCall("Kernel32\GlobalAlloc", "UInt", 0x42,
			"UPtr", Record["bytes"], "Ptr")
		if !Record["allocation"]
			throw MemoryError("The native plain clipboard allocation failed.")
		Pointer := DllCall("Kernel32\GlobalLock", "Ptr", Record["allocation"], "Ptr")
		if !Pointer
			throw OSError(A_LastError, A_ThisFunc)
		Record["allocation_locked"] := true
		StrPut(Text, Pointer, StrLen(Text) + 1, "UTF-16")
		DllCall("Kernel32\SetLastError", "UInt", 0)
		Unlocked := DllCall("Kernel32\GlobalUnlock", "Ptr", Record["allocation"], "Int")
		NativeError := A_LastError
		if !Unlocked && NativeError
			throw OSError(NativeError, A_ThisFunc)
		Record["allocation_locked"] := false

		PreviousCritical := Critical("On"), InCritical := true
		if !_CB_PlainRecordCurrent(Record)
			return Record
		; GetOpen=0 is ambiguous with Open(NULL). The real Windows control proves
		; that a same-thread NULL borrower refuses this different HWND. A held
		; own-HWND lease is refused BEFORE Open, since same-HWND reopen succeeds.
		if DllCall("User32\GetOpenClipboardWindow", "Ptr") != 0
			return Record
		Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
		if !Opened
			return Record
		if !_CB_PlainRecordCurrent(Record) || CBClipboardOwner.mutation_id != Record["capture_mutation"]
			|| DllCall("User32\GetClipboardSequenceNumber", "UInt") != Record["capture_sequence"]
			return Record
		Record["mutation_id"] := _CB_BeginOwnedMutation()
		; A native exception with a lost return cannot turn a possibly changed
		; clipboard into an ordinary zero-sequence debt or free a transferred handle.
		Record["changed"] := true
		if !DllCall("User32\EmptyClipboard", "Int") {
			Record["changed"] := false
			_CB_CancelOwnedMutation(Record["mutation_id"])
			return Record
		}
		Record["expected_handle"] := Record["allocation"]
		Record["allocation_unknown"] := true
		Accepted := DllCall("User32\SetClipboardData", "UInt", 13,
			"Ptr", Record["allocation"], "Ptr")
		if Accepted {
			Record["allocation"] := 0
			Record["expected_handle"] := Accepted
			Record["published"] := true
		}
		Record["allocation_unknown"] := false
		Record["mutation_sequence"] := DllCall("User32\GetClipboardSequenceNumber", "UInt")
		return Record
	} catch Any as Failure {
		_CB_PlainFailure(Record, Failure)
		return Record
	} finally {
		if Opened {
			; A missing Close ACK is not permission to close a sampled later lease.
			Record["lease_unknown"] := true
			try {
				if DllCall("User32\CloseClipboard", "Int")
					Record["lease_unknown"] := false
			} catch Any as Failure {
				_CB_PlainFailure(Record, Failure)
			}
		}
		if InCritical
			Critical(PreviousCritical)
	}
}

; A successful fresh Open after GetOpen=0 witnesses that an old own-HWND lease
; ended. The entire acquisition/metadata/Close span is short Critical; failed
; acquisition never closes a NULL or foreign borrower and never sleeps here.
_CB_PlainAuthenticate(Record) {
	Opened := false, Matched := false, Closed := false
	PreviousCritical := Critical("On")
	try {
		if !_CB_PlainRecordCurrent(Record) || DllCall("User32\GetOpenClipboardWindow", "Ptr") != 0
			return false
		Opened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
		if !Opened
			return false
		Record["lease_unknown"] := true
		if !_CB_PlainRecordCurrent(Record)
			return false
		Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		if Record["changed"] && Sequence && Owner != A_ScriptHwnd
			&& Sequence != Record["capture_sequence"] {
			; Retire the restore RIGHT now, but retain this same record until
			; its NEW read lease has its own Close ACK too.
			Record["restoration_right"] := false
		} else if Record["changed"] && Sequence && Owner == A_ScriptHwnd
			&& CBClipboardOwner.mutation_id == Record["mutation_id"] {
			if Record["published"] || Record["allocation_unknown"] {
				Handle := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
				Matched := Handle && Handle == Record["expected_handle"]
					&& DllCall("Kernel32\GlobalSize", "Ptr", Handle, "UPtr") >= Record["bytes"]
				if Matched && Record["allocation_unknown"] {
					Record["allocation"] := 0
					Record["published"] := true
					Record["allocation_unknown"] := false
				}
			} else {
				; A failed Set after Empty may restore only that exact owned empty
				; generation, never an unavailable/zero-sequence publication.
				Matched := Record["mutation_sequence"] && Sequence == Record["mutation_sequence"]
					&& DllCall("User32\CountClipboardFormats", "Int") == 0
			}
			if Matched
				Record["auth_sequence"] := Sequence
		}
	} catch Any as Failure {
		_CB_PlainFailure(Record, Failure)
	} finally {
		if Opened {
			try {
				Closed := DllCall("User32\CloseClipboard", "Int") != 0
				Record["lease_unknown"] := !Closed
			} catch Any as Failure {
				_CB_PlainFailure(Record, Failure)
			}
		}
		Critical(PreviousCritical)
	}
	return Matched && Closed && _CB_PlainRecordCurrent(Record)
}

; Writes only the generation captured by CB_SavePlainSnapshot. Positive output
; keeps a ready debt through native paste and timer arming; only the exact
; delayed callback (or its failure rollback) may turn it into an ordinary debt.
CB_WritePlainSnapshot(Capture, Text, &OwnedSequence) {
	OwnedSequence := 0
	if !(Capture is Map) || !(Text is String) || Text == "" || RegExMatch(Text, "\x00")
		return false
	Record := _CB_PlainRetain(Capture)
	if !(Record is Map)
		return false
	Admitted := false
	try {
		_CB_PlainNativeMutationCAS(Record, Text)
		if Record["changed"] && Record["published"] && !Record["lease_unknown"] && !IsObject(Record["failure"])
			&& _CB_PlainAuthenticate(Record) {
			PreviousCritical := Critical("On")
			try {
				if _CB_PlainRecordCurrent(Record) && Record["restoration_right"] && Record["auth_sequence"] {
					Record["phase"] := "ready"
					OwnedSequence := Record["auth_sequence"]
					Admitted := true
				}
			} finally Critical(PreviousCritical)
		}
		if IsObject(Record["failure"])
			throw Record["failure"]
		return Admitted
	} catch Any as Failure {
		_CB_PlainFailure(Record, Failure)
		throw Failure
	} finally {
		if !Admitted {
			Record["phase"] := "recover"
			_CB_PlainRetryDebt(Record)
		}
	}
}

; Native unknown debt must never fall through to the ordinary expected=0
; policy, which legitimately discards an unowned legacy snapshot. A single
; global retry function avoids record/timer bound-function retention cycles.
_CB_PlainRetryDebt(Record) {
	PreviousCritical := Critical("On")
	try {
		if !_CB_PlainRecordCurrent(Record)
			return true
		if Record["phase"] == "preparing" || Record["phase"] == "ready" || Record["attempting"]
			return false
		Record["attempting"] := true
		Record["attempts"] += 1
	} finally Critical(PreviousCritical)
	Settled := false, Ordinary := false
	try {
		if Record["lease_unknown"] || (Record["changed"] && Record["restoration_right"])
			_CB_PlainAuthenticate(Record)
		if !_CB_PlainRecordCurrent(Record)
			return true
		if Record["lease_unknown"]
			return false
		if !_CB_PlainFreeAllocation(Record)
			return false
		if !Record["changed"] || !Record["restoration_right"] {
			Settled := _CB_SettleRestoreDebt(Record)
			return Settled
		}
		if !Record["auth_sequence"]
			return false
		PreviousCritical := Critical("On")
		try {
			if !_CB_PlainRecordCurrent(Record)
				return true
			Record["expected_sequence"] := Record["auth_sequence"]
			Record["kind"] := "restore"
			Record["attempting"] := false
			Ordinary := true
		} finally Critical(PreviousCritical)
		return CB_RetryRestoreDebt(Record)
	} catch Any as Failure {
		_CB_PlainFailure(Record, Failure)
		throw Record["failure"]
	} finally {
		PreviousCritical := Critical("On")
		try {
			if !Settled && !Ordinary && CBClipboardOwner.restore_debt == Record {
				Record["attempting"] := false
				try SetTimer(CB_RetryRestoreDebt, -CB_RESTORE_RETRY_MS)
				catch Any as Failure {
					Record["retry_failure"] := Failure
					_CB_PlainFailure(Record, Failure)
					throw Record["failure"]
				}
			}
		} finally Critical(PreviousCritical)
	}
}

CB_RestorePlainSnapshotEventually(Saved, ExpectedSequence, OwnerToken, Source) {
	PreviousCritical := Critical("On")
	try {
		Record := CBClipboardOwner.restore_debt
		if !(Record is Map) || Record["owner_token"] != OwnerToken
			|| Record["saved"] != Saved || !_CB_PlainRecordCurrent(Record)
			return false
		if Record.Get("kind", "") == "plain_native" {
			if Record["phase"] != "ready" || !ExpectedSequence || Record["auth_sequence"] != ExpectedSequence
				return false
			Record["expected_sequence"] := ExpectedSequence
			Record["kind"] := "restore"
		}
	} finally Critical(PreviousCritical)
	return CB_RetryRestoreDebt(Record)
}

; Mutators call this before taking a new snapshot or publishing content. It
; gives an existing debt one immediate chance, then refuses the new mutation if
; the old user clipboard still cannot be restored.
_CB_ResolveRestoreDebtBeforeMutation() {
	if !(CBClipboardOwner.restore_debt is Map)
		return true
	CB_RetryRestoreDebt()
	return !(CBClipboardOwner.restore_debt is Map)
}

; OnExit calls this before its irreversible boundary. A still-locked clipboard
; is a refusal, because exiting would destroy the only ClipboardAll snapshot.
CB_PrepareShutdown() {
	CB_RetryRestoreDebt()
	PreviousCritical := Critical("On")
	try {
		return !(CBClipboardOwner.restore_debt is Map)
			&& !CBClipboardOwner.paste_transaction
			&& (CBClipboardOwner.active.Count == 0)
	} finally {
		Critical(PreviousCritical)
	}
}

; True only while a clipboard transaction which actually emits Ctrl+V is live.
; The keystats's pass-through hotkey uses this to discard the driver's paste
; without silencing physical pastes during non-paste clipboard jobs.
CB_IsDriverPasteActive() {
	PreviousCritical := Critical("On")
	try {
		for _, Owner in CBClipboardOwner.active {
			if Owner["suppress_paste"]
				return true
		}
		return false
	} finally {
		Critical(PreviousCritical)
	}
}

; Reserve before A_Clipboard is assigned, so even a callback which becomes
; runnable during the OS operation already has an ownership record to consume.
_CB_BeginOwnedMutation() {
	PreviousCritical := Critical("On")
	try {
		PreserveProvenance := CBClipboardOwner.active.Count > 0
		for _, Owner in CBClipboardOwner.active {
			if !Owner["preserve_provenance"] {
				PreserveProvenance := false
				break
			}
		}
		MutationId := ++CBClipboardOwner.mutation_id
		if CBClipboardOwner.observer_active
			CBClipboardOwner.pending.Push(Map(
				"id", MutationId,
				"kind", PreserveProvenance ? "temporary" : "replace"))
		return MutationId
	} finally {
		Critical(PreviousCritical)
	}
}

; Reserves the next notification for a clipboard write performed by another
; process at the driver's request (Ctrl+C selection capture, Snipping Tool).
; The caller owns the returned id and must cancel it if the external producer
; never changes the clipboard.
CB_ExpectOwnedChange() {
	return _CB_BeginOwnedMutation()
}

CB_CancelExpectedChange(MutationId) {
	_CB_CancelOwnedMutation(MutationId)
}

_CB_CancelOwnedMutation(MutationId) {
	PreviousCritical := Critical("On")
	try {
		for Index, Mutation in CBClipboardOwner.pending {
			if (Mutation["id"] == MutationId) {
				CBClipboardOwner.pending.RemoveAt(Index)
				return
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
}

; Consumes one Windows clipboard notification in mutation order.  Returns a
; String classification for driver traffic and false for a genuine user
; change; callers must type-check because AHK v2 considers the String "0"
; equal to false.
CB_ConsumeOwnedChange() {
	PreviousCritical := Critical("On")
	try {
		if !CBClipboardOwner.pending.Length
			return false
		Mutation := CBClipboardOwner.pending.RemoveAt(1)
		return Mutation["kind"]
	} finally {
		Critical(PreviousCritical)
	}
}

; Drop notifications which predate observer registration.  Active transaction
; tokens deliberately survive: a deferred restore still owns its synthetic
; paste even if the keystats observer is restarted in the middle.
CB_DiscardOwnedNotifications() {
	PreviousCritical := Critical("On")
	try CBClipboardOwner.pending := []
	finally Critical(PreviousCritical)
}

; Clipboard mutation receipts exist only for the keystats observer. When that
; optional consumer is stopped, retaining one record per adapter assignment
; would grow a FIFO which no callback can ever drain.
CB_SetOwnershipObserverActive(Active) {
	PreviousCritical := Critical("On")
	try {
		CBClipboardOwner.pending := []
		CBClipboardOwner.observer_active := Active ? true : false
	} finally {
		Critical(PreviousCritical)
	}
	return true
}





; ====================================
; ====================================
; ======= 2/ Adapter Functions =======
; ====================================
; ====================================

; Returns the current clipboard content as a plain string.
; Non-text clipboard content (images, file lists) yields "" — A_Clipboard
; already coerces binary clipboard data to "" automatically in AHK v2.
; @return {String} Clipboard text, or "" if empty or non-text.
CB_Read() {
	try {
		return A_Clipboard
	} catch {
		return ""
	}
}

; Writes Text to the clipboard, replacing any previous content.
; @param Text {String} The text to place on the clipboard.
; @return {Boolean} True on success, false on error.
CB_Write(Text) {
	if !_CB_ResolveRestoreDebtBeforeMutation()
		return false
	MutationId := _CB_BeginOwnedMutation()
	try {
		A_Clipboard := Text
		return true
	} catch {
		_CB_CancelOwnedMutation(MutationId)
		return false
	}
}

; Windows-only publication receipt; the shared write port remains Boolean-only.
; A successful setter may already have been replaced when it returns. Authenticate
; this exact mutation under a new native read lease before lending its sequence.
; Empty/truncated text, native failures and lost ownership have no receipt; the
; Boolean still reports the genuine setter result, never a promise of rollback.
CB_WriteTextWithReceipt(Text, &OwnedSequence := 0) {
	OwnedSequence := 0
	PreviousCritical := Critical("On")
	try BeforeMutation := CBClipboardOwner.mutation_id
	finally Critical(PreviousCritical)
	Published := CB_Write(Text)
	if !Published
		return false
	Length := StrLen(Text)
	if !Length
		return true
	Opened := false
	try {
		Opened := CB_OpenClipboardWithin(A_ScriptHwnd)
		if !Opened || DllCall("User32\GetClipboardOwner", "Ptr") != A_ScriptHwnd
			return true
		Data := DllCall("User32\GetClipboardData", "UInt", 13, "Ptr")
		if !Data || DllCall("Kernel32\GlobalSize", "Ptr", Data, "UPtr") < (Length + 1) * 2
			return true
		Pointer := DllCall("Kernel32\GlobalLock", "Ptr", Data, "Ptr")
		if !Pointer
			return true
		try {
			; An AHK reader may close the raw lease without changing the mutation.
			; These HWND-only queries cannot render data; acquisition stays outside
			; Critical. Refuse the lost lease before touching its retained pointer.
			PreviousCritical := Critical("On")
			try {
				Matches := CBClipboardOwner.mutation_id == BeforeMutation + 1
					&& DllCall("User32\GetOpenClipboardWindow", "Ptr") == A_ScriptHwnd
					&& DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd
					&& NumGet(Pointer, Length * 2, "UShort") == 0
					&& StrLen(StrGet(Pointer, Length, "UTF-16")) == Length
					&& StrGet(Pointer, -Length, "UTF-16") == Text
			} finally Critical(PreviousCritical)
		} finally DllCall("Kernel32\GlobalUnlock", "Ptr", Data)
		if !Matches
			return true
		Sequence := CB_GetSequenceNumber()
		if !Sequence || DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd
				|| DllCall("User32\GetClipboardOwner", "Ptr") != A_ScriptHwnd
			return true
		; Only RAM is inspected in this transaction. The still-open native lease
		; excludes external writes; an extra driver mutation also invalidates it.
		PreviousCritical := Critical("On")
		try {
			if CBClipboardOwner.mutation_id == BeforeMutation + 1
				OwnedSequence := Sequence
		} finally Critical(PreviousCritical)
	} catch {
		OwnedSequence := 0
	} finally {
		if Opened {
			try {
				if DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd
						|| !DllCall("User32\CloseClipboard", "Int")
					OwnedSequence := 0
			} catch {
				OwnedSequence := 0
			}
		}
	}
	return true
}

; Snapshots the current clipboard and returns it for later restoration.
; Returns "__CB_SAVE_ERROR__" when the clipboard is locked so callers can
; distinguish a read failure from a legitimately empty clipboard.
; The caller is responsible for passing the returned value to CB_Restore.
; @return {String} Current clipboard text, "" if empty/non-text, or "__CB_SAVE_ERROR__" on failure.
CB_Save() {
	try {
		return A_Clipboard
	} catch as Err {
		try LoggerWarn("Clipboard", "CB_Save failed: {1}.", Err.Message)
		return "__CB_SAVE_ERROR__"
	}
}

; Restores a previously saved clipboard snapshot.
; Skips the restore when Saved is the error sentinel "__CB_SAVE_ERROR__" so a
; failed CB_Save never overwrites the clipboard with a garbage value.
; Passing "" explicitly clears the clipboard rather than leaving stale content.
; @param Saved {String} Value previously returned by CB_Save(), or "" to clear.
; @return {Boolean} True on success, false on error or when Saved is the error sentinel.
CB_Restore(Saved) {
	if (Saved == "__CB_SAVE_ERROR__")
		return false
	MutationId := _CB_BeginOwnedMutation()
	try {
		A_Clipboard := Saved
		return true
	} catch {
		_CB_CancelOwnedMutation(MutationId)
		return false
	}
}

; Snapshots ALL clipboard formats (text, images, files, RTF, HTML …) for later
; restoration. Use instead of CB_Save when the caller may hold non-text content.
; Returns "__CB_SAVE_ERROR__" when the clipboard is locked so callers (and
; CB_RestoreAll) can distinguish a read failure from a legitimately empty
; clipboard — same sentinel contract as CB_Save.
; @return {ClipboardAll|String} Opaque all-formats snapshot, or "__CB_SAVE_ERROR__" on failure.
CB_SaveAll() {
	if !_CB_ResolveRestoreDebtBeforeMutation() {
		try LoggerWarn("Clipboard",
			"CB_SaveAll refused while an earlier clipboard restore remains blocked.")
		return "__CB_SAVE_ERROR__"
	}
	try {
		return ClipboardAll()
	} catch as Err {
		try LoggerWarn("Clipboard", "CB_SaveAll failed: {1} (holder: {2}).",
			RTrim(Err.Message, "."), CB_DescribeClipboardHolder()["summary"])
		return "__CB_SAVE_ERROR__"
	}
}

; Identifies who holds the native clipboard lock, for failure logs and notices.
; GetOpenClipboardWindow is 0 both when the lock is free again and when it was
; opened without a window (OpenClipboard(NULL)), which names no process; the
; summary says so instead of guessing. GetClipboardOwner is the window whose
; data the clipboard currently holds, which may differ from the lock holder.
; Windows-local diagnostics: not part of the cross-driver Clipboard port.
; @return {Map} hwnd, pid, process ("" when unknown), own, owner_process, summary.
CB_DescribeClipboardHolder() {
	Hwnd := DllCall("User32\GetOpenClipboardWindow", "Ptr")
	Holder := _CB_DescribeClipboardWindow(Hwnd)
	Owner := _CB_DescribeClipboardWindow(DllCall("User32\GetClipboardOwner", "Ptr"))
	if !Hwnd
		Summary := "no window holds the lock (released since, or opened without a window)"
	else
		Summary := Format("hwnd=0x{:X} pid={} process={} own_process={}", Hwnd,
			Holder["pid"], Holder["label"], Holder["own"] ? "yes" : "no")
	Summary .= "; data owner " . Owner["label"]
	return Map("hwnd", Hwnd, "pid", Holder["pid"], "process", Holder["process"],
		"own", Holder["own"], "owner_process", Owner["process"], "summary", Summary)
}

_CB_DescribeClipboardWindow(Hwnd) {
	Pid := 0, ProcName := "", Label := "none"
	if Hwnd {
		DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &Pid)
		if Pid {
			try {
				ProcName := ProcessGetName(Pid)
				Label := ProcName
			} catch as Err {
				Label := "pid " . Pid . " (name unavailable: " . RTrim(Err.Message, ".") . ")"
			}
		} else {
			Label := "unknown (window gone)"
		}
	}
	return Map("pid", Pid, "process", ProcName, "label", Label,
		"own", Pid != 0 && Pid == DllCall("Kernel32\GetCurrentProcessId", "UInt"))
}

; Restores a previously saved all-formats clipboard snapshot.
; Skips the restore when Saved is the error sentinel "__CB_SAVE_ERROR__" so a
; failed CB_SaveAll never wipes the clipboard (a bare A_Clipboard := "" would
; be indistinguishable from "clipboard was legitimately empty").
; @param Saved {ClipboardAll|String} Value previously returned by CB_SaveAll().
; @return {Boolean} True on success, false on error or when Saved is the error sentinel.
CB_RestoreAll(Saved) {
	if (Type(Saved) == "String" and Saved == "__CB_SAVE_ERROR__") {
		try LoggerWarn("Clipboard", "CB_RestoreAll: skipping restore — Saved is the __CB_SAVE_ERROR__ sentinel from a failed CB_SaveAll.")
		return false
	}
	MutationId := _CB_BeginOwnedMutation()
	try {
		A_Clipboard := Saved
		return true
	} catch {
		_CB_CancelOwnedMutation(MutationId)
		return false
	}
}

; Returns the Win32 clipboard change sequence. Consumers use it as an ownership
; fence: a delayed restore must not overwrite content copied by the user after
; the transaction released the clipboard. Zero is an unavailable/error sentinel.
CB_GetSequenceNumber() {
	try return DllCall("GetClipboardSequenceNumber", "UInt")
	return 0
}

; True only when a bitmap/DIB clipboard format is available. This is deliberately
; kept in the Clipboard adapter: a domain feature must not make raw Win32 calls
; merely to distinguish a screenshot from a later text copy.
CB_HasImage() {
	try return DllCall("IsClipboardFormatAvailable", "UInt", 2)
		|| DllCall("IsClipboardFormatAvailable", "UInt", 8)
		|| DllCall("IsClipboardFormatAvailable", "UInt", 17)
	return false
}

; Publishes a staged BMP file as CF_BITMAP. Screenshot workers write only the
; private file; the owning AHK generation calls this function after completion,
; so a canceled or orphaned child process cannot mutate the clipboard by itself.
; The HBITMAP ownership transfers to Windows only when SetClipboardData succeeds.
; CloseClipboard materializes synthesized DIB formats, so the optional receipt
; authenticates the exact publication under a new read lock after that close.
; A sequence sampled after return cannot establish ownership.
CB_WriteBitmapFile(Path, &MutationSequence := 0, AdmissionFn := 0) {
	MutationSequence := 0
	if !_CB_ResolveRestoreDebtBeforeMutation()
		return false
	BitmapHandle := 0
	try {
		if !(AdmissionFn is Integer && AdmissionFn == 0) && !HasMethod(AdmissionFn, "Call")
			throw TypeError("Bitmap admission must be a callable or Integer0.")
		; Load before final admission and keep file I/O outside the short claim.
		; CF_BITMAP needs a DDB usable by another process, without LR_CREATEDIBSECTION.
		BitmapHandle := DllCall("User32\LoadImageW", "Ptr", 0, "Str", Path,
			"UInt", 0, "Int", 0, "Int", 0, "UInt", 0x10, "Ptr")
		if !BitmapHandle
			throw Error("LoadImageW could not load the staged bitmap")
		return _CB_PublishLoadedBitmap(&BitmapHandle, &MutationSequence, AdmissionFn)
	} catch as Err {
		if BitmapHandle {
			try DllCall("Gdi32\DeleteObject", "Ptr", BitmapHandle)
			BitmapHandle := 0
		}
		; The native helper has closed its lock and restored Critical before logging.
		try LoggerError("Clipboard", "CB_WriteBitmapFile failed for '{1}': {2}.", Path, Err.Message)
		return false
	} finally {
		if BitmapHandle
			try DllCall("Gdi32\DeleteObject", "Ptr", BitmapHandle)
	}
}

; Admission is a pure, zero-argument predicate. Only Integer1 authorizes the
; mutation; its callback cannot yield to UI or perform clipboard/file I/O.
; The caller still owns the loaded bitmap until SetClipboardData transfers it.
_CB_PublishLoadedBitmap(&BitmapHandle, &MutationSequence, AdmissionFn) {
	PreviousCritical := Critical("On")
	ClipboardOpened := false, ClipboardMutated := false
	MutationId := 0, TransferredBitmap := 0
	try {
		ClipboardOpened := CB_OpenClipboardWithin(A_ScriptHwnd)
		if !ClipboardOpened
			throw Error("OpenClipboard failed")
		if HasMethod(AdmissionFn, "Call") {
			Admitted := AdmissionFn.Call()
			if !(Admitted is Integer && Admitted == 1)
				return false
		}
		; Reserve only after the loaded bitmap, native lock and caller admission
		; are current. Refusal must never consume a foreign clipboard notification.
		MutationId := _CB_BeginOwnedMutation()
		if !DllCall("User32\EmptyClipboard", "Int")
			throw Error("EmptyClipboard failed")
		ClipboardMutated := true
		TransferredBitmap := DllCall("User32\SetClipboardData", "UInt", 2, "Ptr", BitmapHandle, "Ptr")
		if !TransferredBitmap
			throw Error("SetClipboardData(CF_BITMAP) failed")
		BitmapHandle := 0
		return true
	} catch as Err {
		if MutationId && !ClipboardMutated
			_CB_CancelOwnedMutation(MutationId)
		throw Err
	} finally {
		if ClipboardOpened
			MutationSequence := _CB_CloseBitmapPublication(&ClipboardOpened, ClipboardMutated, TransferredBitmap)
		Critical(PreviousCritical)
	}
}

; Windows synthesizes CF_DIB/CF_DIBV5 when a CF_BITMAP publication closes. Only
; a reopened lock and the exact native owner/bitmap can authenticate its final
; sequence. Critical excludes same-HWND AHK writes across the close/reopen gap;
; another process may win that gap, in which case no receipt is returned.
_CB_CloseBitmapPublication(&ClipboardOpened, ClipboardMutated, TransferredBitmap) {
	PreviousCritical := Critical("On")
	try {
		if !DllCall("User32\CloseClipboard", "Int")
			return 0
		ClipboardOpened := false
		if !ClipboardMutated
			return 0
		; Readers notified by the close race this reopen; the owner check below
		; still refuses a receipt if another process replaced the content meanwhile.
		ClipboardOpened := CB_OpenClipboardWithin(A_ScriptHwnd)
		if !ClipboardOpened || DllCall("User32\GetClipboardOwner", "Ptr") != A_ScriptHwnd
			return 0
		if TransferredBitmap {
			if DllCall("User32\GetClipboardData", "UInt", 2, "Ptr") != TransferredBitmap
				return 0
		} else {
			; EmptyClipboard succeeded but SetClipboardData failed. The local bitmap
			; never transferred, so only our still-empty clipboard can be owned.
			DllCall("Kernel32\SetLastError", "UInt", 0)
			FormatCount := DllCall("User32\CountClipboardFormats", "Int")
			if FormatCount != 0 || A_LastError != 0
				return 0
		}
		Sequence := CB_GetSequenceNumber()
		if !DllCall("User32\CloseClipboard", "Int")
			return 0
		ClipboardOpened := false
		return Sequence
	} catch {
		return 0
	} finally {
		if ClipboardOpened
			try DllCall("User32\CloseClipboard", "Int")
		ClipboardOpened := false
		Critical(PreviousCritical)
	}
}

; True when another process currently holds the clipboard open, i.e. reading or
; writing it now would contend with that process.
;
; OpenClipboard is the only honest test for this: it returns 0 immediately when
; someone else owns the handle, it does NOT wait. GetClipboardSequenceNumber
; cannot answer the question at all — it is a monotonic counter of past changes
; and says nothing about the current owner.
;
; The probe closes the clipboard again straight away when it succeeds. Leaving it
; open would make THIS process the blocker, which is the exact failure the probe
; exists to avoid.
CB_IsBusy() {
	Opened := 0
	try Opened := DllCall("User32\OpenClipboard", "Ptr", 0, "Int")
	catch
		return true
	if !Opened
		return true
	try DllCall("User32\CloseClipboard")
	return false
}

; Opens the native clipboard lock for Hwnd, waiting up to CB_NATIVE_OPEN_TIMEOUT_MS
; while another process holds it. A single attempt loses to the readers that open
; the clipboard just after every change, which is exactly when callers need it.
; @param {Integer} Hwnd The window that will own the lock.
; @param {Func} OnRefused Optional; called once, at the first refused attempt.
; @returns {Boolean} True once the lock is held; false when the bound expired.
CB_OpenClipboardWithin(Hwnd, OnRefused := 0) {
	global CB_NATIVE_OPEN_TIMEOUT_MS, CB_NATIVE_OPEN_RETRY_MS
	Started := A_TickCount
	Refused := false
	Loop {
		if DllCall("User32\OpenClipboard", "Ptr", Hwnd, "Int")
			return true
		if !Refused {
			Refused := true
			if HasMethod(OnRefused, "Call")
				OnRefused.Call()
		}
		if TickElapsed(Started) >= CB_NATIVE_OPEN_TIMEOUT_MS
			return false
		Sleep(CB_NATIVE_OPEN_RETRY_MS)
	}
}


; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_CLIPBOARD := Map(
    "read",        CB_Read,
    "write",       CB_Write,
    "save",        CB_Save,
    "restore",     CB_Restore,
    "save_all",    CB_SaveAll,
    "restore_all", CB_RestoreAll,
	"sequence_number", CB_GetSequenceNumber,
	"has_image", CB_HasImage,
)
; CB_IsBusy is deliberately absent from the contract map above. That map declares
; the CROSS-DRIVER Clipboard port, and every name in it must exist in
; _shared/core/ports/Clipboard.spec.js — adding one here would oblige the macOS
; adapter to implement a contention probe that only the Windows Critical path
; needs. It stays a Windows-local helper: still in the adapter, because a domain
; module must not make raw Win32 calls itself, just not part of the port.
