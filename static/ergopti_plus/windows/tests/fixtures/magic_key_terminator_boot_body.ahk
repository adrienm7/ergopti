; tests/fixtures/magic_key_terminator_boot_body.ahk

; ==============================================================================
; MODULE: Configured Magic-Key Terminator Boot Fixture
; DESCRIPTION:
; Drives the real durable editor, snapshot reader and boot projection. Native
; packet modes measure callback framing and matching with an older consuming
; hook; no output is emitted to an application and no config reload is launched.
; ==============================================================================

if A_Args.Length != 5 || A_Args[1] != "--allow-explicit-user32-sendinput"
	throw Error("The exact owned fixture arguments and explicit native opt-in are required.")
if A_AhkVersion != "2.0.26" || A_PtrSize != 8
	throw Error("Pinned AutoHotkey 2.0.26 x64 is required.")
_MKTB_Allowed := Map("default-star", true, "default-section", true, "default-astral", true,
	"historical-controls", true, "custom-controls", true, "custom-collision", true,
	"restore-section", true, "native-astral", true, "native-shared-high", true)
if !_MKTB_Allowed.Has(A_Args[2]) || !InStr(A_Args[5], A_Temp . "\ergopti_magic_terminator_")
	throw Error("An unknown case or non-owned temporary root was refused.")

global _MKTB := { Mode: A_Args[2], Failures: [], Reloads: 0, Notifications: [], Hook: 0,
	Frames: [], Matches: [], Ends: [], MatchBuffers: [], CallbackError: 0 }
global _UNC := { Case: "terminator-" . A_Args[2], Gui: 0, Edit: 0, Hwnd: 0, EditHwnd: 0, Thread: 0,
	Pid: DllCall("GetCurrentProcessId", "UInt"), Guard: 0, Observer: 0, Target: 0,
	Units: [], ExpectedObserved: 0, Observed: [], Tail: [], Ups: 0, UpScs: [], UpVk: 0xE7,
	Calls: 0, Inserted: -1, Debt: false, Injected: false, Cancelled: false, Error: 0 }
OnExit(_MKTB_Exit)

BootProfile_Stamp(*) {
	; The real entry's timing observer does not participate in config publication.
}

_MKTB_Check(Condition, Message) {
	global _MKTB
	if !Condition
		_MKTB.Failures.Push(Message)
}

_MKTB_Reload() {
	global _MKTB
	_MKTB.Reloads += 1
	return 1
}

_MKTB_Notify(Message, Options) {
	global _MKTB
	_MKTB.Notifications.Push(Message)
}

_MKTB_ContainsScalar(Text, Scalar) {
	for Character in _TextCodepoints(Text)
		if Character == Scalar
			return true
	return false
}

_MKTB_Match(Text, Star := false) {
	global HSE_LastEndChar, HSE_Buffer
	HSE_RegistryClear()
	HSE_FeedReset(true)
	HSE_Register(Star ? "*C" : "C", Star ? "qr" . Text : "qr", (*) => 0, { Replacement: "RESULT" })
	HSE_FeedChar("q", true), HSE_FeedChar("r", true)
	Match := HSE_FeedChar(Text, true)
	if !IsObject(Match)
		return { Found: false, End: HSE_LastEndChar, Result: HSE_Buffer }
	End := HSE_LastEndChar
	HSE_ApplyExpansion(Match, "RESULT", End)
	return { Found: true, End: End, Result: HSE_Buffer }
}

_MKTB_Boot() {
	global _MKTB, ConfigurationFile, Features, ScriptInformation
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	Mode := _MKTB.Mode, Star := Chr(0x2605), Section := Chr(0xA7), Face := Chr(0x1F600)
	Magic := (Mode == "default-star" || InStr(Mode, "native-") == 1) ? Star
		: (Mode == "default-astral" ? Face : Section)
	Tail := '[future]`nopaque = { keep = "literal", number = 7 } # keep this exact span`n'
	Records := ""
	if InStr(Mode, "native-") == 1 || Mode == "custom-controls"
		Records := '[hotstrings]`nterminators = [{ key = "face", char = "😀", label = "Face", consume = '
			. (Mode == "custom-controls" ? "false" : "true") . ' }]`n'
	if Mode == "custom-controls"
		Records := '[hotstrings]`nterminators = [{ key = "face", char = "😀", label = "Face", consume = false },'
			. '{ key = "currency", char = "¤", label = "Currency", consume = true }]`n'
			. '[hotstrings.terminator_states]`ncurrency = false`n'
	if Mode == "custom-collision"
		Records := '[hotstrings]`nterminators = [{ key = "new_reserved", char = "§", label = "Reserved", consume = true },'
			. '{ key = "former_star", char = "★", label = "Independent", consume = false }]`n'
	Source := '_meta.schema_version = ' . ConfigMigrateCurrentVersion() . "`n" . Records . Tail
	ConfigurationFile := A_Args[5] . "\config.toml"
	_UNC_Require(!FileExist(ConfigurationFile), "The durable subject must start at a fresh owned path.")
	_UNC_Require(FSWriteDurable(ConfigurationFile, Source), "The independent current source could not be written.")
	Boot := ConfigMigrateBoot(ConfigurationFile)
	_UNC_Require(Boot["status"] == "current" && Boot["read_only"] == 0, "The genuine journal must admit the current source.")
	Features := ManifestBuildFeaturesMap()
	Before := ConfigTomlReadSnapshot(ConfigurationFile)
	_UNC_Require(Before is Object && Before.Source is String, "The original durable snapshot must be real.")
	; Only the post-commit external process launch is observed. The native writer,
	; conditional journal, byte comparisons and in-memory publisher stay genuine.
	Committed := ModifyMagicKey(0, Magic, 0, _MKTB_Notify, _MKTB_Reload)
	if !Committed {
		FileAppend("EDITOR_FAILURE notifications=" . _MKTB.Notifications.Length
			. " reloads=" . _MKTB.Reloads . "`n", "**")
		; The real logger has a bounded ring even before LoggerInit. Preserve the
		; underlying writer/admission cause instead of replacing the failing API.
		for Line in LoggerRingBufferSnapshot()
			FileAppend("EDITOR_LOG " . Line . "`n", "**")
	}
	_UNC_Require(Committed, "The real editor commit was refused.")
	Snapshot := ConfigTomlReadSnapshot(ConfigurationFile)
	_UNC_Require(Snapshot is Object && Snapshot.Source is String, "The persisted scalar must be readable.")
	_UNC_Require(Snapshot.Cache["hotstrings"]["trigger_char"] == Magic, "The typed file lost the complete configured scalar.")
	_UNC_Require(Features["hotstrings"]["trigger_char"] == Magic && ScriptInformation["MagicKey"] == Magic,
		"The real editor publisher must retain the exact scalar.")
	_UNC_Require(InStr(Snapshot.Source, Tail, true) > 0 && _MKTB.Reloads == 1 && _MKTB.Notifications.Length == 0,
		"A durable edit must preserve foreign source and acknowledge exactly one reload.")
	OverridePath := A_Args[5] . "\hotstrings_config.toml"
	HistoricalWord := "", HistoricalConsumed := ""
	if Mode == "historical-controls"
		HistoricalWord := Star . Section . "¤¤", HistoricalConsumed := Section . "¤"
	else if Mode == "custom-controls"
		HistoricalWord := "¤" . Star, HistoricalConsumed := "¤" . Star
	OverrideSource := HistoricalWord == "" ? "" : '[__global__]`nword_delimiters = '
		. TOML_RenderString(HistoricalWord) . '`nconsumed_delimiters = ' . TOML_RenderString(HistoricalConsumed) . "`n"
	_UNC_Require(FSWriteDurable(OverridePath, OverrideSource), "The private historical preference file must be durable.")
	HotstringsConfigInit(OverridePath)
	AdmittedOverrideSource := FSReadStrict(OverridePath)
	_UNC_Require(_HotstringsWordDelimiters == HistoricalWord && _HotstringsConsumedDelimiters == HistoricalConsumed,
		"The actual override loader must admit the exact independent preference strings.")
	; Reset only the runtime leaf, then execute the actual entry's current window.
	ScriptInformation["MagicKey"] := ManifestDefaultFor("hotstrings.trigger_char")
	_MKTB_ReadBoot(Snapshot)
	_UNC_Require(ScriptInformation["MagicKey"] == Magic, "The genuine reader must restore the exact persisted scalar.")
	_UNC_Require(HotstringsTerminatorRecordsInitBoot(Snapshot), "The actual boot record owner refused its admitted snapshot.")
	_UNC_Require(_HotstringsWordDelimiters == HistoricalWord && _HotstringsConsumedDelimiters == HistoricalConsumed
		&& FSReadStrict(OverridePath) == AdmittedOverrideSource, "Boot must neither mutate nor rewrite independent historical preferences.")
	return { Magic: Magic, Star: Star, Face: Face, Snapshot: Snapshot }
}

_MKTB_CheckProjection(Data) {
	global _MKTB, HSE_Terminators, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS, _HotstringsTerminatorRecords
	Mode := _MKTB.Mode
	if Mode == "historical-controls" {
		_MKTB_Check(HSE_WORD_TERMINATORS == "★§¤¤" && HSE_CONSUMED_DELIMITERS == "§¤",
			"Independent historical strings must retain exact order, duplicates and old-star intent.")
		_MKTB_Check(_MKTB_Match("§").Found && _MKTB_Match("★").Found, "Both independently admitted historical markers must terminate.")
		return
	}
	if Mode == "custom-controls" {
		_MKTB_Check(HSE_WORD_TERMINATORS == "★😀" && HSE_CONSUMED_DELIMITERS == "★",
			"Disabled currency must withdraw its exact scalar while the enabled nonconsumed face remains independent.")
		_MKTB_Check(_HotstringsTerminatorRecords.Records.Length == 2 && _HotstringsTerminatorRecords.Rejected.Length == 0,
			"Both independent custom records must be admitted by the actual boot owner.")
		return
	}
	if Mode == "custom-collision" {
		_MKTB_Check(_HotstringsTerminatorRecords.Records.Length == 1
			&& _HotstringsTerminatorRecords.Records[1].Key == "former_star"
			&& _HotstringsTerminatorRecords.Rejected.Length == 1
			&& _HotstringsTerminatorRecords.Rejected[1]["reason"] == "character_collision",
			"The configured slot reserves its new scalar before records resolve; the former star is independently available.")
		return
	}
	if Mode == "restore-section" {
		_UNC_Require(HSE_Terminators.addCustom("runtime_only", ["¤"], "Runtime only", true), "The runtime-only token must be genuinely registered.")
		Restored := HSE_TerminatorRestoreDefaults("★¤", "★¤")
		_MKTB_Check(_MKTB_ContainsScalar(Restored.DefaultWord, Data.Magic)
			&& Restored.DefaultConsumed == Data.Magic && !_MKTB_ContainsScalar(Restored.DefaultWord, Data.Star),
			"Reset defaults must honor the configured magic scalar without resetting that setting.")
		_MKTB_Check(!_MKTB_ContainsScalar(Restored.DefaultWord, "¤") && !_MKTB_ContainsScalar(Restored.DefaultConsumed, "¤")
			&& _MKTB_ContainsScalar(Restored.Word, "¤") && _MKTB_ContainsScalar(Restored.Consumed, "¤"),
			"Runtime-only tokens are personal strings, never silently promoted to shipped reset defaults.")
		return
	}
	if InStr(Mode, "native-") == 1
		return
	_MKTB_Check(HSE_Terminators.isTerminator(Data.Magic) && HSE_Terminators.isConsumed(Data.Magic),
		"The real configured catalogue must own the new magic terminator and consume slot.")
	_MKTB_Check(_MKTB_ContainsScalar(HSE_WORD_TERMINATORS, Data.Magic)
		&& HSE_CONSUMED_DELIMITERS == Data.Magic, "Default engine projections must follow the complete configured scalar.")
	EndMatch := _MKTB_Match(Data.Magic)
	_MKTB_Check(EndMatch.Found && EndMatch.End == Data.Magic && EndMatch.Result == "RESULT",
		"An ordinary END rule must match once and consume the configured magic scalar.")
	StarMatch := _MKTB_Match(Data.Magic, true)
	_MKTB_Check(StarMatch.Found && StarMatch.End == "" && StarMatch.Result == "RESULT",
		"The independent explicit STAR registration must still match the complete trigger.")
	if Data.Magic != Data.Star
		_MKTB_Check(!HSE_Terminators.isTerminator(Data.Star) && !_MKTB_ContainsScalar(HSE_WORD_TERMINATORS, Data.Star)
			&& !_MKTB_Match(Data.Star).Found, "The former default star must not terminate without independent user ownership.")
}

_MKTB_OnChar(Hook, Text) {
	global _MKTB, HSE_LastEndChar, HSE_Buffer
	try {
		_UNC_Admit()
		_MKTB.Frames.Push(_UNC_Hex(_UNC_Units(Text)))
		Match := HSE_FeedChar(Text, true)
		_MKTB.Matches.Push(IsObject(Match) ? 1 : 0)
		_MKTB.Ends.Push(_UNC_Hex(_UNC_Units(HSE_LastEndChar)))
		_MKTB.MatchBuffers.Push(_UNC_Hex(_UNC_Units(HSE_Buffer)))
	} catch as Err {
		_MKTB.CallbackError := Err
	}
}

_MKTB_Native(Data) {
	global _MKTB, _UNC, _HotstringsTerminatorRecords
	_UNC_Require(_HotstringsTerminatorRecords.Records.Length == 1
		&& _HotstringsTerminatorRecords.Records[1].Char == Data.Face,
		"The astral terminator must come from a genuine admitted config record.")
	HSE_RegistryClear()
	HSE_FeedReset(true)
	HSE_Register("C", "qr", (*) => 0, { Replacement: "RESULT" })
	HSE_FeedChar("q", true), HSE_FeedChar("r", true)
	_UNC.Units := _UNC_Units(_MKTB.Mode == "native-shared-high" ? Chr(0x1F601) : Data.Face)
	_UNC_OpenCapture()
	; This uses the real watcher's native shape, but deliberately observes only
	; callback framing -> genuine HSE matcher. Focus/UI rendering and application
	; senders are outside this tier; the older guard consumes every packet.
	_MKTB.Hook := InputHook("V L0 I1")
	_MKTB.Hook.OnChar := _MKTB_OnChar
	_MKTB.Hook.Start()
	_UNC_Require(_MKTB.Hook.MinSendLevel == 1 && _MKTB.Hook.InProgress, "The native I1 matcher hook must be active.")
	_UNC.Observer := InputHook("V L0")
	_UNC.Observer.KeyOpt("{All}", "N")
	_UNC.Observer.OnChar := _UNC_Observed
	_UNC.Observer.OnKeyUp := _UNC_Up
	_UNC.Observer.Start()
	Packets := _UNC_Packets(_UNC.Units)
	PreviousCritical := Critical("On")
	try {
		_UNC_Admit()
		_UNC_Require(!_UNC.Cancelled, "The exact native fixture was cancelled before admission.")
		_UNC.Debt := true, _UNC.Injected := true, _UNC.Calls += 1
		_UNC.Inserted := _LLM_TerminalOutputSendInputNative(_UNC.Units.Length * 2, Packets, 40)
		_UNC_Require(_UNC.Inserted == _UNC.Units.Length * 2, "The exact native batch was not fully inserted.")
	} finally Critical(PreviousCritical)
	_UNC_Drain()
	Started := DllCall("GetTickCount64", "UInt64")
	while _MKTB.Frames.Length < 2 && !IsObject(_MKTB.CallbackError) && DllCall("GetTickCount64", "UInt64") - Started < 5000
		Sleep(10)
	_UNC_Require(!IsObject(_MKTB.CallbackError), "The real matcher callback failed: " . (IsObject(_MKTB.CallbackError) ? _MKTB.CallbackError.Message : ""))
	_UNC_Require(_MKTB.Frames.Length == 2 && _MKTB.Frames[1] == "D83D"
		&& _MKTB.Frames[2] == (_MKTB.Mode == "native-shared-high" ? "DE01" : "DE00"),
		"The actual OnChar framing must expose each original packet's UTF16 unit.")
	_UNC_Require(_UNC.Edit.Value == "" && _UNC_Same(_UNC.Tail, _UNC.Units), "The older guard must consume the entire batch before any receiving application.")
	_MKTB_Check(_MKTB.Matches[1] == 0, "A high surrogate alone must never complete an END rule.")
	_MKTB_Check(_MKTB.Matches[2] == (_MKTB.Mode == "native-shared-high" ? 0 : 1),
		"Only the complete admitted terminator may match; another scalar sharing its high surrogate must remain literal.")
	_MKTB_Check(_MKTB.Ends[2] == (_MKTB.Mode == "native-shared-high" ? "empty" : "D83D,DE00"),
		"A completed END decision must carry the entire scalar, never one half.")
}

_MKTB_Exit(Reason, Code) {
	global _MKTB, _UNC
	if _UNC.Debt {
		FileAppend("RETAINED native_input_debt=true external_owned_retirement_required=true`n", "**")
		return 1
	}
	try {
		for Hook in [_MKTB.Hook, _UNC.Observer, _UNC.Guard]
			if IsObject(Hook)
				Hook.Stop()
		if IsObject(_UNC.Gui)
			_UNC.Gui.Destroy()
	} catch as Err {
		FileAppend("RETAINED cleanup_failure=" . Err.Message . "`n", "**")
		return 1
	}
	FileAppend("NATURAL_EXIT code=" . Code . " native_input_debt=false`n", "*")
	return 0
}

try {
	Data := _MKTB_Boot()
	_MKTB_CheckProjection(Data)
	if InStr(_MKTB.Mode, "native-") == 1
		_MKTB_Native(Data)
	Trace := "RECEIPT source_scope=parent_execution_manifest case=" . _MKTB.Mode
		. " configured=" . _UNC_Hex(_UNC_Units(Data.Magic)) . " word=" . _UNC_Hex(_UNC_Units(HSE_WORD_TERMINATORS))
		. " consumed=" . _UNC_Hex(_UNC_Units(HSE_CONSUMED_DELIMITERS)) . " callbacks=" . _MKTB.Frames.Length
		. " input=" . _UNC_Hex(_UNC.Units) . " observed=" . _UNC_Hex(_UNC.Observed) . " tail=" . _UNC_Hex(_UNC.Tail)
		. " ups=" . _UNC.Ups . " native_calls=" . _UNC.Calls . " inserted=" . _UNC.Inserted
	for Index, Frame in _MKTB.Frames
		Trace .= " frame" . Index . "=" . Frame . " match" . Index . "=" . _MKTB.Matches[Index] . " end" . Index . "=" . _MKTB.Ends[Index] . " buffer" . Index . "=" . _MKTB.MatchBuffers[Index]
	FileAppend(Trace . "`n", "*")
	for Failure in _MKTB.Failures
		FileAppend("GOLDEN_FAILURE " . Failure . "`n", "*")
	if _MKTB.Failures.Length
		throw Error("Configured terminator goldens failed: " . _MKTB.Failures.Length)
	FileAppend("PASS magic-key-terminator-boot " . _MKTB.Mode . "`n", "*")
	ExitApp(0)
} catch as Err {
	FileAppend("FAIL " . Err.Message . "`n" . Err.Stack . "`n", "**")
	ExitApp(1)
}
