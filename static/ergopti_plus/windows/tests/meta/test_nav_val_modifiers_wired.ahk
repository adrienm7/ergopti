; tests/meta/test_nav_val_modifiers_wired.ahk

; ==============================================================================
; MODULE: Nav Val Modifiers Wired Meta Test
; DESCRIPTION:
; Static source guard for the "nav-val-modifiers-not-wired" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

; Scans the whole ui/menu/menu_llm/ directory instead of one hardcoded file. All
; three assertions are PRESENCE checks, so widening the scope cannot weaken one —
; and _DriverDirConcat throws when the directory moves, instead of dying with an
; unreadable-path error that says nothing about the invariant at stake.
_TNV_ReadSource() {
	return _DriverDirConcat("ui/menu/menu_llm")
}

_TNV_Check() {
	Src := _TNV_ReadSource()
	Assert(InStr(Src, "LLM_Menu_BindNavHotkeys") > 0, "tab_accept.ahk must bind nav hotkeys dynamically")
	Assert(InStr(Src, "nav_modifiers") > 0, "tab_accept.ahk must read nav_modifiers")
	Assert(InStr(Src, "val_modifiers") > 0, "tab_accept.ahk must read val_modifiers")
	for Name in ["LLM_Menu_PromptNavModifiers", "LLM_Menu_PromptValModifiers"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "LLM_Menu_CommitNavModifier(") > 0,
			Name . " must delegate validation and persistence to the canonical owner")
		Assert(InStr(Body, "LLM_Menu_CommitMutation(") == 0,
			Name . " must not bypass modifier validation with a direct commit")
	}
	CommitBody := _DriverFuncBody("_LLM_Menu_CommitNavMutation")
	Assert(InStr(CommitBody, "_LLM_Menu_PrepareNavBindingCandidate") > 0,
		"the production modifier commit must prepare an inactive native slot before I/O")
	Assert(InStr(CommitBody, "_LLM_Menu_PublishPreparedNavCandidate") > 0,
		"the production modifier commit must publish RAM and the prepared slot together")
	Assert(InStr(CommitBody, "DefaultPrepare, DefaultPublish") > 0,
		"the production transaction call must receive both canonical owners directly")
	Assert(InStr(CommitBody, 'ResolvedPort.Get("prepare"') == 0
			&& InStr(CommitBody, 'ResolvedPort.Get("publish"') == 0,
		"tests may inject primitive native ports, never bypass canonical ownership")
	ApplyBody := _DriverFuncBody("_LLM_Menu_ApplyNavCommitted")
	Assert(ApplyBody != "",
		"the post-durability apply owner must remain reachable to this guard")
	Assert(InStr(ApplyBody, "LLM_Menu_BindNavHotkeys") == 0,
		"post-durability application must not start a fallible native rebind")
	InitBody := _DriverFuncBody("LLM_Menu_Init")
	Assert(InStr(InitBody,
		"if !_LLM_Menu_ActivateFirstRestoreHotkeys(FirstRestore)") > 0,
		"boot must consume the first-restore binding owner and retain failures")
	Assert(InStr(InitBody, "LLM_Menu_BindNavHotkeys") == 0,
		"ordinary tray rebuilds must not bypass the first-restore owner")
}

Test("LLMTray: nav and val modifiers are wired to Hotkey()", _TNV_Check)
