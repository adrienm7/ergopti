; tests/meta/test_registry_oserror_number_not_extra.ahk

; ==============================================================================
; MODULE: Registry OSError.Number (not .Extra) Meta Test
; DESCRIPTION:
; Regression guard for a systemic bug found across five sites in
; lib/registry.ahk: each checked `e.Extra = 2` (or `!= 2 and != 3`) to
; recognise ERROR_FILE_NOT_FOUND/ERROR_PATH_NOT_FOUND from RegDelete/RegRead/
; the Reg loop directive, but the Win32 error code for these OSErrors lands
; in the `Number` property, not `Extra` -- confirmed empirically with a
; standalone probe (safe, local-only registry I/O under a throwaway HKCU test
; key, no network/installer/browser side effects): `e.Extra` is always empty
; for this OSError shape, `e.Number` holds the real code (2).
;
; Impact before the fix:
;   - Reg_DeleteValue / Reg_DeleteKey: `e.Extra = 2` never matched, so every
;     "delete an absent key" call fell through to the false/LoggerError path
;     despite the docstring's "true on success or not found" contract.
;   - Reg_KeyExists: all three `e.Extra` checks were always in their "not 2
;     and not 3" branch, so EVERY absent-key probe (the ordinary, ubiquitous
;     case of checking whether a key exists yet) logged a spurious
;     LoggerWarn "unexpected error" for what is normal, expected behavior.
;
; SCOPE: source introspection of lib/registry.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ No remaining e.Extra checks ==============
; =====================================================
; =====================================================

_RONE_NoRemainingExtraChecks() {
	Src := _DriverDirConcat("lib")
	Assert(Src != "", "lib must be readable")

	for _, FuncName in ["Reg_DeleteValue", "Reg_DeleteKey", "Reg_KeyExists"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist in lib/registry.ahk")
		Assert(InStr(Body, "e.Extra") = 0,
			FuncName . " must not check e.Extra for the Win32 error code -- OSError's Extra property is empty for RegDelete/RegRead/Reg-loop errors; the real code is in e.Number")
		if (FuncName == "Reg_KeyExists")
			Assert(InStr(Body, "Status = 2") > 0 && InStr(Body, "Status = 3") > 0,
				"Reg_KeyExists must recognise ERROR_FILE_NOT_FOUND/ERROR_PATH_NOT_FOUND from RegOpenKeyExW status")
		else
			Assert(InStr(Body, "e.Number") > 0,
				FuncName . " must check e.Number instead of e.Extra to recognise ERROR_FILE_NOT_FOUND/ERROR_PATH_NOT_FOUND")
	}
}
Test("registry: Reg_DeleteValue/Reg_DeleteKey/Reg_KeyExists check e.Number, not e.Extra (registry-oserror-number-not-extra)",
	_RONE_NoRemainingExtraChecks)
