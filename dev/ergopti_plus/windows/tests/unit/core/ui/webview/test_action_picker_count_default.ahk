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
