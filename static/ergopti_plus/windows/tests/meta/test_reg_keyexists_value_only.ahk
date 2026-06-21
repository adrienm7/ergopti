; tests/meta/test_reg_keyexists_value_only.ahk

; ==============================================================================
; MODULE: Reg_KeyExists Value-Only Key Meta Test
; DESCRIPTION:
; Static source guard for the reg-keyexists-false-negative-value-only-key
; finding.
;
; The original Reg_KeyExists() proved existence by (a) enumerating sub-keys
; and, if none, (b) reading the (Default) value. A key that holds only named
; values (no sub-keys, no (Default) value) is a valid existing key - the
; common case for an app settings key - yet the default-value probe throws
; FILE_NOT_FOUND on it, so the function wrongly reported the key absent.
;
; The fix enumerates VALUES (Loop Reg, keyPath, "V") between the sub-key probe
; and the default-value fallback, so existence no longer hinges on a (Default)
; value being set. This guard asserts that value enumeration is present in the
; Reg_KeyExists body.
;
; This is a meta-static test (scans source text) rather than a behavioral one:
; the repo's test_registry.ahk deliberately performs no registry writes so the
; suite stays safe on any CI runner, and exercising this fix behaviorally would
; require creating and deleting a real HKCU key. Asserting the V enumeration is
; present in the source captures the root cause without OS-mutating side effects.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_RKVO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ====================================================
; ====================================================
; ======= 2/ Value-enumeration guard assertion =======
; ====================================================
; ====================================================

_RKVO_KeyExistsEnumeratesValues() {
	Src := _RKVO_ReadSource("lib/registry.ahk")
	Seg := _DriverFuncBody("Reg_KeyExists")
	Assert(Seg != "", "Reg_KeyExists(keyPath) declaration must exist in lib/registry.ahk")
	; The fix iterates named values so a value-only key (no sub-keys, no
	; (Default) value) is reported as existing. Both forms of the directive are
	; accepted to stay robust to quote style.
	DoubleQuoted := InStr(Seg, "Loop Reg, keyPath, " . Chr(34) . "V" . Chr(34)) > 0
	SingleQuoted := InStr(Seg, "Loop Reg, keyPath, 'V'") > 0
	HasValueLoop := DoubleQuoted or SingleQuoted
	Assert(HasValueLoop,
		"Reg_KeyExists must enumerate values (Loop Reg, keyPath, V) - otherwise a key with only named values and no (Default) value is wrongly reported absent")
}
Test("registry: Reg_KeyExists enumerates values for value-only keys (reg-keyexists-false-negative-value-only-key)", _RKVO_KeyExistsEnumeratesValues)
