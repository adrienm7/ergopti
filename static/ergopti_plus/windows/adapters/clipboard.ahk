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
}

; Claims the one process-wide temporary paste slot before its caller performs
; any blocking clipboard snapshot. The returned token is also the regular
; clipboard provenance owner, so one exact identity governs admission, paste
; suppression, and terminal release.
CB_TryBeginPasteTransaction(Source) {
	if !(Source is String) or (Trim(Source) == "")
		throw ValueError("A clipboard paste transaction source is required.")
	PreviousCritical := Critical("On")
	try {
		if CBClipboardOwner.paste_transaction
			return 0
		Token := ++CBClipboardOwner.generation
		CBClipboardOwner.active[Token] := Map(
			"source", Source,
			"suppress_paste", true,
			"preserve_provenance", true)
		CBClipboardOwner.paste_transaction := Token
		return Token
	} finally {
		Critical(PreviousCritical)
	}
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

; Starts an out-of-order-safe clipboard transaction.  PreserveProvenance is
; true for temporary save/write/paste/restore dances: their intermediate
; payloads must not replace the keylogger's last genuine user-copy metadata.
; SuppressPaste is restricted to transactions which inject Ctrl+V; selection
; capture and screenshots do not hide unrelated physical paste actions merely
; because they also happen to own a clipboard snapshot.
CB_BeginOwnedTransaction(Source := "", SuppressPaste := false, PreserveProvenance := true) {
	PreviousCritical := Critical("On")
	try {
		Token := ++CBClipboardOwner.generation
		CBClipboardOwner.active[Token] := Map(
			"source", Source,
			"suppress_paste", SuppressPaste ? true : false,
			"preserve_provenance", PreserveProvenance ? true : false)
		return Token
	} finally {
		Critical(PreviousCritical)
	}
}

; Releases exactly the token returned by CB_BeginOwnedTransaction.  A Map of
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

; True only while a clipboard transaction which actually emits Ctrl+V is live.
; The keylogger's pass-through hotkey uses this to discard the driver's paste
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
; paste even if the keylogger observer is restarted in the middle.
CB_DiscardOwnedNotifications() {
	PreviousCritical := Critical("On")
	try CBClipboardOwner.pending := []
	finally Critical(PreviousCritical)
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
	MutationId := _CB_BeginOwnedMutation()
	try {
		A_Clipboard := Text
		return true
	} catch {
		_CB_CancelOwnedMutation(MutationId)
		return false
	}
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
	try {
		return ClipboardAll()
	} catch as Err {
		try LoggerWarn("Clipboard", "CB_SaveAll failed: {1}.", Err.Message)
		return "__CB_SAVE_ERROR__"
	}
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
CB_WriteBitmapFile(Path) {
	static IMAGE_BITMAP := 0
	static CF_BITMAP := 2
	static LR_LOADFROMFILE := 0x10
	static LR_CREATEDIBSECTION := 0x2000
	MutationId := 0
	BitmapHandle := 0
	ClipboardOpened := false
	ClipboardMutated := false
	try {
		BitmapHandle := DllCall("User32\LoadImageW", "Ptr", 0, "Str", Path,
			"UInt", IMAGE_BITMAP, "Int", 0, "Int", 0,
			"UInt", LR_LOADFROMFILE | LR_CREATEDIBSECTION, "Ptr")
		if !BitmapHandle
			throw Error("LoadImageW could not load the staged bitmap")
		ClipboardOpened := DllCall("User32\OpenClipboard", "Ptr", A_ScriptHwnd, "Int") != 0
		if !ClipboardOpened
			throw Error("OpenClipboard failed")
		; No clipboard notification can be ours until the file is loaded and the
		; clipboard lock is held. Reserving earlier could consume an unrelated user
		; copy while LoadImageW or OpenClipboard was still in progress.
		MutationId := _CB_BeginOwnedMutation()
		if !DllCall("User32\EmptyClipboard", "Int")
			throw Error("EmptyClipboard failed")
		ClipboardMutated := true
		if !DllCall("User32\SetClipboardData", "UInt", CF_BITMAP, "Ptr", BitmapHandle, "Ptr")
			throw Error("SetClipboardData(CF_BITMAP) failed")
		BitmapHandle := 0
		return true
	} catch as Err {
		; EmptyClipboard itself emits the owned notification. Cancel the reservation
		; only when the clipboard never changed, otherwise the observer must consume it.
		if MutationId && !ClipboardMutated
			_CB_CancelOwnedMutation(MutationId)
		; Release the global clipboard lock before file-backed logging can yield.
		if ClipboardOpened {
			try DllCall("User32\CloseClipboard")
			ClipboardOpened := false
		}
		if BitmapHandle {
			try DllCall("Gdi32\DeleteObject", "Ptr", BitmapHandle)
			BitmapHandle := 0
		}
		try LoggerError("Clipboard", "CB_WriteBitmapFile failed for '{1}': {2}.", Path, Err.Message)
		return false
	} finally {
		if ClipboardOpened
			try DllCall("User32\CloseClipboard")
		if BitmapHandle
			try DllCall("Gdi32\DeleteObject", "Ptr", BitmapHandle)
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


; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
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
