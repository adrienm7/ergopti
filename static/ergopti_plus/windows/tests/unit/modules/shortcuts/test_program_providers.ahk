; tests/unit/modules/shortcuts/test_program_providers.ahk

; ==============================================================================
; MODULE: Program Providers
; DESCRIPTION:
; Program providers keep their shared receipts and raw page arguments, the
; picker closes without assigning retained debt, protected native metadata
; keeps custody, and the installed AutoHotkey, Python and PowerShell
; providers run real scripts.
; ==============================================================================

#Requires AutoHotkey v2.0





; The shared catalogue owns provider commands. These fixtures only supply native
; receipts or independently authored scripts; none launches during discovery.
_RPP_Catalogue() {
	global _SharedDir
	Raw := FSReadUtf8ExactBounded(_SharedDir . "\modules\actions\program_providers.json", 65536)
	Assert(Raw is String, "provider tests read the actual bounded canonical catalogue")
	return Raw
}

_RPP_ControlledOwner() {
	State := Map("directory", "directory1", "script", "script1", "tool", "tool1",
		"route", "C:\owned106\scripts", "retired", true, "owner", 0, "move", "", "readable", true)
	Identity(Path) {
		if State["move"] == "invalidate" {
			State["move"] := ""
			State["owner"].Invalidate()
		}
		if Path == State["route"]
			return Map("kind", "directory", "token", State["directory"])
		if Path == State["route"] . "\été 日本.py"
			return Map("kind", "file", "token", State["script"], "readable", State["readable"], "executable", false)
		if Path == "C:\tool106\python3.exe"
			return Map("kind", "file", "token", State["tool"], "readable", true, "executable", true)
		return Map("kind", "missing", "token", "missing")
	}
	Interpreter(Commands, ProviderId) {
		if State["move"] == "readrevoke" {
			State["move"] := ""
			State["readable"] := false
		}
		if Commands[1] == "python3.exe"
			return Map("executable", "C:\tool106\python3.exe", "token", State["tool"])
		return false
	}
	Owner := ProgramProviderSession(_RPP_Catalogue(), Map(
		"route", (*) => State["route"], "identity", Identity,
		"interpreter", Interpreter, "list", (*) => Map("names", ["été 日本.py"], "truncated", false),
		"retire", (*) => State["retired"]))
	State["owner"] := Owner
	return State
}

_RPP_PolicyReceipts() {
	Catalogue := _RPP_Catalogue()
	AssertEqual(4, ProgramProviderCatalogue(Catalogue).Length, "only the four canonical Windows provider descriptors are admitted")
	AssertFalse(ProgramProviderCatalogue(StrReplace(Catalogue, '"version": 1', '"version": true')),
		"the native parser cannot erase the catalogue Boolean version distinction")
	AssertFalse(ProgramProviderCatalogue(StrReplace(Catalogue, '"ahk"', '"foreign"')),
		"foreign command platform metadata never becomes an installed Windows provider")
	for Pair in [['"id": "python"', '"id": "python\u0000suffix"'],
		['"python3.exe"', '"python3.exe\u0000suffix"'],
		['"/ErrorStdOut=UTF-8"', '"/ErrorStdOut=UTF-8\u0000suffix"']] {
		Corrupt := StrReplace(Catalogue, Pair[1], Pair[2], true)
		Assert(Corrupt != Catalogue, "each independently authored escaped-NUL mutation reaches metadata")
		AssertFalse(ProgramProviderCatalogue(Corrupt), "raw metadata NUL cannot truncate into an admitted catalogue scalar")
	}
	Literal := StrReplace(Catalogue, '"/ErrorStdOut=UTF-8"', '"/ErrorStdOut=UTF-8\\u0000"', true)
	Assert(Literal != Catalogue, "literal escaped-backslash metadata control reaches the canonical prefix")
	Assert(ProgramProviderCatalogue(Literal) is Array, "escaped backslash plus u0000 remains an ordinary metadata literal")
	for Role in ["route", "identity", "interpreter", "list"]
		for Thrown in ["private-metadata106", 41]
			_RPP_ThrowPort(Role, Thrown)
	State := _RPP_ControlledOwner(), Owner := State["owner"]
	Packet := Owner.Discover()
	Assert(Packet is Map, "actual shared discovery policy admits owned native receipts")
	AssertEqual(1, Packet["choices"].Length, "only the verified Python script is exposed")
	AssertEqual("été 日本.py", Packet["choices"][1]["label"], "page sees a basename instead of a machine path")
	Key := Packet["choices"][1]["key"]
	Scalar := Owner.Resolve(Key, ["", "two words", "日本語", "$(literal)", "%literal%", "line`nnext"])
	Parsed := ProgramParameterParse(Scalar)
	Assert(Parsed is Map, "provider resolves through the actual version-one program decoder")
	AssertEqual("C:\tool106\python3.exe", Parsed["executable"], "exact interpreter is preserved")
	AssertEqual(State["route"] . "\été 日本.py", Parsed["arguments"][1], "script is literal argv zero")
	AssertEqual("", Parsed["arguments"][2], "empty script argument remains literal")
	AssertEqual("$(literal)", Parsed["arguments"][5], "shell-looking argument never becomes a command")
	AssertEqual("%literal%", Parsed["arguments"][6], "percent text is never expanded")
	State["readable"] := false
	AssertFalse(Owner.Resolve(Key, []), "same physical script token does not excuse revoked read admission")
	State["readable"] := true
	State["move"] := "readrevoke"
	AssertFalse(Owner.Resolve(Key, []), "final script read admission is rechecked after interpreter callbacks")
	State["readable"] := true
	State["script"] := "replacement"
	AssertFalse(Owner.Resolve(Key, []), "same-named script replacement invalidates the captured choice")
	State["script"] := "script1"
	State["tool"] := "replacement"
	AssertFalse(Owner.Resolve(Key, []), "interpreter replacement invalidates the captured choice")
	State["tool"] := "tool1"
	State["move"] := "invalidate"
	AssertFalse(Owner.Resolve(Key, []), "native callback invalidation cannot lend its old choice to a successor")
	Packet := Owner.Discover()
	Assert(Packet is Map, "fresh discovery explicitly admits its own new generation")
	AssertFalse(Owner.Resolve(Key, []), "old opaque key cannot address the fresh generation")
	State["retired"] := false
	AssertFalse(Owner.Invalidate(), "refused native close remains a real retirement refusal")
	AssertFalse(Owner.Resolve(Packet["choices"][1]["key"], []), "logical invalidation happens even when physical close refuses")
	State["retired"] := true
	AssertTrue(Owner.Invalidate(), "same exact retirement capability can acknowledge its later retry")
}
Test("program providers: exact shared receipts and stale native choices", _RPP_PolicyReceipts)

_RPP_ThrowPort(Role, Thrown) {
	State := _RPP_ControlledOwner(), Owner := State["owner"]
	Original := Owner.Ports[Role]
	Fault(*) {
		throw Thrown
	}
	Owner.Ports[Role] := Fault
	AssertFalse(Owner.Discover(), "arbitrary native port exceptions return a closed discovery refusal")
	AssertFalse(IsObject(Owner.Current), "failed discovery cannot leave an admitted old choice")
	Owner.Ports[Role] := Original
	Packet := Owner.Discover()
	Assert(Packet is Map, "fresh exact ports can admit a new session after controlled discovery refusal")
	Key := Packet["choices"][1]["key"]
	if Role != "list" {
		; Resolve never invokes list: only its actual native observation ports are
		; injected here, so a missing callback cannot manufacture a passing test.
		Owner.Ports[Role] := Fault
		AssertFalse(Owner.Resolve(Key, []), "arbitrary resolution port exceptions cannot escape closed admission")
		Owner.Ports[Role] := Original
	}
	Retire := Owner.Ports["retire"]
	Owner.Ports["retire"] := Fault
	AssertFalse(Owner.Invalidate(), "arbitrary retirement exceptions remain an explicit cleanup refusal")
	AssertFalse(Owner.Resolve(Key, []), "logical invalidation fences choices while exact cleanup still refuses")
	Owner.Ports["retire"] := Retire
	State["retired"] := false
	AssertFalse(Owner.Invalidate(), "restored native cleanup still requires its actual admitted receipt")
	State["retired"] := true
	AssertTrue(Owner.Invalidate(), "same controlled owner acknowledges only a fresh successful cleanup receipt")
}

_RPP_RawMessage() {
	Good := ProgramProviderMessage('{"providerKey":"1:2","programArguments":["","日本語","\\u0000","line\nnext"]}')
	Assert(Good is Map, "raw page message retains its argument-array source")
	AssertEqual("", Good["arguments"][1], "empty page argument survives")
	AssertEqual("\u0000", Good["arguments"][3], "escaped backslash plus u0000 is an ordinary literal")
	AssertFalse(ProgramProviderMessage('{"providerKey":"1:2\u0000","programArguments":[]}'),
		"native key truncation cannot alias an existing opaque choice")
	AssertFalse(ProgramProviderMessage('{"providerKey":"1:2","programArguments":["a\u0000b"]}'),
		"native argument truncation is rejected by the exact raw scalar span")
	AssertFalse(ProgramProviderMessage('{"providerKey":"1:2","programArguments":[true]}'), "non-string page arguments refuse")
	AssertFalse(ProgramProviderMessage('{"providerKey":"../foreign","programArguments":[]}'), "foreign page keys refuse")
}
Test("program providers: lossless raw page arguments and opaque key rejection", _RPP_RawMessage)

_RPP_PickerRetirement() {
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramPacket, _ActPickWeb_ProgramDebt
	global _ActPickWeb_ProgramCapturing, _ActPickWeb_ProgramRetiring, _ActPickWeb_Confirming
	global _ActPickWeb_OnConfirm, _ActPickWeb_Gui, _ActPickWeb_ResetDone, _ActPickWeb_SessionEpoch
	global _GesturePickedParameter
	AssertEqual(0, _ActPickWeb_Gui, "headless picker controls allocate no native GUI")
	AssertEqual(0, _ActPickWeb_ProgramDebt.Length, "controlled picker starts without foreign discovery debt")
	Saved := Map("owner", _ActPickWeb_ProgramOwner, "packet", _ActPickWeb_ProgramPacket,
		"debt", _ActPickWeb_ProgramDebt, "reset", _ActPickWeb_ResetDone,
		"epoch", _ActPickWeb_SessionEpoch, "callback", _ActPickWeb_OnConfirm, "parameter", _GesturePickedParameter)
	try {
		for Mode in ["false", "throw", "success", "reentry"]
			for Manual in [false, true]
				_RPP_PickerMode(Mode, Manual)
	} finally {
		_ActPickWeb_ProgramOwner := Saved["owner"]
		_ActPickWeb_ProgramPacket := Saved["packet"]
		_ActPickWeb_ProgramDebt := Saved["debt"]
		_ActPickWeb_ResetDone := Saved["reset"]
		_ActPickWeb_SessionEpoch := Saved["epoch"]
		_ActPickWeb_OnConfirm := Saved["callback"]
		_GesturePickedParameter := Saved["parameter"]
		_ActPickWeb_ProgramCapturing := false
		_ActPickWeb_ProgramRetiring := false
		_ActPickWeb_Confirming := false
	}
}
_RPP_PickerMode(Mode, Manual) {
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramDebt, _ActPickWeb_ResetDone
	global _ActPickWeb_OnConfirm, _ActPickWeb_SessionEpoch, _GesturePickedParameter
	State := _RPP_ControlledOwner(), Calls := []
	Retire() {
		global _ActPickWeb_SessionEpoch
		if Mode == "throw"
			throw "private-retirement106"
		if Mode == "reentry" {
			_ActPickWeb_SessionEpoch += 1
			return true
		}
		return Mode == "success"
	}
	State["owner"].Ports["retire"] := Retire
	_ActPickWeb_ProgramOwner := State["owner"]
	_ActPickWeb_ProgramDebt := []
	_ActPickWeb_ResetDone := false
	_ActPickWeb_OnConfirm := Confirm
	Confirm(Id) {
		global _GesturePickedParameter
		Calls.Push(Map("id", Id, "parameter", _GesturePickedParameter))
	}
	_GesturePickedParameter := "sentinel106"
	Scalar := '{"version":1,"executable":"C:\\owned106\\program.exe","arguments":[]}'
	Id := Manual ? "run_program" : "send_text"
	Epoch := _ActPickWeb_SessionEpoch
	Result := _ActPickWeb_Confirm(Id, Manual, Scalar)
	if Mode == "success" {
		AssertTrue(Result, "ordinary confirmation requires actual exact retirement admission")
		AssertEqual(1, Calls.Length, "admitted ordinary confirmation assigns exactly once")
		if Manual {
			Assert(Calls[1]["parameter"] is Map, "manual scalar is offered only inside the admitted assignment")
			AssertEqual(Scalar, Calls[1]["parameter"]["value"], "admitted manual assignment receives exact literal scalar")
		}
	} else {
		AssertFalse(Result, "refusal or session reentry cannot assign an ordinary action")
		AssertEqual(0, Calls.Length, "retirement failure cannot invoke a captured assignment callback")
		AssertEqual("sentinel106", _GesturePickedParameter, "refused manual or ordinary confirmation cannot offer a parameter")
	}
	if Mode != "reentry" {
		AssertTrue(_ActPickWeb_ResetDone, "retirement refusal still tears down the current picker session")
		AssertEqual(Epoch + 1, _ActPickWeb_SessionEpoch, "only that closed session advances its generation")
	}
	if Mode == "false" || Mode == "throw" {
		AssertEqual(1, _ActPickWeb_ProgramDebt.Length, "exact discovery owner remains globally retained after refused confirmation")
		AssertEqual(State["owner"], _ActPickWeb_ProgramDebt[1], "retained picker debt preserves original owner identity")
		State["owner"].Ports["retire"] := (*) => true
		AssertTrue(_ActPickWeb_ProgramRetire(), "fresh retirement ACK closes the same retained owner")
		_ActPickWeb_ResetDone := false
		_ActPickWeb_OnConfirm := (Id) => Calls.Push(Id)
		AssertTrue(_ActPickWeb_Confirm("send_text"), "new session can confirm only after exact debt retirement")
		AssertEqual(1, Calls.Length, "successful retry never resurrects the refused old assignment")
	}
}

Test("program providers: actual picker refusal closes without assigning retained debt", _RPP_PickerRetirement)

; Test resources remain globally reachable if any exact cleanup receipt refuses.
; A directory marker alone is never used as a substitute for native custody.
global _RPP_TestOwners := []

_RPP_TestReserve(Context) {
	global _RPP_TestOwners
	for Pending in _RPP_TestOwners.Clone()
		_RPP_TestRetire(Pending)
	AssertEqual(0, _RPP_TestOwners.Length, "new native fixture cannot displace retained exact cleanup debt")
	Record := Map("context", Context, "native", 0, "owner", 0,
		"process", 0, "job", 0, "protected", 0, "program", false)
	Context["preserve_directory"] := true
	_RPP_TestOwners.Push(Record)
	return Record
}

_RPP_TestRetire(Record) {
	global _RPP_TestOwners
	Native := Record["native"], Owner := Record["owner"]
	Ready := true
	try {
		if Record["protected"] {
			if !DllCall("kernel32\SetHandleInformation", "Ptr", Record["protected"], "UInt", 2, "UInt", 0, "Int")
				Ready := false
			else Record["protected"] := 0
		}
	} catch Any {
		Ready := false
	}
	try {
		if IsObject(Native) && !Native.Retire()
			Ready := false
	} catch Any {
		Ready := false
	}
	try {
		if IsObject(Owner) && !Owner.Invalidate()
			Ready := false
	} catch Any {
		Ready := false
	}
	if Record["program"] || Record["job"] || Record["process"] {
		try {
			if Record["job"] && _SRTOW_ExactJobActiveProcessCount(Record["job"]) != 0
				if !DllCall("kernel32\TerminateJobObject", "Ptr", Record["job"], "UInt", 1, "Int")
					Ready := false
			ProgramActions_Stop(true)
			_RPA_WaitSettled()
			if !ProgramActions_Stop(true)
				Ready := false
		} catch Any {
			Ready := false
		}
	}
	; Do not drop a live group's last duplicate capability or an unsignalled root.
	try {
		if Record["job"] {
			if _SRTOW_ExactJobActiveProcessCount(Record["job"]) != 0
				Ready := false
			else if DllCall("kernel32\CloseHandle", "Ptr", Record["job"], "Int")
				Record["job"] := 0
			else Ready := false
		}
	} catch Any {
		Ready := false
	}
	try {
		if Record["process"] {
			if !_SRTOW_WaitForExactProcessExit(Record["process"])
				Ready := false
			else if DllCall("kernel32\CloseHandle", "Ptr", Record["process"], "Int")
				Record["process"] := 0
			else Ready := false
		}
	} catch Any {
		Ready := false
	}
	if !Ready || Record["job"] || Record["process"] || Record["protected"]
		return false
	for Index, Pending in _RPP_TestOwners
		if Pending == Record {
			_RPP_TestOwners.RemoveAt(Index)
			Record["context"]["preserve_directory"] := false
			return true
		}
	return false
}

_RPP_NativeDebt(Context) {
	global _RPP_TestOwners
	Record := _RPP_TestReserve(Context)
	Native := ProgramProvidersNative((*) => Context["directory"], (*) => "")
	Record["native"] := Native
	AssertTrue(Native.Retire(), "empty actual native inventory begins retired")
	PreviousCritical := Critical("On")
	try {
		Handle := DllCall("kernel32\CreateFileW", "Str", Context["script"], "UInt", 0,
			"UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x00200000, "Ptr", 0, "Ptr")
		if Handle != -1
			Native.Debts.Push(Map("kind", "file", "handle", Handle))
	} finally Critical(PreviousCritical)

	try {
		Assert(Handle != -1, "native close-fault fixture acquires an actual exact file handle")
		Record["protected"] := Handle
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Handle, "UInt", 2, "UInt", 2, "Int"),
			"the actual held handle is protected from close")
		AssertFalse(Native.Retire(), "actual refused CloseHandle does not clear native capability custody")
		AssertEqual(1, Native.Debts.Length, "exact protected native handle remains retained")
		AssertThrows(Native.List.Bind(Native, Context["directory"], 256), "retained close debt prevents successor enumeration")
		AssertEqual(Handle, Native.Debts[1]["handle"], "refused successor work cannot replace the exact original capability")
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Handle, "UInt", 2, "UInt", 0, "Int"),
			"only the exact test-owned protection is removed")
		Record["protected"] := 0
		AssertTrue(Native.Retire(), "later strict native close retires that exact handle")
		AssertEqual(0, Native.Debts.Length, "no numeric handle remains available for accidental reuse")
		PreviousCritical := Critical("On")
		try Record["job"] := DllCall("kernel32\CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
		finally Critical(PreviousCritical)
		Assert(Record["job"] != 0, "observer cleanup control acquires an actual empty native Job")
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Record["job"], "UInt", 2, "UInt", 2, "Int"),
			"the actual observer HANDLE is protected from close")
		AssertFalse(_RPP_TestRetire(Record), "refused observer close retains the exact test registry owner")
		AssertEqual(1, _RPP_TestOwners.Length, "failed observer cleanup remains globally owned across helper return")
		AssertEqual(Record, _RPP_TestOwners[1], "retained global capability is the original observer record")
		Assert(Record["job"] != 0, "refused close does not discard or replace the exact Job HANDLE")
		AssertThrows(_RPP_TestReserve.Bind(Context), "retained observer close debt prevents another fixture acquisition")
		Assert(DllCall("kernel32\SetHandleInformation", "Ptr", Record["job"], "UInt", 2, "UInt", 0, "Int"),
			"only the exact observer protection is removed before retry")

	} finally {
		if Record["job"]
			DllCall("kernel32\SetHandleInformation", "Ptr", Record["job"], "UInt", 2, "UInt", 0, "Int")
		AssertTrue(_RPP_TestRetire(Record), "exact native test registry must acknowledge physical metadata retirement")
	}
}
Test("program providers: actual protected native metadata close retains exact custody", _RPA_WithFixture.Bind(_RPP_NativeDebt))

_RPP_NativeScript(ProviderId, Context, RequiredCommand := "") {
	global GestureActionParameters, ConfigurationFile, _UserProgramEntries, _SR_TreeOwnedTasks
	global _UserProgramPaused
	Scripts := Context["directory"] . "\scripts", Tools := Context["directory"] . "\outils été 日本"
	DirCreate(Scripts), DirCreate(Tools)
	Gate := Context["directory"] . "\provider gate", Output := Context["output"]
	for Old in [Gate, Output]
		if FileExist(Old)
			FileDelete(Old)
	_RPA_ClearProgramLogs(Context)
	_UserProgramPaused := false
	ProcessObserver := 0, JobObserver := 0, NativeState := 0, Native := 0
	Owner := 0
	Record := _RPP_TestReserve(Context)
	Values := ["", "two words", "日本語", "e" . Chr(0x301), "$(literal106)", "%literal106%", "line`nnext", "quote" . Chr(34), "tick" . Chr(96), "semi" . Chr(59)]
	Expected := "10`n0:`n9:74776F20776F726473`n9:E697A5E69CACE8AA9E`n3:65CC81`n"
		. "13:24286C69746572616C31303629`n12:256C69746572616C31303625`n9:6C696E650A6E657874`n"
		. "6:71756F746522`n5:7469636B60`n5:73656D693B`n"
	; These UTF-8 byte counts and hex strings are authored independently. A wrong
	; provider CLI cannot regenerate the expected native receipt from its result.
	Context["preserve_directory"] := true
	try {
		if ProviderId == "autohotkey" {
			AssertFalse(A_IsCompiled, "native provider fixture requires the genuine interpreted runtime")
			if !FileExist(Tools . "\AutoHotkey64.exe")
				FileCopy(A_AhkPath, Tools . "\AutoHotkey64.exe", false)
			Script := Scripts . "\été 日本 fixture.ahk"
			Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
				. 'Result := (A_Args.Length - 2) . Chr(10)`n'
				. 'for Index, Value in A_Args {`n if Index <= 2`n  continue`n'
				. ' BufferBytes := Buffer(StrPut(Value, "UTF-8"))`n'
				. ' Count := StrPut(Value, BufferBytes, "UTF-8") - 1`n Result .= Count . ":"`n'
				. ' loop Count`n  Result .= Format("{:02X}", NumGet(BufferBytes, A_Index - 1, "UChar"))`n'
				. ' Result .= Chr(10)`n}`nFileAppend(Result, A_Args[1], "UTF-8-RAW")`n'
				. 'while !FileExist(A_Args[2])`n Sleep(10)`n'
				. 'FileAppend("private-stdout106", "*")`nFileAppend("private-stderr106", "**")`nExitApp(37)`n'
			Path := Tools
		} else if ProviderId == "python" {
			Script := Scripts . "\été 日本 fixture.py"
			Source := "import os, sys, time`n"
				. "data = [str(len(sys.argv) - 3)]`n"
				. "for value in sys.argv[3:]:`n    raw = value.encode('utf-8')`n    data.append(str(len(raw)) + ':' + raw.hex().upper())`n"
				. "with open(sys.argv[1], 'wb') as f: f.write(('\n'.join(data) + '\n').encode('utf-8'))`n"
				. "while not os.path.exists(sys.argv[2]): time.sleep(0.01)`n"
				. "sys.stdout.write('private-stdout106'); sys.stderr.write('private-stderr106'); sys.exit(37)`n"
			Path := EnvGet("PATH")
		} else {
			Script := Scripts . "\été 日本 fixture.ps1"
			Source := "$utf8 = New-Object System.Text.UTF8Encoding $false`n"
				. "$lines = @([string]($args.Count - 2))`n"
				. "for ($i = 2; $i -lt $args.Count; $i++) {`n"
				. " $raw = $utf8.GetBytes([string]$args[$i])`n"
				. " $lines += [string]$raw.Length + ':' + [BitConverter]::ToString($raw).Replace('-', '')`n}`n"
				. "[IO.File]::WriteAllText($args[0], [string]::Join([char]10, $lines) + [char]10, $utf8)`n"
				. "while (!(Test-Path -LiteralPath $args[1])) { Start-Sleep -Milliseconds 10 }`n"
				. "[Console]::Out.Write('private-stdout106'); [Console]::Error.Write('private-stderr106'); exit 37`n"
			Path := EnvGet("PATH")
		}
		if FileExist(Script)
			FileDelete(Script)
		FileAppend(Source, Script, "UTF-8")
		Native := ProgramProvidersNative((*) => Scripts, (*) => Path)
		Record["native"] := Native
		Ports := Native.Ports()
		if RequiredCommand != "" {
			Select(Commands, Id) {
				return Native.Interpreter(Id == ProviderId ? [RequiredCommand] : Commands, Id)
			}
			Ports["interpreter"] := Select
		}
		Owner := ProgramProviderSession(_RPP_Catalogue(), Ports)
		Record["owner"] := Owner
		Packet := Owner.Discover()
		Assert(Packet is Map, "actual Win32 enumeration produces a bounded public packet")
		Key := ""
		for Choice in Packet["choices"]
			if Choice["provider"] == ProviderId
				Key := Choice["key"]
		Assert(Key != "", "actual installed provider discovers its independently authored fixture script")
		AssertEqual(0, Native.Debts.Length, "discovery leaves no unacknowledged native enumeration or file handles")
		Args := [Output, Gate]
		for Value in Values
			Args.Push(Value)
		Scalar := Owner.Resolve(Key, Args)
		Assert(Scalar is String, "exact still-current native choice lowers to the existing literal scalar")
		Parsed := ProgramParameterParse(Scalar)
		Assert(Parsed is Map, "lowered native provider is accepted by the qualified decoder")
		if ProviderId == "autohotkey"
			AssertEqual(Tools . "\AutoHotkey64.exe", Parsed["executable"], "PATH resolution admits the owned Unicode/spaced actual interpreter")
		GestureActionParameters := Map("gesture__tap_3__run_program", Scalar)
		FileDelete(ConfigurationFile)
		FileAppend('[gestures]`ntap_3 = "run_program"`n[action_parameters]`n"gesture__tap_3__run_program" = '
			. JsonStringLiteral(Scalar) . '`n', ConfigurationFile, "UTF-8")
		Record["program"] := true
		AssertTrue(ProgramActions_Run("gesture__tap_3"), "real provider script starts through the actual canonical action owner")
		Entry := _UserProgramEntries["gesture__tap_3"]
		PreviousCritical := Critical("On")
		try {
			Pid := Entry["handle"].processId()
			for _, State in _SR_TreeOwnedTasks
				if State["Pid"] == Pid {
					NativeState := State
					break
				}
			Assert(NativeState is Map, "fixture retains only the exact live program owner")
			ProcessObserver := _SRTOW_OpenExactProcess(Pid)
			Record["process"] := ProcessObserver
			JobObserver := _SRTOW_DuplicateNativeHandle(NativeState["JobHandle"])
			Record["job"] := JobObserver
		} finally Critical(PreviousCritical)
		Assert(ProcessObserver && JobObserver, "exact process and duplicate Job stay retained before opening the fixture gate")
		AssertFalse(NativeState["CaptureOutput"], "actual provider streams are physically discarded")
		AssertTrue(NativeState["PrivateDiagnostics"], "actual provider diagnostics use closed native status")
		Deadline := A_TickCount + 5000
		while !FileExist(Output) && A_TickCount < Deadline
			Sleep(10)
		Assert(FileExist(Output) != "", "actual independently authored script records its own argv")
		AssertEqual(Expected, FSReadUtf8Exact(Output), "native provider CLI preserves every independent literal UTF-8 byte vector")
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(ProcessObserver), "receipt alone cannot retire the gated actual child")
		FileAppend("release", Gate, "UTF-8-RAW")
		_RPA_WaitSettled()
		Assert(_SRTOW_WaitForExactProcessExit(ProcessObserver), "exact native process HANDLE signals before completion")
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(JobObserver), "duplicate actual Job proves original group quiescence")
		AssertEqual(0, NativeState["ProcessHandle"], "actual process capability is retired")
		AssertEqual(0, NativeState["JobHandle"], "actual Job capability is retired")
		Lines := _RPA_ProgramDiagnostics(Context)
		AssertEqual(1, Lines.Length, "real provider nonzero completion emits one closed diagnostic")
		AssertContains(Lines[1], "User program exited with status 37.", "actual provider retains exact nonzero exit status")
		for Line in Context["logs"] {
			AssertFalse(InStr(Line, Script, true), "provider diagnostics never reveal the selected script path")
			AssertFalse(InStr(Line, Parsed["executable"], true), "provider diagnostics never reveal the selected interpreter path")
		}
		AssertTrue(Owner.Invalidate(), "exact native inventory closes without private capability debt")
	} finally {
		CleanupReceipt := _RPP_TestRetire(Record)
		ProcessClosed := Record["process"] == 0
		JobClosed := Record["job"] == 0
		Assert(ProcessClosed, "exact process observer closes")
		Assert(JobClosed, "exact duplicate Job observer closes")
		AssertTrue(CleanupReceipt, "all exact native fixture capabilities retire before directory cleanup")
	}
}
_RPP_NativeVariants(ProviderId, Context) {
	if ProviderId == "autohotkey"
		return _RPP_NativeScript(ProviderId, Context)
	; Every present fallback is independently invoked through actual policy/Job
	; ownership. A preferred tool never qualifies another executable's argv ABI.
	Providers := ProgramProviderCatalogue(_RPP_Catalogue()), Commands := []
	for Provider in Providers
		if Provider["id"] == ProviderId
			Commands := Provider["commands"]["ahk"].Clone()
	Assert(Commands.Length > 0, "native CLI variants come only from the canonical shared catalogue")
	Native := ProgramProvidersNative((*) => Context["directory"] . "\scripts")
	Record := _RPP_TestReserve(Context)
	Record["native"] := Native
	Present := []
	try {
		for Command in Commands {
			Target := Native.Interpreter([Command], ProviderId)
			if Target is Map
				Present.Push(Command)
			else AssertFalse(Target, "missing CLI variant is an explicit native absence receipt")
		}
		Assert(Present.Length > 0, "at least one real installed provider is required; no fake or skipped invocation")
	} finally AssertTrue(_RPP_TestRetire(Record), "variant eligibility handles retire before actual child allocation")
	for Command in Present
		_RPP_NativeScript(ProviderId, Context, Command)
}
for ProviderId in ["autohotkey", "python", "powershell"]
	Test("program providers: real installed " . ProviderId . " script argv and exact Job retirement",
		_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPP_NativeVariants.Bind(ProviderId))))

#Include test_program_picker_modal_owner.ahk
