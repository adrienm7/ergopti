; lib/script_altgr_hotkeys.ahk

; ==============================================================================
; MODULE: Script AltGr Hotkeys
; DESCRIPTION:
; Registration + dispatch for the script's AltGr chord shortcuts (AltGr+Enter/
; BackSpace/Delete/Escape and their Kana-fixup / suspended-state variants).
; Extracted verbatim from ErgoptiPlus.ahk (P4 entrypoint decomposition) and
; #Include'd at the original position so boot order is unchanged.
; ==============================================================================

_ScriptAltGrChordDebounce(Slot) {
		static last := Map()
		now := A_TickCount
		prev := last.Has(Slot) ? last[Slot] : 0
		if ((now - prev) & 0xFFFFFFFF) < 80
				return true
		last[Slot] := now
		return false
}
_ScriptAltGrIsPhysical(SuffixSC) {
		global _ALTGR_KANA_FIXUP
		if !GetKeyState(SuffixSC, "P")
				return false
		if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
				return GetKeyState("SC138", "P")
		if GetKeyState("SC138", "P") or GetKeyState("RAlt", "P")
				return true
		return InStr(A_ThisHotkey, "^!") and GetKeyState("Ctrl", "P") and GetKeyState("Alt", "P") and !(GetKeyState("LAlt", "P") and !GetKeyState("RAlt", "P"))
}
_ScriptAltGrDispatch(SuffixSC, Slot, NativeSend, CtrlAltSuffixKey) {
		if _ScriptAltGrChordDebounce(Slot)
				return
		if !_ScriptAltGrIsPhysical(SuffixSC) {
				if InStr(A_ThisHotkey, "^!")
						SendFinalResult("^!{" . CtrlAltSuffixKey . "}")
				else
						SendFinalResult(NativeSend)
				return
		}
		; Run the action even while suspended: _RegisterScriptAltGrHotkeys registers
		; a dedicated set of suffix-only hotkeys gated on "A_IsSuspended and
		; GetKeyState(SC138, 'P')" precisely so the script-management chords (pause
		; toggle, reload, open personal shortcuts, quit) keep working from the
		; keyboard while paused -- otherwise a user paused via the tray menu or a
		; gesture has no keyboard way back (feedback: AltGr+Enter/BackSpace silently
		; no-op while paused).
		RunScriptShortcutAction(Slot)
		ResetScriptComboKeys(SuffixSC)
}
_ScriptAltGrEnterHandler(*) {
		_ScriptAltGrDispatch("SC01C", "script_altgr_enter", "{Enter}", "Enter")
}
_ScriptAltGrBackSpaceHandler(*) {
		_ScriptAltGrDispatch("SC00E", "script_altgr_backspace", "{BackSpace}", "Backspace")
}
_ScriptAltGrDeleteHandler(*) {
		_ScriptAltGrDispatch("SC153", "script_altgr_delete", "{Delete}", "Delete")
}
_ScriptAltGrEscapeHandler(*) {
		_ScriptAltGrDispatch("SC001", "script_altgr_escape", "{Escape}", "Escape")
}

global _SCRIPT_ALTGR_HOTKEY_OPTS := "I3 S"
_ScriptAltGrHookKey(KeyName) {
		return (SubStr(KeyName, 1, 1) = "$" or InStr(KeyName, " & ")) ? KeyName : "$" . KeyName
}
_RegisterScriptAltGrHotkeys() {
		global _SCRIPT_ALTGR_HOTKEY_OPTS
		opts := _SCRIPT_ALTGR_HOTKEY_OPTS
		HotIf((*) => IsRealAltGrPress())
		Hotkey(_ScriptAltGrHookKey("RAlt & Enter"), _ScriptAltGrEnterHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC01C"), _ScriptAltGrEnterHandler, opts)
		Hotkey(_ScriptAltGrHookKey("RAlt & BackSpace"), _ScriptAltGrBackSpaceHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC00E"), _ScriptAltGrBackSpaceHandler, opts)
		Hotkey(_ScriptAltGrHookKey("RAlt & Delete"), _ScriptAltGrDeleteHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC153"), _ScriptAltGrDeleteHandler, opts)
		Hotkey(_ScriptAltGrHookKey("RAlt & Escape"), _ScriptAltGrEscapeHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC001"), _ScriptAltGrEscapeHandler, opts)
		HotIf()
		if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
				Hotkey(_ScriptAltGrHookKey("^!Enter"), _ScriptAltGrEnterHandler, opts)
				Hotkey(_ScriptAltGrHookKey("^!Backspace"), _ScriptAltGrBackSpaceHandler, opts)
				Hotkey(_ScriptAltGrHookKey("^!Delete"), _ScriptAltGrDeleteHandler, opts)
				Hotkey(_ScriptAltGrHookKey("^!Escape"), _ScriptAltGrEscapeHandler, opts)
		}
		if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
				HotIf((*) => GetKeyState("SC138", "P"))
				Hotkey(_ScriptAltGrHookKey("SC01C"), _ScriptAltGrEnterHandler, opts)
				Hotkey(_ScriptAltGrHookKey("SC00E"), _ScriptAltGrBackSpaceHandler, opts)
				Hotkey(_ScriptAltGrHookKey("SC153"), _ScriptAltGrDeleteHandler, opts)
				Hotkey(_ScriptAltGrHookKey("SC001"), _ScriptAltGrEscapeHandler, opts)
				HotIf()
		}
		HotIf((*) => A_IsSuspended and GetKeyState("SC138", "P"))
		Hotkey(_ScriptAltGrHookKey("SC01C"), _ScriptAltGrEnterHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC00E"), _ScriptAltGrBackSpaceHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC153"), _ScriptAltGrDeleteHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC001"), _ScriptAltGrEscapeHandler, opts)
		HotIf()
}
