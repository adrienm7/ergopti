; tests/unit/modules/hotstrings/personal/test_user_hotstrings.ahk

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

#Include test_user_hotstring_loader_lifetime.ahk
