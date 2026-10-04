; static/ergopti_plus/windows/tests/unit/test_keylogger_device_uuid.ahk

; ==============================================================================
; MODULE: Keylogger Device UUID Tests
; DESCRIPTION:
; Native GUID integer fields must keep their numeric order in persistent identity
; text. Literal fixtures and the native GUID formatter provide independent oracles.
; No device configuration, journal, registry or input state is opened.
; ==============================================================================

#Requires AutoHotkey v2.0+

_KLDU_Fill(Guid, Data1, Data2, Data3, Data4) {
	AssertEqual(16, Guid.Size)
	NumPut("UInt", Data1, "UShort", Data2, "UShort", Data3, Guid)
	for Index, Value in Data4
		NumPut("UChar", Value, Guid, Index + 7)
	return 0
}

_KLDU_Literal(Data1, Data2, Data3, Data4, Expected) {
	AssertEqual(Expected, KL_UuidV4(_KLDU_Fill.Bind(, Data1, Data2, Data3, Data4)),
		"canonical identity text must preserve native integer fields and Data4 bytes")
}
Test("device UUID: native integer fields retain order (device-uuid-format)",
	_KLDU_Literal.Bind(0x12345678, 0x9ABC, 0x4DEF, [0x8F, 0xED, 1, 0x23, 0x45, 0x67, 0x89, 0xAB],
		"12345678-9abc-4def-8fed-0123456789ab"))
Test("device UUID: unsigned field and maximum tail (device-uuid-format)",
	_KLDU_Literal.Bind(0xFEDCBA98, 0x7654, 0x4321, [0xBF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
		"fedcba98-7654-4321-bfff-ffffffffffff"))
Test("device UUID: zero padding and lowercase text (device-uuid-format)",
	_KLDU_Literal.Bind(1, 2, 0x4003, [0x80, 4, 0, 0, 0, 0, 0, 5],
		"00000001-0002-4003-8004-000000000005"))

_KLDU_NativeReference() {
	Captured := { Guid: 0 }
	Create := (Guid) => _KLDU_CreateNative(Captured, Guid)
	Actual := KL_UuidV4(Create)
	Text := Buffer(78, 0)
	Written := DllCall("ole32\StringFromGUID2", "Ptr", Captured.Guid, "Ptr", Text, "Int", 39, "Int")
	AssertEqual(39, Written, "the independent native formatter must succeed")
	Expected := StrLower(SubStr(StrGet(Text, "UTF-16"), 2, 36))
	AssertEqual(Expected, Actual, "device text must agree with the native formatter for the same GUID")
	AssertTrue(RegExMatch(Actual, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
}

_KLDU_CreateNative(Captured, Guid) {
	Captured.Guid := Guid
	Result := DllCall("ole32\CoCreateGuid", "Ptr", Guid, "Int")
	AssertEqual(0, Result, "the native comparison fixture must obtain a GUID")
	return Result
}
Test("device UUID: actual native GUID formatter agrees (device-uuid-format)", _KLDU_NativeReference)

_KLDU_DefaultNative() {
	Actual := KL_UuidV4()
	AssertTrue(RegExMatch(Actual, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
		"the actual supported native producer must retain its UUID version and variant")
}
Test("device UUID: default native producer retains version (device-uuid-format)", _KLDU_DefaultNative)

; A failed native producer must not persist zero bytes or an apparently valid ID.
_KLDU_Failure(Result, Fill) {
	Create := (Guid) => _KLDU_Refuse(Guid, Result, Fill)
	Caught := 0
	try KL_UuidV4(Create)
	catch as Failure
		Caught := Failure
	AssertTrue(IsObject(Caught), "a failed GUID producer must escape before returning an identity")
	if Result is Integer
		AssertContains(Caught.Message, Format("0x{:08X}", Result & 0xFFFFFFFF), "the failure preserves its complete HRESULT")
	else
		AssertEqual("TypeError", Type(Caught), "invalid producer state must fail explicitly")
}

_KLDU_Refuse(Guid, Result, Fill) {
	if Fill
		_KLDU_Fill(Guid, 0x12345678, 0x9ABC, 0x4DEF, [0x8F, 0xED, 1, 0x23, 0x45, 0x67, 0x89, 0xAB])
	return Result
}
Test("device UUID: negative HRESULT rejects zero identity (device-uuid-failure)", _KLDU_Failure.Bind(-2147024882, false))
Test("device UUID: failed filled buffer is refused (device-uuid-failure)", _KLDU_Failure.Bind(-2147467259, true))
Test("device UUID: nonzero success code is not S_OK (device-uuid-failure)", _KLDU_Failure.Bind(1, true))
Test("device UUID: invalid producer result fails fast (device-uuid-failure)", _KLDU_Failure.Bind("", false))

; Identity recovery scans only an exclusively acquired, disposable fixture tree.
_KLDR_Host(State) {
	State.HostCalls += 1
	return State.Host
}

_KLDR_Guid(State, Guid) {
	State.MintCalls += 1
	return _KLDU_Fill(Guid, 0x00112233, 0x4455, 0x4677,
		[0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
}

_KLDR_Fixture(Action) {
	static Serial := 0
	Serial += 1
	Root := A_Temp . "\ergopti-device-recovery-" . PLC_CurrentProcessIdStrict() . "-" . A_TickCount . "-" . Serial
	AssertFalse(DirExist(Root), "the fixture must never adopt existing state")
	FSCreateDirectoryExclusiveStrict(Root)
	OwnedRoot := _KLDR_FullPath(Root)
	State := {Root: Root, CleanupPermitted: true, Host: "owned-device-host", HostCalls: 0, MintCalls: 0,
		Modern: "00112233-4455-4677-8899-aabbccddeeff", Legacy: "33221100-5544-7766-8899-aabbccddeeff"}
	Caught := 0
	try Action.Call(State)
	catch as Failure
		Caught := Failure
	if !State.CleanupPermitted {
		if IsObject(Caught)
			throw Caught
		throw Error("Fixture access was not restored; owned tree retained.")
	}
	AssertEqual(OwnedRoot, _KLDR_FullPath(Root), "cleanup must retain the exact exclusively acquired absolute root")
	try DirDelete(OwnedRoot, 1)
	catch as CleanupFailure {
		if IsObject(Caught)
			throw Error(Caught.Message . " Cleanup failed: " . CleanupFailure.Message)
		throw CleanupFailure
	}
	if IsObject(Caught)
		throw Caught
}

_KLDR_Write(State, Folder, Raw) {
	Dir := State.Root . "\by_device\" . Folder
	DirCreate(Dir)
	Path := Dir . "\device.json"
	AssertFalse(FileExist(Path), "fixture publication cannot overwrite any candidate")
	FileAppend(Raw, Path, "UTF-8-RAW")
	return Path
}

_KLDR_Raw(Host, Id) {
	return '{"host_signature":' . JsonStringLiteral(Host) . ',"device_id":' . JsonStringLiteral(Id) . '}'
}

_KLDR_Resolve(State) {
	return KL_ResolveDevice(State.Root, _KLDR_Host.Bind(State), _KLDR_Guid.Bind(State))
}

_KLDR_Refused(State, Path) {
	Caught := 0
	try _KLDR_Resolve(State)
	catch as Failure
		Caught := Failure
	AssertTrue(IsObject(Caught), "uncertain device history must refuse recovery")
	AssertEqual("Error", Type(Caught), "refusal must come from the real contextual recovery guard")
	AssertContains(Caught.Extra, Path, "the refused candidate must remain available for triage")
	AssertEqual(0, State.MintCalls, "uncertainty cannot grant a fresh identity")
	AssertEqual(1, State.HostCalls, "one host observation owns the complete scan")
}

_KLDR_InvalidId(Mode, State) {
	switch Mode {
		case "missing": Raw := '{"host_signature":"owned-device-host"}'
		case "empty": Raw := _KLDR_Raw(State.Host, "")
		case "null": Raw := '{"host_signature":"owned-device-host","device_id":null}'
		case "number": Raw := '{"host_signature":"owned-device-host","device_id":17}'
		case "object": Raw := '{"host_signature":"owned-device-host","device_id":{}}'
		case "slash": Raw := _KLDR_Raw(State.Host, "../../escape")
		case "backslash": Raw := _KLDR_Raw(State.Host, "..\escape")
		case "dot": Raw := _KLDR_Raw(State.Host, ".")
		case "suffix": Raw := _KLDR_Raw(State.Host, State.Modern . ".")
		case "nul": Raw := '{"host_signature":"owned-device-host","device_id":"00112233-4455-4677-8899-aabbccddeeff\u0000"}'
		case "newline": Raw := _KLDR_Raw(State.Host, State.Modern . "`n")
		case "mismatch": Raw := _KLDR_Raw(State.Host, State.Legacy)
		case "shadowed": Raw := '{"host_signature":"owned-device-host","device_id":"' . State.Modern . '","device_id":null}'
	}
	Path := _KLDR_Write(State, State.Modern, Raw)
	_KLDR_Refused(State, Path)
}
for _KLDR_Mode in ["missing", "empty", "null", "number", "object", "slash", "backslash", "dot", "suffix", "nul", "newline", "mismatch", "shadowed"]
	Test("device recovery: invalid matching identity " . _KLDR_Mode,
		_KLDR_Fixture.Bind(_KLDR_InvalidId.Bind(_KLDR_Mode)))

_KLDR_InvalidDocument(Mode, State) {
	switch Mode {
		case "truncated": Raw := SubStr(_KLDR_Raw(State.Host, State.Modern), 1, -1)
		case "array": Raw := '[' . _KLDR_Raw(State.Host, State.Modern) . ']'
		case "null": Raw := "null"
		case "scalar": Raw := '"owned-device-host"'
		case "missing-host": Raw := '{"device_id":"' . State.Modern . '"}'
		case "empty-host": Raw := _KLDR_Raw("", State.Modern)
		case "null-host": Raw := '{"host_signature":null,"device_id":"' . State.Modern . '"}'
		case "number-host": Raw := '{"host_signature":17,"device_id":"' . State.Modern . '"}'
		case "nested-host": Raw := '{"metadata":' . _KLDR_Raw(State.Host, State.Modern) . '}'
		case "shadowed-host": Raw := '{"host_signature":"owned-device-host","host_signature":null,"device_id":"' . State.Modern . '"}'
	}
	Path := _KLDR_Write(State, State.Modern, Raw)
	_KLDR_Refused(State, Path)
}
for _KLDR_Mode in ["truncated", "array", "null", "scalar", "missing-host", "empty-host", "null-host", "number-host", "nested-host", "shadowed-host"]
	Test("device recovery: invalid document " . _KLDR_Mode,
		_KLDR_Fixture.Bind(_KLDR_InvalidDocument.Bind(_KLDR_Mode)))

_KLDR_MissingFile(DirectoryInstead, State) {
	Dir := State.Root . "\by_device\" . State.Modern
	DirCreate(Dir)
	Path := Dir . "\device.json"
	if DirectoryInstead
		DirCreate(Path)
	_KLDR_Refused(State, Path)
}
Test("device recovery: a missing identity cannot replace existing history", _KLDR_Fixture.Bind(_KLDR_MissingFile.Bind(false)))
Test("device recovery: unreadable identity keeps its path context", _KLDR_Fixture.Bind(_KLDR_MissingFile.Bind(true)))

_KLDR_Valid(Mode, State) {
	Id := Mode = "legacy" ? State.Legacy : State.Modern
	if Mode = "uppercase"
		Id := StrUpper(Id)
	_KLDR_Write(State, StrLower(Id), _KLDR_Raw(State.Host, Id))
	Obj := _KLDR_Resolve(State)
	AssertEqual(Id, Obj["device_id"], "existing identity text must stay byte-exact")
	AssertEqual(State.Host, Obj["host_signature"])
	AssertEqual(0, State.MintCalls)
	AssertEqual(1, State.HostCalls)
}
for _KLDR_Mode in ["modern", "legacy", "uppercase"]
	Test("device recovery: preserves valid " . _KLDR_Mode, _KLDR_Fixture.Bind(_KLDR_Valid.Bind(_KLDR_Mode)))

_KLDR_Escapes(State) {
	State.Host := "owned-" . Chr(34) . "host\é"
	Raw := '{"host_signature":' . JsonStringLiteral(State.Host) . ',"device_id":"' . State.Legacy
		. '","name":"line\nquote\"slash\\é","unknown":{"value":27},"schema_version":9}'
	_KLDR_Write(State, State.Legacy, Raw)
	Obj := _KLDR_Resolve(State)
	AssertEqual(State.Legacy, Obj["device_id"])
	AssertEqual(State.Host, Obj["host_signature"], "decoded host escapes own matching")
	AssertEqual("line`nquote" . Chr(34) . "slash\é", Obj["name"])
	AssertEqual(27, Obj["unknown"]["value"], "unknown metadata cannot be discarded")
	AssertEqual(9, Obj["schema_version"], "stored metadata cannot be replaced by defaults")
	AssertEqual(0, State.MintCalls)
}
Test("device recovery: preserves decoded host and complete escaped metadata", _KLDR_Fixture.Bind(_KLDR_Escapes))

_KLDR_Fresh(Mode, State) {
	if Mode = "foreign"
		_KLDR_Write(State, "foreign-history", '{"host_signature":"foreign-host","device_id":null}')
	if Mode = "nested-foreign"
		_KLDR_Write(State, State.Legacy, '{"metadata":' . _KLDR_Raw(State.Host, State.Legacy)
			. ',"host_signature":"foreign-host","device_id":null}')
	Obj := _KLDR_Resolve(State)
	AssertEqual(State.Modern, Obj["device_id"], "a proven fresh identity uses the real GUID formatter")
	AssertEqual(State.Host, Obj["host_signature"])
	AssertEqual("windows", Obj["os"])
	AssertEqual(KeylogConst.SCHEMA_VERSION, Obj["schema_version"])
	AssertEqual(1, State.MintCalls, "only a completely resolved scan may mint once")
	AssertEqual(1, State.HostCalls)
}
for _KLDR_Mode in ["empty", "foreign", "nested-foreign"]
	Test("device recovery: mints only after proven " . _KLDR_Mode . " history", _KLDR_Fixture.Bind(_KLDR_Fresh.Bind(_KLDR_Mode)))

_KLDR_Ambiguous(State) {
	_KLDR_Write(State, State.Modern, _KLDR_Raw(State.Host, State.Modern))
	_KLDR_Write(State, State.Legacy, _KLDR_Raw(State.Host, State.Legacy))
	_KLDR_Refused(State, State.Root . "\by_device\")
}
Test("device recovery: two matching histories cannot be selected by directory order", _KLDR_Fixture.Bind(_KLDR_Ambiguous))

_KLDR_LateCorruption(State) {
	DirCreate(State.Root . "\by_device\" . State.Modern)
	DirCreate(State.Root . "\by_device\" . State.Legacy)
	Folders := []
	Loop Files, State.Root . "\by_device\*", "D"
		Folders.Push(A_LoopFileName)
	AssertEqual(2, Folders.Length)
	_KLDR_Write(State, Folders[1], _KLDR_Raw(State.Host, Folders[1]))
	Path := _KLDR_Write(State, Folders[2], "{")
	_KLDR_Refused(State, Path)
}
Test("device recovery: corruption after a valid match still refuses adoption", _KLDR_Fixture.Bind(_KLDR_LateCorruption))

; Resolve the exact acquired path again before any recursive fixture cleanup.
_KLDR_FullPath(Path) {
	Text := Buffer(65536, 0)
	Length := DllCall("Kernel32\GetFullPathNameW", "Str", Path, "UInt", 32768,
		"Ptr", Text, "Ptr", 0, "UInt")
	AssertTrue(Length > 0 && Length < 32768, "the owned fixture path must resolve completely")
	return StrGet(Text, Length, "UTF-16")
}

_KLDR_DeniedObservation(State, Captured) {
	try Captured.Identity := _KLDR_Resolve(State)
	catch as Failure
		Captured.Failure := Failure
	Captured.Mints := State.MintCalls
}

_KLDR_WithDeniedListing(State, Scenario) {
	Path := State.Root . "\by_device"
	Needed := 0
	DllCall("Advapi32\GetFileSecurityW", "Str", Path, "UInt", 4,
		"Ptr", 0, "UInt", 0, "UInt*", &Needed)
	AssertTrue(Needed > 0)
	Saved := Buffer(Needed, 0)
	AssertTrue(DllCall("Advapi32\GetFileSecurityW", "Str", Path, "UInt", 4,
		"Ptr", Saved, "UInt", Saved.Size, "UInt*", &Needed))
	Denied := 0
	AssertTrue(DllCall("Advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW",
		"Str", "D:(D;;0x1;;;WD)(A;;FA;;;WD)", "UInt", 1,
		"Ptr*", &Denied, "Ptr", 0))
	Changed := false
	try {
		AssertTrue(DllCall("Advapi32\SetFileSecurityW", "Str", Path, "UInt", 4, "Ptr", Denied))
		Changed := true
		State.CleanupPermitted := false
		Data := Buffer(592, 0)
		Handle := DllCall("Kernel32\FindFirstFileW", "Str", Path . "\*", "Ptr", Data, "Ptr")
		ErrorCode := A_LastError
		if Handle != -1
			AssertTrue(DllCall("Kernel32\FindClose", "Ptr", Handle, "Int"))
		AssertEqual(-1, Handle, "the owned fixture must really deny native enumeration")
		AssertEqual(5, ErrorCode, "the refusal must be native ERROR_ACCESS_DENIED")
		AssertTrue(DirExist(Path), "listing denial is not directory absence")
		Scenario.Call()
	} finally {
		Restored := !Changed || DllCall("Advapi32\SetFileSecurityW", "Str", Path, "UInt", 4, "Ptr", Saved)
		if Restored
			State.CleanupPermitted := true
		try AssertTrue(Restored, "restore the exact saved fixture DACL before cleanup")
		finally AssertEqual(0, DllCall("Kernel32\LocalFree", "Ptr", Denied, "Ptr"))
	}
}

_KLDR_NativeListing(Existing, State) {
	if Existing
		_KLDR_Write(State, State.Legacy, _KLDR_Raw(State.Host, State.Legacy))
	else
		DirCreate(State.Root . "\by_device")
	Captured := {Failure: 0, Identity: 0, Mints: 0}
	_KLDR_WithDeniedListing(State, _KLDR_DeniedObservation.Bind(State, Captured))
	AssertTrue(State.CleanupPermitted, "restoration must finish before the next observation")
	State.MintCalls := 0
	Recovered := _KLDR_Resolve(State)
	AssertEqual(Existing ? State.Legacy : State.Modern, Recovered["device_id"],
		"restored access must recover the real history or prove a fresh scan")
	AssertEqual(Existing ? 0 : 1, State.MintCalls, "the restored scan retains its exact creation authority")
	AssertEqual(0, Captured.Mints, "failed enumeration must precede any UUID mint")
	AssertTrue(IsObject(Captured.Failure), "denied listing cannot be admitted as an empty device history")
	AssertEqual("OSError", Type(Captured.Failure))
	AssertEqual(5, Captured.Failure.Number, "strict enumeration preserves native access denial")
}
for _KLDR_Existing in [false, true]
	Test("device recovery: native denied listing and restored " . (_KLDR_Existing ? "existing" : "fresh") . " history",
		_KLDR_Fixture.Bind(_KLDR_NativeListing.Bind(_KLDR_Existing)))
