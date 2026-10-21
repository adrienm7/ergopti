; tests/unit/modules/hotstrings/personal/test_personal_info_editor_source.ahk
; Real decoded identity A supplies each full form. A competing file B is already
; present before Save starts, so a staging-only witness cannot protect it.
#Requires AutoHotkey v2.0

_PIES_Image(Last, SwapLetters := false) {
	return '[info]`nfirst_name = "Alice"`nlast_name = "' . Last . '"`n[letters]`n'
		. (SwapLetters ? 'p = "last_name"`nn = "first_name"`n'
			: 'p = "first_name"`nn = "last_name"`n')
}

_PIES_WebValues() {
	; Decode the actual host's field image. This models the shared page's full
	; collectValues payload, without claiming browser or JavaScript execution.
	Script := _PiEdWeb_InitDataJs()
	AssertTrue(Script != "")
	Quoted := '"(?:[^"\\]|\\.)*"'
	Pattern := '\{key:(' . Quoted . '),label:(' . Quoted . '),value:('
		. Quoted . '),hint:(' . Quoted . ')\}'
	Values := Map(), At := 1
	while RegExMatch(Script, Pattern, &Field, At) {
		Key := JsonParse(Field[1]), Value := JsonParse(Field[3])
		AssertTrue(Key is String && Value is String)
		AssertFalse(Values.Has(Key), "the rendered form must not duplicate a field")
		Values[Key] := Value
		At := Field.Pos + Field.Len
	}
	AssertEqual(2, Values.Count, "the real init image must contain the complete private identity")
	AssertEqual("Alice", Values["first_name"])
	AssertEqual("Original", Values["last_name"])
	return Values
}

_PIES_Notify(Receipt, *) {
	Receipt["notify"] += 1
}

_PIES_Reload(Receipt, *) {
	Receipt["reload"] += 1
	return true
}

_PIES_Confirm(Receipt, *) {
	Receipt["confirm"] += 1
}

_PIES_Run(Surface, Mode, Path, State) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global HSE_RuntimeDecisionGeneration
	AssertEqual(1, FSWriteDurable(Path, _PIES_Image("Original")))
	ReadPersonalInfoToml(Path)
	AssertEqual("Alice", PersonalInformation["first_name"])
	AssertEqual("Original", PersonalInformation["last_name"])
	AssertEqual("first_name", PersonalInformationLetters["p"])
	AssertTrue(_ReadPersonalInfoTomlCache is Map, "the actual loader must retain model A")
	LoadedInformation := PersonalInformation, LoadedLetters := PersonalInformationLetters
	Generation := HSE_RuntimeDecisionGeneration
	Values := Surface == "web" ? _PIES_WebValues() : PersonalInformation.Clone()
	if Surface == "native" {
		State.Gui := Gui("+ToolWindow", "Private personal information source")
		State.Hwnd := State.Gui.Hwnd
		Edits := Map()
		for Key, Value in Values
			Edits[Key] := State.Gui.Add("Edit", "w160", Value)
		AssertTrue(DllCall("IsWindow", "Ptr", State.Hwnd, "Int"))
	}

	; Neither the loader cache nor the already rendered form sees this edit.
	if Mode != "live"
		AssertEqual(1, FSWriteDurable(Path,
			_PIES_Image(Mode == "last" ? "External" : "Original", Mode == "letters")))
	Winner := FSReadBytesStrict(Path)
	AssertTrue(PersonalInformation == LoadedInformation && PersonalInformationLetters == LoadedLetters)
	AssertEqual("Original", PersonalInformation["last_name"])
	AssertEqual("first_name", PersonalInformationLetters["p"])
	AssertEqual("Original", _ReadPersonalInfoTomlCache["info"]["last_name"])
	Values["first_name"] := "Edited"
	Receipt := Map("notify", 0, "reload", 0, "confirm", 0)
	if Surface == "native" {
		Edits["first_name"].Text := Values["first_name"]
		AssertEqual("Original", Edits["last_name"].Text,
			"only the first field is edited in the real native controls")
		Result := ProcessUserInput(State.Gui, Edits, 0, 0, 0, 0,
			_PIES_Notify.Bind(Receipt), _PIES_Reload.Bind(Receipt), _PIES_Confirm.Bind(Receipt))
	} else
		Result := _PiEdWeb_Save(Values, 0, 0, 0, 0,
			_PIES_Notify.Bind(Receipt), _PIES_Reload.Bind(Receipt))

	if Mode != "live" {
		; This business oracle precedes the Boolean: the old code overwrites B
		; successfully, rather than failing for a new helper or argument count.
		_PISW_Bytes(Winner, FSReadBytesStrict(Path),
			"an unchanged form field or noneditable alias must not replace a newer identity source")
		AssertTrue(Result is Integer && Result == 0)
		AssertTrue(PersonalInformation == LoadedInformation)
		AssertTrue(PersonalInformationLetters == LoadedLetters)
		AssertEqual("Alice", PersonalInformation["first_name"])
		AssertEqual("Original", PersonalInformation["last_name"])
		AssertEqual("first_name", PersonalInformationLetters["p"])
		AssertEqual(Generation, HSE_RuntimeDecisionGeneration)
		AssertEqual(1, Receipt["notify"])
		AssertEqual(0, Receipt["reload"])
		AssertEqual(0, Receipt["confirm"])
		if Surface == "native"
			AssertTrue(DllCall("IsWindow", "Ptr", State.Hwnd, "Int"),
				"a refused save must retain the real editor controls")
	} else {
		AssertTrue(Result is Integer && Result == 1)
		AssertEqual("Edited", PersonalInformation["first_name"])
		AssertEqual("Original", PersonalInformation["last_name"])
		AssertEqual("first_name", PersonalInformationLetters["p"])
		AssertEqual(1, Receipt["reload"])
		AssertEqual(0, Receipt["notify"])
		AssertEqual(Surface == "native" ? 1 : 0, Receipt["confirm"])
		if Surface == "native"
			AssertFalse(DllCall("IsWindow", "Ptr", State.Hwnd, "Int"),
				"a successful native save retires its own real controls")
	}
	Stages := 0
	loop files, Path . ".*.tmp"
		Stages += 1
	AssertEqual(0, Stages, "the completed handler must leave no owned staging file")
	Lease := _PersonalTomlWriteLeaseTryAcquire(Path, "personal-info-editor-source-control")
	AssertTrue(Lease is Object, "both terminal outcomes must release their exact write lease")
	try AssertTrue(_PersonalTomlWriteLeaseOwns(Lease, Path))
	finally _PersonalTomlWriteLeaseRelease(Lease)
	; Force an independent disk decode, not the old cache. B's fields and aliases
	; are admitted by the same public reader that originally built model A.
	_ReadPersonalInfoTomlCache := false
	ReadPersonalInfoToml(Path)
	AssertEqual(Mode == "live" ? "Edited" : "Alice", PersonalInformation["first_name"])
	AssertEqual(Mode == "last" ? "External" : "Original", PersonalInformation["last_name"])
	AssertEqual(Mode == "letters" ? "last_name" : "first_name", PersonalInformationLetters["p"])
	AssertEqual(Mode == "letters" ? "first_name" : "last_name", PersonalInformationLetters["n"])
}

_PIES_Case(Surface, Mode) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global ScriptInformation, _TomlUnreadableFiles, HSE_RuntimeDecisionGeneration
	global _PrefixInputHook, _PrefixVisibleFireDecisions
	static Sequence := 0
	Saved := {HadInfo: IsSet(PersonalInformation), HadLetters: IsSet(PersonalInformationLetters),
		Cache: _ReadPersonalInfoTomlCache, Generation: HSE_RuntimeDecisionGeneration,
		HadPath: ScriptInformation.Has("PersonalInfoTomlPath"), Path: ScriptInformation.Get("PersonalInfoTomlPath", "")}
	Saved.Info := Saved.HadInfo ? PersonalInformation : 0
	Saved.Letters := Saved.HadLetters ? PersonalInformationLetters : 0
	Root := A_Temp . "\ergopti_personal_editor_source_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	Path := Root . "\personal_info.toml"
	; Exclusive acquisition precedes cleanup ownership: no colliding file is adopted.
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Gui: 0, Hwnd: 0}, Primary := 0, CleanupError := 0
	try {
		AssertFalse(A_IsSuspended)
		; Successful saves invalidate the real watcher projection. Require its
		; inactive state so this private identity cannot dismiss or schedule UI.
		AssertFalse(_PrefixInputHook)
		AssertTrue(_PrefixVisibleFireDecisions is Array && _PrefixVisibleFireDecisions.Length == 0)
		PersonalInformation := Map("first_name", "Default", "last_name", "Default")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
		_PIES_Run(Surface, Mode, Path, State)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(State.Gui) && DllCall("IsWindow", "Ptr", State.Hwnd, "Int")
				State.Gui.Destroy()
		} catch as Failure {
			CleanupError := Failure
		} finally {
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

for _PIES_Surface in ["native", "web"]
	for _PIES_Mode in ["last", "letters", "live"]
		Test("personal info editor source: " . _PIES_Surface . " " . _PIES_Mode
			. " (personal-info-editor-source)", _PIES_Case.Bind(_PIES_Surface, _PIES_Mode))
