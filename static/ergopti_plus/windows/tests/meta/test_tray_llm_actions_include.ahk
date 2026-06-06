; tests/meta/test_tray_llm_actions_include.ahk
; Guards against #Include tray_llm/persist.ahk inside ui/tray_llm/actions.ahk
; (resolves to ui/tray_llm/tray_llm/persist.ahk and breaks ErgoptiPlus startup).

#Requires AutoHotkey v2.0

_Meta_ActionsMustNotIncludeTrayLlmPersist() {
	actionsPath := A_ScriptDir . "\..\ui\tray_llm\actions.ahk"
	body := FileRead(actionsPath, "UTF-8")
	Assert(!InStr(body, "#Include tray_llm/persist.ahk", false),
		"actions.ahk must not #Include tray_llm/persist.ahk (use ui/tray_llm.ahk wiring only)")
	Assert(InStr(body, "LLM_Tray_SaveConfig", false),
		"actions.ahk missing LLM_Tray_SaveConfig")
}
Test("meta: actions.ahk has no broken tray_llm/persist #Include",
	_Meta_ActionsMustNotIncludeTrayLlmPersist)