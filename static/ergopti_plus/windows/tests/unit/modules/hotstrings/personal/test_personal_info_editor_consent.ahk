; tests/unit/modules/hotstrings/personal/test_personal_info_editor_consent.ahk
; AFTER-only controls for explicit form receipts. Reopening or decoding B must
; never lend its authority to a retained A, including deferred web callbacks.
#Requires AutoHotkey v2.0

class _PIEC_View {
	__New() {
		this.Scripts := []
	}
	ExecuteScriptAsync(Script) {
		this.Scripts.Push(Script)
		return _PIEC_Settled()
	}
}

class _PIEC_Settled {
	onSettled(Success, Failure) {
		Success.Call("null")
	}
}

_PIEC_Load(Path, Last) {
	global _ReadPersonalInfoTomlCache, PersonalInformation
	AssertEqual(1, FSWriteDurable(Path, _PIES_Image(Last)))
	_ReadPersonalInfoTomlCache := false
	ReadPersonalInfoToml(Path)
	AssertEqual(Last, PersonalInformation["last_name"])
	return _PersonalInfoCaptureEditorSource(Path)
}

_PIEC_Fields(Script) {
	Quoted := '"(?:[^"\\]|\\.)*"'
	Pattern := '\{key:(' . Quoted . '),label:(' . Quoted . '),value:('
		. Quoted . '),hint:(' . Quoted . ')\}'
	Values := Map(), At := 1
	while RegExMatch(Script, Pattern, &Field, At) {
		Key := JsonParse(Field[1]), Value := JsonParse(Field[3])
		AssertFalse(Values.Has(Key))
		Values[Key] := Value
		At := Field.Pos + Field.Len
	}
	AssertEqual(2, Values.Count)
	return Values
}

_PIEC_Exercise(Surface, Mode, Path, State) {
	global PersonalInformation, PersonalInformationLetters, HSE_RuntimeDecisionGeneration
	global _PiEdWeb_EditorSource, _PiEdWeb_SessionEpoch, _PiEdWeb_ResetDone, _PiEdWeb_WebView
	SourceA := _PIEC_Load(Path, "Original")
	Values := SourceA["information"].Clone()
	AssertEqual("Alice", Values["first_name"])
	AssertEqual("Original", Values["last_name"])
	Values["first_name"] := "Edited"
	if Surface == "web" {
		_PiEdWeb_SessionEpoch += 1
		_PiEdWeb_ResetDone := false
		_PiEdWeb_EditorSource := SourceA
		SourceA["web_epoch"] := _PiEdWeb_SessionEpoch
		State.View := _PIEC_View()
		_PiEdWeb_WebView := State.View
	}
	if Mode == "renewed" || Mode == "reinit" {
		SourceB := _PIEC_Load(Path, "External")
		AssertTrue(SourceB != SourceA)
		if Mode == "renewed" {
			; A second real model can save normally. Its fresh receipt must not
			; become an omitted-argument fallback for the older explicit form.
			AssertTrue(PersonalInfoCommitValues(Path, Map("last_name", "Reopened"),
				0, 0, 0, 0, SourceB))
			AssertEqual("Reopened", PersonalInformation["last_name"])
		} else {
			_PiEdWeb_PushInitData()
			_PiEdWeb_PushInitData()
			AssertEqual(2, State.View.Scripts.Length)
			for Script in State.View.Scripts {
				Fields := _PIEC_Fields(Script)
				AssertEqual("Alice", Fields["first_name"])
				AssertEqual("Original", Fields["last_name"],
					"a repeated init of A cannot silently recertify its unchanged field from B")
			}
		}
	} else if Mode == "retired" {
		Epoch := _PiEdWeb_SessionEpoch
		_PiEdWeb_Reset()
		AssertFalse(SourceA["active"])
		AssertTrue(_PiEdWeb_SessionEpoch > Epoch)
		SourceB := _PIEC_Load(Path, "External")
		_PiEdWeb_ResetDone := false
		_PiEdWeb_EditorSource := SourceB
		SourceB["web_epoch"] := _PiEdWeb_SessionEpoch
		_PiEdWeb_WebView := State.View
		AssertTrue(_PiEdWeb_EditorSourceCurrent(_PiEdWeb_SessionEpoch, SourceB))
	}
	Provided := SourceA
	if Mode == "false"
		Provided := false
	else if Mode == "unknown" {
		Provided := SourceA.Clone()
		Provided["source"] := 0
	} else if Mode == "malformed" {
		Provided := SourceA.Clone()
		Provided["source"] := SourceA["source"].Clone()
		Provided["source"]["admitted"] := "1"
	}
	Winner := FSReadBytesStrict(Path)
	BeforeInformation := PersonalInformation, BeforeLetters := PersonalInformationLetters
	Generation := HSE_RuntimeDecisionGeneration
	Receipt := Map("notify", 0, "reload", 0, "confirm", 0)
	if Surface == "native" {
		State.Gui := Gui("+ToolWindow", "Private personal consent")
		State.Hwnd := State.Gui.Hwnd
		Edits := Map()
		for Key, Value in Values
			Edits[Key] := State.Gui.Add("Edit", "w160", Value)
	}
	; Both adapters must preserve a supplied value through their real Critical
	; recursion. A provided false is not the historical omitted argument.
	PreviousCritical := Critical("On")
	try {
		if Surface == "native"
			Result := ProcessUserInput(State.Gui, Edits, 0, 0, 0, 0,
				_PIES_Notify.Bind(Receipt), _PIES_Reload.Bind(Receipt), _PIES_Confirm.Bind(Receipt), Provided)
		else
			Result := _PiEdWeb_Save(Values, 0, 0, 0, 0,
				_PIES_Notify.Bind(Receipt), _PIES_Reload.Bind(Receipt), Provided)
		AssertTrue(A_IsCritical)
	} finally Critical(PreviousCritical)
	if Mode == "live" {
		AssertTrue(Result is Integer && Result == 1)
		AssertEqual("Edited", PersonalInformation["first_name"])
		AssertEqual("Original", PersonalInformation["last_name"])
		AssertEqual(1, Receipt["reload"])
		AssertEqual(0, Receipt["notify"])
		if Surface == "native"
			AssertFalse(DllCall("IsWindow", "Ptr", State.Hwnd, "Int"))
	} else {
		_PISW_Bytes(Winner, FSReadBytesStrict(Path),
			"a retained or malformed explicit form must preserve the current source")
		AssertTrue(Result is Integer && Result == 0)
		AssertTrue(PersonalInformation == BeforeInformation && PersonalInformationLetters == BeforeLetters)
		AssertEqual(Generation, HSE_RuntimeDecisionGeneration)
		AssertEqual(0, Receipt["reload"])
		AssertEqual(1, Receipt["notify"])
		AssertEqual(0, Receipt["confirm"])
		if Surface == "native"
			AssertTrue(DllCall("IsWindow", "Ptr", State.Hwnd, "Int"))
	}
	Lease := _PersonalTomlWriteLeaseTryAcquire(Path, "personal-editor-consent-control")
	AssertTrue(Lease is Object)
	try AssertTrue(_PersonalTomlWriteLeaseOwns(Lease, Path))
	finally _PersonalTomlWriteLeaseRelease(Lease)
	Stages := 0
	loop files, Path . ".*.tmp"
		Stages += 1
	AssertEqual(0, Stages)
}

_PIEC_Case(Surface, Mode) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global HSE_RuntimeDecisionGeneration, ScriptInformation, _TomlUnreadableFiles
	global _PrefixInputHook, _PrefixVisibleFireDecisions
	global _PiEdWeb_EditorSource, _PiEdWeb_SessionEpoch, _PiEdWeb_ResetDone, _PiEdWeb_Gui
	global _PiEdWeb_WebView, _PiEdWeb_Controller, _PiEdWeb_MsgSub, _PiEdWeb_NavSub
	static Sequence := 0
	Saved := {HadInfo: IsSet(PersonalInformation), HadLetters: IsSet(PersonalInformationLetters),
		Cache: _ReadPersonalInfoTomlCache, Generation: HSE_RuntimeDecisionGeneration,
		HadPath: ScriptInformation.Has("PersonalInfoTomlPath"), Path: ScriptInformation.Get("PersonalInfoTomlPath", ""),
		Source: _PiEdWeb_EditorSource, Epoch: _PiEdWeb_SessionEpoch, Reset: _PiEdWeb_ResetDone,
		HadView: IsSet(_PiEdWeb_WebView), HadController: IsSet(_PiEdWeb_Controller),
		HadMsg: IsSet(_PiEdWeb_MsgSub), HadNav: IsSet(_PiEdWeb_NavSub)}
	Saved.Info := Saved.HadInfo ? PersonalInformation : 0
	Saved.Letters := Saved.HadLetters ? PersonalInformationLetters : 0
	Saved.View := Saved.HadView ? _PiEdWeb_WebView : 0
	Saved.Controller := Saved.HadController ? _PiEdWeb_Controller : 0
	Saved.Msg := Saved.HadMsg ? _PiEdWeb_MsgSub : 0
	Saved.Nav := Saved.HadNav ? _PiEdWeb_NavSub : 0
	; Refuse a foreign host before acquiring any cleanup ownership.
	AssertFalse(_PiEdWeb_Gui)
	AssertFalse(Saved.HadView || Saved.HadController || Saved.HadMsg || Saved.HadNav)
	Root := A_Temp . "\ergopti_personal_consent_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	Path := Root . "\personal_info.toml"
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Gui: 0, Hwnd: 0, View: 0}, Primary := 0, CleanupError := 0
	try {
		AssertFalse(A_IsSuspended)
		AssertFalse(_PrefixInputHook)
		AssertTrue(_PrefixVisibleFireDecisions is Array && _PrefixVisibleFireDecisions.Length == 0)
		PersonalInformation := Map("first_name", "Default", "last_name", "Default")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
		_PIEC_Exercise(Surface, Mode, Path, State)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(State.Gui) && DllCall("IsWindow", "Ptr", State.Hwnd, "Int")
				State.Gui.Destroy()
		} catch as Failure {
			CleanupError := Failure
		} finally {
			_PiEdWeb_WebView := Saved.HadView ? Saved.View : unset
			_PiEdWeb_Controller := Saved.HadController ? Saved.Controller : unset
			_PiEdWeb_MsgSub := Saved.HadMsg ? Saved.Msg : unset
			_PiEdWeb_NavSub := Saved.HadNav ? Saved.Nav : unset
			_PiEdWeb_EditorSource := Saved.Source
			_PiEdWeb_SessionEpoch := Saved.Epoch
			_PiEdWeb_ResetDone := Saved.Reset
			PersonalInformation := Saved.HadInfo ? Saved.Info : unset
			PersonalInformationLetters := Saved.HadLetters ? Saved.Letters : unset
			_ReadPersonalInfoTomlCache := Saved.Cache
			HSE_RuntimeDecisionGeneration := Saved.Generation
			if Saved.HadPath
				ScriptInformation["PersonalInfoTomlPath"] := Saved.Path
			else
				ScriptInformation.Delete("PersonalInfoTomlPath")
			if IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path)
				_TomlUnreadableFiles.Delete(Path)
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for _PIEC_Surface in ["native", "web"]
	for _PIEC_Mode in ["live", "renewed", "false", "unknown", "malformed"]
		Test("personal editor consent: " . _PIEC_Surface . " " . _PIEC_Mode
			. " (personal-info-editor-consent)", _PIEC_Case.Bind(_PIEC_Surface, _PIEC_Mode))
for _PIEC_Mode in ["reinit", "retired"]
	Test("personal editor consent: web " . _PIEC_Mode . " (personal-info-editor-consent)",
		_PIEC_Case.Bind("web", _PIEC_Mode))
