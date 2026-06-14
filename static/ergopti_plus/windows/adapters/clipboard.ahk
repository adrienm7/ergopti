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
; CB_SaveAll/CB_RestoreAll use ClipboardAll() which round-trips ALL formats
; (CF_BITMAP, CF_HDROP, HTML, RTF). Use these whenever the caller may hold
; non-text content that must survive the snapshot/restore cycle.
;
; FAIL-SAFE:
; All A_Clipboard assignments are wrapped in try/catch. Any clipboard-access
; failure (locked clipboard, restricted context) returns false rather than throwing.
; ==============================================================================



; ======================================
; ======================================
; ======= 1/ Adapter Functions =======
; ======================================
; ======================================

; Returns the current clipboard content as a plain string.
; Non-text clipboard content (images, file lists) yields  — A_Clipboard
; already coerces binary clipboard data to  automatically in AHK v2.
; @return {String} Clipboard text, or  if empty or non-text.
CB_Read() {
	try {
		return A_Clipboard
	} catch {
		return 
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
; The caller is responsible for passing the returned value to CB_Restore.
; @return {String} Current clipboard text, or  if empty or non-text.
CB_Save() {
	try {
		return A_Clipboard
	} catch {
		return 
	}
}

; Restores a previously saved clipboard snapshot.
; Passing  explicitly clears the clipboard rather than leaving stale content.
; @param Saved {String} Value previously returned by CB_Save(), or  to clear.
; @return {Boolean} True on success, false on error.
CB_Restore(Saved) {
	try {
		A_Clipboard := Saved
		return true
	} catch {
		return false
	}
}

; Snapshots ALL clipboard formats (text, images, files, RTF, HTML …) for later
; restoration. Use instead of CB_Save when the caller may hold non-text content.
; @return {ClipboardAll|String} Opaque all-formats snapshot, or "" on error.
CB_SaveAll() {
	try {
		return ClipboardAll()
	} catch {
		return ""
	}
}

; Restores a previously saved all-formats clipboard snapshot.
; Nulls Saved after assignment so AHK can free the internal buffer.
; @param Saved {ClipboardAll|String} Value previously returned by CB_SaveAll().
; @return {Boolean} True on success, false on error.
CB_RestoreAll(Saved) {
	try {
		A_Clipboard := Saved
		Saved := ""
		return true
	} catch {
		return false
	}
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
)
