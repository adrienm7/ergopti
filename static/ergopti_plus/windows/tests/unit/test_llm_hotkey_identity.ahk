; tests/unit/test_llm_hotkey_identity.ahk

; ==============================================================================
; MODULE: LLM Hotkey Identity Tests
; DESCRIPTION:
; The LLM menu translates its modifier settings through the shared chord
; grammar (LLM_Menu_ShortcutToAhk), refuses a mistyped modifier before any
; rebinding, and restores its persisted options exactly once per process.
; These cases lived in the retired trigger-shortcut transaction suite; the
; functions they cover remain the navigation and validation hotkeys' owners.
; ==============================================================================

#Requires AutoHotkey v2.0

_LHI_SharedGrammar() {
	AssertEqual("^space", LLM_Menu_ShortcutToAhk("control+space"))
	AssertEqual("^m", LLM_Menu_ShortcutToAhk("ctrl+ctrl+m"))
	AssertEqual("", LLM_Menu_ShortcutToAhk("crtl+space"))
}
Test("[llm-hotkey-identity] translation delegates to the shared chord grammar",
	_LHI_SharedGrammar)

_LHI_NavigationModifierValidation() {
	AssertEqual(true, LLM_Menu_IsValidModifierString(""))
	AssertEqual(true, LLM_Menu_IsValidModifierString("ctrl"))
	AssertEqual(true, LLM_Menu_IsValidModifierString("control+shift"))
	AssertEqual(false, LLM_Menu_IsValidModifierString("crtl"))
	AssertEqual(false, LLM_Menu_IsValidModifierString("alt+unknown"))
}
Test("[llm-hotkey-identity] navigation modifier typos are rejected before rebinding",
	_LHI_NavigationModifierValidation)

_LHI_StaleSavedOptsCannotRollbackLive() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedLoaded := _LLM_Menu_Loaded
	HadModel := _LLM_Menu.Has("model")
	SavedModel := _LLM_Menu.Get("model", "")
	HadPort := _LLM_Menu.Has("ollama_port")
	SavedPort := _LLM_Menu.Get("ollama_port", 0)
	try {
		_LLM_Menu_Loaded := false
		_LLM_Menu["model"] := "live-model"
		_LLM_Menu["ollama_port"] := 11434
		BootSnapshot := Map("model", "boot-model", "ollama_port", 12000)
		AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(BootSnapshot))
		AssertEqual("boot-model", _LLM_Menu["model"])
		AssertEqual(12000, _LLM_Menu["ollama_port"])
		; Simulate the first init terminal, then a successful live menu edit.
		_LLM_Menu_Loaded := true
		_LLM_Menu["model"] := "edited-model"
		_LLM_Menu["ollama_port"] := 13000
		AssertFalse(_LLM_Menu_RestoreSavedOptsOnce(BootSnapshot),
			"a root tray rebuild must not replay its stale boot snapshot")
		AssertEqual("edited-model", _LLM_Menu["model"])
		AssertEqual(13000, _LLM_Menu["ollama_port"],
			"the one-shot guard must protect the whole saved-options class")
	} finally {
		_LLM_Menu_Loaded := SavedLoaded
		if HadModel
			_LLM_Menu["model"] := SavedModel
		else
			_LLM_Menu.Delete("model")
		if HadPort
			_LLM_Menu["ollama_port"] := SavedPort
		else
			_LLM_Menu.Delete("ollama_port")
	}
}
Test("[llm-hotkey-identity] tray rebuild cannot replay stale boot options",
	_LHI_StaleSavedOptsCannotRollbackLive)
