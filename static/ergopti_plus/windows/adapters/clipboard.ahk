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
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ Adapter Functions =======
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
	try {
		A_Clipboard := Text
		return true
	} catch {
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
	try {
		A_Clipboard := Saved
		return true
	} catch {
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
	try {
		A_Clipboard := Saved
		return true
	} catch {
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
