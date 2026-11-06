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
	Owned := false, Handle := 0, Probe := 0, Denied := 0, ChangedAcl := false, Original := 0, LongName := ""
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
		if Mode == "long-name-control" {
			LongName := "long_"
			loop 600
				LongName .= "x"
			AssertTrue(ST_Set(LongName, "long-value"))
			Found := 0
			for Name in ST_Keys()
				if Name == LongName
					Found += 1
			AssertEqual(1, Found, "a name larger than the initial native buffer must retain its exact identity")
		}
		if Mode == "absent-control" {
			AssertEqual(0, DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt"))
			Handle := 0
			AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647, "Str", Subkey, "UInt"))
			Owned := false
			AbsentHandle := 0
			AbsentStatus := DllCall("Advapi32\RegOpenKeyExW", "Ptr", -2147483647,
				"Str", Subkey, "UInt", 0, "UInt", 1, "Ptr*", &AbsentHandle, "UInt")
			if AbsentHandle
				DllCall("Advapi32\RegCloseKey", "Ptr", AbsentHandle, "UInt")
			AssertEqual(2, AbsentStatus, "the native positive control must be genuinely absent, not inaccessible")
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
			AssertEqual(0, ST_Keys().Length, "public keys keeps its legacy empty-on-error behavior")
		}
		Result := ST_Clear()
		_TestPrint("# storage-native-enum mode=" . Mode . " clear_result=" . Result . " acl_denied=" . ChangedAcl)
		AssertEqual(Mode != "denied", Result, "the actual default Storage clear cannot acknowledge an inaccessible store as empty")
		if Mode != "denied"
			AssertFalse(ST_Has("owned_marker"), "a successful real clear must actually remove its marker")
		if LongName != ""
			AssertFalse(ST_Has(LongName), "the complete native inventory must also delete the full long name")
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
for _STEA_Mode in ["denied", "accessible-control", "empty-control", "absent-control", "long-name-control"]
	Test("storage native enumeration receipt: " . _STEA_Mode, _STEA_ActualClear.Bind(_STEA_Mode))

_STNN_ActualName(Mode) {
	global STORAGE_REG_BASE
	SavedBase := STORAGE_REG_BASE
	Subkey := "Software\Ergopti_StorageNameAudit_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := "HKCU\" . Subkey, Owned := false, Handle := 0
	Payload := JsonParse('{"name":"owned\u0000foreign"}')
	Name := Payload["name"]
	AssertEqual(13, StrLen(Name), "the name is a real JSON String value with complete native UTF-16 metadata")
	AssertEqual(0, NumGet(StrPtr(Name), 10, "UShort"))
	AssertEqual(Ord("f"), NumGet(StrPtr(Name), 12, "UShort"))
	try {
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 0xF003F,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		Owned := Status == 0 && Disposition == 1
		AssertTrue(Owned, "only a genuinely new unrelated HKCU child may become the private storage fixture")
		AssertTrue(Handle != 0)
		STORAGE_REG_BASE := Path
		AssertTrue(ST_Set("owned", "Original"))
		AssertEqual("Original", ST_Get("owned", "missing"), "the distinct short native neighbor must really exist before the operation")
		Result := "unset", Roundtrip := "unused", Present := "unused"
		switch Mode {
			case "set":
				Result := ST_Set(Name, "Edited")
				Roundtrip := ST_Get(Name, "missing")
			case "get": Result := ST_Get(Name, "missing")
			case "has": Result := ST_Has(Name)
			case "delete": Result := ST_Delete(Name)
			case "unicode-control", "default-control", "integer-key-control", "float-key-control":
				Name := Mode == "unicode-control" ? "é😀" : Mode == "integer-key-control" ? 17 : Mode == "float-key-control" ? 0.125 : ""
				Result := ST_Set(Name, "Independent")
				Roundtrip := ST_Get(Name, "missing")
				Present := ST_Has(Name)
		}
		if Mode == "integer-key-control" || Mode == "float-key-control"
			AssertTrue(Name is Number, "the genuine native call receives the legacy numeric key type")
		ActualNeighbor := ST_Get("owned", "missing")
		_TestPrint("# storage-native-name mode=" . Mode . " disposition=" . Disposition
			. " requested_units=" . StrLen(Name) . " result=" . Result
			. " neighbor=" . ActualNeighbor . " roundtrip=" . Roundtrip . " present=" . Present)
		AssertEqual("Original", ActualNeighbor, "an unsupported full name cannot mutate or delete the distinct shorter native neighbor")
		switch Mode {
			case "set":
				AssertTrue((Result is Integer) && (Result == 0 || Result == 1))
				if Result == 1
					AssertEqual("Edited", Roundtrip, "a backend may ACK a fully encoded distinct name only when that full logical name roundtrips")
			case "get": AssertEqual("missing", Result, "the uncreated logical name must not read the existing shorter neighbor")
			case "has": AssertFalse(Result, "the uncreated logical name must not borrow another native value's membership")
			case "delete":
				AssertTrue((Result is Integer) && (Result == 0 || Result == 1), "refusal or a safe idempotent delete is allowed, never deletion of another name")
			case "unicode-control", "default-control", "integer-key-control", "float-key-control":
				AssertTrue(Result)
				AssertEqual("Independent", Roundtrip)
				AssertTrue(Present)
		}
	} finally {
		STORAGE_REG_BASE := SavedBase
		try {
			if Owned
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647,
					"Str", Subkey, "UInt"), "delete only this exclusively created native child")
		} finally {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
		}
	}
}
for _STNN_Mode in ["set", "get", "has", "delete", "unicode-control", "default-control"]
	Test("storage native name identity: " . _STNN_Mode . " (storage-native-name-nul)", _STNN_ActualName.Bind(_STNN_Mode))

for _STNC_Mode in ["integer-key-control", "float-key-control"]
	Test("storage native name legacy coercion: " . _STNC_Mode . " (storage-native-name-coercion)", _STNN_ActualName.Bind(_STNC_Mode))

_STSP_FloatBits(Value) {
	if !(Value is Float)
		return "<" . Type(Value) . ">"
	Bytes := Buffer(8)
	NumPut("Double", Value, Bytes)
	return Format("{:016x}", NumGet(Bytes, 0, "Int64"))
}

_STSP_ActualPayload(Mode, FloatShape := "") {
	global STORAGE_REG_BASE
	SavedBase := STORAGE_REG_BASE
	Subkey := "Software\Ergopti_StorageScalarAudit_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := "HKCU\" . Subkey, Owned := false, Handle := 0
	if Mode == "float-wide" || Mode == "float-exact-control" || Mode == "float-digits-control" {
		Requested := JsonParse(Mode == "float-wide" ? '{"value":0.30000000000000004}' : Mode == "float-digits-control" ? '{"value":1.2345678901234567}' : '{"value":42.5}')["value"]
		AssertTrue(Requested is Float)
		AssertEqual(Mode == "float-wide" ? "3fd3333333333334" : Mode == "float-digits-control" ? "3ff3c0ca428c59fb" : "4045400000000000", _STSP_FloatBits(Requested),
			"the genuine JSON producer must first retain the independent expected binary64 value")
	} else {
		Payload := JsonParse('{"value":"A\u0000B"}')
		Scalar := Payload["value"]
		AssertEqual(3, StrLen(Scalar))
		AssertEqual(0, NumGet(StrPtr(Scalar), 2, "UShort"))
		AssertEqual(66, NumGet(StrPtr(Scalar), 4, "UShort"))
		Requested := Mode == "nul-map-control" ? Payload : Scalar
	}
	if FloatShape != "" {
		AssertTrue(FloatShape == "map" || FloatShape == "array")
		AssertTrue(Requested is Float)
		ExpectedFloat := Requested
		Requested := FloatShape == "map" ? Map("value", Requested) : [Requested]
	}
	try {
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 0xF003F,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		Owned := Status == 0 && Disposition == 1
		AssertTrue(Owned)
		AssertTrue(Handle != 0)
		STORAGE_REG_BASE := Path
		AssertTrue(ST_Set("payload", "Original"))
		AssertEqual("Original", ST_Get("payload", "missing"))
		Result := ST_Set("payload", Requested)
		Actual := ST_Get("payload", "missing")
		Observed := Mode == "nul-map-control" && (Actual is Map) && Actual.Has("value") ? Actual["value"] : Actual
		if FloatShape == "map" && (Actual is Map) && Actual.Has("value")
			Observed := Actual["value"]
		else if FloatShape == "array" && (Actual is Array) && Actual.Length == 1
			Observed := Actual[1]
		_TestPrint("# storage-scalar-persistence mode=" . Mode . " float_shape=" . FloatShape . " disposition=" . Disposition . " result=" . Result
			. " actual_type=" . Type(Actual) . " actual_float_bits=" . _STSP_FloatBits(Observed)
			. " actual_string_units=" . (Observed is String ? StrLen(Observed) : -1))
		if Mode == "float-wide" || Mode == "float-exact-control" || Mode == "float-digits-control" {
			AssertTrue(Result)
			if FloatShape == "map"
				AssertTrue(Actual is Map)
			else if FloatShape == "array"
				AssertTrue(Actual is Array)
			AssertTrue(Observed is Float)
			AssertEqual(_STSP_FloatBits(FloatShape != "" ? ExpectedFloat : Requested), _STSP_FloatBits(Observed),
				"a successful persistent numeric value must retain every original binary64 bit")
		} else if Result {
			if Mode == "nul-map-control"
				AssertTrue(Actual is Map, "the ordinary JSON envelope remains a genuine supported nested-value control")
			AssertTrue(Observed is String)
			AssertEqual(3, StrLen(Observed), "a successful persisted String must retain its original complete native units")
			AssertEqual(65, NumGet(StrPtr(Observed), 0, "UShort"))
			AssertEqual(0, NumGet(StrPtr(Observed), 2, "UShort"))
			AssertEqual(66, NumGet(StrPtr(Observed), 4, "UShort"))
		} else {
			AssertTrue(Mode == "nul-string", "the genuinely supported JSON-map control must not be refused")
			AssertEqual("Original", Actual, "an unsupported scalar must refuse without replacing its original value")
		}
	} finally {
		STORAGE_REG_BASE := SavedBase
		try {
			if Owned
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647, "Str", Subkey, "UInt"))
		} finally {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
		}
	}
}
for _STSP_Mode in ["float-wide", "float-exact-control", "nul-string", "nul-map-control"]
	Test("storage scalar persistence: " . _STSP_Mode . " (storage-native-scalar-persistence)", _STSP_ActualPayload.Bind(_STSP_Mode))

_STNT_NativeValueCount(Handle) {
	Status := DllCall("Advapi32\RegQueryInfoKeyW", "Ptr", Handle,
		"Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0,
		"UInt*", &Count := 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt")
	if Status != 0
		throw OSError(Status, "private native registry value-count query")
	return Count
}

_STNT_ClearCountedName(CountedNul) {
	global STORAGE_REG_BASE, STORAGE_VALUE_PREFIX
	SavedBase := STORAGE_REG_BASE
	Subkey := "Software\Ergopti_StorageCountedAudit_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := "HKCU\" . Subkey, Handle := 0, Owned := false
	Name := JsonParse(CountedNul ? '{"name":"owned\u0000foreign"}' : '{"name":"owned_foreign"}')["name"]
	AssertEqual(13, StrLen(Name))
	NameBytes := Buffer((StrLen(Name) + 1) * 2, 0)
	DllCall("ntdll\RtlMoveMemory", "Ptr", NameBytes, "Ptr", StrPtr(Name), "UPtr", StrLen(Name) * 2)
	if CountedNul {
		AssertEqual(0, NumGet(NameBytes, 10, "UShort"))
		AssertEqual(Ord("f"), NumGet(NameBytes, 12, "UShort"))
	}
	try {
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 0xF003F,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		Owned := Status == 0 && Disposition == 1
		AssertTrue(Owned)
		AssertTrue(Handle != 0)
		STORAGE_REG_BASE := Path
		AssertTrue(ST_Set("owned", "Original"))
		Value := STORAGE_VALUE_PREFIX . "s:Distinct"
		ValueBytes := Buffer(StrPut(Value, "UTF-16") * 2, 0)
		StrPut(Value, ValueBytes, "UTF-16")
		UnicodeName := Buffer(2 * A_PtrSize, 0)
		NumPut("UShort", StrLen(Name) * 2, "UShort", NameBytes.Size, UnicodeName)
		NumPut("Ptr", NameBytes.Ptr, UnicodeName, A_PtrSize)
		NtStatus := DllCall("ntdll\NtSetValueKey", "Ptr", Handle, "Ptr", UnicodeName,
			"UInt", 0, "UInt", 1, "Ptr", ValueBytes, "UInt", ValueBytes.Size, "UInt")
		_TestPrint("# storage-counted-name setup counted_nul=" . CountedNul . " nt_status=" . Format("0x{:08X}", NtStatus))
		AssertEqual(0, NtStatus, "the actual NT counted-name producer must successfully create this distinct private native value")
		BeforeCount := _STNT_NativeValueCount(Handle)
		AssertEqual(2, BeforeCount)
		AssertEqual("Original", ST_Get("owned", "missing"), "the counted-name producer must not have overwritten its distinct short neighbor")
		FullNativeNames := 0
		loop BeforeCount {
			Characters := 64, RawName := Buffer(Characters * 2, 0)
			EnumStatus := DllCall("Advapi32\RegEnumValueW", "Ptr", Handle, "UInt", A_Index - 1,
				"Ptr", RawName, "UInt*", &Characters, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt")
			AssertEqual(0, EnumStatus)
			if Characters == StrLen(Name) && DllCall("ntdll\RtlCompareMemory", "Ptr", RawName,
					"Ptr", NameBytes, "UPtr", Characters * 2, "UPtr") == Characters * 2
				FullNativeNames += 1
		}
		AssertEqual(1, FullNativeNames, "the actual Win32 inventory must retain all counted UTF-16 units before any String conversion")
		Result := ST_Clear()
		AfterCount := _STNT_NativeValueCount(Handle)
		_TestPrint("# storage-counted-name clear counted_nul=" . CountedNul . " native_full_names=" . FullNativeNames
			. " before_count=" . BeforeCount . " result=" . Result . " after_count=" . AfterCount)
		AssertTrue((Result is Integer) && (Result == 0 || Result == 1))
		if Result
			AssertEqual(0, AfterCount, "a clear ACK must not leave a counted native value hidden behind its shorter Win32 alias")
		if CountedNul && !Result {
			AssertEqual(BeforeCount, AfterCount, "an unaddressable inventory must refuse before deleting any prefix value")
			AssertEqual("Original", ST_Get("owned", "missing"), "the legitimate shorter native neighbor remains intact on enumeration refusal")
			AssertEqual(0, ST_Keys().Length, "public keys retains its documented empty-array-on-inventory-error contract")
		}
		if !CountedNul {
			AssertTrue(Result, "the same actual NT producer remains an ordinary supported-name positive control")
			AssertEqual(0, AfterCount)
		}
	} finally {
		STORAGE_REG_BASE := SavedBase
		try {
			if Owned
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647, "Str", Subkey, "UInt"))
		} finally {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
		}
	}
}
for _STNT_Counted in [true, false]
	Test("storage counted native name inventory: nul=" . _STNT_Counted
		. " (storage-native-counted-inventory)", _STNT_ClearCountedName.Bind(_STNT_Counted))

_STQ_OriginalEnvelopeCompatibility() {
	global STORAGE_VALUE_PREFIX
	for Value in ["Ordinary", "001", "é😀", STORAGE_VALUE_PREFIX . 'q:"literal user text"'] {
		AssertEqual(STORAGE_VALUE_PREFIX . "s:" . Value, _ST_EncodeValue(Value), "ordinary string bytes keep the original s: envelope")
		AssertEqual(Value, _ST_DecodeValue(_ST_EncodeValue(Value)))
	}
	OldObject := _ST_DecodeValue(STORAGE_VALUE_PREFIX . 'j:{"value":"old object","items":[1,2]}')
	AssertTrue(OldObject is Map)
	AssertEqual("old object", OldObject["value"])
	AssertTrue(OldObject["items"] is Array)
	AssertEqual(2, OldObject["items"][2])
	AssertEqual("42", _ST_DecodeValue("42"), "untagged legacy strings retain their original interpretation")
}
Test("storage quoted scalar: original s/j and untagged envelopes stay compatible (storage-quoted-scalar-protocol)", _STQ_OriginalEnvelopeCompatibility)

_STQ_QuotedScalarContract() {
	global STORAGE_VALUE_PREFIX
	Value := JsonParse('{"value":"A\u0000B"}')["value"]
	AssertEqual(3, StrLen(Value))
	Encoded := _ST_EncodeValue(Value)
	AssertEqual(STORAGE_VALUE_PREFIX . 'q:"A\u0000B"', Encoded, "only a NUL-bearing scalar selects the new JSON-string envelope")
	Decoded := _ST_DecodeValue(Encoded)
	AssertTrue(Decoded is String)
	AssertEqual(3, StrLen(Decoded))
	AssertEqual(0, NumGet(StrPtr(Decoded), 2, "UShort"))
	AssertEqual(66, NumGet(StrPtr(Decoded), 4, "UShort"))
	for Raw in ['q:"unterminated', 'q:"prefix" true', 'q:{"value":"not a scalar string"}', 'q:["not a scalar string"]', 'j:"still not an object"'] {
		Threw := false
		try _ST_DecodeValue(STORAGE_VALUE_PREFIX . Raw)
		catch
			Threw := true
		AssertTrue(Threw, "malformed or wrongly typed envelopes retain out-of-band decoder refusal")
	}
}
Test("storage quoted scalar: complete String and strict decoder type (storage-quoted-scalar-protocol)", _STQ_QuotedScalarContract)

_STQ_PublicInvalidEnvelope(Kind) {
	global STORAGE_REG_BASE, STORAGE_VALUE_PREFIX
	SavedBase := STORAGE_REG_BASE
	Subkey := "Software\Ergopti_StorageQuotedAudit_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := "HKCU\" . Subkey, Handle := 0, Owned := false
	Stored := STORAGE_VALUE_PREFIX . (Kind == "syntax" ? 'q:"unterminated' : 'q:{"not":"a String"}')
	try {
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 0xF003F,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		Owned := Status == 0 && Disposition == 1
		AssertTrue(Owned)
		AssertTrue(Handle != 0)
		STORAGE_REG_BASE := Path
		AssertTrue(Reg_WriteString(Path, "payload", Stored))
		AssertTrue(Reg_TryRead(Path, "payload", &Before))
		AssertEqual(Stored, Before)
		Actual := ST_Get("payload", "quoted scalar safe fallback")
		AssertTrue(Reg_TryRead(Path, "payload", &After))
		_TestPrint("# storage-quoted-scalar-invalid kind=" . Kind . " disposition=" . Disposition
			. " returned_fallback=" . (Actual == "quoted scalar safe fallback") . " raw_unchanged=" . (Before == After))
		AssertEqual("quoted scalar safe fallback", Actual, "the public reader must refuse invalid q: syntax/types with its caller's default")
		AssertEqual(Before, After, "a refused envelope read never rewrites the authoritative stored bytes")
	} finally {
		STORAGE_REG_BASE := SavedBase
		try {
			if Owned
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647, "Str", Subkey, "UInt"))
		} finally {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
		}
	}
}
for _STQ_Kind in ["syntax", "type"]
	Test("storage quoted scalar public refusal: " . _STQ_Kind
		. " (storage-quoted-scalar-invalid)", _STQ_PublicInvalidEnvelope.Bind(_STQ_Kind))

for _STNF_Shape in ["map", "array"]
	for _STNF_Mode in ["float-wide", "float-digits-control"]
		Test("storage nested binary64 persistence: " . _STNF_Shape . "/" . _STNF_Mode
			. " (storage-native-nested-float)", _STSP_ActualPayload.Bind(_STNF_Mode, _STNF_Shape))
