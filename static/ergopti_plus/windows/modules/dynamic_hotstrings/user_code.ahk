; modules/dynamic_hotstrings/user_code.ahk

; ==============================================================================
; MODULE: Programmable Dynamic Hotstrings Native Owner
; DESCRIPTION:
; Executes admitted personal source snapshots in a cancellable Windows Job and
; publishes returned text through the existing native hotstring transport.
; Metadata preview never executes user callbacks.
; ==============================================================================

#Include ../../../_shared/modules/hotstrings/user_code.ahk
#Include ../../adapters/user_hotstrings_native.ahk

; Native programmable hotstrings run outside the keyboard hook, in an owned Job.
; Only the host may publish returned text. Callback actions remain user-owned.
; A two-MiB wire envelope bounds staged callback output (UTF-8 hex doubles bytes).
global USER_HOTSTRINGS_MAX_WIRE_BYTES := 2 * 1024 * 1024
global _UserHotstringsOwner := 0
global _UserHotstringsInputSerial := 0
global _UserHotstringsCapture := 0
global _UserHotstringsLoader := 0
global _UserHotstringsJobs := Map()
global _UserHotstringsLoadEpoch := 0
global _UserHotstringsLastRepair := ""
; Why an enabled programmable source is not running, as the Hotstrings menu
; shows it: "missing" (no source file: create the example), "failed" (the
; source could not be read or loaded: open it), "" when nothing is wrong.
global _UserHotstringsProblem := ""

UserHotstringsSourcePath() {
	global _ConfigDir
	return _ConfigDir . "personal_dynamic_hotstrings.ahk"
}

UserHotstringsCount() {
	global _UserHotstringsOwner
	return IsObject(_UserHotstringsOwner) && _UserHotstringsOwner.ready ? _UserHotstringsOwner.Count() : 0
}

_UserHotstringsRefreshMenu() {
	global _DriverMenuReady
	; Boot's initial projection already reads the admitted metadata. An async
	; load finishing later requests the existing serialized tray publication.
	if IsSet(_DriverMenuReady) && _DriverMenuReady
		SetTimer(RebuildTrayMenu, -1)
	return true
}

; The source problems the user repairs from the Hotstrings menu, and the
; problem each one shows there. Every other refusal is a driver fault.
global USER_HOTSTRINGS_SOURCE_PROBLEMS := Map("source-missing", "missing",
	"source-unreadable", "failed", "source-load-failed", "failed")

_UserHotstringsReport(Kind, Id) {
	global _UserHotstringsLoadEpoch, _UserHotstringsLastRepair, _UserHotstringsProblem
	global USER_HOTSTRINGS_SOURCE_PROBLEMS
	; Stable identifiers only: user exceptions may contain private source/text.
	Receipt := _UserHotstringsLoadEpoch . ":" . Kind . ":" . Id
	if Receipt == _UserHotstringsLastRepair
		return true
	_UserHotstringsLastRepair := Receipt
	; A missing or broken personal source is the user's to repair, not a driver
	; failure: one WARNING, and the Hotstrings menu row shows the problem with
	; its repair (create the example, open the script). It used to be a modal
	; Yes/No offer at every boot with the option on and no file.
	if (Id == "load" and USER_HOTSTRINGS_SOURCE_PROBLEMS.Has(Kind)) {
		_UserHotstringsProblem := USER_HOTSTRINGS_SOURCE_PROBLEMS[Kind]
		if (_UserHotstringsProblem == "missing")
			LoggerWarn("UserHotstrings", "Programmable hotstrings are on but personal_dynamic_hotstrings.ahk does not exist — the Hotstrings menu offers to create an example.")
		else
			LoggerWarn("UserHotstrings", "Programmable source refused: {1} — the Hotstrings menu offers to open it.", Kind)
		_UserHotstringsRefreshMenu()
		return true
	}
	LoggerError("UserHotstrings", "Programmable source refused: {1} ({2}).", Kind, Id)
	return true
}

/**
 * Why the enabled programmable source is not running.
 * @returns {String} "missing", "failed", or "" when nothing is wrong.
 */
UserHotstringsProblem() {
	global _UserHotstringsProblem
	return _UserHotstringsProblem
}

/**
 * Creates the example source from the menu, then loads it at once when the
 * option is on, so the problem the menu showed is gone.
 * @returns {Boolean} Whether the example was created, and loaded when on.
 */
UserHotstringsRepairWithExample(*) {
	global Features
	; The example never overwrites a source: an existing one is only loaded.
	if FSStrictExists(UserHotstringsSourcePath()) {
		LoggerInfo("UserHotstrings", "The programmable source already exists — kept unchanged.")
	} else if !UserHotstringsCreateExample() {
		LoggerError("UserHotstrings", "The example programmable source could not be created.")
		return false
	} else {
		LoggerInfo("UserHotstrings", "Example programmable source created.")
	}
	Requested := Features["hotstrings"]["dynamic"].Has("user_code")
		&& Features["hotstrings"]["dynamic"]["user_code"]["enabled"] && IsCategoryGated("Hotstrings")
	if !Requested
		return true
	return UserHotstringsSetEnabled(true)
}

UserHotstringsOpenSource(*) {
	Path := UserHotstringsSourcePath()
	; Missing sources are created only by the explicit create-example action.
	if !FSStrictExists(Path)
		return false
	try {
		UHN_OpenSource(Path)
		return true
	} catch {
		LoggerError("UserHotstrings", "The personal code editor could not be opened.")
		return false
	}
}

UserHotstringsInit() {
	global _UserHotstringsOwner, Features
	if !IsObject(_UserHotstringsOwner) {
		_UserHotstringsOwner := UserHotstringOwner(Map("capture", _UserHotstringsCaptureRule,
			"current", _UserHotstringsCurrent, "invoke", _UserHotstringsInvoke,
			"commit", _UserHotstringsCommit, "report", _UserHotstringsReport))
	}
	Enabled := Features["hotstrings"]["dynamic"].Has("user_code")
		&& Features["hotstrings"]["dynamic"]["user_code"]["enabled"] && IsCategoryGated("Hotstrings")
	return UserHotstringsSetEnabled(Enabled)
}

UserHotstringsSetEnabled(Enabled) {
	global _UserHotstringsOwner, _UserHotstringsProblem
	if !IsObject(_UserHotstringsOwner) || !(Enabled is Integer) || (Enabled != 0 && Enabled != 1)
		return false
	; A disabled source has no problem to show; an enable reloads and reports.
	if !Enabled
		_UserHotstringsProblem := ""
	WasEnabled := _UserHotstringsOwner.enabled
	NeedsLoad := Enabled && (!WasEnabled || !_UserHotstringsOwner.ready)
	; Close callback admission before cancelling the independently owned loader.
	Closed := _UserHotstringsOwner.SetEnabled(false)
	Cancelled := UserHotstringsInvalidate("enabled")
	if !Closed || !Cancelled
		return false
	; An explicit repeated enable must prove the source still exists. Cached
	; posture cannot acknowledge admission after deletion or an external edit.
	if Enabled && !NeedsLoad
		NeedsLoad := !(_UserHotstringsOwner.source is Map) || !_UserHotstringsSourceCurrent(_UserHotstringsOwner.source)
	if NeedsLoad
		_UserHotstringsOwner.ready := false
	if !_UserHotstringsOwner.SetEnabled(Enabled)
		return false
	; Default-off boot must not execute user code. Enabling explicitly loads it.
	if NeedsLoad
		return UserHotstringsReload()
	return true
}

UserHotstringsObserveInput() {
	global _UserHotstringsInputSerial, _UserHotstringsOwner
	_UserHotstringsInputSerial += 1
	; InputHook admission is RAM-only; cancellation and source IO happen later.
	if IsObject(_UserHotstringsOwner) && _UserHotstringsOwner.active.Count
		SetTimer(_UserHotstringsCancelStale, -1)
}

_UserHotstringsPoll(*) {
	global _UserHotstringsJobs, _UserHotstringsOwner
	_UserHotstringsCancelStale()
	if IsObject(_UserHotstringsOwner) && _UserHotstringsOwner.debt.Length
		_UserHotstringsOwner.Invalidate("cancellation-retry")
	for Job in _UserHotstringsJobs.Clone() {
		if Job.cancelled
			Job.cancel()
		else if Job.pending is Array
			Job.Finish(Job.pending*)
		else if !_UserHotstringsSourceCurrent(Job.source)
			Job.cancel()
	}
}

_UserHotstringsCancelStale() {
	global _UserHotstringsOwner
	if !IsObject(_UserHotstringsOwner)
		return true
	for Ticket in _UserHotstringsOwner.active.Clone() {
		if !_UserHotstringsOwner.Current(Ticket) {
			_UserHotstringsOwner.active.Delete(Ticket)
			if Ticket.Has("operation") && !_UserHotstringsOwner.Cancel(Ticket["operation"])
				_UserHotstringsOwner.debt.Push(Ticket["operation"])
		}
	}
	return !_UserHotstringsOwner.debt.Length
}

UserHotstringsInvalidate(Reason := "lifecycle") {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch, _UserHotstringsJobs
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending
	_UserHotstringsLoadEpoch += 1
	Ready := !IsObject(_UserHotstringsOwner) || _UserHotstringsOwner.Invalidate(Reason)
	if IsObject(_UserHotstringsLoader)
		Ready := _UserHotstringsLoader.cancel() && Ready
	; The native terminal scheduler retains text publication after worker exit.
	if (_HSE_TerminalOwner is Map) && _HSE_TerminalOwner.Get("UserCodeOwned", false) {
		TerminalOwner := _HSE_TerminalOwner
		; Claim the scheduled runner exactly once. Its generation is revoked,
		; so it aborts output and releases capture; a late timer cannot do it twice.
		; Native text output retains its own completion callback and suppression.
		; Revoked publication is observed by admission/commit; the terminal runner
		; cannot retire this sender, and its completion releases its own capture.
		if !TerminalOwner.Get("NativeLiteral", false)
			_HSE_RunOwnedTerminalTransaction(TerminalOwner)
		Ready := !TerminalOwner["Pending"] && Ready
	}
	if (_HSE_TerminalReplayPending is Map) && _HSE_TerminalReplayPending.Get("UserCodeOwned", false)
		Ready := _HSE_RetryTerminalReplay() && Ready
	; Retry every retained process/stage owner, including failed loader cleanup.
	for Job in _UserHotstringsJobs.Clone()
		Ready := Job.cancel() && Ready
	return !!Ready
}

UserHotstringsStop() {
	global _UserHotstringsOwner
	Cancelled := UserHotstringsInvalidate("shutdown")
	if !Cancelled
		return false
	return !IsObject(_UserHotstringsOwner) || _UserHotstringsOwner.Stop()
}

_UserHotstringsReadSource() {
	Path := UserHotstringsSourcePath()
	Present := FSStrictExists(Path)
	Content := Present ? FSReadUtf8Exact(Path) : ""
	if !(Content is String)
		throw Error("The programmable source is not readable as exact UTF-8.")
	return Map("path", Path, "present", Present, "content", Content)
}

_UserHotstringsSourceCurrent(Source) {
	try {
		Actual := _UserHotstringsReadSource()
		return Actual["path"] == Source["path"] && Actual["present"] == Source["present"]
			&& Actual["content"] == Source["content"]
	} catch
		return false
}

UserHotstringsReload(*) {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch
	if !IsObject(_UserHotstringsOwner) || !UserHotstringsInvalidate("reload")
		return false
	_UserHotstringsOwner.ready := false
	_UserHotstringsRefreshMenu()
	Epoch := _UserHotstringsLoadEpoch
	try Source := _UserHotstringsReadSource()
	catch {
		_UserHotstringsOwner.RefuseSource("source-unreadable")
		_UserHotstringsRefreshMenu()
		_UserHotstringsReport("source-unreadable", "load")
		return false
	}
	if !Source["present"] {
		_UserHotstringsOwner.RefuseSource("source-missing")
		_UserHotstringsRefreshMenu()
		_UserHotstringsReport("source-missing", "load")
		return false
	}
	Done(ExitCode, Stdout, Stderr) {
		global _UserHotstringsOwner, _UserHotstringsLoadEpoch, _UserHotstringsLoader, _UserHotstringsProblem
		if Epoch != _UserHotstringsLoadEpoch
			return false
		_UserHotstringsLoader := 0
		try {
			if ExitCode != 0 || !_UserHotstringsSourceCurrent(Source)
				throw Error("Source publication refused.")
			Rules := _UserHotstringsParseMetadata(Stdout)
			Published := _UserHotstringsOwner.Reload(Rules, Source)
			if Published
				_UserHotstringsProblem := ""
			_UserHotstringsRefreshMenu()
			return Published
		} catch {
			_UserHotstringsOwner.RefuseSource("source-load-failed")
			_UserHotstringsRefreshMenu()
			_UserHotstringsReport("source-load-failed", "load")
			return false
		}
	}
	_UserHotstringsLoader := UserHotstringWorker(Source, "load", "", Done)
	return _UserHotstringsLoader.start()
}

_UserHotstringsParseFrame(Text) {
	if !(Text is String) || InStr(Text, "`r")
		throw Error("Invalid worker framing.")
	; ShellRunner trims surrounding CR/LF, so an explicit trailer fences EOF.
	Lines := StrSplit(SubStr(Text, -1) == "`n" ? SubStr(Text, 1, -1) : Text, "`n")
	if Lines.Length < 2 || Lines.RemoveAt(1) != "ERGOPTI_USER_HOTSTRINGS_V1"
		|| Lines.Pop() != "END"
		throw Error("Invalid worker header.")
	return Lines
}

_UserHotstringsParseMetadata(Text) {
	Rules := []
	for Line in _UserHotstringsParseFrame(Text) {
		Fields := StrSplit(Line, "`t")
		if Fields.Length != 3
			throw Error("Invalid metadata framing.")
		Rules.Push(Map("id", UserCodeDecode(Fields[1]), "suffix", UserCodeDecode(Fields[2]),
			"preview", UserCodeDecode(Fields[3]), "callback", (*) => false))
	}
	return Rules
}

_UserHotstringsParseResult(Text) {
	Lines := _UserHotstringsParseFrame(Text)
	if Lines.Length != 1
		throw Error("Invalid result framing.")
	if Lines[1] == "ACTION"
		return true
	if Lines[1] == "CANCEL"
		return false
	Fields := StrSplit(Lines[1], "`t")
	if Fields.Length != 2 || Fields[1] != "TEXT"
		throw Error("Invalid result framing.")
	return UserCodeDecode(Fields[2])
}

_UserHotstringsWindowProcess(Hwnd) {
	ProcessId := 0
	if !Hwnd || !UHN_WindowProcessId(Hwnd, &ProcessId)
		return 0
	return ProcessId
}

_UserHotstringsCaptureRule(Rule) {
	global _UserHotstringsCapture
	return _UserHotstringsCapture
}

UserHotstringsOnChar(BufferValue) {
	global _UserHotstringsOwner, _UserHotstringsCapture, _UserHotstringsInputSerial
	global _PrefixInputContextGeneration, _PrefixDeferredGeneration, HSE_RegistryGeneration
	global HSE_RuntimeDecisionGeneration, Features, ScriptInformation
	if !IsObject(_UserHotstringsOwner)
		return false
	MagicKey := ScriptInformation["MagicKey"]
	if MagicKey == "" || !(SubStr(BufferValue, -StrLen(MagicKey)) == MagicKey)
		return false
	LogicalBuffer := SubStr(BufferValue, 1, StrLen(BufferValue) - StrLen(MagicKey))
	Rule := _UserHotstringsOwner.Find(LogicalBuffer)
	if !(Rule is Map)
		return false
	Delay := Features["hotstrings"]["dynamic"]["user_code"]["time_activation_seconds"]
	Trigger := Rule["suffix"] . MagicKey
	Spec := {Replacement: Rule["preview"], Trigger: Trigger, Length: StrLen(Trigger),
		TimeActivationSeconds: Delay, PrevCharKey: _TextPenultimateCodepoint(Trigger), OnlyText: true}
	if !_HSE_PrepareDispatchDecision(Spec, BufferValue, "")
		return false
	Hwnd := UHN_ForegroundHwnd()
	_UserHotstringsCapture := Map("input", _UserHotstringsInputSerial, "hwnd", Hwnd,
		"process", _UserHotstringsWindowProcess(Hwnd),
		"control", WIGetFocusedControlToken(), "field", SFD_FocusSnapshot(), "buffer", BufferValue, "trigger", Trigger,
		"context", _PrefixInputContextGeneration, "deferred", _PrefixDeferredGeneration,
		"registry", HSE_RegistryGeneration, "decision", HSE_RuntimeDecisionGeneration)
	try return _UserHotstringsOwner.Request(LogicalBuffer)
	finally _UserHotstringsCapture := 0
}

_UserHotstringsCurrent(Capture, Source) {
	global _UserHotstringsInputSerial, _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration, HSE_Buffer
	if A_IsSuspended || !IsCategoryGated("Hotstrings") || Capture["input"] != _UserHotstringsInputSerial
		|| Capture["context"] != _PrefixInputContextGeneration || Capture["deferred"] != _PrefixDeferredGeneration
		|| Capture["registry"] != HSE_RegistryGeneration || Capture["decision"] != HSE_RuntimeDecisionGeneration
		|| !(Capture["buffer"] == HSE_Buffer) || Capture["hwnd"] != UHN_ForegroundHwnd()
		|| !Capture["process"] || Capture["process"] != _UserHotstringsWindowProcess(Capture["hwnd"])
		|| !(Capture["control"] == WIGetFocusedControlToken()) || SFD_IsSecureField()
		return false
	Field := SFD_FocusSnapshot()
	return Field.Generation == Capture["field"].Generation && Field.ElementId == Capture["field"].ElementId
		&& _UserHotstringsSourceCurrent(Source)
}

_UserHotstringsInvoke(Rule, Context, Done, Capture) {
	global _UserHotstringsOwner
	Source := _UserHotstringsOwner.source.Clone()
	Terminal(ExitCode, Stdout, Stderr) {
		try {
			if ExitCode != 0
				throw Error("The worker failed.")
			Result := _UserHotstringsParseResult(Stdout)
		} catch {
			return Done(false, "worker-failed")
		}
		return Done(Result)
	}
	return UserHotstringWorker(Source, "execute", Rule["id"], Terminal, Context,
		Rule["suffix"], Rule["preview"])
}

_UserHotstringsPublicationCurrent(Owner, Capture, Source, Generation) {
	global _UserHotstringsOwner
	Ready := IsObject(_UserHotstringsOwner) && _UserHotstringsOwner == Owner && _UserHotstringsOwner.enabled
		&& _UserHotstringsOwner.ready && !_UserHotstringsOwner.stopped
		&& Generation == _UserHotstringsOwner.generation
	if !Ready || !_UserHotstringsCurrent(Capture, Source)
		return false
	; Source and destination probes can yield; retain the same native publication
	; owner after those reads as well as before entering them.
	return _UserHotstringsOwner == Owner && Owner.enabled && Owner.ready && !Owner.stopped
		&& Generation == Owner.generation
}

_UserHotstringsCommit(Result, Capture, Rule) {
	global _UserHotstringsOwner, _UserHotstringsInputSerial
	if !(Result is String)
		return true ; Action/cancel never erase or otherwise mutate native text.
	PreviousCritical := Critical("On")
	try {
		if !_UserHotstringsCurrent(Capture, _UserHotstringsOwner.source)
			return false
		Spec := {Replacement: Result, Trigger: Capture["trigger"], Length: StrLen(Capture["trigger"]),
			OnlyText: true, IsPrivate: true, Category: "dynamichotstrings", TimeActivationSeconds: 0,
			UserCodeGeneration: _UserHotstringsOwner.generation,
			PublicationCurrent: _UserHotstringsPublicationCurrent.Bind(_UserHotstringsOwner, Capture, _UserHotstringsOwner.source.Clone(),
				_UserHotstringsOwner.generation)}
		; Context/source IO above may yield; perform the final exact input check
		; under Critical before entering the existing native transport.
		if Capture["input"] != _UserHotstringsInputSerial
			return false
		Verdict := HSE_DispatchMatch(Spec, "", &Effect)
		if Verdict is Map
			return Verdict.Has("Pending") ; Existing terminal owner fences its deferred publication.
		if !Verdict
			return false
		_PrefixCommitPostFireEffect(Effect)
		return true
	} finally Critical(PreviousCritical)
}

/** Owns both exact native tree cancellation and create-only worker stages. */
class UserHotstringWorker {
	__New(Source, Mode, Id, Done, Context := 0, Suffix := "", Preview := "") {
		this.source := Source.Clone(), this.mode := Mode, this.id := Id, this.done := Done
		this.context := Context, this.suffix := Suffix, this.preview := Preview
		this.stage := "", this.task := 0, this.event := 0, this.cancelled := false
		this.timer := ObjBindMethod(this, "Run")
		this.paths := [], this.pending := 0
		this.cleanupReported := false
	}

	start() {
		global _UserHotstringsJobs
		_UserHotstringsJobs[this] := this
		SetTimer(_UserHotstringsPoll, 25)
		SetTimer(this.timer, -1)
		return true
	}

	Cleanup() {
		global _UserHotstringsJobs
		Ready := true
		for Path in this.paths
			Ready := FSDelete(Path) && Ready
		if Ready && this.stage != "" && DirExist(this.stage) {
			try DirDelete(this.stage)
			catch
				Ready := false
		}
		if !Ready
			return false
		if this.event
			UHN_CloseEvent(this.event)
		this.event := 0
		if _UserHotstringsJobs.Has(this)
			_UserHotstringsJobs.Delete(this)
		if !_UserHotstringsJobs.Count
			SetTimer(_UserHotstringsPoll, 0)
		return true
	}

	cancel() {
		this.cancelled := true
		SetTimer(this.timer, 0)
		if this.event
			UHN_SignalEvent(this.event)
		if IsObject(this.task) && !UserCodeAcknowledged(this.task.terminate())
			return false
		return this.Cleanup()
	}

	Run(*) {
		global _SharedDir, _VendorDir, USER_HOTSTRINGS_MAX_WIRE_BYTES
		if this.cancelled
			return this.cancel()
		try {
			if IsObject(this.context) && this.context["cancelled"].Call()
				return this.Finish(0, "ERGOPTI_USER_HOTSTRINGS_V1`nCANCEL`nEND`n", "")
			if !_UserHotstringsSourceCurrent(this.source)
				throw Error("The source changed before execution.")
			Nonce := Format("{:x}-{:x}-{:x}", UHN_CurrentProcessId(), A_TickCount, Random(0, 0x7fffffff))
			Name := "Local\ErgoptiPlus.UserHotstrings." . Nonce
			this.event := UHN_CreateCancellationEvent(Name, &EventError)
			if !this.event || EventError == 183
				throw Error("The cancellation event is not exclusively owned.")
			Stage := A_Temp . "\ergopti_user_hotstrings_" . Nonce
			if !FSCreateDirectoryExclusiveStrict(Stage)
				throw Error("The source stage is not exclusively owned.")
			this.stage := Stage
			SourcePath := this.stage . "\source.ahk", Wrapper := this.stage . "\worker.ahk"
			if !FSWriteCreateDurable(SourcePath, this.source["content"])
				throw Error("The source stage could not be published.")
			this.paths.Push(SourcePath)
			Body := "#Include " . _SharedDir . "\modules\hotstrings\user_code.ahk`n"
				. "#Include " . _VendorDir . "\ergopti_user_hotstrings.ahk`n#Include " . SourcePath . "`n"
			if !FSWriteCreateDurable(Wrapper, Body)
				throw Error("The worker stage could not be published.")
			this.paths.Push(Wrapper)
			Runtime := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
			this.task := ShellRunner_SpawnTreeOwned(Runtime, ["/script", "/ErrorStdOut=utf-8", Wrapper,
				this.mode, this.id, Name, UserCodeEncode(this.suffix), UserCodeEncode(this.preview)],
				ObjBindMethod(this, "Finish"), , , USER_HOTSTRINGS_MAX_WIRE_BYTES)
			if this.cancelled || !this.task.start()
				throw Error("The worker launch was refused.")
			return true
		} catch {
			return this.Finish(1, "", "")
		}
	}

	Finish(ExitCode, Stdout, Stderr) {
		; ShellRunner only delivers after its complete native Job is quiescent.
		if IsObject(this.task) && !UserCodeAcknowledged(this.task.terminate())
			return false
		this.pending := [ExitCode, Stdout, Stderr]
		if !this.Cleanup() {
			if !this.cleanupReported {
				this.cleanupReported := true
				_UserHotstringsReport("stage-cleanup-refused", "worker")
			}
			return false
		}
		this.pending := 0
		if !this.cancelled
			return this.done.Call(ExitCode, Stdout, Stderr)
		return true
	}
}


/** Returns a static preview with the same fallback precedence and timing gate. */
UserHotstringsPreviewSpec(BufferBefore, Completion) {
	global _UserHotstringsOwner, Features, ScriptInformation
	if !IsObject(_UserHotstringsOwner) || !(Completion == ScriptInformation["MagicKey"])
		return ""
	Rule := _UserHotstringsOwner.Preview(BufferBefore)
	if !(Rule is Map)
		return ""
	Trigger := Rule["suffix"] . Completion
	return {Replacement: Rule["preview"], Trigger: Trigger, Length: StrLen(Trigger),
		OnlyText: true, IsPrivate: true, Category: "dynamichotstrings",
		TimeActivationSeconds: Features["hotstrings"]["dynamic"]["user_code"]["time_activation_seconds"],
		PrevCharKey: _TextPenultimateCodepoint(Trigger), UserCodeGeneration: _UserHotstringsOwner.generation,
		TransientKind: "user_code"}
}

UserHotstringsPreviewStillCurrent(Decision) {
	global _UserHotstringsOwner
	return IsObject(_UserHotstringsOwner) && _UserHotstringsOwner.enabled
		&& _UserHotstringsOwner.ready && !_UserHotstringsOwner.stopped
		&& Decision.UserCodeGeneration == _UserHotstringsOwner.generation
}


/** Creates the documented source only after an explicit user menu action. */
UserHotstringsCreateExample(*) {
	Path := UserHotstringsSourcePath()
	Example := "; Personal programmable hotstrings. Existing files are never overwritten.`n"
		. "ErgoptiDynamicHotstrings(api) {`n"
		. '`treturn [Map("id", "clock", "suffix", "@clock", "preview", "Current time",`n'
		. '`t`t"callback", (context) => context["cancelled"].Call() ? false : FormatTime(, "HH:mm"))]`n'
		. "}`n"
	return UserCodeAcknowledged(FSWriteCreateDurable(Path, Chr(0xFEFF) . Example))
}
