; tests/fixtures/model_browser_close_pause_owner_body.ahk

; ==============================================================================
; MODULE: Model Browser Native Close Pause Child
; DESCRIPTION:
; Exercises the actual SDK message entry and its native deferred model apply.
; The component host is a real private Gui, with COM/controller state absent.
; Migration, boot loading, menu candidates, full collection and TOML writes are
; genuine. The real menu coordinator owns an explicitly refusing repaint port.
; ==============================================================================

#Requires AutoHotkey v2.0

_MBPO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

class _MBPO_Message {
	__New(Text) {
		this.Text := Text, this.Reads := 0
	}
	TryGetWebMessageAsString() {
		this.Reads += 1
		return this.Text
	}
}

_MBPO_Pulse(*) {
	global _MBPO
	_MBPO.Pulses += 1
}

_MBPO_Observe() {
	global _MBPO
	Before := _MBPO.Pulses, Started := A_TickCount
	while _MBPO.Pulses - Before < 3 && TickElapsed(Started) < 1000
		Sleep(10)
	_MBPO_Require(_MBPO.Pulses - Before >= 3, "Each observation must deliver fresh native timer pulses.")
	if IsObject(_MBPO.Failure)
		throw _MBPO.Failure
}

_MBPO_Repaint() {
	global _MBPO
	_MBPO.RepaintRequests += 1
	; This is only the presentation dependency of the real build coordinator.
	; It refuses publication and does not claim that a tray was rendered.
	return false
}

_MBPO_IsPaused(*) => A_IsSuspended

_MBPO_BuildError(Failure) {
	global _MBPO
	if !IsObject(_MBPO.Failure)
		_MBPO.Failure := Failure
}

_MBPO_OnError(Failure, Mode) {
	global _MBPO
	if !IsObject(_MBPO.Failure)
		_MBPO.Failure := Failure
	return true
}

_MBPO_Log(Line) {
	global _MBPO
	try {
		if InStr(Line, "[ERROR]")
			_MBPO.Errors.Push(Line)
		if InStr(Line, "[LLMObservation.durable-writer.enter]") {
			_MBPO.WriterEntries += 1
			if A_IsSuspended
				_MBPO.PausedWriterEntries += 1
		}
		if InStr(Line, "[LLMObservation.durable-writer.returned]")
			&& InStr(Line, "status=confirmed")
			_MBPO.WriterConfirmed += 1
		if InStr(Line, "[LLMObservation.mutation-return.returned]") {
			_MBPO.MutationReturns += 1
			if InStr(Line, "status=confirmed")
				_MBPO.MutationConfirmed += 1
		}
	} catch Any as Failure {
		if !IsObject(_MBPO.Failure)
			_MBPO.Failure := Failure
	}
}

_MBPO_Destroy(WParam, LParam, Message, Hwnd) {
	global _MBPO, ConfigurationFile
	if Hwnd != _MBPO.Hwnd || _MBPO.Cleaning
		return
	try {
		_MBPO.DestroyCalls += 1
		_MBPO_Require(_MBPO.DestroyCalls == 1 && _MBPO.CommandIssued,
			"Only the exact component host may trigger this native destruction actor after the SDK command.")
		if _MBPO.Mode == "during-close" {
			Suspend(true)
			_MBPO.PauseObserved := A_IsSuspended
			; Snapshot AFTER the actual pause. A legitimate commit before Close is
			; allowed: that already selected image becomes the preserved baseline.
			_MBPO.PauseImage := FSReadBytesStrict(ConfigurationFile)
			_MBPO.PauseHash := CryptoSha256Bytes(_MBPO.PauseImage)
			_MBPO_Require(_MBPO.PauseObserved && _MBPO.PauseHash != "",
				"Native WM_DESTROY must capture the genuine file image while actually suspended.")
		}
	} catch Any as Failure {
		if !IsObject(_MBPO.Failure)
			_MBPO.Failure := Failure
	}
}

_MBPO_Prepare() {
	global _MBPO, ConfigurationFile, Features, _IniCache, _LLM_Menu, _LLM_Menu_Loaded, LLM_Defaults
	global _LLM_MenuBuildCoordinator, _LLM_MBW_Gui, _LLM_MBW_SessionEpoch
	global _LLM_MBW_Controller, _LLM_MBW_WebView, _LLM_MBW_MsgSub, _LLM_MBW_ResetDone, _LLM_MBW_Ready
	Directory := A_Args[2] . "\config"
	FSCreateDirectoryExclusiveStrict(Directory)
	ConfigurationFile := Directory . "\config.toml"
	Index := LLM_GetModelIndex()
	_MBPO.ModelA := LLM_Defaults["llm_model"]
	_MBPO_Require(Index is Map && Index.Has(_MBPO.ModelA), "The baseline must come from the real shared model catalogue/defaults.")
	for Name in Index {
		if Name != _MBPO.ModelA {
			_MBPO.ModelB := Name
			break
		}
	}
	_MBPO_Require(_MBPO.ModelB != "" && _LLM_MBW_IsCatalogueModelName(_MBPO.ModelB),
		"A distinct real catalogue model must pass the actual SDK value admission.")
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion()
		. '`n[script]`nlocale = "fr"`n[llm]`nenabled = false`n[llm.models]`nselected = "api"`nollama = '
		. JsonStringLiteral(_MBPO.ModelA) . '`n[llm.profiles]`nauto_profile_for_model = false`n'
	_MBPO_Require(FSWriteCreateDurable(ConfigurationFile, Source), "The private source must be created exclusively and durably.")
	Boot := ConfigMigrateBoot(ConfigurationFile)
	_MBPO_Require(Boot["status"] == "current" && Boot["read_only"] == 0,
		"The exact private file must pass actual native migration admission.")
	Features := ManifestBuildFeaturesMap()
	_MBPO_Require(ApplyBootConfigToml(Features, ConfigurationFile, &Snapshot) >= 0
		&& Snapshot is Object && ConfigFullStateCanPersist(), "The full state must be admitted by the real boot loader.")
	_IniCache := ParseConfigTomlFile(ConfigurationFile)
	ReadScriptConfig(_IniCache)
	ReadCategoryEnabled(_IniCache)
	MetricsFiltersApplyManifestDefaults()
	_MBPO_Require(_LLM_Menu_RestoreSavedOptsOnce(LLM_Menu_BuildSavedOpts(_IniCache)),
		"The genuine menu restore must consume options derived from the actual boot features/cache.")
	_MBPO_Require(!_LLM_Menu["enabled"] && _LLM_Menu["backend"] == "api"
		&& _LLM_Menu["model"] == _MBPO.ModelA && !_LLM_Menu["auto_profile_for_model"],
		"The private disabled/API state must avoid backend bootstrap without replacing mutation or persistence.")
	_MBPO_Require(!_LLM_Menu_Loaded, "Candidate collection must use its real explicit menu source, not a fabricated loaded flag.")
	_MBPO.Original := FSReadBytesStrict(ConfigurationFile)
	_MBPO.OriginalHash := CryptoSha256Bytes(_MBPO.Original)
	_MBPO_Require(_MBPO.OriginalHash != "", "The independent original RAW image must be measurable.")
	_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(_MBPO_Repaint, _MBPO_IsPaused, _MBPO_BuildError)
	; Deliberately component-only: no ShowWeb constructor, Edge, subscription or
	; controller is fabricated. The real SDK command owns this real private Gui.
	_MBPO_Require(!IsSet(_LLM_MBW_Gui) && !IsSet(_LLM_MBW_Controller)
		&& !IsSet(_LLM_MBW_WebView) && !IsSet(_LLM_MBW_MsgSub) && !_LLM_MBW_ResetDone,
		"The isolated component must start with the genuine cold host/COM state.")
	_MBPO.Window := Gui("+ToolWindow", "Private model browser component")
	_MBPO.Hwnd := _MBPO.Window.Hwnd
	_MBPO.Window.OnEvent("Close", _LLM_MBW_OnClose)
	_LLM_MBW_SessionEpoch += 1
	_MBPO.Epoch := _LLM_MBW_SessionEpoch
	_LLM_MBW_Gui := _MBPO.Window
	_MBPO.Window.Show("w220 h80 NA")
	_MBPO_Require(DllCall("User32\IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
		"The component owns an actual visible native host before admitting the SDK command.")
	; Establish the component's readiness through its actual SDK lifecycle entry,
	; not a Ready assignment. With COM absent, no page or rendering is claimed.
	ReadyArgs := _MBPO_Message("ready")
	_LLM_MBW_OnWebMessage(_MBPO.Epoch, 0, ReadyArgs)
	_MBPO.ReadyReads := ReadyArgs.Reads
	_MBPO_Require(_MBPO.ReadyReads == 1 && _LLM_MBW_Ready,
		"The genuine SDK readiness route must admit this exact component epoch before the selection command.")
}

_MBPO_Receipt(Hash) {
	global _MBPO
	FileAppend("RECEIPT model-browser-close-pause-owner mode=" . _MBPO.Mode
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " sdk_reads=" . _MBPO.Args.Reads
		. " ready_reads=" . _MBPO.ReadyReads . " destroy_calls=" . _MBPO.DestroyCalls . " pause=" . _MBPO.PauseObserved
		. " writer_enter=" . _MBPO.WriterEntries . " writer_confirmed=" . _MBPO.WriterConfirmed
		. " paused_writer=" . _MBPO.PausedWriterEntries . " mutation_returns=" . _MBPO.MutationReturns
		. " mutation_confirmed=" . _MBPO.MutationConfirmed . " repaint_refusals=" . _MBPO.RepaintRequests
		. " pulses=" . _MBPO.Pulses . " original_sha256=" . _MBPO.OriginalHash
		. " pause_sha256=" . _MBPO.PauseHash . " final_sha256=" . Hash
		. " boundary_failure=" . IsObject(_MBPO.Failure) . " errors=" . _MBPO.Errors.Length
		. " browser_com=absent repaint_port=refusal`n", "*", "UTF-8-RAW")
	; Export retained causes outside the logger sink before the unchanged guard.
	for Index, Line in _MBPO.Errors
		FileAppend("DIAGNOSTIC model-browser-close-pause-owner error_index=" . Index
			. " logger_error=" . JsonStringLiteral(Line) . "`n", "*", "UTF-8-RAW")
	if IsObject(_MBPO.Failure)
		FileAppend("DIAGNOSTIC model-browser-close-pause-owner boundary_message=" . JsonStringLiteral(_MBPO.Failure.Message)
			. " boundary_file=" . JsonStringLiteral(_MBPO.Failure.File)
			. " boundary_line=" . _MBPO.Failure.Line . "`n", "*", "UTF-8-RAW")
}

_MBPO_Run() {
	global _MBPO, ConfigurationFile, _LLM_Menu, Features, _LLM_MBW_SessionEpoch
	_MBPO_Prepare()
	_MBPO.Args := _MBPO_Message('{"action":"select_model","name":' . JsonStringLiteral(_MBPO.ModelB) . "}")
	if _MBPO.Mode == "paused-entry"
		Suspend(true)
	_MBPO.CommandIssued := true
	; The only selection producer is the genuine SDK entry. It validates JSON
	; and the catalogue and arms its unchanged native -1 apply timer itself.
	_LLM_MBW_OnWebMessage(_MBPO.Epoch, 0, _MBPO.Args)
	_MBPO_Observe()
	Image := FSReadBytesStrict(ConfigurationFile), Hash := CryptoSha256Bytes(Image)
	_MBPO_Receipt(Hash)
	_MBPO_Require(!IsObject(_MBPO.Failure) && _MBPO.Errors.Length == 0,
		"A startup, schema, collector or runtime diagnostic cannot qualify as a model-selection refusal.")
	_MBPO_Require(_MBPO.Args.Reads == 1 && Hash != "", "The real SDK must consume the transport and the final RAW image must be read.")
	if _MBPO.Mode == "current" {
		_MBPO_Require(_MBPO.DestroyCalls == 1 && !DllCall("User32\IsWindow", "Ptr", _MBPO.Hwnd, "Int"),
			"The real deferred SDK action must close and destroy its exact native component host.")
		_MBPO_Require(_MBPO.WriterEntries == 1 && _MBPO.WriterConfirmed == 1
			&& _MBPO.PausedWriterEntries == 0 && _MBPO.MutationConfirmed == 1,
			"The current positive must confirm the real collector/writer/transaction, not only call a fake sink.")
		Parsed := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		_MBPO_Require(_LLM_Menu["model"] == _MBPO.ModelB && Features["llm"]["models"]["ollama"] == _MBPO.ModelB
			&& Parsed["llm"]["models"]["ollama"] == _MBPO.ModelB && Hash != _MBPO.OriginalHash,
			"Model B must be durable in independently parsed private TOML and published into both real RAM owners.")
		return
	}
	if _MBPO.Mode == "during-close" {
		_MBPO_Require(_MBPO.DestroyCalls == 1 && _MBPO.PauseObserved && A_IsSuspended
			&& _MBPO.PauseImage is Buffer && _MBPO.PauseHash != "",
			"The exact native WM_DESTROY must establish and snapshot the actual late pause.")
		_MBPO_Require(_MBPO.PausedWriterEntries == 0,
			"A model selection must not enter its durable writer while the driver is natively paused.")
		_MBPO_Require(Hash == _MBPO.PauseHash && Image.Size == _MBPO.PauseImage.Size,
			"The actual file image captured at pause must survive; a legitimate commit before Close is permitted.")
		return
	}
	_MBPO_Require(A_IsSuspended && _MBPO.DestroyCalls == 0 && _MBPO.WriterEntries == 0
		&& _LLM_Menu["model"] == _MBPO.ModelA && Hash == _MBPO.OriginalHash
		&& _LLM_MBW_SessionEpoch == _MBPO.Epoch && DllCall("User32\IsWindow", "Ptr", _MBPO.Hwnd, "Int"),
		"An already paused SDK command must leave its host and durable selection untouched.")
	Suspend(false)
	_MBPO_Observe()
	_MBPO_Require(_MBPO.DestroyCalls == 0 && _MBPO.WriterEntries == 0
		&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash,
		"Resume alone cannot replay the refused paused-entry command.")
}

_MBPO_Main() {
	global _MBPO, _LLM_MBW_Gui, _LLM_MBW_Controller, _LLM_MBW_WebView, _LLM_MBW_MsgSub
	_MBPO := {Mode: A_Args[1], Window: 0, Hwnd: 0, Epoch: 0, Args: 0, Original: 0,
		OriginalHash: "", ReadyReads: 0, PauseImage: 0, PauseHash: "", ModelA: "", ModelB: "", CommandIssued: false,
		DestroyCalls: 0, PauseObserved: false, WriterEntries: 0, WriterConfirmed: 0,
		PausedWriterEntries: 0, MutationReturns: 0, MutationConfirmed: 0, RepaintRequests: 0,
		Pulses: 0, Cleaning: false, Errors: [], Failure: 0}
	_MBPO_Require(_MBPO.Mode == "current" || _MBPO.Mode == "during-close" || _MBPO.Mode == "paused-entry",
		"The model browser mode must be explicit.")
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_MBPO_OnError)
	LoggerSetTestSink(_MBPO_Log)
	Primary := 0, WasSuspended := A_IsSuspended, PreviousCritical := Critical("Off")
	Thread("Interrupt", 0)
	OnMessage(0x2, _MBPO_Destroy)
	try {
		Suspend(false)
		SetTimer(_MBPO_Pulse, 10)
		_MBPO_Run()
	} catch Any as Failure {
		Primary := IsObject(_MBPO.Failure) ? _MBPO.Failure : Failure
	} finally {
		_MBPO.Cleaning := true
		try SetTimer(_MBPO_Pulse, 0)
		catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			if IsObject(_MBPO.Window) && DllCall("User32\IsWindow", "Ptr", _MBPO.Hwnd, "Int")
				_LLM_MBW_OnClose()
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			if IsObject(_MBPO.Window) && DllCall("User32\IsWindow", "Ptr", _MBPO.Hwnd, "Int")
				_MBPO.Window.Destroy()
			_MBPO_Require(!_MBPO.Hwnd || !DllCall("User32\IsWindow", "Ptr", _MBPO.Hwnd, "Int"),
				"The exact privately owned native window must retire on every path.")
			_MBPO_Require(!IsSet(_LLM_MBW_Controller) && !IsSet(_LLM_MBW_WebView) && !IsSet(_LLM_MBW_MsgSub),
				"No COM controller or subscription may be fabricated or remain owned by this component.")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnMessage(0x2, _MBPO_Destroy, 0)
		LoggerClearTestSink()
		OnError(_MBPO_OnError, 0)
		Suspend(WasSuspended)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_MBPO.Failure)
		Primary := _MBPO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS model-browser-close-pause-owner " . _MBPO.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_MBPO_Main()
