; tests/fixtures/network_info_native64_cache_probe.ahk

; ==============================================================================
; MODULE: Private WLAN Cache Probe
; DESCRIPTION: Logical WLAN ABI calls supply owned Buffers to the genuine adapter.
; Native CNG and memory reads remain real. No live WLAN or physical long pause.
; ==============================================================================

#Requires AutoHotkey v2.0

class _NWCF_State {
	static Now := 4294968296
	static ClockCalls := 0
	static Response := "A"
	static OpenCalls := 0
	static QueryCalls := 0
	static FreeCalls := 0
	static CloseCalls := 0
	static Clients := Map()
	static Allocations := Map()
	static Interface := 0
	static Attributes := Map()
	static Failure := 0
}

_NWCF_Require(Condition, Message) {
	if !Condition {
		Failure := Error(Message)
		if !IsObject(_NWCF_State.Failure)
			_NWCF_State.Failure := Failure
		throw Failure
	}
}

_NWCF_Rethrow(Failure) {
	if !IsObject(_NWCF_State.Failure)
		_NWCF_State.Failure := Failure
	throw Failure
}

_NWCF_CheckFailure() {
	if IsObject(_NWCF_State.Failure)
		throw _NWCF_State.Failure
}

LoggerError(Tag, Message, Args*) {
	_NWCF_Rethrow(Error("The genuine crypto provider reported failure: " . Tag . " " . Message))
}

_NWCF_Now() {
	_NWCF_Require(_NWCF_State.Now is Integer && _NWCF_State.Now >= 0, "The cache clock requires a nonnegative native64 Integer")
	_NWCF_State.ClockCalls += 1
	return _NWCF_State.Now
}

_NWCF_Open(Name, VersionType, Version, ReservedType, Reserved, NegotiatedType, &Negotiated, ClientType, &Client, ResultType) {
	try {
		_NWCF_Require(Name == "Wlanapi\WlanOpenHandle" && VersionType == "UInt" && Version == 2
			&& ReservedType == "Ptr" && Reserved == 0 && NegotiatedType == "UInt*"
			&& ClientType == "Ptr*" && ResultType == "UInt", "WlanOpenHandle ABI changed")
		_NWCF_State.OpenCalls += 1
		Client := _NWCF_State.OpenCalls, Negotiated := Version
		_NWCF_State.Clients[Client] := true
		return 0
	} catch Any as Failure
		_NWCF_Rethrow(Failure)
}

_NWCF_Enum(Name, ClientType, Client, ReservedType, Reserved, ListType, &List, ResultType) {
	try {
		_NWCF_Require(Name == "Wlanapi\WlanEnumInterfaces" && ClientType == "Ptr" && _NWCF_State.Clients.Has(Client)
			&& ReservedType == "Ptr" && Reserved == 0 && ListType == "Ptr*" && ResultType == "UInt", "WlanEnumInterfaces ABI changed")
		List := _NWCF_State.Interface.Ptr
		_NWCF_Require(!_NWCF_State.Allocations.Has(List), "An interface allocation is still live")
		_NWCF_State.Allocations[List] := Client
		return 0
	} catch Any as Failure
		_NWCF_Rethrow(Failure)
}

_NWCF_Query(Name, ClientType, Client, GuidType, Guid, OpcodeType, Opcode, ReservedType, Reserved, SizeType, &Size, DataType, &Data, ValueTypeType, &ValueType, ResultType) {
	try {
		_NWCF_Require(Name == "Wlanapi\WlanQueryInterface" && ClientType == "Ptr" && _NWCF_State.Clients.Has(Client)
			&& GuidType == "Ptr" && Guid is Buffer && Guid.Size == 16 && OpcodeType == "UInt" && Opcode == 7
			&& ReservedType == "Ptr" && Reserved == 0 && SizeType == "UInt*" && DataType == "Ptr*"
			&& ValueTypeType == "UInt*" && ResultType == "UInt", "WlanQueryInterface ABI changed")
		Attributes := _NWCF_State.Attributes[_NWCF_State.Response]
		Size := Attributes.Size, Data := Attributes.Ptr, ValueType := 0
		_NWCF_Require(!_NWCF_State.Allocations.Has(Data), "A connection allocation is still live")
		_NWCF_State.Allocations[Data] := Client
		_NWCF_State.QueryCalls += 1
		return 0
	} catch Any as Failure
		_NWCF_Rethrow(Failure)
}

_NWCF_Free(Name, PointerType, Pointer) {
	try {
		_NWCF_Require(Name == "Wlanapi\WlanFreeMemory" && PointerType == "Ptr"
			&& _NWCF_State.Allocations.Has(Pointer), "Only the exact outstanding logical WLAN allocation may be freed")
		_NWCF_State.Allocations.Delete(Pointer)
		_NWCF_State.FreeCalls += 1
		return 0
	} catch Any as Failure
		_NWCF_Rethrow(Failure)
}

_NWCF_Close(Name, ClientType, Client, ReservedType, Reserved) {
	try {
		_NWCF_Require(Name == "Wlanapi\WlanCloseHandle" && ClientType == "Ptr" && _NWCF_State.Clients.Has(Client)
			&& ReservedType == "Ptr" && Reserved == 0, "Only the exact outstanding logical WLAN client may be closed")
		for Pointer, Owner in _NWCF_State.Allocations
			_NWCF_Require(Owner != Client, "WLAN memory must retire before its client")
		_NWCF_State.Clients.Delete(Client)
		_NWCF_State.CloseCalls += 1
		return 0
	} catch Any as Failure
		_NWCF_Rethrow(Failure)
}

_NWCF_Attributes(Text, Signal) {
	; Independent Win32 layout: WLAN_CONNECTION_ATTRIBUTES has SSID at 520/524
	; and wlanSignalQuality at 576. No actual adapter result Map is supplied.
	Data := Buffer(580, 0)
	NumPut("UInt", StrLen(Text), Data, 520)
	Loop StrLen(Text)
		NumPut("UChar", Ord(SubStr(Text, A_Index, 1)), Data, 523 + A_Index)
	NumPut("UInt", Signal, Data, 576)
	return Data
}

_NWCF_ReadPublic() {
	Signal := NI_GetSignalStrength()
	_NWCF_CheckFailure()
	Hash := NI_GetSsidHash()
	_NWCF_CheckFailure()
	Snapshot := NI_GetWifiSnapshot()
	_NWCF_CheckFailure()
	return {Signal: Signal, Hash: Hash, Status: Snapshot.Get("status", ""),
		SnapshotSignal: Snapshot.Get("signal_pct", ""), SnapshotHash: Snapshot.Get("ssid_hash", "")}
}

_NWCF_Export(Name, Value) {
	FileAppend("NWCF_RESULT " . Name . " " . Type(Value) . " " . Value . Chr(10), "*", "UTF-8")
}

_NWCF_Main() {
	global NI_WLAN_CACHE_AT, NI_WLAN_CACHE_TTL_MS
	_NWCF_Require(A_Args.Length == 1, "Exactly one WLAN mode is required")
	Mode := A_Args[1]
	switch Mode {
		case "inside-ttl": Elapsed := 1999
		case "exact-ttl": Elapsed := 2000
		case "long-gap": Elapsed := 25769805000
		default: throw ValueError("Unknown WLAN mode.", -1, Mode)
	}
	_NWCF_Require(NI_WLAN_CACHE_TTL_MS == 2000 && NI_WLAN_CACHE_AT == 0, "A fresh adapter and its actual two-second TTL are required")
	; WLAN_INTERFACE_INFO_LIST contains one 532-byte item after its 8-byte header.
	_NWCF_State.Interface := Buffer(540, 0)
	NumPut("UInt", 1, _NWCF_State.Interface, 0)
	NumPut("UInt", 1, _NWCF_State.Interface, 536)
	_NWCF_State.Attributes["A"] := _NWCF_Attributes("ALPHA", 25)
	_NWCF_State.Attributes["B"] := _NWCF_Attributes("BETA", 85)
	Origin := _NWCF_State.Now
	First := _NWCF_ReadPublic()
	_NWCF_Require(First.Signal is Integer && First.Signal == 25 && First.Status == "connected"
		&& First.SnapshotSignal == 25 && First.Hash == "f5cbe4c29262cd4cc9f4556e26fa408fc5fa73f990e98fa2fb7f678981586b3c"
		&& First.SnapshotHash == First.Hash, "PREREQUISITE: genuine buffer parsing and CNG must return the independent A fields")
	_NWCF_Require(NI_WLAN_CACHE_AT is Integer && NI_WLAN_CACHE_AT == Origin
		&& _NWCF_State.QueryCalls == 1 && _NWCF_State.Clients.Count == 0 && _NWCF_State.Allocations.Count == 0
		&& _NWCF_State.CloseCalls == 1 && _NWCF_State.FreeCalls == 2,
		"The real publisher must establish one full-width A origin after exact query retirement")
	_NWCF_State.Response := "B"
	_NWCF_State.Now := Origin + Elapsed
	Second := _NWCF_ReadPublic()
	_NWCF_Require(_NWCF_State.Clients.Count == 0 && _NWCF_State.Allocations.Count == 0
		&& _NWCF_State.CloseCalls == _NWCF_State.OpenCalls && _NWCF_State.FreeCalls == 2 * _NWCF_State.QueryCalls,
		"All actual logical query capabilities must settle before exporting a business result")
	_NWCF_Require(_NWCF_State.ClockCalls >= 6, "All public methods must consult the actual clock boundary")
	FileAppend("NWCF_BOUNDARY now=" . _NWCF_State.Now . " now_type=" . Type(_NWCF_State.Now)
		. " origin=" . Origin . " elapsed=" . Elapsed . " cache_at=" . NI_WLAN_CACHE_AT . " at_type=" . Type(NI_WLAN_CACHE_AT)
		. " clocks=" . _NWCF_State.ClockCalls . " opens=" . _NWCF_State.OpenCalls . " queries=" . _NWCF_State.QueryCalls
		. " frees=" . _NWCF_State.FreeCalls . " closes=" . _NWCF_State.CloseCalls . " clients=" . _NWCF_State.Clients.Count
		. " allocations=" . _NWCF_State.Allocations.Count . Chr(10), "*", "UTF-8")
	_NWCF_Export("signal", Second.Signal)
	_NWCF_Export("hash", Second.Hash)
	_NWCF_Export("status", Second.Status)
	_NWCF_Export("snapshot_signal", Second.SnapshotSignal)
	_NWCF_Export("snapshot_hash", Second.SnapshotHash)
	_NWCF_Export("queries", _NWCF_State.QueryCalls)
	_NWCF_Export("cache_at", NI_WLAN_CACHE_AT)
	FileAppend("NWCF_COMPLETE " . Mode . Chr(10), "*", "UTF-8")
}

try {
	_NWCF_Main()
	ExitApp(0)
} catch Any as Failure {
	FileAppend("NWCF_PREREQUISITE " . Type(Failure) . " " . Failure.Message . " " . Failure.File . ":" . Failure.Line . Chr(10), "*", "UTF-8")
	ExitApp(95)
}
