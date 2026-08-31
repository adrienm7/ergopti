; tests/unit/test_storage_st_delete_contract.ahk

; ==============================================================================
; MODULE: Storage ST_Delete Return-Value Contract Test
; DESCRIPTION:
; ST_Delete always returned true, even when Reg_DeleteValue reported a genuine
; failure -- breaking the Storage port's own documented
; error_behavior=return_false contract and making ST_Clear's AllOk flag
; unable to ever become false. Reg_DeleteValue itself already treats a
; missing value as success (idempotent delete), so ST_Delete now simply
; propagates its real result instead of discarding it.
;
; Meta-static (scans source text): this codebase's own test_registry.ahk
; deliberately performs no registry writes so the suite stays safe on any CI
; runner (see test_reg_keyexists_value_only.ahk); this test follows the same
; convention rather than mutating the real HKCU\Software\Ergopti\Storage key.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================================
; =========================================================
; ======= 1/ ST_Delete propagates Reg_DeleteValue's result ==
; =========================================================
; =========================================================

_STDC_CheckPropagatesResult() {
	Body := _DriverFuncBody("ST_Delete")
	Assert(Body != "", "ST_Delete must exist in adapters/storage.ahk")

	Assert(InStr(Body, "return true") = 0,
		"ST_Delete must not unconditionally return true -- it must propagate Reg_DeleteValue's real result so a genuine failure (not just a missing key) can be reported, per the Storage port's error_behavior=return_false contract")
	Assert(InStr(Body, "return Reg_DeleteValue(") > 0,
		"ST_Delete must return Reg_DeleteValue's own result directly")
}
Test("storage: ST_Delete propagates Reg_DeleteValue's real result instead of hardcoding true (st-delete-return-contract)",
	_STDC_CheckPropagatesResult)





; ====================================================
; ====================================================
; ======= 2/ ST_Clear preserves enumeration errors ===
; ====================================================
; ====================================================

_STDC_EnumerationFailureFailsBeforeDelete() {
	DeleteCalls := 0
	ThrowEnumeration(*) {
		throw Error("injected registry access failure")
	}
	CountDelete(*) {
		DeleteCalls += 1
		return true
	}

	AssertEqual(false, _ST_ClearWith(ThrowEnumeration, CountDelete),
		"clear must report an enumeration failure")
	AssertEqual(0, DeleteCalls,
		"clear must not delete anything when it could not establish the complete key set")
}

_STDC_DeleteFailureIsReported() {
	DeleteCalls := 0
	Enumerate(*) {
		return [{name: "first"}, {name: "second"}]
	}
	RejectDelete(*) {
		DeleteCalls += 1
		return false
	}

	AssertEqual(false, _ST_ClearWith(Enumerate, RejectDelete),
		"clear must propagate the first registry deletion failure")
	AssertEqual(1, DeleteCalls, "clear must stop deleting after the first failure")
}

Test("storage: clear rejects registry enumeration failure before deleting anything (ahk-043)",
	_STDC_EnumerationFailureFailsBeforeDelete)
Test("storage: clear reports and stops on registry deletion failure (ahk-043)",
	_STDC_DeleteFailureIsReported)
