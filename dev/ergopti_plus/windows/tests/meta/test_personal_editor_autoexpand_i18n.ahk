; tests/meta/test_personal_editor_autoexpand_i18n.ahk

; ==============================================================================
; MODULE: Personal Editor Auto-Expand Checkbox i18n Guard
; DESCRIPTION:
; Regression guard for the native personal-hotstring editor's "Auto-expand"
; checkbox (ui/personal_toml_editor.ahk) being a hardcoded English string,
; unlike its 3 sibling checkboxes (chk_word/chk_case/chk_final, all t()-driven)
; and its own WebView2 counterpart (which uses the shared
; editor.hotstrings.cb_auto i18n key — see
; _shared/ui/hotstring_editor/index.html's data-i18n attribute).
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaPersonalEditorAutoExpandI18n() {
	Src := _DriverSourceNoComments()
	Assert(!InStr(Src, '"Auto-expand"'),
		'ui/personal_toml_editor.ahk must not hardcode the literal "Auto-expand" string — use t("editor.hotstrings.cb_auto")')
	Assert(InStr(Src, 't("editor.hotstrings.cb_auto")') > 0,
		'ui/personal_toml_editor.ahk`'s Auto-expand checkbox must use t("editor.hotstrings.cb_auto"), matching its WebView2 counterpart')
}
Test('personal_toml_editor: Auto-expand checkbox uses t("editor.hotstrings.cb_auto") instead of a hardcoded literal', _MetaPersonalEditorAutoExpandI18n)
