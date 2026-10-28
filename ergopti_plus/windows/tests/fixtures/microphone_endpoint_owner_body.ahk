; tests/fixtures/microphone_endpoint_owner_body.ahk

; ==============================================================================
; MODULE: Microphone Endpoint Native ABI Component
; DESCRIPTION:
; Real SystemControl get/set calls enter private IAudioEndpointVolume vtables.
; A default selection changes at the native read boundary without acquiring an
; actual audio device. Logger ports observe the void public action passively.
; ==============================================================================

#Requires AutoHotkey v2.0

_MEO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_MEO_Failure(State, Failure) {
	if !IsObject(State.Failure)
		State.Failure := Failure
}

LoggerInfo(Tag, Message, Args*) {
	global _MEO
	try _MEO.Logs.Push({Level: "INFO", Tag: Tag, Text: Args.Length ? Format(Message, Args*) : Message})
	catch Any as Failure
		_MEO_Failure(_MEO, Failure)
}

LoggerError(Tag, Message, Args*) {
	global _MEO
	try _MEO.Logs.Push({Level: "ERROR", Tag: Tag, Text: Args.Length ? Format(Message, Args*) : Message})
	catch Any as Failure
		_MEO_Failure(_MEO, Failure)
}

class _MEO_System extends SystemControl {
	__New(State) {
		this.State := State
	}

	_CaptureVolume() {
		State := this.State
		Name := State.Default
		Endpoint := State.Endpoints[Name]
		_MEO_Require(State.Invoking, "Only the real public action may acquire a private endpoint.")
		State.Acquisitions.Push(Name)
		; ComValue(VT_UNKNOWN, Ptr) takes one existing native reference in AHK v2.
		Count := DllCall(Endpoint.Callbacks[2], "Ptr", Endpoint.Instance.Ptr, "UInt")
		_MEO_Require(Count > 1, "A private interface acquisition must obtain its own native reference.")
		return ComValue(13, Endpoint.Instance.Ptr)
	}
}

; Stdcall signatures include the interface pointer. Slots 3..13 are genuine
; interface members but are not implemented by this mute-only environment.
_MEO_CreateEndpoint(State, Name, Muted) {
	Endpoint := {Name: Name, Muted: Muted, Initial: Muted, References: 1,
		Vtable: Buffer(16 * A_PtrSize, 0), Instance: Buffer(A_PtrSize, 0), Callbacks: []}
	State.Endpoints[Name] := Endpoint
	NumPut("Ptr", Endpoint.Vtable.Ptr, Endpoint.Instance)
	for Slot, Arity in [3, 1, 1, 2, 2, 2, 3, 3, 2, 2, 4, 4, 3, 3, 3, 2] {
		Callback := CallbackCreate(_MEO_Native.Bind(State, Name, Slot - 1), "", Arity)
		Endpoint.Callbacks.Push(Callback)
		NumPut("Ptr", Callback, Endpoint.Vtable, (Slot - 1) * A_PtrSize)
	}
	return Endpoint
}

_MEO_Native(State, Name, Slot, Arguments*) {
	State.CallbackDepth += 1
	try {
		Endpoint := State.Endpoints[Name]
		_MEO_Require(Arguments.Length > 0 && Arguments[1] == Endpoint.Instance.Ptr,
			"The native call must retain its exact private endpoint pointer.")
		switch Slot {
			case 0:
				_MEO_Require(Arguments.Length == 3 && Arguments[2] && Arguments[3], "QueryInterface requires its real pointer ABI.")
				NumPut("Ptr", 0, Arguments[3])
				if DllCall("msvcrt\memcmp", "Ptr", Arguments[2], "Ptr", State.IUnknown, "UPtr", 16, "CDecl Int")
					&& DllCall("msvcrt\memcmp", "Ptr", Arguments[2], "Ptr", State.IAudioEndpointVolume, "UPtr", 16, "CDecl Int")
					return 0x80004002
				Count := DllCall(Endpoint.Callbacks[2], "Ptr", Endpoint.Instance.Ptr, "UInt")
				_MEO_Require(Count > 1, "QueryInterface must transfer one genuine private COM reference.")
				NumPut("Ptr", Endpoint.Instance.Ptr, Arguments[3])
				State.QueryInterfaces += 1
				return 0
			case 1:
				_MEO_Require(Endpoint.References > 0, "A retired private interface cannot be resurrected.")
				Endpoint.References += 1
				State.AddRefs += 1
				return Endpoint.References
			case 2:
				_MEO_Require(Endpoint.References > 0, "Each native Release must own a real reference.")
				Endpoint.References -= 1
				State.Releases += 1
				return Endpoint.References
			case 14:
				_MEO_Require(State.Invoking && Arguments.Length == 3, "SetMute must use the native public-action ABI.")
				State.Sets.Push({Endpoint: Name, Value: Arguments[2] != 0})
				Endpoint.Muted := Arguments[2] != 0
				return 0
			case 15:
				_MEO_Require(State.Invoking && Arguments.Length == 2 && Arguments[2], "GetMute requires an actual BOOL output pointer.")
				NumPut("Int", Endpoint.Muted ? 1 : 0, Arguments[2])
				State.Gets.Push({Endpoint: Name, Value: Endpoint.Muted})
				if State.Switch && !State.Switched {
					_MEO_Require(Name == "A" && State.Default == "A", "Only A's first real native read may change the logical default.")
					State.Default := "B", State.Switched := true
				}
				return 0
			default:
				throw Error("Unexpected IAudioEndpointVolume slot: " . Slot)
		}
	} catch Any as Failure {
		_MEO_Failure(State, Failure)
		return 0x80004005
	} finally State.CallbackDepth -= 1
}

_MEO_CheckIUnknown(State, Endpoint) {
	; Probe the real QueryInterface/AddRef/Release ABI before the product runs.
	Count := DllCall(Endpoint.Callbacks[2], "Ptr", Endpoint.Instance.Ptr, "UInt")
	_MEO_Require(Count == 2, "The owning fixture reference must be separate from a new COM wrapper.")
	Wrapper := ComValue(13, Endpoint.Instance.Ptr)
	Queried := 0
	try {
		ComCall(0, Wrapper, "Ptr", State.IAudioEndpointVolume, "Ptr*", &Queried)
		_MEO_Require(Queried == Endpoint.Instance.Ptr && Endpoint.References == 3,
			"QueryInterface must return the exact private volume with an owned reference.")
	} finally {
		if Queried
			DllCall(Endpoint.Callbacks[3], "Ptr", Queried, "UInt")
		Wrapper := 0
	}
	_MEO_Require(Endpoint.References == 1 && State.CallbackDepth == 0,
		"Both native COM wrappers must release before the public action starts.")
}

_MEO_Destroy(State) {
	_MEO_Require(State.CallbackDepth == 0, "Native callbacks must return before their executable thunks are freed.")
	for Name, Endpoint in State.Endpoints
		_MEO_Require(Endpoint.References == 1, "All acquired COM wrappers must release before the fixture reference.")
	for Name, Endpoint in State.Endpoints {
		Count := DllCall(Endpoint.Callbacks[3], "Ptr", Endpoint.Instance.Ptr, "UInt")
		_MEO_Require(Count == 0 && Endpoint.References == 0, "Final native Release must retire the exact private endpoint.")
	}
	_MEO_Require(State.CallbackDepth == 0, "Final Release must unwind before CallbackFree.")
	for Name, Endpoint in State.Endpoints {
		for Callback in Endpoint.Callbacks {
			CallbackFree(Callback)
			State.FreedCallbacks += 1
		}
		Endpoint.Callbacks := []
		Endpoint.Instance := 0, Endpoint.Vtable := 0
	}
	_MEO_Require(State.AddRefs + 2 == State.Releases, "Every actual acquired and fixture COM reference must be released once.")
	_MEO_Require(State.FreedCallbacks == 32, "Both complete private vtables must release their callback thunks.")
	State.Endpoints := Map()
}

_MEO_Main() {
	global _MEO
	if A_Args.Length != 1
		ExitApp(2)
	Mode := A_Args[1]
	_MEO := {Endpoints: Map(), Default: "A", Switch: Mode != "current", Switched: false,
		Invoking: false, CallbackDepth: 0, AddRefs: 0, Releases: 0, QueryInterfaces: 0,
		Gets: [], Sets: [], Acquisitions: [], Logs: [], Failure: 0, FreedCallbacks: 0,
		IUnknown: Buffer(16, 0), IAudioEndpointVolume: Buffer(16, 0)}
	State := _MEO, Primary := 0, Sys := 0, Changed := -1, Cleaned := false
	PreviousSuspend := A_IsSuspended
	try {
		_MEO_Require(Mode == "current" || Mode == "switch-to-muted" || Mode == "switch-to-unmuted", "Unknown microphone component mode.")
		Suspend(false)
		DllCall("ole32\CLSIDFromString", "Str", "{00000000-0000-0000-C000-000000000046}", "Ptr", State.IUnknown, "HRESULT")
		DllCall("ole32\CLSIDFromString", "Str", "{5CDF2C82-841E-4546-9722-0CF74078229A}", "Ptr", State.IAudioEndpointVolume, "HRESULT")
		_MEO_CreateEndpoint(State, "A", Mode == "switch-to-unmuted")
		_MEO_CreateEndpoint(State, "B", Mode != "switch-to-unmuted")
		for Name, Endpoint in State.Endpoints
			_MEO_CheckIUnknown(State, Endpoint)
		if IsObject(State.Failure)
			throw State.Failure
		_MEO_Require(State.QueryInterfaces == 2, "Both private interfaces must pass a native IUnknown preflight.")
		Sys := _MEO_System(State)
		State.Invoking := true
		try GestureSysMicMuteToggle(Sys)
		finally State.Invoking := false
		Sys := 0
		if IsObject(State.Failure)
			throw State.Failure
		Errors := 0
		for Line in State.Logs
			Errors += Line.Level == "ERROR" ? 1 : 0
		_MEO_Require(Errors == 0 && State.Gets.Length > 0 && State.Sets.Length > 0,
			"The real public action must reach native GetMute/SetMute without a caught protocol error.")
		_MEO_Require(State.CallbackDepth == 0 && State.Switched == State.Switch,
			"The actual native read boundary must settle before the business oracle.")
		Changed := 0
		for Name, Endpoint in State.Endpoints {
			_MEO_Require(Endpoint.References == 1, "The public action must release every native acquisition before comparison.")
			Changed += Endpoint.Muted != Endpoint.Initial ? 1 : 0
		}
		FileAppend("RECEIPT microphone-endpoint mode=" . Mode . " switched=" . State.Switched
			. " acquisitions=" . State.Acquisitions.Length . " gets=" . State.Gets.Length . " sets=" . State.Sets.Length
			. " changed=" . Changed . " a_before=" . State.Endpoints["A"].Initial . " a_after=" . State.Endpoints["A"].Muted
			. " b_before=" . State.Endpoints["B"].Initial . " b_after=" . State.Endpoints["B"].Muted . " errors=" . Errors . "`n", "*", "UTF-8")
		_MEO_Require(Changed == 1, "The microphone toggle must change exactly one admitted endpoint, even when the default changes.")
	} catch Any as Failure {
		Primary := IsObject(State.Failure) ? State.Failure : Failure
	} finally {
		Sys := 0
		try {
			_MEO_Destroy(State)
			Cleaned := true
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		Suspend(PreviousSuspend)
	}
	FileAppend("CLEANUP microphone-endpoint cleaned=" . Cleaned . " callbacks=" . State.FreedCallbacks
		. " addrefs=" . State.AddRefs . " releases=" . State.Releases . " depth=" . State.CallbackDepth . "`n", "*", "UTF-8")
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS microphone-endpoint-owner " . Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_MEO_Main()
