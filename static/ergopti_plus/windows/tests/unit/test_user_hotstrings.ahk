; tests/unit/test_user_hotstrings.ahk

; ==============================================================================
; MODULE: Programmable Hotstring Owner and Native Worker Tests
; DESCRIPTION:
; Independent ownership receipts verify callback fencing and result semantics.
; Real isolated workers verify the packaged runtime and exact source snapshots.
; ==============================================================================

class _UCHFixture {
	__New() {
		this.source := "A", this.destination := "edit1", this.input := 1
		this.calls := 0, this.nativeChecks := 0, this.output := [], this.errors := [], this.tasks := []
		this.cancelAck := true
		this.owner := UserHotstringOwner(Map("capture", ObjBindMethod(this, "Capture"),
			"current", ObjBindMethod(this, "Current"), "invoke", ObjBindMethod(this, "Invoke"),
			"commit", ObjBindMethod(this, "Commit"), "report", ObjBindMethod(this, "Report")))
		this.rule := Map("id", "clock", "suffix", "@clock", "preview", "Current time",
			"callback", (*) => "12:34")
		Assert(this.owner.Reload([this.rule], Map("path", "personal.ahk", "present", true, "content", "A")))
		Assert(this.owner.SetEnabled(true))
	}
	Capture(Rule) {
		return Map("destination", this.destination, "input", this.input)
	}
	Current(Capture, Source) {
		this.nativeChecks += 1
		return Source["content"] == this.source && Capture["destination"] == this.destination
			&& Capture["input"] == this.input
	}
	Invoke(Rule, Context, Done, Capture) {
		Task := _UCHTask(this, Rule, Context, Done)
		this.tasks.Push(Task)
		return Task
	}
	Commit(Result, Capture, Rule) {
		this.output.Push(Result)
		return true
	}
	Report(Kind, Id) {
		this.errors.Push(Kind . ":" . Id)
		return true
	}
}

class _UCHTask {
	__New(Fixture, Rule, Context, Done) {
		this.fixture := Fixture, this.rule := Rule, this.context := Context, this.done := Done
		this.cancelled := false, this.started := false
	}
	start() {
		this.started := true
		return true
	}
	cancel() {
		this.cancelled := true
		return this.fixture.cancelAck
	}
	Run() {
		if this.cancelled || this.context["cancelled"].Call()
			return this.done.Call(false)
		this.fixture.calls += 1
		return this.done.Call(this.rule["callback"].Call(this.context))
	}
}

_UCHPreviewPure() {
	Fixture := _UCHFixture()
	Preview := Fixture.owner.Preview("prefix@clock")
	AssertEqual("Current time", Preview["preview"])
	AssertEqual(0, Fixture.calls)
	AssertEqual(0, Fixture.nativeChecks, "Preview must not probe native owners or execute callbacks")
	Assert(Fixture.owner.Request("@clock"))
	AssertEqual(0, Fixture.calls, "Admission only schedules native work")
	AssertEqual(0, Fixture.nativeChecks, "Keyboard admission must remain RAM-only")
	Fixture.tasks[1].Run()
	AssertEqual("12:34", Fixture.output[1])
}
Test("programmable hotstrings: metadata preview and admission never execute callbacks", _UCHPreviewPure)

_UCHFenceReceipts() {
	for Dimension in ["source", "destination", "input"] {
		Fixture := _UCHFixture()
		Assert(Fixture.owner.Request("@clock"))
		Fixture.%Dimension% := Dimension == "input" ? 2 : "B"
		Fixture.tasks[1].Run()
		AssertEqual(0, Fixture.calls, "Stale receipt must prevent callback execution")
		AssertEqual(0, Fixture.output.Length)
	}
	Fixture := _UCHFixture()
	Fixture.rule["callback"] := (Context) => (Fixture.input += 1, "too late")
	Assert(Fixture.owner.Reload([Fixture.rule], Map("path", "personal.ahk", "present", true, "content", "A")))
	Assert(Fixture.owner.Request("@clock"))
	Fixture.tasks[1].Run()
	AssertEqual(1, Fixture.calls)
	AssertEqual(0, Fixture.output.Length, "Late cancellation must fence driver output")
}
Test("programmable hotstrings: source, destination and input receipts fence callbacks and output", _UCHFenceReceipts)

_UCHReturnResult(Result, *) {
	return Result
}

_UCHResultsAndLifecycle() {
	for Result in [true, false, "0", "été`n世界"] {
		Fixture := _UCHFixture()
		Fixture.rule["callback"] := _UCHReturnResult.Bind(Result)
		Assert(Fixture.owner.Reload([Fixture.rule], Map("path", "personal.ahk", "present", true, "content", "A")))
		Assert(Fixture.owner.Request("@clock"))
		Fixture.tasks[1].Run()
		AssertEqual(Type(Result), Type(Fixture.output[1]), "Do not coerce action/cancel into text")
		AssertEqual(Result, Fixture.output[1])
	}
	Fixture := _UCHFixture()
	Assert(Fixture.owner.Request("@clock"))
	Fixture.cancelAck := false
	AssertEqual(false, Fixture.owner.SetEnabled(false))
	Assert(Fixture.owner.debt.Length > 0)
	AssertEqual(false, Fixture.owner.Request("@clock"))
	Fixture.cancelAck := true
	Assert(Fixture.owner.Invalidate("retry"))
	Assert(Fixture.owner.SetEnabled(true))
	Assert(Fixture.owner.Stop())
	AssertEqual(false, Fixture.owner.SetEnabled(true))
	AssertEqual(0, Fixture.calls)
}
Test("programmable hotstrings: typed results, cancellation debt and permanent shutdown", _UCHResultsAndLifecycle)

_UCHMissingSourceAndQuarantine() {
	Fixture := _UCHFixture()
	Assert(Fixture.owner.Request("@clock"))
	Fixture.cancelAck := false
	AssertFalse(Fixture.owner.RefuseSource("source-unreadable"))
	AssertFalse(Fixture.owner.enabled)
	AssertFalse(Fixture.owner.ready)
	AssertEqual(1, Fixture.owner.Count(), "refused source retains quarantined metadata")
	Assert(Fixture.owner.debt.Length > 0, "quarantine retains exact cancellation debt")
	AssertFalse(Fixture.owner.Request("@clock"))
	Fixture.cancelAck := true
	Assert(Fixture.owner.RefuseSource("source-retry"))
	AssertEqual(0, Fixture.owner.debt.Length)
	AssertFalse(Fixture.owner.Reload([], Map("path", "personal.ahk", "present", false, "content", "")),
		"a missing source is not an admitted empty factory")
	AssertFalse(Fixture.owner.enabled)
	AssertFalse(Fixture.owner.ready)
	AssertEqual(1, Fixture.owner.Count())
	Assert(Fixture.owner.Reload([], Map("path", "personal.ahk", "present", true, "content", "valid empty factory")))
	Assert(Fixture.owner.SetEnabled(true))
	AssertTrue(Fixture.owner.ready)
	AssertEqual(0, Fixture.owner.Count(), "a present valid empty factory remains a successful publication")
	AssertEqual(0, Fixture.calls, "closing or admitting metadata never executes callbacks")
}
Test("programmable hotstrings: absent source admission differs from empty factory and retains quarantine debt", _UCHMissingSourceAndQuarantine)

_UCHProtocolStrict() {
	for Text in ["0", "été`n世界", "😀", "quote`tvalue"]
		AssertEqual(Text, UserCodeDecode(UserCodeEncode(Text)))
	AssertEqual("0", _UserHotstringsParseResult("ERGOPTI_USER_HOTSTRINGS_V1`nTEXT`t30`nEND"))
	AssertEqual(true, _UserHotstringsParseResult("ERGOPTI_USER_HOTSTRINGS_V1`nACTION`nEND"))
	AssertEqual(false, _UserHotstringsParseResult("ERGOPTI_USER_HOTSTRINGS_V1`nCANCEL`nEND"))
	for Encoded in ["00", "c080", "ff", "30A0"] {
		Refused := false
		try UserCodeDecode(Encoded)
		catch
			Refused := true
		Assert(Refused, "Noncanonical UTF-8 transport must be refused")
	}
}
Test("programmable hotstrings: isolated result framing preserves exact UTF-8 and Boolean types", _UCHProtocolStrict)


/** Selects actual installed include roots only for an explicit compiled probe. */
_UCHPackageRoots() {
	global _SharedDir, _VendorDir
	Saved := Map("shared", _SharedDir, "vendor", _VendorDir)
	PackageRoot := EnvGet("ERGOPTI_USER_HOTSTRINGS_PACKAGE_ROOT")
	if PackageRoot != "" {
		; The bundle preserves shared static paths and relocates Windows vendor
		; sources to vendor/, exactly as the production compiled boot owner does.
		Shared := PackageRoot . "\static\ergopti_plus\_shared", Vendor := PackageRoot . "\vendor"
		Assert(FSStrictExists(Shared . "\modules\hotstrings\user_code.ahk"), "Packaged shared policy must be installed")
		Assert(FSStrictExists(Vendor . "\ergopti_user_hotstrings.ahk"), "Packaged worker source must be installed")
		_SharedDir := Shared, _VendorDir := Vendor
	}
	return Saved
}

_UCHRestorePackageRoots(Saved) {
	global _SharedDir, _VendorDir
	_SharedDir := Saved["shared"], _VendorDir := Saved["vendor"]
}

_UCHRealWorker() {
	global _ConfigDir, _UserHotstringsJobs
	PreviousConfigDir := _ConfigDir
	PackageRoots := _UCHPackageRoots()
	Directory := A_Temp . "\ergopti_user_code_fixture_" . DllCall("GetCurrentProcessId") . "_" . Random(1, 0x7fffffff)
	DirCreate(Directory)
	_ConfigDir := Directory . "\"
	Path := UserHotstringsSourcePath()
	Source := 'ErgoptiDynamicHotstrings(api) {`n`treturn [Map("id", "clock", "suffix", "@clock", "preview", "Time", "callback", (ctx) => ctx["cancelled"].Call() ? false : "été 世界")]`n}`n'
	Workers := []
	try {
		Assert(FSWriteCreateDurable(Path, Source))
		Receipt := _UserHotstringsReadSource()
		Results := []
		Done(Code, Out, Err) => Results.Push(Map("code", Code, "out", Out))
		Loader := UserHotstringWorker(Receipt, "load", "", Done)
		Workers.Push(Loader)
		Assert(Loader.start())
		Started := A_TickCount
		while !Results.Length && TickElapsed(Started) < 10000
			Sleep(10)
		AssertEqual(1, Results.Length, "Real metadata worker must complete")
		AssertEqual(0, Results[1]["code"], "Real packaged interpreter must run /script worker")
		Rules := _UserHotstringsParseMetadata(Results[1]["out"])
		AssertEqual("Time", Rules[1]["preview"])
		Runner := UserHotstringWorker(Receipt, "execute", "clock", Done, 0, "@clock", "Time")
		Workers.Push(Runner)
		Assert(Runner.start())
		Started := A_TickCount
		while Results.Length < 2 && TickElapsed(Started) < 10000
			Sleep(10)
		AssertEqual(2, Results.Length, "Real callback worker must complete")
		AssertEqual(0, Results[2]["code"])
		AssertEqual("été 世界", _UserHotstringsParseResult(Results[2]["out"]))
		AssertEqual(Source, FSReadUtf8Exact(Path), "User source must remain byte-equivalent")
	} finally {
		for Worker in Workers
			Assert(Worker.cancel(), "Every real child tree and stage must retire")
		_ConfigDir := PreviousConfigDir
		_UCHRestorePackageRoots(PackageRoots)
		FSDelete(Path)
		DirDelete(Directory)
	}
}
Test("programmable hotstrings: real Windows worker loads metadata and executes Unicode callback", _UCHRealWorker)

_UCHRealTypedCallbacks() {
	global _ConfigDir
	PreviousConfigDir := _ConfigDir, PackageRoots := _UCHPackageRoots()
	Directory := A_Temp . "\ergopti_user_results_" . DllCall("GetCurrentProcessId") . "_" . Random(1, 0x7fffffff)
	Assert(DllCall("CreateDirectoryW", "Str", Directory, "Ptr", 0))
	_ConfigDir := Directory . "\"
	Path := UserHotstringsSourcePath(), Marker := Directory . "\callback-called.txt", Workers := [], Results := []
	Done(Code, Out, Err) => Results.Push(Map("code", Code, "out", Out))
	try {
		for ResultCase in [Map("expression", "true", "value", true), Map("expression", "false", "value", false),
			Map("expression", '"0"', "value", "0"), Map("expression", '"été``n世界"', "value", "été`n世界")] {
			Source := 'ErgoptiDynamicHotstrings(api) {`n`treturn [Map("id", "typed", "suffix", "@typed", "preview", "Static", "callback", UserTyped)]`n}`n'
				. 'UserTyped(context) {`n`tFileAppend("called", "' . Marker . '", "UTF-8-RAW")`n`treturn '
					. ResultCase["expression"] . '`n}`n'
			Assert(FSWriteDurable(Path, Source))
			Worker := UserHotstringWorker(_UserHotstringsReadSource(), "execute", "typed", Done, 0, "@typed", "Static")
			Workers.Push(Worker), Before := Results.Length
			Assert(Worker.start())
			Started := A_TickCount
			while Results.Length == Before && TickElapsed(Started) < 10000
				Sleep(10)
			AssertEqual(Before + 1, Results.Length, "the real typed callback must complete")
			AssertEqual(0, Results[-1]["code"])
			Parsed := _UserHotstringsParseResult(Results[-1]["out"])
			AssertEqual(Type(ResultCase["value"]), Type(Parsed), "the real worker preserves result type")
			AssertEqual(ResultCase["value"], Parsed)
			AssertEqual("called", FSReadUtf8Exact(Marker), "arbitrary user callback actions really execute")
			if !(Parsed is String)
				AssertTrue(_UserHotstringsCommit(Parsed, Map(), Map()),
					"action and cancellation acknowledge without needing any text destination or mutation")
			Assert(FSDelete(Marker))
			AssertEqual(Source, FSReadUtf8Exact(Path))
		}
	} finally {
		for Worker in Workers
			Assert(Worker.cancel())
		FSDelete(Path), FSDelete(Marker)
		_ConfigDir := PreviousConfigDir
		_UCHRestorePackageRoots(PackageRoots)
		DirDelete(Directory)
	}
}
Test("programmable hotstrings: real callbacks own actions and preserve true false zero and multiline text", _UCHRealTypedCallbacks)


/** Publishes a descendant PID only after its exclusive writer has closed. */
_UCHFixtureChildSource(PidPath) {
	PendingPath := PidPath . ".pending"
	; FileAppend holds an exclusive native file handle. A same-volume rename
	; cannot succeed until that writer has physically closed; no overwrite is allowed.
	return 'FileAppend(DllCall("GetCurrentProcessId"), "' . PendingPath . '", "UTF-8-RAW")`n'
		. 'FileMove("' . PendingPath . '", "' . PidPath . '", false)`nSleep(10000)`n'
}

/** Refuses a read failure before any scalar conversion or process observation. */
_UCHReadFixturePid(PidPath) {
	Content := FSReadUtf8ExactBounded(PidPath, 10)
	if !(Content is String) || !RegExMatch(Content, "\A[1-9][0-9]{0,9}\z")
		throw Error("Fixture PID receipt is not a canonical positive DWORD.")
	Pid := Integer(Content)
	if Pid > 0xFFFFFFFF
		throw Error("Fixture PID receipt exceeds the native DWORD range.")
	return Pid
}


_UCHRealCancellationAndErrors() {
	global _ConfigDir
	PreviousConfigDir := _ConfigDir
	PackageRoots := 0
	Directory := A_Temp . "\ergopti_user_code_cancel_" . DllCall("GetCurrentProcessId") . "_" . Random(1, 0x7fffffff)
	Assert(FSCreateDirectoryExclusiveStrict(Directory), "Fixture namespace must be exclusively created")
	_ConfigDir := Directory . "\"
	Path := UserHotstringsSourcePath(), ChildPath := Directory . "\child.ahk", PidPath := Directory . "\child.pid"
	Workers := []
	try {
		PackageRoots := _UCHPackageRoots()
		ChildSource := _UCHFixtureChildSource(PidPath)
		Assert(FSWriteCreateDurable(ChildPath, ChildSource))
		Source := 'ErgoptiDynamicHotstrings(api) {`n`treturn [Map("id", "wait", "suffix", "@wait", "preview", "Wait", "callback", UserWait)]`n}`n'
			. 'UserWait(context) {`n`tRun(Chr(34) . A_AhkPath . Chr(34) . " /script " . Chr(34) . "' . ChildPath . '" . Chr(34))`n`tSleep(10000)`n`treturn "late"`n}`n'
		Assert(FSWriteCreateDurable(Path, Source))
		Completed := []
		Done(Code, Out, Err) => Completed.Push(Code)
		Worker := UserHotstringWorker(_UserHotstringsReadSource(), "execute", "wait", Done, 0, "@wait", "Wait")
		Workers.Push(Worker)
		Assert(Worker.start())
		Started := A_TickCount
		while !FSStrictExists(PidPath) && TickElapsed(Started) < 10000
			Sleep(10)
		Assert(FSStrictExists(PidPath), "Real callback must launch its fixture descendant")
		ChildPid := _UCHReadFixturePid(PidPath)
		Assert(ProcessExist(ChildPid), "Descendant is running before native cancellation")
		Assert(Worker.cancel(), "Cancellation must confirm the whole exact native Job is quiescent")
		AssertEqual(0, ProcessExist(ChildPid), "Cancellation must retire the callback's descendant")
		AssertEqual(0, Completed.Length, "Cancelled workers must never publish their completion")
		AssertEqual(Source, FSReadUtf8Exact(Path))
		Assert(FSDelete(Path))
		PrivateSource := 'ErgoptiDynamicHotstrings(api) {`n`tthrow Error("private user secret")`n}`n'
		Assert(FSWriteCreateDurable(Path, PrivateSource))
		Failures := []
		FailDone(Code, Out, Err) => Failures.Push(Map("code", Code, "out", Out, "err", Err))
		Failing := UserHotstringWorker(_UserHotstringsReadSource(), "load", "", FailDone)
		Workers.Push(Failing)
		Assert(Failing.start())
		Started := A_TickCount
		while !Failures.Length && TickElapsed(Started) < 10000
			Sleep(10)
		AssertEqual(1, Failures.Length)
		Assert(Failures[1]["code"] != 0, "Real factory failure must be visible to the loader")
		AssertEqual(false, InStr(Failures[1]["out"] . Failures[1]["err"], "private user secret") > 0,
			"Private user exception contents must never cross the diagnostic transport")
	} finally {
		for Worker in Workers
			Assert(Worker.cancel(), "Every process/stage owner must retire before fixture teardown")
		_ConfigDir := PreviousConfigDir
		if IsObject(PackageRoots)
			_UCHRestorePackageRoots(PackageRoots)
		for FixturePath in [Path, ChildPath, PidPath, PidPath . ".pending"]
			FSDelete(FixturePath)
		DirDelete(Directory)
	}
}
Test("programmable hotstrings: real worker cancels descendants and withholds private source errors", _UCHRealCancellationAndErrors)


_UCHCanonicalPreviewPriority() {
	global _UserHotstringsOwner, Features, HSE_Buffer, HSE_StartIsWordBoundary
	global ScriptInformation, LastSentCharacterKeyTime
	PreviousOwner := _UserHotstringsOwner, PreviousFeatures := Features
	PreviousTiming := LastSentCharacterKeyTime
	Saved := _NRP_Setup()
	Fixture := _UCHFixture()
	_UserHotstringsOwner := Fixture.owner
	Features := Map("hotstrings", Map("dynamic", Map("user_code", Map("enabled", true, "time_activation_seconds", 0))))
	MK := ScriptInformation["MagicKey"]
	try {
		HSE_Buffer := "@clock", HSE_StartIsWordBoundary := true
		Decision := HSE_PreviewNextDecision(HSE_Buffer, MK)
		Assert(IsObject(Decision))
		AssertEqual("Current time", Decision.Replacement)
		Assert(Decision.HasOwnProp("UserCodeGeneration"))
		AssertEqual(0, Fixture.calls, "Canonical static preview must never invoke user callbacks")
		AssertEqual(0, Fixture.nativeChecks, "Canonical preview must never read source/focus ports")
		HSE_Register("*?", "@clock" . MK, 0, Map("Replacement", "ordinary"))
		Decision := HSE_PreviewNextDecision(HSE_Buffer, MK)
		AssertEqual("ordinary", Decision.Replacement, "Registered mapping must keep its established precedence")
		HSE_RegistryClear()
		HSE_Register("*?", "@clock" . MK, 0,
			Map("Replacement", "expired ordinary", "TimeActivationSeconds", 0.5))
		LastSentCharacterKeyTime := Map("k", A_TickCount - 10000)
		AssertEqual("", HSE_PreviewNextDecision(HSE_Buffer, MK),
			"A gated registered mapping still blocks the user fallback; preview must agree")
		AssertEqual(0, Fixture.calls)
	} finally {
		_UserHotstringsOwner := PreviousOwner
		Features := PreviousFeatures
		LastSentCharacterKeyTime := PreviousTiming
		_NRP_Teardown(Saved)
	}
}
Test("programmable hotstrings: canonical preview keeps builtin and declined-builtin priority", _UCHCanonicalPreviewPriority)


_UCHDisableCancelsFactory() {
	global _ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs
	PreviousConfigDir := _ConfigDir, PreviousOwner := _UserHotstringsOwner, PreviousLoader := _UserHotstringsLoader
	PackageRoots := 0
	Directory := A_Temp . "\ergopti_user_factory_cancel_" . DllCall("GetCurrentProcessId") . "_" . Random(1, 0x7fffffff)
	Assert(FSCreateDirectoryExclusiveStrict(Directory), "Fixture namespace must be exclusively created")
	_ConfigDir := Directory . "\"
	Path := UserHotstringsSourcePath(), ChildPath := Directory . "\child.ahk", PidPath := Directory . "\child.pid"
	Fixture := _UCHFixture()
	_UserHotstringsOwner := Fixture.owner
	try {
		PackageRoots := _UCHPackageRoots()
		Assert(UserHotstringsSetEnabled(false))
		Assert(FSWriteCreateDurable(ChildPath, _UCHFixtureChildSource(PidPath)))
		Source := 'ErgoptiDynamicHotstrings(api) {`n`tRun(Chr(34) . A_AhkPath . Chr(34) . " /script " . Chr(34) . "' . ChildPath . '" . Chr(34))`n`tSleep(10000)`n`treturn []`n}`n'
		Assert(FSWriteCreateDurable(Path, Source))
		Assert(UserHotstringsSetEnabled(true), "Explicit enable must start the actual source loader")
		Started := A_TickCount
		while !FSStrictExists(PidPath) && TickElapsed(Started) < 10000
			Sleep(10)
		Assert(FSStrictExists(PidPath), "Real loading factory must launch its fixture descendant")
		Pid := _UCHReadFixturePid(PidPath)
		Assert(ProcessExist(Pid))
		Assert(UserHotstringsSetEnabled(false), "Live disable must own factory cancellation, not only callback tickets")
		AssertEqual(0, ProcessExist(Pid), "Successful disable must leave no factory descendant alive")
		AssertEqual(0, _UserHotstringsJobs.Count)
		AssertEqual(false, _UserHotstringsOwner.enabled)
		AssertEqual(false, _UserHotstringsOwner.ready)
		AssertEqual(Source, FSReadUtf8Exact(Path))
	} finally {
		Assert(UserHotstringsInvalidate("fixture-cleanup"))
		_ConfigDir := PreviousConfigDir, _UserHotstringsOwner := PreviousOwner, _UserHotstringsLoader := PreviousLoader
		if IsObject(PackageRoots)
			_UCHRestorePackageRoots(PackageRoots)
		for FixturePath in [Path, ChildPath, PidPath, PidPath . ".pending"]
			FSDelete(FixturePath)
		DirDelete(Directory)
	}
}
Test("programmable hotstrings: real live disable cancels a loading factory and its descendants", _UCHDisableCancelsFactory)

_UCHDeferredPublicationFences() {
	global _THTO_Runner, _THTO_Payloads, _THTO_NativeState
	for Dimension in ["source", "control", "enable", "generation"] {
		_THTO_Reset()
		Receipt := Map("source", "A", "control", "edit1", "enable", true, "generation", 7)
		Owner := _THTO_MakeOwner()
		Owner["PublicationCurrent"] := () => Receipt["source"] == "A" && Receipt["control"] == "edit1"
			&& Receipt["enable"] && Receipt["generation"] == 7
		Assert(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
		Receipt[Dimension] := Dimension == "enable" ? false : (Dimension == "generation" ? 8 : "B")
		AssertEqual(false, _THTO_Runner.Call())
		AssertEqual(0, _THTO_Payloads.Length, "Deferred native sender must retain the original programmable publication owner")
		AssertEqual(1, _THTO_NativeState["AbortCalls"].Length)
		AssertEqual(false, _THTO_NativeState["Capturing"])
	}
	_THTO_Reset()
	Receipt := Map("current", true)
	Owner := _THTO_MakeOwner()
	Owner["PublicationCurrent"] := () => Receipt["current"]
	Owner["DelayFn"] := (Delay, Duration) => (Receipt["current"] := false, true)
	Assert(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	AssertEqual(false, _THTO_Runner.Call())
	AssertEqual(0, _THTO_Payloads.Length, "Recheck at the actual sender after the native key-delay boundary")
	OutputHostResolverConfigure()
}
Test("programmable hotstrings: actual deferred terminal owner fences source control enable and late publication", _UCHDeferredPublicationFences)

_UCHNativeMenuProjection() {
	_HSCS_WithDynamicBootState(Project)
	Project() {
		global _ConfigDir, _UserHotstringsOwner
		SavedDirectory := _ConfigDir, SavedOwner := _UserHotstringsOwner
		Directory := A_Temp . "\ergopti_user_menu_" . A_TickCount . "_" . Random(1, 999999)
		Assert(DllCall("CreateDirectoryW", "Str", Directory, "Ptr", 0))
		_ConfigDir := Directory . "\"
		Fixture := _UCHFixture(), _UserHotstringsOwner := Fixture.owner
		Root := _MR_GetManifestRoot(), Original := Root["programmable_hotstrings"]
		try {
			AssertFalse(FSStrictExists(UserHotstringsSourcePath()), "menu projection must not create personal source")
			Declarations := _MR_GetMenuDef("programmable_hotstrings")
			Rows := _HS_ProgrammableHotstringRows()
			AssertEqual(4, Rows.Length)
			AssertEqual(t("menu.hotstrings.user_code.title") . " (1)", Rows[1]["label"])
			AssertFalse(Rows[1]["checked"], "the canonical shipped request remains disabled")
			AssertEqual(0, Fixture.calls, "native row projection reads static metadata only")
			Root["programmable_hotstrings"] := [Declarations[4], Declarations[2], Declarations[1], Declarations[3]]
			Reordered := _HS_ProgrammableHotstringRows()
			AssertEqual(t("menu.hotstrings.user_code.create_example"), Reordered[1]["label"],
				"shared declaration order drives the actual native projection")
			AssertFalse(Reordered[2]["action"].Call(), "opening absent source must not create or execute it")
			AssertFalse(FSStrictExists(UserHotstringsSourcePath()))
			AssertTrue(Reordered[1]["action"].Call(), "the explicit declared example command creates source")
			Bytes := FSReadUtf8Exact(UserHotstringsSourcePath())
			Assert(Bytes is String && InStr(Bytes, "ErgoptiDynamicHotstrings(api)"))
			AssertEqual(Chr(0xFEFF), SubStr(Bytes, 1, 1), "the explicit AHK example uses UTF-8 with BOM")
			AssertFalse(Reordered[1]["action"].Call(), "a second explicit create refuses an existing file")
			AssertEqual(Bytes, FSReadUtf8Exact(UserHotstringsSourcePath()), "an existing personal source is byte-preserved")
			AssertEqual(0, Fixture.calls, "creation never loads or calls the example")
		} finally {
			Root["programmable_hotstrings"] := Original
			FSDelete(UserHotstringsSourcePath())
			_ConfigDir := SavedDirectory, _UserHotstringsOwner := SavedOwner
			DirDelete(Directory)
		}
	}
}
Test("programmable hotstrings: actual native menu projects shared order and owns explicit create only", _UCHNativeMenuProjection)

_UCHNativePreferences() {
	_HSCS_WithDynamicBootState(Preferences)
	Preferences() {
		global Features, _ConfigDir, ConfigurationFile, CategoryEnabled
		global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch
		global _UserHotstringsLastRepair, _UserHotstringsRepairPending
		Saved := [_ConfigDir, ConfigurationFile, _UserHotstringsOwner, _UserHotstringsLoader, CategoryEnabled,
			_UserHotstringsLoadEpoch, _UserHotstringsLastRepair, _UserHotstringsRepairPending]
		State := MasterGateState(), SavedState := State.Clone()
		Fixture := _ScopeOwnerFixture(), SourcePath := Fixture.directory . "\personal_dynamic_hotstrings.ahk"
		Sentinel := Fixture.directory . "\factory-ran.txt"
		try {
			State["initialized"] := false
			; Keep the real classified error receipt without opening a modal repair
			; prompt inside the native harness. Production offers the same action.
			_UserHotstringsRepairPending := true
			_ConfigDir := Fixture.directory . "\", ConfigurationFile := Fixture.path
			CategoryEnabled := Map("Hotstrings", true)
			Node := Features["hotstrings"]["dynamic"]["user_code"]
			AssertFalse(Node["enabled"], "canonical boot preference is off")
			Node["time_activation_seconds"] := 0.75
			Config := '[hotstrings.dynamic.user_code]`nenabled = false`ntime_activation_seconds = 0.75`n'
				. '[private]`ncredential = "retain-user-code-preferences"`n'
			Assert(FSWriteDurable(Fixture.path, Config))
			Source := 'ErgoptiDynamicHotstrings(api) {`n`tFileAppend("unexpected", "' . Sentinel
				. '", "UTF-8-RAW")`n`treturn []`n}`n'
			Assert(FSWriteCreateDurable(SourcePath, Source))
			_UserHotstringsOwner := 0
			Assert(UserHotstringsInit(), "actual boot initialization accepts the default-off source")
			Sleep(50)
			AssertFalse(FSStrictExists(Sentinel), "default-off boot never executes an existing factory")
			AssertFalse(_UserHotstringsOwner.enabled)
			AssertEqual(Source, FSReadUtf8Exact(SourcePath))
			Assert(FSDelete(SourcePath))
			Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
			Assert(Receipt.handled && Receipt.ok, "the actual live menu adapter persists enable")
			AssertFalse(_UserHotstringsOwner.enabled, "an absent requested source cannot acknowledge native activation")
			AssertFalse(_UserHotstringsOwner.ready)
			Assert(InStr(_UserHotstringsLastRepair, ":source-missing:load"), "the actual native owner reports the existing repair action")
			AssertEqual(0, UserHotstringsCount(), "an absent requested source admits no invented mappings")
			Parsed := TOML_ParseFreshFileTyped(Fixture.path)
			AssertTrue(Parsed["hotstrings.dynamic.user_code"]["enabled"].Value)
			AssertEqual(0.75, Parsed["hotstrings.dynamic.user_code"]["time_activation_seconds"])
			AssertEqual("retain-user-code-preferences", Parsed["private"]["credential"])
			Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
			Assert(Receipt.handled && Receipt.ok)
			AssertFalse(_UserHotstringsOwner.enabled)
			Before := FSReadUtf8Exact(Fixture.path)
			WasSuspended := A_IsSuspended
			try {
				Suspend(true)
				Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
				Assert(Receipt.handled && !Receipt.ok, "a retained live toggle cannot activate code while paused")
				AssertEqual(Before, FSReadUtf8Exact(Fixture.path))
			} finally Suspend(WasSuspended)
			OwnerFixture := _UCHFixture(), _UserHotstringsOwner := OwnerFixture.owner
			Assert(OwnerFixture.owner.Request("@clock"))
			OwnerFixture.cancelAck := false
			Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
			Assert(Receipt.handled && !Receipt.ok, "unacknowledged cancellation refuses persistence")
			AssertEqual(Before, FSReadUtf8Exact(Fixture.path), "refused native cancellation preserves exact preference bytes")
			AssertFalse(ReadFeatureStateV2("hotstrings.dynamic.user_code")["enabled"])
			OwnerFixture.cancelAck := true
			Assert(UserHotstringsInvalidate("test-retirement"))
		} finally {
			Assert(UserHotstringsInvalidate("fixture-cleanup"))
			_ConfigDir := Saved[1], ConfigurationFile := Saved[2]
			_UserHotstringsOwner := Saved[3], _UserHotstringsLoader := Saved[4], CategoryEnabled := Saved[5]
			_UserHotstringsLoadEpoch := Saved[6], _UserHotstringsLastRepair := Saved[7], _UserHotstringsRepairPending := Saved[8]
			State.Clear()
			for Key, Value in SavedState
				State[Key] := Value
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
Test("programmable hotstrings: actual boot live persistence and cancellation refusal preserve source and preferences", _UCHNativePreferences)

_UCHActualSourceAdmission() {
	global _ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _UserHotstringsLastRepair, _UserHotstringsRepairPending, _DriverMenuReady
	AssertEqual(0, _UserHotstringsJobs.Count)
	AssertFalse(IsObject(_UserHotstringsLoader), "source admission fixtures require prior loader retirement")
	Saved := [_ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch,
		_UserHotstringsLastRepair, _UserHotstringsRepairPending]
	SavedMenuReady := IsSet(_DriverMenuReady) ? _DriverMenuReady : unset
	PackageRoots := _UCHPackageRoots(), Fixture := _ScopeOwnerFixture(), Hold := 0
	Sentinel := Fixture.directory . "\empty-factory-ran.txt"
	try {
		_ConfigDir := Fixture.directory . "\", _DriverMenuReady := false, _UserHotstringsRepairPending := true
		_UserHotstringsOwner := UserHotstringOwner(Map("capture", _UserHotstringsCaptureRule,
			"current", _UserHotstringsCurrent, "invoke", _UserHotstringsInvoke,
			"commit", _UserHotstringsCommit, "report", _UserHotstringsReport))
		Path := UserHotstringsSourcePath()
		AssertFalse(FSStrictExists(Path))
		AssertFalse(UserHotstringsSetEnabled(true), "explicit enable cannot load an absent source")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(0, _UserHotstringsJobs.Count, "absence never launches an interpreter")
		Assert(InStr(_UserHotstringsLastRepair, ":source-missing:load"))
		BeforeCreateEpoch := _UserHotstringsLoadEpoch
		Assert(UserHotstringsCreateExample(), "source repair is a deliberate create-only action")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(BeforeCreateEpoch, _UserHotstringsLoadEpoch, "creation never loads or admits the example")
		AssertEqual(0, _UserHotstringsJobs.Count)
		ExampleSource := FSReadUtf8Exact(Path)
		Assert(UserHotstringsSetEnabled(true))
		WaitForActualLoader()
		AssertTrue(_UserHotstringsOwner.enabled)
		AssertTrue(_UserHotstringsOwner.ready)
		AssertEqual(1, UserHotstringsCount(), "the actual repaired source publishes its declared rule")
		Assert(FSDelete(Path))
		AssertFalse(UserHotstringsSetEnabled(true), "repeated enable must reprove the source after disappearance")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(1, _UserHotstringsOwner.Count(), "the old metadata remains quarantined")
		Assert(FSWriteCreateDurable(Path, ExampleSource))
		Assert(UserHotstringsSetEnabled(true))
		WaitForActualLoader()
		AssertTrue(_UserHotstringsOwner.enabled)
		AssertTrue(_UserHotstringsOwner.ready)
		Assert(FSDelete(Path))
		AssertFalse(UserHotstringsReload(), "explicit absent reload never claims a successful load")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		Assert(InStr(_UserHotstringsLastRepair, ":source-missing:load"))
		EmptySource := 'ErgoptiDynamicHotstrings(api) {`n`tFileAppend("loaded", "' . Sentinel
			. '", "UTF-8-RAW")`n`treturn []`n}`n'
		Assert(FSWriteCreateDurable(Path, EmptySource))
		Assert(UserHotstringsSetEnabled(true))
		WaitForActualLoader()
		AssertTrue(_UserHotstringsOwner.enabled, "a present valid empty factory can acknowledge its native gate")
		AssertTrue(_UserHotstringsOwner.ready)
		AssertEqual(0, UserHotstringsCount())
		AssertEqual("loaded", FSReadUtf8Exact(Sentinel), "the real interpreter executed the independent empty factory")
		Hold := DllCall("CreateFileW", "Str", Path, "UInt", 0x80000000, "UInt", 0, "Ptr", 0,
			"UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		Assert(Hold && Hold != -1, "the fixture owns an actual exclusive source read lock")
		AssertFalse(UserHotstringsReload(), "an actual unreadable source must refuse reload")
		AssertFalse(UserHotstringsSetEnabled(true), "an actual unreadable source cannot acknowledge enable")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(0, _UserHotstringsJobs.Count)
		Assert(InStr(_UserHotstringsLastRepair, ":source-unreadable:load"))
		Assert(DllCall("CloseHandle", "Ptr", Hold))
		Hold := 0
		AssertEqual(EmptySource, FSReadUtf8Exact(Path), "native refusal never edits executable source")
	} finally {
		if Hold && Hold != -1
			DllCall("CloseHandle", "Ptr", Hold)
		Assert(UserHotstringsInvalidate("source-admission-fixture-cleanup"))
		_ConfigDir := Saved[1], _UserHotstringsOwner := Saved[2], _UserHotstringsLoader := Saved[3]
		_UserHotstringsLoadEpoch := Saved[4], _UserHotstringsLastRepair := Saved[5], _UserHotstringsRepairPending := Saved[6]
		_DriverMenuReady := IsSet(SavedMenuReady) ? SavedMenuReady : unset
		_UCHRestorePackageRoots(PackageRoots)
		_ScopeOwnerCleanup(Fixture)
	}
	WaitForActualLoader() {
		Started := A_TickCount
		while _UserHotstringsJobs.Count && TickElapsed(Started) < 10000
			Sleep(10)
		AssertEqual(0, _UserHotstringsJobs.Count, "the actual packaged loader and all stages must retire")
		AssertFalse(IsObject(_UserHotstringsLoader))
	}
}
Test("programmable hotstrings: actual absent repaired empty disappeared and unreadable sources acknowledge honest admission", _UCHActualSourceAdmission)

_UCHNativePrivacyAndPause() {
	global _ConfigDir, CategoryEnabled, HSE_Buffer, SFD_FIELD_CACHE
	global _UserHotstringsOwner
	global _UserHotstringsInputSerial, _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	Saved := [_ConfigDir, CategoryEnabled, HSE_Buffer, SFD_FIELD_CACHE.Clone(), A_IsSuspended, WinExist("A"), _UserHotstringsOwner]
	Fixture := _ScopeOwnerFixture(), Window := Gui("+ToolWindow", "Programmable hotstrings native privacy fixture")
	Normal := Window.Add("Edit", "w280", "ordinary input")
	Password := Window.Add("Edit", "w280 Password", "private input")
	try {
		_ConfigDir := Fixture.directory . "\", CategoryEnabled := Map("Hotstrings", true)
		Assert(FSWriteCreateDurable(UserHotstringsSourcePath(), "; Exact native source receipt.`n"))
		Source := _UserHotstringsReadSource()
		HSE_Buffer := "@clock", Suspend(false)
		Window.Show("w310 h120")
		WinActivate("ahk_id " . Window.Hwnd)
		Assert(WinWaitActive("ahk_id " . Window.Hwnd, , 2), "native privacy fixture requires the actual foreground window")
		Normal.Focus()
		SFD_InvalidateFocus()
		AssertFalse(SFD_IsSecureField(), "the actual native Edit style is conclusively ordinary")
		Capture := CaptureCurrent()
		AssertTrue(_UserHotstringsCurrent(Capture, Source), "the exact normal native destination admits publication")
		OriginalOwner := _UCHFixture().owner, _UserHotstringsOwner := OriginalOwner
		AssertTrue(_UserHotstringsPublicationCurrent(OriginalOwner, Capture, Source, OriginalOwner.generation))
		ForeignOwner := _UCHFixture().owner, _UserHotstringsOwner := ForeignOwner
		AssertEqual(OriginalOwner.generation, ForeignOwner.generation, "independent owners may reuse a generation number")
		AssertFalse(_UserHotstringsPublicationCurrent(OriginalOwner, Capture, Source, OriginalOwner.generation),
			"the actual deferred publication fence retains the exact native owner identity")
		_UserHotstringsOwner := OriginalOwner
		Suspend(true)
		AssertFalse(_UserHotstringsCurrent(Capture, Source), "actual suspended input refuses before callback/output")
		Suspend(false)
		Password.Focus()
		SFD_InvalidateFocus()
		AssertTrue(SFD_IsSecureField(), "the actual ES_PASSWORD native control is private")
		PrivateCapture := CaptureCurrent()
		AssertFalse(_UserHotstringsCurrent(PrivateCapture, Source), "privacy refuses even an otherwise current captured control")
		Normal.Focus()
		SFD_InvalidateFocus()
		AssertFalse(SFD_IsSecureField())
		AssertFalse(_UserHotstringsCurrent(PrivateCapture, Source), "changing the real control revokes its old receipt")
		Capture := CaptureCurrent()
		AssertTrue(_UserHotstringsCurrent(Capture, Source))
		Assert(FSWriteDurable(UserHotstringsSourcePath(), "; External source edit.`n"))
		AssertFalse(_UserHotstringsCurrent(Capture, Source), "external source edits revoke an otherwise current native destination")
	} finally {
		Suspend(Saved[5])
		Window.Destroy()
		_ConfigDir := Saved[1], CategoryEnabled := Saved[2], HSE_Buffer := Saved[3], SFD_FIELD_CACHE := Saved[4]
		_UserHotstringsOwner := Saved[7]
		if Saved[6] && WinExist("ahk_id " . Saved[6])
			WinActivate("ahk_id " . Saved[6])
		_ScopeOwnerCleanup(Fixture)
	}
	CaptureCurrent() {
		Hwnd := WinExist("A")
		return Map("input", _UserHotstringsInputSerial, "hwnd", Hwnd,
			"process", _UserHotstringsWindowProcess(Hwnd), "control", WIGetFocusedControlToken(),
			"field", SFD_FocusSnapshot(), "buffer", HSE_Buffer,
			"context", _PrefixInputContextGeneration, "deferred", _PrefixDeferredGeneration,
			"registry", HSE_RegistryGeneration, "decision", HSE_RuntimeDecisionGeneration)
	}
}
Test("programmable hotstrings: real native ordinary password pause control and source receipts fence publication", _UCHNativePrivacyAndPause)

_UCHScopedConfiguration(ScopeId, Mode, CancellationRefused := false) {
	global _ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch, _UserHotstringsJobs
	global _PersonalShortcutsRegistry, KeyboardShortcutAssignments, GestureActionParameters, _SharedDir
	AssertEqual(0, _UserHotstringsJobs.Count, "scope fixtures cannot borrow live programmable worker ownership")
	AssertFalse(IsObject(_UserHotstringsLoader), "scope fixtures require the previous source loader to be retired")
	Saved := [_ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch]
	SavedRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	SavedKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	Fixture := _HotstringsScopeFixture(), Borrowed := 0, Refusal := 0, Launches := 0
	Native := _UCHFixture()
	SourcePath := Fixture.directory . "\personal_dynamic_hotstrings.ahk"
	Source := Chr(0xFEFF) . 'ErgoptiDynamicHotstrings(api) {`n`tthrow Error("source must remain unexecuted by scope publication")`n}`n'
	Initial := Fixture.source . '[hotstrings.dynamic.user_code]`nenabled = true`ntime_activation_seconds = 0.75`nunknown_source_choice = "retain"`n'
	Launch(_Success, Bundle, Refused) {
		Borrowed := Bundle, Refusal := Refused, Launches += 1
		; The production shutdown preflight consumes this exact cancellation
		; verdict before handing the complete WAL to the replacement driver.
		if !UserHotstringsInvalidate("scoped-configuration-native-preflight")
			return false
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		_ConfigDir := Fixture.directory . "\", _UserHotstringsOwner := Native.owner, _UserHotstringsLoader := 0
		_PersonalShortcutsRegistry := Map("__Order", []), KeyboardShortcutAssignments := Map(), GestureActionParameters := Map()
		Assert(FSWriteDurable(Fixture.path, Initial))
		Assert(FSWriteCreateDurable(SourcePath, Source))
		if ScopeId == "global" {
			Fixture.options["tap_hold_path"] := Fixture.directory . "\tap_hold.toml"
			Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
			Fixture.options["layers_config_dir"] := Fixture.directory
			Assert(FSWriteDurable(Fixture.options["tap_hold_path"], '[tap_hold]`ninherit_defaults = true`n'))
		}
		Assert(Native.owner.Request("@clock"))
		Native.cancelAck := !CancellationRefused
		Commands := ScopeId == "global" ? _MI_GlobalScopeCommands(Fixture.options) : _HS_ScopeCommands(Fixture.options)
		Receipt := Commands[Mode == "clear" ? "scope_clear" : "scope_restore"].Call()
		AssertEqual(1, Launches, "the real scoped journal reaches one native cancellation/handoff boundary")
		AssertEqual(Source, FSReadUtf8Exact(SourcePath), "scope restore and clear never alter executable personal source")
		AssertEqual(0, Native.calls, "scoped configuration never re-evaluates the source factory or callback")
		if CancellationRefused {
			AssertEqual("refused", Receipt["status"], "unacknowledged native cancellation rolls back the complete scope")
			Assert(Native.owner.debt.Length > 0, "the exact failed cancellation remains owned after scoped rollback")
			AssertEqual(0, Native.owner.Find("@clock"), "retained cancellation debt keeps callback admission closed")
		} else {
			AssertEqual("pending", Receipt["status"])
			Parsed := TOML_ParseFreshFileTyped(Fixture.path)
			Node := Parsed["hotstrings.dynamic.user_code"]
			AssertFalse(Node.Has("enabled"), "both default and recommendation clear the sparse false switch")
			AssertFalse(Node.Has("time_activation_seconds"), "both scopes restore the canonical activation interval sparsely")
			AssertEqual("retain", Node["unknown_source_choice"], "unknown programmable source choices remain user-owned")
			AssertEqual(0, Native.owner.debt.Length)
			Refusal.Call("replacement native driver refused readiness")
			AssertEqual("refused", Receipt["status"])
		}
		AssertEqual(Initial, FSReadUtf8Exact(Fixture.path), "native refusal restores exact original programmable preference bytes")
		AssertEqual(Source, FSReadUtf8Exact(SourcePath))
		Native.cancelAck := true
		Assert(UserHotstringsInvalidate("scope-fixture-retirement"))
	} finally {
		Native.cancelAck := true
		Assert(UserHotstringsInvalidate("fixture-cleanup"))
		if Borrowed is Object
			_ConfigWriteTerminalRelease(Borrowed)
		_ConfigDir := Saved[1], _UserHotstringsOwner := Saved[2], _UserHotstringsLoader := Saved[3]
		_UserHotstringsLoadEpoch := Saved[4]
		_PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboard) ? SavedKeyboard : unset
		GestureActionParameters := IsSet(SavedParameters) ? SavedParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
for _UCHScopeId in ["global", "hotstrings"] {
	for _UCHScopeMode in ["recommended", "clear"]
		Test("programmable hotstrings: real " . _UCHScopeId . " " . _UCHScopeMode . " journal preserves source and rolls back native refusal",
			_UCHScopedConfiguration.Bind(_UCHScopeId, _UCHScopeMode))
}
Test("programmable hotstrings: real scoped restore refuses native cancellation debt without losing its owner",
	_UCHScopedConfiguration.Bind("hotstrings", "recommended", true))

/** Native-literal invalidation revokes admission without claiming sender cleanup. */
_UCHNativeNotepadInvalidation() {
	_HNP_Run(_UCHNativeNotepadInvalidationBody)
}

_UCHNativeNotepadInvalidationBody() {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending, HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer
	global _PrefixWatcherSuppressed, _HSE_FireLogQueue
	Saved := {Owner: _UserHotstringsOwner, Loader: _UserHotstringsLoader,
		Jobs: _UserHotstringsJobs, LoadEpoch: _UserHotstringsLoadEpoch,
		Replay: _HSE_TerminalReplayPending}
	try {
		Fixture := _UCHFixture()
		_UserHotstringsOwner := Fixture.owner
		_UserHotstringsLoader := 0
		_UserHotstringsJobs := Map()
		_HSE_TerminalReplayPending := 0
		ExpectedGeneration := Fixture.owner.generation
		HSE_Buffer := "xxab", _PrefixBuffer := "xxab", _LLM_Bridge_Buffer := "xxab"
		OutputHostResolverPrimeForTest("notepad.exe")
		State := Map("Requests", [], "ReleaseCalls", 0)
		Spec := _AHK04_NormalSpec()
		Spec.UserCodeGeneration := ExpectedGeneration
		Spec.PublicationCurrent := () => Fixture.owner.generation == ExpectedGeneration
		Owner := HSE_DispatchMatch(Spec, "", &Effect, false, _HNP_Record.Bind(State))
		AssertTrue(Owner is Map && Owner["Pending"], "the actual native sender retains pending publication")
		AssertTrue(Owner.Get("UserCodeOwned", false), "the programmable receipt must reach the native owner")
		Owner["Port"] := Map("abort_terminal", _UCHNativeNotepadRelease.Bind(State))
		AssertTrue(_HSE_NotepadOwnerIsCurrent(Owner), "the original programmable generation admits publication")
		AssertFalse(UserHotstringsInvalidate("native-notepad-fixture"),
			"native completion still owns cleanup after publication revocation")
		AssertTrue(Owner["Pending"] && _HSE_TerminalOwner == Owner,
			"invalidation cannot retire the actual pending native sender")
		AssertEqual(0, State["ReleaseCalls"], "Notepad never acquired the legacy terminal capture")
		AssertEqual(0, _HSE_TerminalReplayPending, "invalidation must not fabricate terminal replay debt")
		AssertEqual(1, _PrefixWatcherSuppressed, "native completion retains its sole suppression lease")
		AssertFalse(Owner["OutputOwnershipReleased"], "only actual native completion releases output ownership")
		AssertFalse(_HSE_NotepadOwnerIsCurrent(Owner), "the old publication generation is revoked")
		Request := State["Requests"][1]
		PreviousCritical := Critical("On")
		try {
			Refused := false
			try Request.Opts["atomic_commit"].Call()
			catch as CommitFailure {
				if Type(CommitFailure) != "Error"
						|| CommitFailure.Message != "The Notepad canonical commit lost its publication authority."
					throw CommitFailure
				Refused := true
			}
			AssertTrue(Refused, "the actual commit rejects the revoked publication receipt")
		} finally Critical(PreviousCritical)
		Request.Callback.Call(false, "recorded native refusal")
		AssertTrue(Owner["CompletionClaimed"] && Owner["OutputOwnershipReleased"] && !Owner["Pending"],
			"the real callback settles its retained owner exactly once")
		AssertEqual(0, _PrefixWatcherSuppressed, "actual completion releases suppression")
		AssertEqual(0, Keylogger.synth_active, "actual completion releases its synthetic marker")
		AssertEqual("xxab", HSE_Buffer, "refusal preserves the original typed buffer")
		AssertEqual(0, _HSE_FireLogQueue.Length, "revoked output cannot report a fire")
		AssertTrue(UserHotstringsInvalidate("native-notepad-retry"), "settled native completion permits cleanup retry")
		Request.Callback.Call(false, "duplicate recorded refusal")
		AssertEqual(0, _PrefixWatcherSuppressed, "duplicate completion cannot release the same lease twice")
		AssertEqual(0, State["ReleaseCalls"], "no legacy terminal release occurs at completion or retry")
	} finally {
		try {
			if (_HSE_TerminalOwner is Map) && _HSE_TerminalOwner.Get("Pending", false)
				_HSE_CompleteNotepadOwner(_HSE_TerminalOwner, false, "fixture cleanup")
		} finally {
			_UserHotstringsOwner := Saved.Owner
			_UserHotstringsLoader := Saved.Loader
			_UserHotstringsJobs := Saved.Jobs
			_UserHotstringsLoadEpoch := Saved.LoadEpoch
			_HSE_TerminalReplayPending := Saved.Replay
		}
	}
}

/** Records accidental legacy release without invoking the native DLL. */
_UCHNativeNotepadRelease(State, Token) {
	State["ReleaseCalls"] += 1
	return 1
}

Test("programmable hotstrings: Notepad invalidation retains native completion ownership (notepad-publication)",
	_UCHNativeNotepadInvalidation)

/** A duplicate native event remains separately owned and reports its collision. */
_UCHNativeEventBoundary() {
	First := 0, Duplicate := 0
	Name := "Local\ErgoptiPlus.NativeBoundaryTest." . UHN_CurrentProcessId() . "." . A_TickCount . "." . Random(0, 0x7fffffff)
	try {
		First := UHN_CreateCancellationEvent(Name, &FirstError)
		AssertTrue(First != 0, "the actual native adapter acquires an event handle")
		AssertTrue(FirstError != 183, "a fresh name does not adopt an existing event")
		AssertEqual(258, PLC_WaitHandle(First, 0), "the manual-reset event starts nonsignaled")
		Duplicate := UHN_CreateCancellationEvent(Name, &DuplicateError)
		AssertTrue(Duplicate != 0, "CreateEvent returns a separately closeable collision handle")
		AssertEqual(183, DuplicateError, "the caller receives the immediate native collision error")
		AssertTrue(UHN_SignalEvent(First), "the actual signal succeeds")
		AssertEqual(0, PLC_WaitHandle(Duplicate, 0), "the collision handle observes the same signaled native event")
	} finally {
		try {
			if Duplicate
				AssertTrue(UHN_CloseEvent(Duplicate), "the owned duplicate is closed once")
		} finally {
			if First
				AssertTrue(UHN_CloseEvent(First), "the owned initial handle is closed once")
		}
	}
}
Test("programmable hotstrings: native adapter preserves event ownership and immediate collision error", _UCHNativeEventBoundary)

/** Read-only probes preserve the active process and reject the null window. */
_UCHNativeWindowBoundary() {
	global DriverPid
	AssertEqual(DriverPid, UHN_CurrentProcessId(), "the nonce source is the actual interpreter process")
	ProcessId := 0
	AssertEqual(0, UHN_WindowProcessId(0, &ProcessId), "a null window acquires no process identity")
	AssertEqual(0, ProcessId)
	Hwnd := UHN_ForegroundHwnd()
	AssertTrue(Hwnd is Integer, "the active-window probe returns a native HWND value")
	if Hwnd {
		AssertTrue(UHN_WindowProcessId(Hwnd, &ProcessId) != 0)
		AssertTrue(ProcessId > 0, "an actual foreground window yields a native process identity")
	}
}
Test("programmable hotstrings: native adapter preserves foreground and process identity", _UCHNativeWindowBoundary)
