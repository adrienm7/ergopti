; tests/unit/core/ui/webview/test_action_picker_count_default.ahk

; ==============================================================================
; MODULE: Action Picker Count Default
; DESCRIPTION:
; The picker's default prediction count names the menu the tray draws, the
; locale's menu.llm.title, and not an "AI menu" no tray has. The real string
; builder hands that text to the page raw, with the {1} the page fills.
; ==============================================================================

#Requires AutoHotkey v2.0

TestAPCD_PageReadsTheLocaleText() {
	; The builder also reads the prompt labels, which ask the menu's profiles.
	global _LLM_Menu
	Saved := _LLM_Menu.Clone()
	_LLM_Menu["user_profiles"] := [], _LLM_Menu["n_predictions"] := 1
	try Source := _ActPickWeb_ParameterStringsJson()
	finally _LLM_Menu := Saved
	Text := t("dialog.action_picker.count_default")
	AssertTrue(InStr(Text, "{1}"), "the page fills the count: " . Text)
	AssertTrue(InStr(Source, _ActPickWeb_Kv("countDefault", Text)), "the builder hands the page this text raw")
	AssertFalse(InStr(Text, "AI menu"), "no tray draws an AI menu: " . Text)
}
Test("action picker: the count default reaches the page raw (action-picker-count-default)", TestAPCD_PageReadsTheLocaleText)

TestAPCD_ConfirmNamesAnAction() {
	for Payload in [Map("action", "confirm"), Map("action", "confirm", "id", ""),
			Map("action", "confirm", "id", 7)] {
		AssertFalse(_ActPickWeb_ConfirmedId(Payload, &Id),
			"pck-07: a confirmation that names no action is refused, never the native passthrough")
		AssertEqual("", Id)
	}
	AssertTrue(_ActPickWeb_ConfirmedId(Map("action", "confirm", "id", "none"), &Id))
	AssertEqual("none", Id, "the page's own specials pass unchanged")
}
Test("action picker: a confirmation names an action, as on macOS and Linux (pck-07)", TestAPCD_ConfirmNamesAnAction)

; A caller that refuses the pick (false: a read-only config.toml, a dismissed
; parameter prompt) keeps the picker open for another pick, as macOS and Linux
; do; the window used to close before the callback ran.
TestAPCD_RefusedConfirmationKeepsThePicker() {
	global _ActPickWeb_OnConfirm, _ActPickWeb_ResetDone, _ActPickWeb_SessionEpoch
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramDebt, _ActPickWeb_Gui
	AssertEqual(0, _ActPickWeb_Gui, "headless picker controls allocate no native GUI")
	Saved := Map("callback", _ActPickWeb_OnConfirm, "reset", _ActPickWeb_ResetDone,
		"epoch", _ActPickWeb_SessionEpoch, "owner", _ActPickWeb_ProgramOwner, "debt", _ActPickWeb_ProgramDebt)
	Calls := []
	try {
		_ActPickWeb_ProgramOwner := 0, _ActPickWeb_ProgramDebt := []
		_ActPickWeb_ResetDone := false
		Refuse := (Id) => (Calls.Push(Id), false)
		_ActPickWeb_OnConfirm := Refuse
		Epoch := _ActPickWeb_SessionEpoch
		AssertFalse(_ActPickWeb_Confirm("send_text"), "pck-15: a refused pick is not a confirmation")
		AssertEqual(1, Calls.Length, "the caller was asked once")
		AssertFalse(_ActPickWeb_ResetDone, "pck-15: a refused pick keeps the picker open")
		AssertEqual(Epoch, _ActPickWeb_SessionEpoch, "pck-15: the same session stays current")
		AssertEqual(Refuse, _ActPickWeb_OnConfirm, "pck-15: the retry reaches the same caller")
		_ActPickWeb_OnConfirm := (Id) => Calls.Push(Id)
		AssertTrue(_ActPickWeb_Confirm("none"), "the retry is accepted")
		AssertEqual(2, Calls.Length)
		AssertTrue(_ActPickWeb_ResetDone, "an accepted pick closes the picker")
		AssertEqual(Epoch + 1, _ActPickWeb_SessionEpoch, "only that session retires")
	} finally {
		_ActPickWeb_OnConfirm := Saved["callback"], _ActPickWeb_ResetDone := Saved["reset"]
		_ActPickWeb_SessionEpoch := Saved["epoch"], _ActPickWeb_ProgramOwner := Saved["owner"]
		_ActPickWeb_ProgramDebt := Saved["debt"]
	}
}
Test("action picker: a refused confirmation keeps the picker open, as on macOS and Linux (pck-15)", TestAPCD_RefusedConfirmationKeepsThePicker)

TestAPCD_EveryLocaleNamesTheMenuTitle() {
	global _SharedDir
	Checked := 0
	loop files _SharedDir . "\core\i18n\data\locales\*.json" {
		Locale := JsonParse(FileRead(A_LoopFileFullPath, "UTF-8"))
		; The title opens with its emoji; the sentence quotes the words.
		Title := RegExReplace(Locale["menu.llm.title"], "^[^\p{L}]+")
		AssertTrue(Title != "", A_LoopFileName)
		AssertTrue(InStr(Locale["dialog.action_picker.count_default"], Title), A_LoopFileName . " quotes " . Title)
		Checked += 1
	}
	AssertEqual(21, Checked, "every locale")
}
Test("action picker: the count default names the menu title in every locale (action-picker-count-default)", TestAPCD_EveryLocaleNamesTheMenuTitle)
