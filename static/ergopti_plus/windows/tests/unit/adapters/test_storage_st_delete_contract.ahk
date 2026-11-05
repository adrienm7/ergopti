; tests/unit/adapters/test_storage_st_delete_contract.ahk

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

; Native fixture exclusively owns one unrelated HKCU child. Never deny or clear
; the user's Ergopti store. The pre-denial full-access handle retains WRITE_DAC.
_STEA_ActualClear(Mode) {
	global STORAGE_REG_BASE
	SavedBase := STORAGE_REG_BASE
	Subkey := "Software\Ergopti_StorageAudit_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := "HKCU\" . Subkey
	Owned := false, Handle := 0, Probe := 0, Denied := 0, ChangedAcl := false, Original := 0
	try {
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 0xF003F,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		Owned := Status == 0 && Disposition == 1
		AssertTrue(Owned, "the native key must be newly created, never an existing user's key")
		AssertTrue(Handle != 0)
		STORAGE_REG_BASE := Path
		if Mode != "empty-control" {
			AssertTrue(ST_Set("owned_marker", "keep"))
			AssertEqual("keep", ST_Get("owned_marker", "missing"))
		}
		if Mode == "denied" {
			Needed := 0
			Status := DllCall("Advapi32\RegGetKeySecurity", "Ptr", Handle, "UInt", 4,
				"Ptr", 0, "UInt*", &Needed, "UInt")
			AssertEqual(122, Status, "capture the exact original DACL size before changing anything")
			AssertTrue(Needed > 0)
			Original := Buffer(Needed, 0)
			AssertEqual(0, DllCall("Advapi32\RegGetKeySecurity", "Ptr", Handle, "UInt", 4,
				"Ptr", Original, "UInt*", &Needed, "UInt"))
			; Deny only KEY_QUERY_VALUE. Other rights stay available, including
			; the original handle's right to restore this exact descriptor.
			AssertTrue(DllCall("Advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW",
				"Str", "D:(D;;0x1;;;WD)(A;;KA;;;WD)", "UInt", 1,
				"Ptr*", &Denied, "Ptr", 0))
			AssertTrue(Denied != 0)
			Status := DllCall("Advapi32\RegSetKeySecurity", "Ptr", Handle, "UInt", 4, "Ptr", Denied, "UInt")
			ChangedAcl := Status == 0
			AssertTrue(ChangedAcl)
			Query := 0
			QueryStatus := DllCall("Advapi32\RegOpenKeyExW", "Ptr", -2147483647,
				"Str", Subkey, "UInt", 0, "UInt", 1, "Ptr*", &Query, "UInt")
			if Query
				DllCall("Advapi32\RegCloseKey", "Ptr", Query, "UInt")
			AssertEqual(5, QueryStatus, "the same private path must genuinely refuse a fresh native value query")
			AssertEqual(0, DllCall("Advapi32\RegOpenKeyExW", "Ptr", -2147483647,
				"Str", Subkey, "UInt", 0, "UInt", 8, "Ptr*", &Probe, "UInt"),
				"the key still exists and its independent subkey-list right is available")
			Name := Buffer(512, 0), NameLength := 256, ValueType := 0, DataLength := 0
			EnumStatus := DllCall("Advapi32\RegEnumValueW", "Ptr", Probe, "UInt", 0,
				"Ptr", Name, "UInt*", &NameLength, "Ptr", 0, "UInt*", &ValueType,
				"Ptr", 0, "UInt*", &DataLength, "UInt")
			AssertEqual(5, EnumStatus, "the real native value enumeration must report ERROR_ACCESS_DENIED, never ERROR_NO_MORE_ITEMS")
		}
		Result := ST_Clear()
		_TestPrint("# storage-native-enum mode=" . Mode . " clear_result=" . Result . " acl_denied=" . ChangedAcl)
		AssertEqual(Mode != "denied", Result, "the actual default Storage clear cannot acknowledge an inaccessible store as empty")
		if Mode != "denied"
			AssertFalse(ST_Has("owned_marker"), "a successful real clear must actually remove its marker")
	} finally {
		try {
			if ChangedAcl {
				AssertTrue(Original is Buffer)
				AssertEqual(0, DllCall("Advapi32\RegSetKeySecurity", "Ptr", Handle,
					"UInt", 4, "Ptr", Original, "UInt"), "restore the exact saved native DACL through the original WRITE_DAC handle")
				ChangedAcl := false
				AssertEqual("keep", ST_Get("owned_marker", "missing"), "a refused inaccessible clear preserves its actual stored value")
			}
		} finally {
			STORAGE_REG_BASE := SavedBase
			if Probe
				DllCall("Advapi32\RegCloseKey", "Ptr", Probe, "UInt")
			if Denied
				DllCall("Kernel32\LocalFree", "Ptr", Denied, "Ptr")
			try {
				if Owned && !ChangedAcl
					AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647,
						"Str", Subkey, "UInt"), "delete only the exclusively created key after its exact ACL restoration")
			} finally {
				if Handle
					DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
			}
		}
	}
}
for _STEA_Mode in ["denied", "accessible-control", "empty-control"]
	Test("storage native enumeration receipt: " . _STEA_Mode, _STEA_ActualClear.Bind(_STEA_Mode))
