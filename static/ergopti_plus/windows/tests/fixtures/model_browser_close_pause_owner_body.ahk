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
		if HasProp(_MBPO, "AdmissionArmed") && _MBPO.AdmissionArmed && !_MBPO.AdmissionActorFired {
			FirstConfirmed := InStr(Line, "[LLMObservation.mutation-return.returned]") && InStr(Line, "status=confirmed")
			SecondSchemaMode := _MBPO.Mode == "native-backend-second-schema-pause"
			SecondWriterMode := _MBPO.Mode == "native-backend-second-writer-replaced"
			DeferredMode := SecondSchemaMode || SecondWriterMode
			if DeferredMode && FirstConfirmed
				_MBPO.FirstModelAckObserved := true
			else if (!DeferredMode && FirstConfirmed) || (DeferredMode
					&& HasProp(_MBPO, "FirstModelAckObserved") && _MBPO.FirstModelAckObserved
					&& InStr(Line, SecondWriterMode ? "[LLMObservation.durable-writer.enter]" : "[LLMObservation.schema-admission.enter]")) {
				_MBPO.AtSecondWriter := SecondWriterMode
				_MBPO.AtSecondSchema := SecondSchemaMode
				_MBPO.AdmissionActorFired := true
				_MBPO_BackendAdmissionActor()
			}
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
	global _LLM_IndexCache, _LLM_PresetsCache
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_Ollama_WarmupHttp, _LLM_ManagedBootstrap, _OllamaWV_Gui
	global _LLM_MBW_Controller, _LLM_MBW_WebView, _LLM_MBW_MsgSub, _LLM_MBW_ResetDone, _LLM_MBW_Ready
	Directory := A_Args[2] . "\config"
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	_MBPO_Require((Creation is Integer) && Creation == 1, "The private configuration directory must be acquired exclusively")
	ConfigurationFile := Directory . "\config.toml"
	if _MBPO.Mode == "native-ctor-malformed" {
		_MBPO_Require(!IsSet(_LLM_IndexCache) && !IsSet(_LLM_PresetsCache), "Malformed metadata must enter the genuine cold reader, not an overwritten cache")
		ModelsPath := LLM_GetSharedPath("models.json")
		RawModels := FSReadUtf8Exact(ModelsPath)
		ChangedModels := RegExReplace(RawModels, '("speed_tok_s"\s*:\s*)[0-9]+(?:\.[0-9]+)?', '$1{"unexpected":"object-speed"}', &ChangedFields, 1)
		_MBPO_Require(ChangedFields == 1 && JsonParse(ChangedModels) is Array,
			"Only one actual shipped numeric speed leaf may become a valid JSON object")
		_MBPO_Require(FSWriteDurable(ModelsPath, ChangedModels), "The exclusively owned private asset must reach disk before the real reader")
	}
	Index := LLM_GetModelIndex()
	_MBPO.ModelA := _MBPO.Mode == "native-sort" ? "Qwen3.5-9B" : LLM_Defaults["llm_model"]
	if _MBPO.Mode == "native-ctor-malformed" {
		BadSpeeds := 0
		for Name, Info in Index
			if Info.Get("speed_tok_s", 0) is Map
				BadSpeeds += 1
		_MBPO_Require(BadSpeeds == 1, "The genuine JSON parser and metadata decoder must expose exactly the changed object leaf")
		_MBPO.BadMetadataDecoded := true
	}
	_MBPO_Require(Index is Map && Index.Has(_MBPO.ModelA), "The baseline must come from the real shared model catalogue/defaults.")
	for Name in Index {
		if Name != _MBPO.ModelA {
			_MBPO.ModelB := Name
			break
		}
	}
	_MBPO_Require(_MBPO.ModelB != "" && _LLM_MBW_IsCatalogueModelName(_MBPO.ModelB),
		"A distinct real catalogue model must pass the actual SDK value admission.")
	_MBPO.InitialBackend := _MBPO.Mode == "native-backend-current" ? "ollama" : "api"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion()
		. '`n[script]`nlocale = "fr"`n[llm]`nenabled = false`n[llm.models]`nselected = '
		. JsonStringLiteral(_MBPO.InitialBackend) . '`nollama = '
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
	_MBPO_Require(!_LLM_Menu["enabled"] && _LLM_Menu["backend"] == _MBPO.InitialBackend
		&& _LLM_Menu["model"] == _MBPO.ModelA && !_LLM_Menu["auto_profile_for_model"],
		"The private disabled state must preserve its actual backend/model without starting network dependencies.")
	_MBPO_Require(!_LLM_Menu_Loaded, "Candidate collection must use its real explicit menu source, not a fabricated loaded flag.")
	if InStr(_MBPO.Mode, "native-backend-") == 1 {
		; Model activation always invalidates its previous Ollama owners, even
		; when inference is disabled. Run that genuine neutral cleanup before SUT.
		_MBPO_Require(_LLM_AuxOwners.Count == 0 && _LLM_AuxCleanupDebt.Count == 0
			&& _LLM_Ollama_WarmupHttp == 0 && !IsObject(_LLM_ManagedBootstrap) && !IsSet(_OllamaWV_Gui),
			"The actual runtime owners must start idle without a transport, installer or browser")
		_MBPO_Require(LLM_Menu_CancelOllamaOwnership() == true && _MBPO.Errors.Length == 0,
			"The genuine idle Ollama lifecycle must be admitted without missing owners before native model selection")
		FileAppend("RECEIPT native-model-lifecycle idle_cleanup_confirmed=1 errors=" . _MBPO.Errors.Length . "`n", "*", "UTF-8-RAW")
	}

	_MBPO.Original := FSReadBytesStrict(ConfigurationFile)
	_MBPO.OriginalHash := CryptoSha256Bytes(_MBPO.Original)
	_MBPO_Require(_MBPO.OriginalHash != "", "The independent original RAW image must be measurable.")
	_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(_MBPO_Repaint, _MBPO_IsPaused, _MBPO_BuildError)
	if InStr(_MBPO.Mode, "native-") == 1
		return
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

_MBPO_NativeCommand(WParam, LParam, Message, Hwnd) {
	global _MBPO
	if LParam == _MBPO.NativePick && ((WParam >> 16) & 0xFFFF) == 0
		_MBPO.NativeCommands += 1
}

_MBPO_NativeClick(ButtonHwnd, ExpectedReturns) {
	global _MBPO
	BeforeCommands := _MBPO.NativeCommands
	DllCall("User32\SendMessageW", "Ptr", ButtonHwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (_MBPO.NativeCommands == BeforeCommands || _MBPO.MutationReturns < ExpectedReturns) && !IsObject(_MBPO.Failure) && TickElapsed(Started) < 3000
		Sleep(10)
	_MBPO_Observe()
	_MBPO_Require(_MBPO.NativeCommands == BeforeCommands + 1
		&& _MBPO.MutationReturns == ExpectedReturns && !IsObject(_MBPO.Failure),
		"the actual native Pick event must settle its real model transaction")
}

_MBPO_NativeRefused() {
	global _MBPO, _LLM_ModelBrowser_Gui, ConfigurationFile, _LLM_Menu, Features
	_MBPO.Window := _LLM_ModelBrowser_Build()
	_MBPO.Hwnd := _MBPO.Window.Hwnd
	_LLM_ModelBrowser_Gui := _MBPO.Window
	_MBPO.Window.Show("NA")
	List := _MBPO.Window.ListView, Selected := 0, ButtonHwnd := 0
	Loop List.GetCount() {
		if List.GetText(A_Index, 1) == _MBPO.ModelB
			Selected := A_Index
	}
	_MBPO_Require(Selected > 0, "the genuine catalogue ListView must contain B")
	List.Modify(0, "-Select")
	List.Modify(Selected, "Select Focus")
	for Control in _MBPO.Window {
		if Control.Type == "Button" && Control.Text == t("menu.llm.browse_pick")
			ButtonHwnd := Control.Hwnd
	}
	_MBPO_Require(ButtonHwnd != 0, "the actual native Pick button must resolve")
	_MBPO.NativePick := ButtonHwnd
	if _MBPO.Mode == "native-paused" {
		Suspend(true)
		try {
			_MBPO_NativeClick(ButtonHwnd, 0)
			_MBPO_Require(_MBPO.WriterEntries == 0 && _MBPO.Errors.Length == 0
				&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash
				&& _LLM_Menu["model"] == _MBPO.ModelA && Features["llm"]["models"]["ollama"] == _MBPO.ModelA
				&& DllCall("User32\IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
				"a real native Pick click while paused must not enter persistence or hide its browser")
		} finally Suspend(false)
		_MBPO_Observe()
		_MBPO_Require(_MBPO.MutationReturns == 0
			&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash,
			"resuming must not replay a native selection refused while paused")
	} else {
		Lease := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "native-browser-test")
		_MBPO_Require(Lease is Object, "a genuine configuration lease must own the deterministic refusal")
		try {
			_MBPO_NativeClick(ButtonHwnd, 1)
			_MBPO_Require(DllCall("User32\IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
				"a refused native model selection must keep the browser visible")
			_MBPO_Require(CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash
				&& _LLM_Menu["model"] == _MBPO.ModelA && Features["llm"]["models"]["ollama"] == _MBPO.ModelA
				&& _MBPO.WriterEntries == 0 && _MBPO.MutationConfirmed == 0,
				"the actual lease refusal must preserve both durable and live model A")
			_MBPO_Require(_MBPO.Errors.Length == 1 && InStr(_MBPO.Errors[1], "another configuration transaction owns the global barrier"),
				"only the intentional, identified lease refusal can explain the negative result")
		} finally _ConfigWriteLeaseRelease(Lease)
	}
	ExpectedCommits := _LLM_Menu["backend"] == "ollama" ? 1 : 2
	_MBPO_NativeClick(ButtonHwnd, _MBPO.MutationReturns + ExpectedCommits)
	Parsed := TOML_ParseFreshFile(ConfigurationFile)
	_MBPO_Require(Parsed is Map && Parsed.Has("llm.models") && Parsed["llm.models"] is Map
		&& Parsed["llm.models"].Has("ollama"),
		"The genuine uncached TOML parser must expose the literal llm.models section and its model leaf.")
	_MBPO_Require(_LLM_Menu["model"] == _MBPO.ModelB && Features["llm"]["models"]["ollama"] == _MBPO.ModelB
		&& Parsed["llm.models"]["ollama"] == _MBPO.ModelB && _MBPO.WriterConfirmed == ExpectedCommits
		&& _MBPO.MutationConfirmed == ExpectedCommits, "retry must really publish the model and active backend through the actual durable writer")
	_MBPO_Require(_LLM_Menu["backend"] == "ollama" && Features["llm"]["models"]["selected"] == "ollama"
		&& Parsed["llm.models"].Get("selected", ManifestDefaultFor("llm.models.selected")) == "ollama",
		"A successful fresh retry must activate the selected local backend in every real projection")
	_MBPO_Require(!DllCall("User32\IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
		"the acknowledged retry may hide its exact original browser")
	FileAppend("RECEIPT native-model-refusal negative=lease positive=durable writer_confirmed=" . _MBPO.WriterConfirmed . "`n", "*", "UTF-8-RAW")
}

_MBPO_NativeSortSelection(List, Phase) {
	global _MBPO
	Selected := List.GetNext(0), Small := 0, Large := 0
	_MBPO_Require(Selected > 0 && List.GetText(Selected, 1) == _MBPO.ModelA,
		"The actual native selected row must name the active model after " . Phase . ".")
	Loop List.GetCount() {
		Name := List.GetText(A_Index, 1)
		if Name == "Qwen3.5-9B"
			Small := A_Index
		if Name == "Qwen3.5-27B"
			Large := A_Index
	}
	_MBPO_Require(Small > 0 && Large > Small,
		"The real native rows must retain numeric parameter order: 9B before 27B after " . Phase . ".")
}

_MBPO_NativeSort() {
	global _MBPO, _LLM_ModelBrowser_Gui, _LLM_Menu, ConfigurationFile
	Index := LLM_GetModelIndex()
	_MBPO_Require(Index.Has("Qwen3.5-9B") && Index.Has("Qwen3.5-27B")
		&& Index["Qwen3.5-9B"]["params_b"] < Index["Qwen3.5-27B"]["params_b"],
		"The genuine catalogue must supply the lexical-versus-numeric ordering counterexample.")
	_MBPO.Window := _LLM_ModelBrowser_Build()
	_MBPO.Hwnd := _MBPO.Window.Hwnd
	_LLM_ModelBrowser_Gui := _MBPO.Window
	_MBPO.Window.Show("NA")
	List := _MBPO.Window.ListView
	_MBPO_NativeSortSelection(List, "initial construction")
	_LLM_ModelBrowser_RefreshRows(List)
	_MBPO_NativeSortSelection(List, "full refresh")
	_LLM_ModelBrowser_RefreshRows(List, "Qwen3.5")
	_MBPO_NativeSortSelection(List, "family filter")
	_LLM_ModelBrowser_RefreshRows(List, "no-such-audit-catalogue-model")
	_MBPO_Require(List.GetCount() == 0 && List.GetNext(0) == 0,
		"A filter with no catalogue match must leave no selected row.")
	_LLM_ModelBrowser_RefreshRows(List)
	_MBPO_NativeSortSelection(List, "filter removal")
	_MBPO_Require(_MBPO.WriterEntries == 0 && _MBPO.MutationReturns == 0 && _MBPO.Errors.Length == 0
		&& _LLM_Menu["model"] == _MBPO.ModelA
		&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash,
		"Construction, selection highlighting and filtering must preserve the actual durable active model.")
	FileAppend("RECEIPT native-model-sort active=" . List.GetText(List.GetNext(0), 1)
		. " count=" . List.GetCount() . "`n", "*", "UTF-8-RAW")
}

_MBPO_Run() {
	global _MBPO, ConfigurationFile, _LLM_Menu, Features, _LLM_MBW_SessionEpoch
	_MBPO_Prepare()
	if _MBPO.Mode == "native-show-current" || _MBPO.Mode == "native-show-close" || _MBPO.Mode == "native-hide-reopen-close" {
		_MBPO_VisibilityReentry()
		return
	}
	if _MBPO.Mode == "native-ctor-current" || _MBPO.Mode == "native-ctor-malformed" {
		_MBPO_ConstructorFailure()
		return
	}
	if _MBPO.Mode == "native-hide-current" || _MBPO.Mode == "native-hide-reopen" || _MBPO.Mode == "native-hide-native-current" || _MBPO.Mode == "native-hide-native-reopen" {
		_MBPO_ShowHide()
		return
	}
	if _MBPO.Mode == "native-backend-second-refused" || _MBPO.Mode == "native-backend-replaced" || _MBPO.Mode == "native-backend-pause-resume" || _MBPO.Mode == "native-backend-superseded" || _MBPO.Mode == "native-backend-second-schema-pause" || _MBPO.Mode == "native-backend-second-writer-replaced" {
		_MBPO_BackendAdmission()
		return
	}
	if _MBPO.Mode == "native-backend-current" || _MBPO.Mode == "native-backend-api" {
		_MBPO_NativeBackendPick()
		return
	}
	if _MBPO.Mode == "native-sort" {
		_MBPO_NativeSort()
		return
	}
	if InStr(_MBPO.Mode, "native-") == 1 {
		_MBPO_NativeRefused()
		return
	}
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
		Pulses: 0, Cleaning: false, Errors: [], Failure: 0, NativePick: 0, NativeCommands: 0, InitialBackend: "", BackendPickReturns: 0}
	_MBPO_Require(_MBPO.Mode == "current" || _MBPO.Mode == "during-close" || _MBPO.Mode == "paused-entry" || _MBPO.Mode == "native-refused" || _MBPO.Mode == "native-paused" || _MBPO.Mode == "native-sort"
		|| _MBPO.Mode == "native-backend-current" || _MBPO.Mode == "native-backend-api"
		|| _MBPO.Mode == "native-backend-second-refused" || _MBPO.Mode == "native-backend-replaced" || _MBPO.Mode == "native-backend-pause-resume" || _MBPO.Mode == "native-backend-superseded" || _MBPO.Mode == "native-backend-second-schema-pause" || _MBPO.Mode == "native-backend-second-writer-replaced"
		|| _MBPO.Mode == "native-hide-current" || _MBPO.Mode == "native-hide-reopen"
		|| _MBPO.Mode == "native-hide-native-current" || _MBPO.Mode == "native-hide-native-reopen"
		|| _MBPO.Mode == "native-show-current" || _MBPO.Mode == "native-show-close" || _MBPO.Mode == "native-hide-reopen-close"
		|| _MBPO.Mode == "native-ctor-current" || _MBPO.Mode == "native-ctor-malformed",
		"The model browser mode must be explicit.")
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_MBPO_OnError)
	LoggerSetTestSink(_MBPO_Log)
	Primary := 0, WasSuspended := A_IsSuspended, PreviousCritical := Critical("Off")
	Thread("Interrupt", 0)
	OnMessage(0x2, _MBPO_Destroy)
	OnMessage(0x111, _MBPO_NativeCommand)
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
		OnMessage(0x111, _MBPO_NativeCommand, 0)
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

_MBPO_BackendPickReturned(This, Args*) {
	global _MBPO
	try return Func.Prototype.Call.Call(This, Args*)
	finally _MBPO.BackendPickReturns += 1
}

_MBPO_NativeBackendPick() {
	global _MBPO, _LLM_ModelBrowser_Gui, _LLM_Menu, Features, ConfigurationFile
	Picker := _LLM_ModelBrowser_PickRow
	HadCall := Picker.HasOwnProp("Call")
	if HadCall
		OldCall := Picker.GetOwnPropDesc("Call")
	Installed := false
	try {
		_MBPO.Window := _LLM_ModelBrowser_Build()
		_MBPO.Hwnd := _MBPO.Window.Hwnd
		_LLM_ModelBrowser_Gui := _MBPO.Window
		_MBPO.Window.Show("NA")
		List := _MBPO.Window.ListView, Selected := 0, ButtonHwnd := 0
		Loop List.GetCount() {
			if List.GetText(A_Index, 1) == _MBPO.ModelB
				Selected := A_Index
		}
		_MBPO_Require(Selected > 0, "The actual catalogue ListView must contain selected model B")
		List.Modify(0, "-Select"), List.Modify(Selected, "Select Focus")
		for Control in _MBPO.Window {
			if Control.Type == "Button" && Control.Text == t("menu.llm.browse_pick")
				ButtonHwnd := Control.Hwnd
		}
		_MBPO_Require(ButtonHwnd != 0, "The genuine native Pick button must be identified")
		_MBPO.NativePick := ButtonHwnd
		BeforeCommands := _MBPO.NativeCommands
		Picker.DefineProp("Call", {Call: _MBPO_BackendPickReturned}), Installed := true
		DllCall("User32\SendMessageW", "Ptr", ButtonHwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while _MBPO.BackendPickReturns == 0 && !IsObject(_MBPO.Failure) && TickElapsed64(Started) < 3000
			Sleep(10)
		_MBPO_Observe()
		_MBPO_Require(!IsObject(_MBPO.Failure) && _MBPO.BackendPickReturns == 1 && _MBPO.NativeCommands == BeforeCommands + 1,
			"Exactly one genuine BM_CLICK must return from the real production Pick handler")
		Parsed := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		; The native sparse writer removes the selected backend at its genuine default.
		DurableBackend := Parsed["llm"]["models"].Get("selected", ManifestDefaultFor("llm.models.selected"))
		Caption := _LLM_Menu_ModelDisplayText()
		FileAppend("RECEIPT native-model-backend mode=" . _MBPO.Mode . " before=" . _MBPO.InitialBackend
			. " live_backend=" . _LLM_Menu["backend"] . " feature_backend=" . Features["llm"]["models"]["selected"]
			. " durable_backend=" . DurableBackend
			. " model_b=" . (_LLM_Menu["model"] == _MBPO.ModelB) . " caption_b=" . (Caption == _MBPO.ModelB)
			. " visible=" . DllCall("User32\IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int")
			. " writers=" . _MBPO.WriterConfirmed . " mutation_returns=" . _MBPO.MutationReturns
			. " mutation_confirmed=" . _MBPO.MutationConfirmed . " errors=" . _MBPO.Errors.Length . "`n", "*", "UTF-8-RAW")
		; This private seeded child retains every original logger cause; export
		; outside the sink before judging its unchanged zero-error contract.
		for Index, Line in _MBPO.Errors
			FileAppend("DIAGNOSTIC native-model-backend error_index=" . Index
				. " logger_error=" . JsonStringLiteral(Line) . "`n", "*", "UTF-8-RAW")
		_MBPO_Require(_MBPO.WriterConfirmed >= 1 && _MBPO.MutationReturns >= 1
			&& _MBPO.MutationReturns == _MBPO.MutationConfirmed && _MBPO.Errors.Length == 0,
			"Actual schema/collector/native writer and acknowledged model mutation must complete without errors")
		_MBPO_Require(_LLM_Menu["model"] == _MBPO.ModelB && Features["llm"]["models"]["ollama"] == _MBPO.ModelB
			&& Parsed["llm"]["models"]["ollama"] == _MBPO.ModelB,
			"The chosen row must actually publish model B in the real menu, features and durable file")
		_MBPO_Require(_LLM_Menu["backend"] == "ollama" && Features["llm"]["models"]["selected"] == "ollama"
			&& DurableBackend == "ollama" && Caption == _MBPO.ModelB,
			"Selecting a catalogue Ollama model through the sole model-selector must activate it, including from API backend")
		_MBPO_Require(!DllCall("User32\IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
			"Only the acknowledged actual active selection may hide its native selector")
	} finally {
		if Installed {
			if HadCall
				Picker.DefineProp("Call", OldCall)
			else
				Picker.DeleteProp("Call")
		}
	}
}

_MBPO_Main()


; The actor runs at the real transaction-return logger boundary AFTER the first
; model's durable/live ACK and after its genuine configuration bundle released.
_MBPO_BackendAdmissionActor() {
	global _MBPO, ConfigurationFile, _LLM_ModelBrowser_Gui
	if _MBPO.Mode == "native-backend-second-refused" {
		_MBPO.AdmissionLease := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "native-backend-second-admission")
		_MBPO_Require(_MBPO.AdmissionLease is Object, "A real lease must own the second, not the first, configuration refusal")
	} else if _MBPO.Mode == "native-backend-replaced" || _MBPO.Mode == "native-backend-second-writer-replaced" {
		_LLM_ModelBrowser_OnClose()
		_MBPO.ReplacementWindow := _LLM_ModelBrowser_Build()
		_LLM_ModelBrowser_Gui := _MBPO.ReplacementWindow
		_MBPO.ReplacementWindow.Show("NA")
		_MBPO.ReplacementHwnd := _MBPO.ReplacementWindow.Hwnd
		_MBPO_Require(DllCall("IsWindowVisible", "Ptr", _MBPO.ReplacementHwnd, "Int"), "The genuine replacement native browser must be visible")
	} else if _MBPO.Mode == "native-backend-superseded" {
		Nested := LLM_Menu_SetModel(_MBPO.ModelA)
		Image := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		_MBPO.SupersededConfirmed := Nested is Integer && Nested == 1
			&& _LLM_Menu["model"] == _MBPO.ModelA && Image["llm"]["models"].Get("ollama", ManifestDefaultFor("llm.models.ollama")) == _MBPO.ModelA
			&& _LLM_Menu["backend"] == "api"
		FileAppend("RECEIPT native-backend-superseding confirmed=" . _MBPO.SupersededConfirmed
			. " actual_model_a=" . (_LLM_Menu["model"] == _MBPO.ModelA) . " backend=" . _LLM_Menu["backend"] . "`n", "*", "UTF-8-RAW")
		_MBPO_Require(_MBPO.SupersededConfirmed, "The newer public model mutation must actually acknowledge its real durable/live A before the old picker resumes")
	} else {
		; This uses the canonical transition allocator and native suspend bit.
		; It does not claim to execute every full-driver suspend/resume owner.
		Transition := LifecycleTransitionBegin("suspend")
		LifecycleTransitionMarkStarted(Transition)
		Suspend(true)
		_MBPO.NativePaused := A_IsSuspended
		_MBPO_Require(LifecycleTransitionFinish(Transition), "The narrow transition allocator must close its own frame")
		Resumed := LifecycleTransitionBegin("resume")
		LifecycleTransitionMarkStarted(Resumed)
		Suspend(false)
		_MBPO.NativeResumed := !A_IsSuspended
		_MBPO_Require(LifecycleTransitionFinish(Resumed) && _MBPO.NativePaused && _MBPO.NativeResumed,
			"Actual native pause/resume must finish before the old model handler resumes")
	}
}
_MBPO_BackendAdmissionReturned(This, Args*) {
	global _MBPO
	try {
		Result := Func.Prototype.Call.Call(This, Args*)
		_MBPO.AdmissionReturns.Push(Result)
		return Result
	} finally _MBPO.BackendPickReturns += 1
}
_MBPO_BackendAdmissionClick(ButtonHwnd, ExpectedReturn) {
	global _MBPO
	BeforeCommands := _MBPO.NativeCommands
	DllCall("SendMessageW", "Ptr", ButtonHwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while _MBPO.BackendPickReturns < ExpectedReturn && !IsObject(_MBPO.Failure) && TickElapsed(Started) < 3000
		Sleep(10)
	_MBPO_Observe()
	_MBPO_Require(!IsObject(_MBPO.Failure) && _MBPO.BackendPickReturns == ExpectedReturn
		&& _MBPO.NativeCommands == BeforeCommands + 1 && _MBPO.AdmissionReturns.Length == ExpectedReturn,
		"The actual native button must return through the unchanged production Pick handler exactly once")
}
_MBPO_BackendAdmission() {
	global _MBPO, ConfigurationFile, _LLM_Menu, Features, _LLM_ModelBrowser_Gui
	_MBPO.AdmissionArmed := false, _MBPO.AdmissionActorFired := false, _MBPO.AdmissionLease := 0
	_MBPO.AdmissionReturns := [], _MBPO.ReplacementWindow := 0, _MBPO.NativePaused := false, _MBPO.NativeResumed := false
	Picker := _LLM_ModelBrowser_PickRow, HadCall := Picker.HasOwnProp("Call")
	if HadCall
		OriginalCall := Picker.GetOwnPropDesc("Call")
	Installed := false
	try {
		_MBPO.Window := _LLM_ModelBrowser_Build(), _MBPO.Hwnd := _MBPO.Window.Hwnd
		_LLM_ModelBrowser_Gui := _MBPO.Window
		_MBPO.Window.Show("NA")
		List := _MBPO.Window.ListView, Selected := 0, ButtonHwnd := 0
		Loop List.GetCount()
			if List.GetText(A_Index, 1) == _MBPO.ModelB
				Selected := A_Index
		_MBPO_Require(Selected > 0, "The actual constructor must contain the real catalogue model B")
		List.Modify(0, "-Select"), List.Modify(Selected, "Select Focus")
		for Control in _MBPO.Window
			if Control.Type == "Button" && Control.Text == t("menu.llm.browse_pick")
				ButtonHwnd := Control.Hwnd
		_MBPO_Require(ButtonHwnd != 0 && _MBPO.InitialBackend == "api", "The first genuine Pick must start from the real API backend")
		_MBPO.NativePick := ButtonHwnd
		Picker.DefineProp("Call", {Call: _MBPO_BackendAdmissionReturned}), Installed := true
		_MBPO.AdmissionArmed := true
		_MBPO_BackendAdmissionClick(ButtonHwnd, 1)
		Parsed := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		FileAppend("RECEIPT native-backend-admission mode=" . _MBPO.Mode . " actor=" . _MBPO.AdmissionActorFired
			. " returned=" . _MBPO.AdmissionReturns[1] . " model_b=" . (_LLM_Menu["model"] == _MBPO.ModelB)
			. " backend=" . _LLM_Menu["backend"] . " writers=" . _MBPO.WriterConfirmed
			. " mutations=" . _MBPO.MutationReturns . " confirmed=" . _MBPO.MutationConfirmed
			. " errors=" . _MBPO.Errors.Length . "`n", "*", "UTF-8-RAW")
		if _MBPO.Mode == "native-backend-superseded" {
			_MBPO_Require(_MBPO.SupersededConfirmed && _MBPO.AdmissionActorFired,
				"The genuine newer model setter must complete before judging the original row")
			_MBPO_Require(_MBPO.AdmissionReturns[1] is Integer && _MBPO.AdmissionReturns[1] == 0
				&& _MBPO.Errors.Length == 0 && _LLM_Menu["model"] == _MBPO.ModelA
				&& Features["llm"]["models"]["ollama"] == _MBPO.ModelA
				&& Parsed["llm"]["models"].Get("ollama", ManifestDefaultFor("llm.models.ollama")) == _MBPO.ModelA
				&& _LLM_Menu["backend"] == "api" && Features["llm"]["models"]["selected"] == "api"
				&& Parsed["llm"]["models"]["selected"] == "api"
				&& DllCall("IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
				"The old B handler cannot activate A's backend or hide after the real newer model intent supersedes it")
			return
		}
		_MBPO_Require(_MBPO.AdmissionActorFired && _MBPO.AdmissionReturns[1] is Integer && _MBPO.AdmissionReturns[1] == 0,
			"The original admitted model receipt must not certify the refused or withdrawn backend activation")
		_MBPO_Require(_MBPO.WriterConfirmed == 1 && _LLM_Menu["model"] == _MBPO.ModelB
			&& Features["llm"]["models"]["ollama"] == _MBPO.ModelB && Parsed["llm"]["models"]["ollama"] == _MBPO.ModelB,
			"The first actual model ACK remains durable and live; no pretend rollback may explain the refusal")
		_MBPO_Require(_LLM_Menu["backend"] == "api" && Features["llm"]["models"]["selected"] == "api"
			&& Parsed["llm"]["models"]["selected"] == "api", "The second backend admission must not commit after refusal or context withdrawal")
		if _MBPO.Mode == "native-backend-second-refused" {
			_MBPO_Require(_MBPO.AdmissionLease is Object && _MBPO.MutationReturns == 2 && _MBPO.MutationConfirmed == 1
				&& _MBPO.Errors.Length == 1 && InStr(_MBPO.Errors[1], "another configuration transaction owns the global barrier")
				&& DllCall("IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
				"The genuine second lease refusal alone must keep the chosen native row visible")
			_ConfigWriteLeaseRelease(_MBPO.AdmissionLease), _MBPO.AdmissionLease := 0
		} else if _MBPO.Mode == "native-backend-second-writer-replaced" {
			_MBPO_Require(_MBPO.AtSecondWriter && _MBPO.MutationReturns == 2 && _MBPO.MutationConfirmed == 1
				&& _MBPO.Errors.Length == 1 && InStr(_MBPO.Errors[1], "borrowed configuration writer")
				&& IsObject(_MBPO.ReplacementWindow) && _LLM_ModelBrowser_Gui == _MBPO.ReplacementWindow
				&& DllCall("IsWindowVisible", "Ptr", _MBPO.ReplacementHwnd, "Int"),
				"The original receipt must refuse the durable writer after its real mutator/collector without hiding B")
			return
		} else if _MBPO.Mode == "native-backend-second-schema-pause" {
			_MBPO_Require(_MBPO.AtSecondSchema && _MBPO.NativePaused && _MBPO.NativeResumed && !A_IsSuspended
				&& _MBPO.MutationReturns == 2 && _MBPO.MutationConfirmed == 1 && _MBPO.Errors.Length == 1
				&& InStr(_MBPO.Errors[1], "candidate construction was refused")
				&& DllCall("IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
				"The original receipt must refuse the real second mutator after bundle acquisition despite completed native pause/resume")
		} else {
			_MBPO_Require(_MBPO.MutationReturns == 1 && _MBPO.MutationConfirmed == 1 && _MBPO.Errors.Length == 0,
				"A withdrawn native context cannot begin the second transaction")
			if _MBPO.Mode == "native-backend-replaced" {
				_MBPO_Require(IsObject(_MBPO.ReplacementWindow) && _LLM_ModelBrowser_Gui == _MBPO.ReplacementWindow
					&& DllCall("IsWindowVisible", "Ptr", _MBPO.ReplacementHwnd, "Int"),
					"The returning old native selection cannot hide its real replacement")
				return
			}
			_MBPO_Require(_MBPO.NativePaused && _MBPO.NativeResumed && !A_IsSuspended
				&& DllCall("IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
				"Native resume alone must not complete the old activation or hide its original browser")
		}
		BeforeRetry := _MBPO.MutationReturns, ExpectedErrors := _MBPO.Errors.Length
		_MBPO_BackendAdmissionClick(ButtonHwnd, 2)
		Parsed := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		_MBPO_Require(_MBPO.AdmissionReturns[2] is Integer && _MBPO.AdmissionReturns[2] == 1
			&& _MBPO.MutationReturns == BeforeRetry + 2 && _MBPO.MutationConfirmed == 3 && _MBPO.WriterConfirmed == 3,
			"A fresh native Pick of the already stored B must obtain genuine model and backend ACKs")
		_MBPO_Require(_MBPO.Errors.Length == ExpectedErrors && _LLM_Menu["backend"] == "ollama"
			&& Features["llm"]["models"]["selected"] == "ollama"
			&& Parsed["llm"]["models"].Get("selected", ManifestDefaultFor("llm.models.selected")) == "ollama"
			&& _LLM_Menu_ModelDisplayText() == _MBPO.ModelB && !DllCall("IsWindowVisible", "Ptr", _MBPO.Hwnd, "Int"),
			"Only the fresh fully acknowledged activation may switch all backend projections and hide its native browser")
	} finally {
		_MBPO.AdmissionArmed := false
		if _MBPO.AdmissionLease is Object
			_ConfigWriteLeaseRelease(_MBPO.AdmissionLease)
		if Installed {
			if HadCall
				Picker.DefineProp("Call", OriginalCall)
			else
				Picker.DeleteProp("Call")
		}
		if IsObject(_MBPO.ReplacementWindow) {
			if IsSet(_LLM_ModelBrowser_Gui) && _LLM_ModelBrowser_Gui == _MBPO.ReplacementWindow
				_LLM_ModelBrowser_OnClose()
			try _MBPO.ReplacementWindow.Destroy()
			_LLM_ModelBrowser_Gui := _MBPO.Window
		}
		Suspend(false)
	}
}


; A genuine WM_SHOWWINDOW from the genuine Hide delegates its native window
; procedure first, then issues the real public Show. This is explicit native
; reentry, not a simulated timer gap before Hide or a fabricated Win32 failure.

_MBPO_CloseEventEntered(State, Window, *) {
	_MBPO_Require(Window == State.Window && Window.Hwnd == State.Hwnd,
		"Only this exact genuine GUI event may qualify the native Close")
	State.CloseEntries += 1
}
_MBPO_ShowHideProc(State, Hwnd, Message, WParam, LParam, Id, Data) {
	global _LLM_ModelBrowser_Gui, _LLM_ModelBrowser_Epoch
	State.Active += 1
	try {
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message, "Ptr", WParam, "Ptr", LParam, "Ptr")
		if State.Armed && !State.HideSeen && Hwnd == State.Hwnd && Message == 0x18 && !WParam {
			State.HideSeen := true
			State.EpochAtHide := _LLM_ModelBrowser_Epoch
			State.CallbackCritical := A_IsCritical
			if State.Reopen {
				_MBPO_Require(WinGetPID("ahk_id " . Hwnd) == ProcessExist(), "The natural visibility callback may only reopen its exact owned process")
				State.ShowReturned := LLM_ModelBrowser_Show()
				State.SameOwner := State.ShowReturned == State.Window && _LLM_ModelBrowser_Gui == State.Window
				State.VisibleDuring := !!DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int")
			}
		}
		return Result
	} catch Any as Failure {
		State.Failed := true, State.Failure := Failure
		return 0
	} finally State.Active -= 1
}
_MBPO_ShowHide() {
	global _MBPO, _LLM_ModelBrowser_Gui, _LLM_ModelBrowser_Epoch, _VendorDir, _DriverDir, ConfigurationFile
	HadVendor := IsSet(_VendorDir)
	if HadVendor
		OriginalVendor := _VendorDir
	else
		; This is the real uncompiled driver vendor location. The component
		; contains no browser SDK; availability must take its genuine false branch.
		_VendorDir := _DriverDir . "\vendor"
	PreviousCritical := Critical("Off")
	State := {Window: 0, Hwnd: 0, Proc: 0, Installed: false, Armed: false, Active: 0,
		HideSeen: false, Reopen: _MBPO.Mode == "native-hide-reopen" || _MBPO.Mode == "native-hide-native-reopen", CloseEntries: 0, EpochAtHide: -1, CallbackCritical: -1,
		SameOwner: false, VisibleDuring: false, Failed: false, Failure: 0, Debt: false}
	_MBPO.HideState := State
	try {
		_MBPO_Require(!_LLM_MBW_WebView2Available(), "The actual component must remain genuinely outside browser availability, not use a fallback policy stub")
		_MBPO.Window := _LLM_ModelBrowser_Build(), _MBPO.Hwnd := _MBPO.Window.Hwnd
		_LLM_ModelBrowser_Gui := _MBPO.Window
		State.Window := _MBPO.Window, State.Hwnd := _MBPO.Hwnd
		State.Window.Show("NA")
		_MBPO_Require(DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int")
			&& WinGetPID("ahk_id " . State.Hwnd) == ProcessExist(), "The genuine native browser must own its visible HWND before Close")
		State.Proc := CallbackCreate(_MBPO_ShowHideProc.Bind(State), , 6)
		_MBPO_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", State.Hwnd, "Ptr", State.Proc,
			"UPtr", 0x4D425348, "UPtr", 0, "Int"), "The exact native browser must admit its visibility witness")
		State.Installed := true, State.Armed := true
		BeforeEpoch := _LLM_ModelBrowser_Epoch
		if InStr(_MBPO.Mode, "native-hide-native-") == 1 {
			State.Window.OnEvent("Close", _MBPO_CloseEventEntered.Bind(State), -1)
			_MBPO_Require(DllCall("PostMessageW", "Ptr", State.Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
				"The native visibility check must post WM_CLOSE to its exact owned GUI")
			Started := A_TickCount
			while (!State.CloseEntries || !State.HideSeen) && TickElapsed(Started) < 1000
				Sleep(10)
			_MBPO_Require(State.CloseEntries == 1 && State.HideSeen,
				"The actual registered native Close handler must reach its own Hide before visibility is judged")
		} else
			_LLM_ModelBrowser_OnClose()
		_MBPO_Observe()
		State.Armed := false
		VisibleAfter := !!DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int")
		FileAppend("OBSERVATION native-model-show-hide mode=" . _MBPO.Mode . " hide_seen=" . State.HideSeen
			. " epoch_before=" . BeforeEpoch . " epoch_at_hide=" . State.EpochAtHide
			. " same_owner=" . State.SameOwner . " visible_during_show=" . State.VisibleDuring
			. " visible_after_close=" . VisibleAfter . " callback_critical=" . State.CallbackCritical . "`n", "*", "UTF-8-RAW")
		if State.Failed
			FileAppend("DIAGNOSTIC native-model-show-hide callback_type=" . JsonStringLiteral(Type(State.Failure))
				. " callback_message=" . JsonStringLiteral(State.Failure is Error ? State.Failure.Message : "non-Error callback value") . "`n", "*", "UTF-8-RAW")
		_MBPO_Require(!State.Failed && State.HideSeen && State.EpochAtHide == BeforeEpoch + 1,
			"The real native visibility message must follow its original production Close claim")
		_MBPO_Require(_MBPO.Errors.Length == 0 && _MBPO.WriterEntries == 0
			&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash,
			"A natural window visibility check must never need configuration writes or technical errors")
		if State.Reopen
			_MBPO_Require(State.SameOwner && State.VisibleDuring && VisibleAfter,
				"A newer actual public Show accepted during native Hide must remain visible after the older Close returns")
		else
			_MBPO_Require(!VisibleAfter, "The current Close without a newer Show must still hide its actual browser")
	} finally {
		State.Armed := false
		Removed := !State.Installed || !DllCall("IsWindow", "Ptr", State.Hwnd, "Int")
		if !Removed
			Removed := !!DllCall("Comctl32\RemoveWindowSubclass", "Ptr", State.Hwnd, "Ptr", State.Proc, "UPtr", 0x4D425348, "Int")
		Started := A_TickCount
		while State.Active && TickElapsed(Started) < 1000
			Sleep(1)
		if Removed && !State.Active {
			if State.Proc
				CallbackFree(State.Proc)
			State.Proc := 0
		} else
			State.Debt := true
		if HasProp(State, "ShowReturned") && IsObject(State.ShowReturned) && State.ShowReturned != State.Window
			try State.ShowReturned.Destroy()
		if HadVendor
			_VendorDir := OriginalVendor
		else
			_VendorDir := unset
		Critical(PreviousCritical)
	}
	_MBPO_Require(!State.Debt, "The exact native subclass must retire before its callback memory is released")
}


; This marker holds only its independent scalar state, never the observed Gui.
class _MBPC_Finalizer {
	__New(State) {
		this.State := State
	}
	__Delete() {
		this.State.Disposed += 1
	}
}
; Native HWND custody includes hidden, not-yet-shown construction windows.
; WinGetPID's title search otherwise excludes them by default.
_MBPO_NativeWindowPid(Hwnd) {
	Pid := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &Pid, "UInt")
	return ThreadId ? Pid : 0
}

_MBPC_Create(This, Params*) {
	global _MBPO
	Window := Func.Prototype.Call.Call(This, Params*)
	State := _MBPO.CtorState
	if State.Armed {
		State.Created += 1
		State.Hwnd := Window.Hwnd, State.GuiPtr := ObjPtr(Window)
		State.Pid := _MBPO_NativeWindowPid(State.Hwnd)
		Window.CtorWitness := _MBPC_Finalizer(State)
	}
	return Window
}
_MBPO_ConstructorFailure() {
	global _MBPO, _LLM_ModelBrowser_Gui, _VendorDir, _DriverDir, ConfigurationFile
	_MBPO_Require(!IsSet(_LLM_ModelBrowser_Gui), "A cold constructor cannot borrow a cached native GUI")
	HadVendor := IsSet(_VendorDir)
	if HadVendor
		OriginalVendor := _VendorDir
	else
		_VendorDir := _DriverDir . "\vendor"
	Factory := Gui_Create, HadCall := Factory.HasOwnProp("Call")
	if HadCall
		OriginalCall := Factory.GetOwnPropDesc("Call")
	State := {Armed: false, Created: 0, Hwnd: 0, GuiPtr: 0, Pid: 0, Disposed: 0}
	_MBPO.CtorState := State
	Installed := false, Product := 0, Threw := false, FailureType := ""
	try {
		_MBPO_Require(!_LLM_MBW_WebView2Available(), "This constructor role requires genuine absence of the browser binding")
		Factory.DefineProp("Call", {Call: _MBPC_Create}), Installed := true, State.Armed := true
		try Product := LLM_ModelBrowser_Show()
		catch Any as Failure {
			Threw := true, FailureType := Type(Failure)
		}
		State.Armed := false
		_MBPO_Observe()
		Alive := !!DllCall("IsWindow", "Ptr", State.Hwnd, "Int")
		FileAppend("OBSERVATION native-model-constructor mode=" . _MBPO.Mode . " created=" . State.Created
			. " threw=" . Threw . " failure_type=" . FailureType . " native_alive=" . Alive
			. " published=" . IsSet(_LLM_ModelBrowser_Gui) . " disposed=" . State.Disposed . "`n", "*", "UTF-8-RAW")
		_MBPO_Require(State.Created == 1 && State.Pid == ProcessExist() && State.Hwnd != 0 && State.GuiPtr != 0,
			"The observer must delegate exactly one real production factory without retaining its object")
		_MBPO_Require(_MBPO.Errors.Length == 0 && _MBPO.WriterEntries == 0
			&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash,
			"Constructor input failure must not be confused with a configuration or runtime refusal")
		if _MBPO.Mode == "native-ctor-malformed" {
			_MBPO_Require(_MBPO.BadMetadataDecoded && Threw && FailureType == "TypeError",
				"The real malformed speed leaf must reach the actual native renderer before cleanup is judged")
			_MBPO_Require(!Alive && !IsSet(_LLM_ModelBrowser_Gui) && State.Disposed == 1,
				"An unsuccessful native constructor must retire its hidden HWND and captured callback graph")
		} else
			_MBPO_Require(!Threw && Product is Gui && IsSet(_LLM_ModelBrowser_Gui)
				&& _LLM_ModelBrowser_Gui == Product && Alive && DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int"),
				"The ordinary real catalogue must still produce its actual visible cached native browser")
	} finally {
		State.Armed := false
		if Installed {
			if HadCall
				Factory.DefineProp("Call", OriginalCall)
			else
				Factory.DeleteProp("Call")
		}
		Cleanup := IsSet(_LLM_ModelBrowser_Gui) && ObjPtr(_LLM_ModelBrowser_Gui) == State.GuiPtr ? _LLM_ModelBrowser_Gui : 0
		if !IsObject(Cleanup) && DllCall("IsWindow", "Ptr", State.Hwnd, "Int")
			Cleanup := GuiFromHwnd(State.Hwnd)
		if IsObject(Cleanup) {
			_MBPO_Require(ObjPtr(Cleanup) == State.GuiPtr && _MBPO_NativeWindowPid(State.Hwnd) == ProcessExist(),
				"Only the exact originally observed live Gui may be adopted for failure-path cleanup")
			if IsSet(_LLM_ModelBrowser_Gui) && _LLM_ModelBrowser_Gui == Cleanup
				_LLM_ModelBrowser_Gui := unset
			if Cleanup.HasOwnProp("FilterDebounce") {
				Timer := Cleanup.FilterDebounce
				SetTimer(Timer, 0)
				Cleanup.FilterDebounce := 0, Timer := 0
			}
			Cleanup.Destroy()
			if Cleanup.HasOwnProp("ListView")
				Cleanup.DeleteProp("ListView")
		}
		Product := 0, Cleanup := 0
		if HadVendor
			_VendorDir := OriginalVendor
		else
			_VendorDir := unset
	}
	_MBPO_Require(!DllCall("IsWindow", "Ptr", State.Hwnd, "Int") && State.Disposed == 1,
		"The exact privately observed native window and lifetime marker must settle before child exit")
}


; The window procedure delegates first and then issues a real public request.
; Each explicit action fires once; no fake Show/Hide ACK or timer is involved.
; This retained private sidecar is diagnostic only. It survives forced child
; retirement, so an unfinished callback cannot erase the last native phase.
_MBPO_VisibilityTrace(State, Phase) {
	if State.Mode != "native-hide-reopen-close" || !State.HasOwnProp("PhasePath")
		return
	try FileAppend(Phase . " active=" . State.Active . " shows=" . State.ShowCount
		. " closes=" . State.CloseCalls . " tick=" . A_TickCount . "`n", State.PhasePath, "UTF-8-RAW")
	catch
		State.TraceFailures += 1
}
_MBPO_VisibilityProc(State, Hwnd, Message, WParam, LParam, Id, Data) {
	global _LLM_ModelBrowser_Gui
	State.Active += 1
	try {
		if State.Armed && Hwnd == State.Hwnd && Message == 0x18
			_MBPO_VisibilityTrace(State, "callback.enter." . WParam)
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message, "Ptr", WParam, "Ptr", LParam, "Ptr")
		if State.Armed && Hwnd == State.Hwnd && Message == 0x18
			_MBPO_VisibilityTrace(State, "callback.delegated." . WParam)
		if !State.Armed || Hwnd != State.Hwnd || Message != 0x18
			return Result
		_MBPO_Require(_MBPO_NativeWindowPid(Hwnd) == ProcessExist(), "Only the exact owned native visibility callback may drive another action")
		if State.Mode == "native-hide-reopen-close" && !WParam && !State.Reopened {
			State.Reopened := true
			_MBPO_VisibilityTrace(State, "public-show.before")
			State.ShowReturned := LLM_ModelBrowser_Show()
			_MBPO_VisibilityTrace(State, "public-show.after")
			State.VisibleAfterFirstShow := !!DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int")
			State.SameAfterReopen := IsSet(_LLM_ModelBrowser_Gui) && _LLM_ModelBrowser_Gui == State.Window
		} else if WParam {
			State.ShowSeen := true, State.ShowCount += 1
			State.CriticalAtShow := A_IsCritical
			if (State.Mode == "native-show-close" && State.ShowCount == 1)
					|| (State.Mode == "native-hide-reopen-close" && State.ShowCount == 2) {
				State.CloseCalls += 1
				_MBPO_VisibilityTrace(State, "nested-close.before")
				_LLM_ModelBrowser_OnClose()
				_MBPO_VisibilityTrace(State, "nested-close.after")
				State.HiddenDuringClose := !DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int")
			}
		}
		return Result
	} catch Any as Failure {
		State.Failed := true, State.Failure := Failure
		_MBPO_VisibilityTrace(State, "callback.failed." . Type(Failure))
		return 0
	} finally State.Active -= 1
}
_MBPO_VisibilityReentry() {
	global _MBPO, _LLM_ModelBrowser_Gui, _VendorDir, _DriverDir, ConfigurationFile
	HadVendor := IsSet(_VendorDir)
	if HadVendor
		OriginalVendor := _VendorDir
	else
		_VendorDir := _DriverDir . "\vendor"
	PreviousCritical := Critical("Off")
	State := {Window: 0, Hwnd: 0, Proc: 0, Installed: false, Armed: false, Active: 0,
		Mode: _MBPO.Mode, Reopened: false, ShowSeen: false, ShowCount: 0, VisibleAfterFirstShow: false, CloseCalls: 0, HiddenDuringClose: false,
		SameAfterReopen: false, CriticalAtShow: -1, Failed: false, Failure: 0, Debt: false, TraceFailures: 0}
	if State.Mode == "native-hide-reopen-close" {
		State.PhasePath := A_Args[2] . "\visibility-phases.txt"
		Creation := FSWriteCreateDurable(State.PhasePath, "visibility-phase-start`n")
		_MBPO_Require((Creation is Integer) && Creation == 1, "The private diagnostic sidecar must be created exclusively")
	}
	try {
		_MBPO_VisibilityTrace(State, "setup.before-build")
		_MBPO_Require(!_LLM_MBW_WebView2Available(), "The native visibility subject must use the actual missing browser binding")
		_MBPO.Window := _LLM_ModelBrowser_Build(), _MBPO.Hwnd := _MBPO.Window.Hwnd
		_LLM_ModelBrowser_Gui := _MBPO.Window
		_MBPO_VisibilityTrace(State, "setup.after-build")
		State.Window := _MBPO.Window, State.Hwnd := _MBPO.Hwnd
		if State.Mode == "native-hide-reopen-close"
			State.Window.Show("NA")
		_MBPO_Require(_MBPO_NativeWindowPid(State.Hwnd) == ProcessExist()
			&& !!DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int") == (State.Mode == "native-hide-reopen-close"),
			"The real starting visibility must match the tested production action")
		State.Proc := CallbackCreate(_MBPO_VisibilityProc.Bind(State), , 6)
		_MBPO_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", State.Hwnd, "Ptr", State.Proc,
			"UPtr", 0x4D425653, "UPtr", 0, "Int"), "The exact native browser must admit its real visibility witness")
		State.Installed := true, State.Armed := true
		_MBPO_VisibilityTrace(State, "subject.before")
		if State.Mode == "native-hide-reopen-close"
			_LLM_ModelBrowser_OnClose()
		else
			State.ShowReturned := LLM_ModelBrowser_Show()
		_MBPO_VisibilityTrace(State, "subject.after")
		_MBPO_Observe()
		_MBPO_VisibilityTrace(State, "observation.after")
		State.Armed := false
		VisibleAfter := !!DllCall("IsWindowVisible", "Ptr", State.Hwnd, "Int")
		SameOwner := IsSet(_LLM_ModelBrowser_Gui) && _LLM_ModelBrowser_Gui == State.Window
		FileAppend("OBSERVATION native-model-visibility-reentry mode=" . State.Mode . " show_seen=" . State.ShowSeen
			. " close_calls=" . State.CloseCalls . " hidden_during_close=" . State.HiddenDuringClose
			. " reopened=" . State.Reopened . " show_count=" . State.ShowCount . " first_show_visible=" . State.VisibleAfterFirstShow . " same_owner=" . SameOwner . " visible_after=" . VisibleAfter
			. " trace_failures=" . State.TraceFailures . " critical_at_show=" . State.CriticalAtShow . "`n", "*", "UTF-8-RAW")
		if State.Failed
			FileAppend("DIAGNOSTIC native-model-visibility-reentry callback_type=" . JsonStringLiteral(Type(State.Failure))
				. " callback_message=" . JsonStringLiteral(State.Failure is Error ? State.Failure.Message : "non-Error callback value") . "`n", "*", "UTF-8-RAW")
		_MBPO_Require(!State.Failed && State.ShowSeen && SameOwner,
			"The native Show callback must execute on the actual unchanged GUI owner")
		_MBPO_Require(_MBPO.Errors.Length == 0 && _MBPO.WriterEntries == 0
			&& CryptoSha256Bytes(FSReadBytesStrict(ConfigurationFile)) == _MBPO.OriginalHash,
			"Visibility ordering must preserve configuration bytes without technical errors")
		if State.Mode == "native-show-current"
			_MBPO_Require(State.CloseCalls == 0 && State.ShowReturned == State.Window && VisibleAfter,
				"An unopposed public native Show must still return and display its actual window")
		else {
			_MBPO_Require(State.CloseCalls == 1 && State.HiddenDuringClose && !VisibleAfter,
				"A newer actual Close accepted inside Show must remain hidden during Close and after the older Show returns")
			if State.Mode == "native-hide-reopen-close"
				_MBPO_Require(State.Reopened && State.SameAfterReopen && State.ShowCount == 2 && State.VisibleAfterFirstShow,
					"The third action must follow the successful visible public reopen and occur inside its actual repair Show")
		}
	} finally {
		State.Armed := false
		_MBPO_VisibilityTrace(State, "cleanup.before-remove")
		Removed := !State.Installed || !DllCall("IsWindow", "Ptr", State.Hwnd, "Int")
		if !Removed
			Removed := !!DllCall("Comctl32\RemoveWindowSubclass", "Ptr", State.Hwnd, "Ptr", State.Proc, "UPtr", 0x4D425653, "Int")
		Started := A_TickCount
		while State.Active && TickElapsed(Started) < 1000
			Sleep(1)
		if Removed && !State.Active {
			if State.Proc
				CallbackFree(State.Proc)
			State.Proc := 0
		} else
			State.Debt := true
		_MBPO_VisibilityTrace(State, "cleanup.after-free")
		if HadVendor
			_VendorDir := OriginalVendor
		else
			_VendorDir := unset
		Critical(PreviousCritical)
	}
	_MBPO_Require(!State.Debt, "The exact visibility subclass must retire before its callback code is freed")
}
