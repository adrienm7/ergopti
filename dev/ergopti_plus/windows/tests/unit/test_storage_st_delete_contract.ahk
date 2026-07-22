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
