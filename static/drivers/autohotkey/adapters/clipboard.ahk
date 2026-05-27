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
;   read()        → CB_Read()
;   write(text)   → CB_Write(Text)
;   save()        → CB_Save()
;   restore(data) → CB_Restore(Saved)
;
; SENTINEL VALUE:
; AHK v2 has no null type. The empty string  serves as the null/empty
; sentinel throughout this adapter: CB_Read returns  for a non-text or empty
; clipboard, and CB_Restore() explicitly clears the clipboard.
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