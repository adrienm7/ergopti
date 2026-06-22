; tests/meta/test_menu_llm_actions_include.ahk
; Guards against #Include menu_llm/persist.ahk inside ui/menu/menu_llm/actions.ahk
; (resolves to ui/menu/menu_llm/menu_llm/persist.ahk and breaks ErgoptiPlus startup).

#Requires AutoHotkey v2.0

_Meta_ActionsMustNotIncludeTrayLlmPersist() {
	actionsPath := A_ScriptDir . "\..\ui\menu\menu_llm\actions.ahk"
	body := FileRead(actionsPath, "UTF-8")
	Assert(!InStr(body, "#Include menu_llm/persist.ahk", false),
		"actions.ahk must not #Include menu_llm/persist.ahk (use ui/menu/menu_llm.ahk wiring only)")
	Assert(InStr(body, "LLM_Menu_SaveConfig", false),
		"actions.ahk missing LLM_Menu_SaveConfig")
}
Test("meta: actions.ahk has no broken menu_llm/persist #Include",
	_Meta_ActionsMustNotIncludeTrayLlmPersist)