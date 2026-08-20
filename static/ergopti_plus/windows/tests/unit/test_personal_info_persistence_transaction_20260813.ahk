; tests/unit/test_personal_info_persistence_transaction_20260813.ahk

; ==============================================================================
; MODULE: Personal-information persistence transaction regression
; DESCRIPTION:
; Drives the real personal_info.toml gateway and both save callbacks through
; injected stage/replace/UI seams. The tests pin global terminal admission,
; detached RAM publication, final authorization after a yielded stage, strict
; adapter statuses, malformed WebView payload rejection and failure feedback.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../ui/editors.ahk
#Include ../../ui/personal_info_editor/init.ahk

global _PIPT20260813_WriterCalls := 0
global _PIPT20260813_ReplaceCalls := 0
global _PIPT20260813_DeleteCalls := 0
global _PIPT20260813_NotifyCalls := 0
global _PIPT20260813_ReloadCalls := 0
global _PIPT20260813_ConfirmCalls := 0
global _PIPT20260813_Content := ""
global _PIPT20260813_Events := []
global _PIPT20260813_ObservedLive := []
global _PIPT20260813_CriticalStates := []

class _PIPT20260813_Edit {
	__New(Text) {
		this.Text := Text
	}
}

class _PIPT20260813_Gui {
	Destroyed := 0

	Destroy() {
		this.Destroyed += 1
	}
}

_PIPT20260813_Reset() {
	global _PIPT20260813_WriterCalls, _PIPT20260813_ReplaceCalls
	global _PIPT20260813_DeleteCalls, _PIPT20260813_NotifyCalls
	global _PIPT20260813_ReloadCalls, _PIPT20260813_ConfirmCalls
	global _PIPT20260813_Content, _PIPT20260813_Events
	global _PIPT20260813_ObservedLive, _PIPT20260813_CriticalStates
	_PIPT20260813_WriterCalls := 0
	_PIPT20260813_ReplaceCalls := 0
	_PIPT20260813_DeleteCalls := 0
	_PIPT20260813_NotifyCalls := 0
	_PIPT20260813_ReloadCalls := 0
	_PIPT20260813_ConfirmCalls := 0
	_PIPT20260813_Content := ""
	_PIPT20260813_Events := []
	_PIPT20260813_ObservedLive := []
	_PIPT20260813_CriticalStates := []
}

_PIPT20260813_RecordCritical(Phase) {
	global _PIPT20260813_CriticalStates
	_PIPT20260813_CriticalStates.Push(Map(
		"phase", Phase,
		"critical", A_IsCritical))
}

_PIPT20260813_WriteSuccess(StagePath, Content) {
	global _PIPT20260813_WriterCalls, _PIPT20260813_Content
	global _PIPT20260813_Events, _PIPT20260813_ObservedLive
	global PersonalInformation
	_PIPT20260813_WriterCalls += 1
	_PIPT20260813_Content := Content
	_PIPT20260813_Events.Push("write")
	_PIPT20260813_RecordCritical("write")
	_PIPT20260813_ObservedLive.Push(PersonalInformation["first_name"])
	return true
}

_PIPT20260813_WriteFalse(StagePath, Content) {
	global _PIPT20260813_WriterCalls, _PIPT20260813_Events
	_PIPT20260813_WriterCalls += 1
	_PIPT20260813_Events.Push("write-false")
	return false
}

_PIPT20260813_WriteStringOne(StagePath, Content) {
	global _PIPT20260813_WriterCalls
	_PIPT20260813_WriterCalls += 1
	return "1"
}

_PIPT20260813_ReplaceSuccess(StagePath, TargetPath) {
	global _PIPT20260813_ReplaceCalls, _PIPT20260813_Events
	global _PIPT20260813_ObservedLive, PersonalInformation
	_PIPT20260813_ReplaceCalls += 1
	_PIPT20260813_Events.Push("replace")
	_PIPT20260813_RecordCritical("replace")
	_PIPT20260813_ObservedLive.Push(PersonalInformation["first_name"])
	return true
}

_PIPT20260813_Delete(StagePath) {
	global _PIPT20260813_DeleteCalls
	_PIPT20260813_DeleteCalls += 1
	return true
}

_PIPT20260813_AuthorizeFalse() {
	global _PIPT20260813_Events
	_PIPT20260813_Events.Push("authorize-false")
	return false
}

_PIPT20260813_Notify(Message, Options) {
	global _PIPT20260813_NotifyCalls
	_PIPT20260813_NotifyCalls += 1
	return true
}

_PIPT20260813_Reload() {
	global _PIPT20260813_ReloadCalls, _PIPT20260813_ObservedLive
	global PersonalInformation
	_PIPT20260813_ReloadCalls += 1
	_PIPT20260813_RecordCritical("reload")
	_PIPT20260813_ObservedLive.Push(PersonalInformation["first_name"])
	return true
}

_PIPT20260813_Confirm(Message) {
	global _PIPT20260813_ConfirmCalls, _PIPT20260813_ObservedLive
	global PersonalInformation
	_PIPT20260813_ConfirmCalls += 1
	_PIPT20260813_ObservedLive.Push(PersonalInformation["first_name"])
	return true
}

_PIPT20260813_WithState(TestFn) {
	global PersonalInformation, PersonalInformationLetters
	global _ReadPersonalInfoTomlCache, ScriptInformation
	HadInformation := IsSet(PersonalInformation)
	OldInformation := HadInformation ? PersonalInformation : false
	HadLetters := IsSet(PersonalInformationLetters)
	OldLetters := HadLetters ? PersonalInformationLetters : false
	OldCache := _ReadPersonalInfoTomlCache
	OldPath := ScriptInformation.Get("PersonalInfoTomlPath", "")
	Path := A_Temp . "\ergopti_personal_info_tx_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	PersonalInformation := Map("first_name", "Old", "last_name", "Before")
	PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
	_ReadPersonalInfoTomlCache := false
	ScriptInformation["PersonalInfoTomlPath"] := Path
	_PIPT20260813_Reset()
	try TestFn.Call(Path)
	finally {
		if HadInformation
			PersonalInformation := OldInformation
		else
			PersonalInformation := unset
		if HadLetters
			PersonalInformationLetters := OldLetters
		else
			PersonalInformationLetters := unset
		_ReadPersonalInfoTomlCache := OldCache
		ScriptInformation["PersonalInfoTomlPath"] := OldPath
		try FileDelete(Path)
	}
}

_PIPT20260813_TerminalBarrierBody(Path) {
	global _PIPT20260813_WriterCalls, PersonalInformation
	Terminal := _ConfigWriteTerminalTryAcquire(
		A_Temp . "\ergopti_unrelated_terminal_" . A_ScriptHwnd . ".toml")
	AssertTrue(Terminal is Object,
		"the fixture must own a process-wide terminal barrier")
	try Result := PersonalInfoCommitValues(Path,
		Map("first_name", "New"), _PIPT20260813_WriteSuccess,
		_PIPT20260813_ReplaceSuccess, _PIPT20260813_Delete)
	finally _ConfigWriteTerminalRelease(Terminal)
	AssertFalse(Result,
		"an unrelated terminal transition must close admission to personal_info.toml")
	AssertEqual(0, _PIPT20260813_WriterCalls,
		"terminal refusal must happen before candidate staging")
	AssertEqual("Old", PersonalInformation["first_name"],
		"terminal refusal must leave the live identity unchanged")
}

_PIPT20260813_TerminalBarrier() {
	_PIPT20260813_WithState(_PIPT20260813_TerminalBarrierBody)
}
Test("personal-info-global-barrier-20260813: unrelated terminal refusal has zero writer and unchanged RAM",
	_PIPT20260813_TerminalBarrier)

_PIPT20260813_FailedStageBody(Path) {
	global _PIPT20260813_WriterCalls, _PIPT20260813_ReplaceCalls
	global PersonalInformation
	Result := PersonalInfoCommitValues(Path, Map("first_name", "New"),
		_PIPT20260813_WriteFalse, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete)
	AssertFalse(Result)
	AssertEqual(1, _PIPT20260813_WriterCalls)
	AssertEqual(0, _PIPT20260813_ReplaceCalls,
		"a refused stage must never reach durable replacement")
	AssertEqual("Old", PersonalInformation["first_name"],
		"failed durability must not publish the candidate to RAM")
}

_PIPT20260813_FailedStage() {
	_PIPT20260813_WithState(_PIPT20260813_FailedStageBody)
}
Test("personal-info-global-barrier-20260813: stage refusal publishes no live value",
	_PIPT20260813_FailedStage)

_PIPT20260813_StrictStatusBody(Path) {
	global _PIPT20260813_ReplaceCalls, PersonalInformation
	Result := PersonalInfoCommitValues(Path, Map("first_name", "New"),
		_PIPT20260813_WriteStringOne, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete)
	AssertFalse(Result,
		"the string lookalike '1' is not a strict successful adapter status")
	AssertEqual(0, _PIPT20260813_ReplaceCalls)
	AssertEqual("Old", PersonalInformation["first_name"])
}

_PIPT20260813_StrictStatus() {
	_PIPT20260813_WithState(_PIPT20260813_StrictStatusBody)
}
Test("personal-info-global-barrier-20260813: string writer status cannot publish",
	_PIPT20260813_StrictStatus)

_PIPT20260813_FinalAuthorizationBody(Path) {
	global _PIPT20260813_WriterCalls, _PIPT20260813_ReplaceCalls
	global _PIPT20260813_Events, PersonalInformation
	Result := PersonalInfoCommitValues(Path, Map("first_name", "New"),
		_PIPT20260813_WriteSuccess, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete, _PIPT20260813_AuthorizeFalse)
	AssertFalse(Result)
	AssertEqual(1, _PIPT20260813_WriterCalls,
		"the fixture must yield through a completed stage before authorization")
	AssertEqual(0, _PIPT20260813_ReplaceCalls,
		"final authorization refusal must preserve the durable target")
	AssertEqual("Old", PersonalInformation["first_name"],
		"final authorization refusal must preserve the live identity")
	AssertEqual("authorize-false", _PIPT20260813_Events[2],
		"authorization must be re-evaluated after the stage writer")
}

_PIPT20260813_FinalAuthorization() {
	_PIPT20260813_WithState(_PIPT20260813_FinalAuthorizationBody)
}
Test("personal-info-global-barrier-20260813: final authorization refusal preserves disk and RAM",
	_PIPT20260813_FinalAuthorization)

_PIPT20260813_AtomicPublicationBody(Path) {
	global _PIPT20260813_Content, _PIPT20260813_Events
	global _PIPT20260813_ObservedLive, PersonalInformation
	Result := PersonalInfoCommitValues(Path, Map("first_name", "New"),
		_PIPT20260813_WriteSuccess, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete)
	AssertTrue(Result)
	AssertEqual("write", _PIPT20260813_Events[1])
	AssertEqual("replace", _PIPT20260813_Events[2])
	AssertEqual("Old", _PIPT20260813_ObservedLive[1],
		"the stage writer must not see speculative RAM")
	AssertEqual("Old", _PIPT20260813_ObservedLive[2],
		"the durable replacer must run before live publication")
	AssertEqual("New", PersonalInformation["first_name"],
		"a successful replace must publish the exact detached candidate")
	AssertTrue(InStr(_PIPT20260813_Content, 'first_name = "New"') > 0,
		"the staged bytes must contain the same value published to RAM")
}

_PIPT20260813_AtomicPublication() {
	_PIPT20260813_WithState(_PIPT20260813_AtomicPublicationBody)
}
Test("personal-info-global-barrier-20260813: durability precedes one atomic live publication",
	_PIPT20260813_AtomicPublication)

_PIPT20260813_MalformedPayloadBody(Path) {
	global _PIPT20260813_WriterCalls, PersonalInformation
	UnknownResult := PersonalInfoCommitValues(Path, Map("attacker_key", "value"),
		_PIPT20260813_WriteSuccess, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete)
	TypedResult := PersonalInfoCommitValues(Path, Map("first_name", Map()),
		_PIPT20260813_WriteSuccess, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete)
	AssertFalse(UnknownResult)
	AssertFalse(TypedResult)
	AssertEqual(0, _PIPT20260813_WriterCalls,
		"malformed WebView fields must be rejected before serialization")
	AssertEqual("Old", PersonalInformation["first_name"])
	AssertFalse(PersonalInformation.Has("attacker_key"),
		"an arbitrary JSON key must never become a TOML key or live field")
}

_PIPT20260813_MalformedPayload() {
	_PIPT20260813_WithState(_PIPT20260813_MalformedPayloadBody)
}
Test("personal-info-global-barrier-20260813: unknown and non-string WebView fields are side-effect free",
	_PIPT20260813_MalformedPayload)

_PIPT20260813_NativeFailureBody(Path) {
	global _PIPT20260813_NotifyCalls, _PIPT20260813_ReloadCalls
	global PersonalInformation
	GuiObj := _PIPT20260813_Gui()
	Edits := Map("first_name", _PIPT20260813_Edit("New"))
	Result := ProcessUserInput(GuiObj, Edits,
		_PIPT20260813_WriteFalse, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete, 0, _PIPT20260813_Notify,
		_PIPT20260813_Reload, _PIPT20260813_Confirm)
	AssertFalse(Result)
	AssertEqual("Old", PersonalInformation["first_name"])
	AssertEqual(0, GuiObj.Destroyed,
		"failed persistence must keep the only copy of the typed values visible")
	AssertEqual(1, _PIPT20260813_NotifyCalls,
		"the native callback must surface persistence failure exactly once")
	AssertEqual(0, _PIPT20260813_ReloadCalls)
}

_PIPT20260813_NativeFailure() {
	_PIPT20260813_WithState(_PIPT20260813_NativeFailureBody)
}
Test("personal-info-global-barrier-20260813: native failure keeps editor open, reports once and never reloads",
	_PIPT20260813_NativeFailure)

_PIPT20260813_WebSuccessBody(Path) {
	global _PIPT20260813_ReloadCalls, _PIPT20260813_NotifyCalls
	global _PIPT20260813_ObservedLive, PersonalInformation
	Result := _PiEdWeb_Save(Map("first_name", "New"),
		_PIPT20260813_WriteSuccess, _PIPT20260813_ReplaceSuccess,
		_PIPT20260813_Delete, 0, _PIPT20260813_Notify,
		_PIPT20260813_Reload)
	AssertTrue(Result)
	AssertEqual("New", PersonalInformation["first_name"])
	AssertEqual(1, _PIPT20260813_ReloadCalls)
	AssertEqual("New", _PIPT20260813_ObservedLive[3],
		"reload must observe the already-published durable candidate")
	AssertEqual(0, _PIPT20260813_NotifyCalls)
}

_PIPT20260813_WebSuccess() {
	_PIPT20260813_WithState(_PIPT20260813_WebSuccessBody)
}
Test("personal-info-global-barrier-20260813: WebView success publishes before reload",
	_PIPT20260813_WebSuccess)

_PIPT20260813_InheritedCriticalBody(Path) {
	global _PIPT20260813_CriticalStates
	PreviousCritical := Critical("On")
	try {
		Result := _PiEdWeb_Save(Map("first_name", "New"),
			_PIPT20260813_WriteSuccess, _PIPT20260813_ReplaceSuccess,
			_PIPT20260813_Delete, 0, _PIPT20260813_Notify,
			_PIPT20260813_Reload)
		AssertTrue(A_IsCritical,
			"the WebView action must restore the caller's Critical state")
	} finally Critical(PreviousCritical)
	AssertTrue(Result)
	AssertEqual(3, _PIPT20260813_CriticalStates.Length,
		"stage, replace and reload must all expose their Critical state")
	for Sample in _PIPT20260813_CriticalStates {
		AssertEqual(0, Sample["critical"],
			Sample["phase"] . " must remain interruptible under an inherited caller Critical")
	}
}

_PIPT20260813_InheritedCritical() {
	_PIPT20260813_WithState(_PIPT20260813_InheritedCriticalBody)
}
Test("personal-info-global-barrier-20260813: inherited Critical cannot wrap disk IO or reload",
	_PIPT20260813_InheritedCritical)
