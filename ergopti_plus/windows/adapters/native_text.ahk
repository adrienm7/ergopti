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

/**
 * Measures the leading run of code units that all belong to a set (msvcrt
 * wcsspn). Units are compared one by one and the scan stops at the first NUL.
 * @param {Integer} Address Address of the first UTF-16 code unit to scan.
 * @param {Buffer} Set NUL-terminated UTF-16 code units the run is made of.
 * @returns {Integer} Code units before the first unit outside Set or NUL.
 */
NativeTextSpanIncluding(Address, Set) {
	return DllCall("msvcrt\wcsspn", "Ptr", Address, "Ptr", Set, "Cdecl UPtr")
}

/**
 * Reports whether UTF-16 text is well formed: every surrogate code unit is
 * half of a high-then-low pair. One strict conversion measures the text
 * (WideCharToMultiByte with WC_ERR_INVALID_CHARS), writing nothing.
 * @param {Integer} Address Address of the first UTF-16 code unit.
 * @param {Integer} Length Number of code units; embedded NULs are text.
 * @returns {Boolean} True when the text holds no lone surrogate.
 */
NativeTextIsWellFormedUtf16(Address, Length) {
	if (Length <= 0)
		return true
	return DllCall("Kernel32\WideCharToMultiByte", "UInt", 65001, "UInt", 0x80,
		"Ptr", Address, "Int", Length, "Ptr", 0, "Int", 0, "Ptr", 0, "Ptr", 0, "Int") > 0
}
