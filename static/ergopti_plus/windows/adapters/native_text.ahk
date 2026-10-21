; adapters/native_text.ahk

; ==============================================================================
; MODULE: Native Text Scan Adapter
; DESCRIPTION:
; Keeps the Windows CRT's UTF-16 code-unit scans at the native boundary. The
; caller owns the text's lifetime and the meaning of the set; these scans read
; memory only and touch no host state.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Measures the leading run of code units that belong to none of a set
 * (msvcrt wcscspn). Units are compared one by one, so a lone surrogate never
 * swallows the delimiter after it, and the scan stops at the first NUL.
 * @param {Integer} Address Address of the first UTF-16 code unit to scan.
 * @param {Buffer} Set NUL-terminated UTF-16 code units that end the run.
 * @returns {Integer} Code units before the first member of Set or NUL.
 */
NativeTextSpanExcluding(Address, Set) {
	return DllCall("msvcrt\wcscspn", "Ptr", Address, "Ptr", Set, "Cdecl UPtr")
}
