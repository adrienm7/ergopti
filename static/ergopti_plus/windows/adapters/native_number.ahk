; adapters/native_number.ahk

; ==============================================================================
; MODULE: Native Number Classification Adapter
; DESCRIPTION:
; Keeps Windows CRT number classification at its native boundary. The caller
; owns range policy and handles native-call errors; numeric-looking strings
; are not native numbers.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Reports whether a native Integer or Float is finite without coercion.
 * @param {Number} Value Native number to classify.
 * @returns {Integer} Nonzero only for a finite native number.
 */
NativeNumberIsFinite(Value) {
	if Value is Integer
		return true
	if !(Value is Float)
		return false
	return DllCall("msvcrt\_finite", "double", Value, "cdecl int") != 0
}
