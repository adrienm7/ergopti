; infra/script_altgr_hotkeys.ahk

; ==============================================================================
; MODULE: Script AltGr Hotkeys
; DESCRIPTION:
; Registration + dispatch for the script's AltGr chord shortcuts (AltGr+Enter/
; BackSpace/Delete/Escape and their Kana-fixup / suspended-state variants).
; Extracted verbatim from ErgoptiPlus.ahk (the entry-point decomposition) and
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
		return GetKeyState("SC138", "P") or GetKeyState("RAlt", "P")
}
_ScriptAltGrDispatch(SuffixSC, Slot, NativeSend) {
		if _ScriptAltGrChordDebounce(Slot)
				return
		if !_ScriptAltGrIsPhysical(SuffixSC) {
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
		_ScriptAltGrDispatch("SC01C", "script_altgr_enter", "{Enter}")
}
_ScriptAltGrBackSpaceHandler(*) {
		_ScriptAltGrDispatch("SC00E", "script_altgr_backspace", "{BackSpace}")
}
_ScriptAltGrDeleteHandler(*) {
		_ScriptAltGrDispatch("SC153", "script_altgr_delete", "{Delete}")
}
_ScriptAltGrEscapeHandler(*) {
		_ScriptAltGrDispatch("SC001", "script_altgr_escape", "{Escape}")
}

global _SCRIPT_ALTGR_HOTKEY_OPTS := "I3 S"
_ScriptAltGrHookKey(KeyName) {
		return (SubStr(KeyName, 1, 1) = "$" or InStr(KeyName, " & ")) ? KeyName : "$" . KeyName
}
_RegisterScriptAltGrHotkeys() {
		global _SCRIPT_ALTGR_HOTKEY_OPTS
		opts := _SCRIPT_ALTGR_HOTKEY_OPTS
		; The AltGr key by its scan code only. "RAlt & Enter" and "^!Enter" twins
		; were dead: the SC138 hotkeys route every right Alt event to the scan
		; code's record, and the SC01C/SC00E/SC153/SC001 hotkeys below route
		; those keys' events to theirs, so a twin named by a virtual key was never
		; looked up (hook.cpp: sc_takes_precedence). ScriptAltGrChordIsLive keeps
		; them, running and paused, off a layout whose AltGr key is a plain Alt:
		; on QWERTY RAlt+Esc must stay Alt+Esc, not quit the driver.
		HotIf((*) => ScriptAltGrChordIsLive(IsRealAltGrPress()))
		Hotkey(_ScriptAltGrHookKey("SC138 & SC01C"), _ScriptAltGrEnterHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC00E"), _ScriptAltGrBackSpaceHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC153"), _ScriptAltGrDeleteHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC138 & SC001"), _ScriptAltGrEscapeHandler, opts)
		HotIf()
		; The Kana-style twins, registered on every layout: the AltGr family
		; follows the foreground window's layout (infra/altgr_family.ahk), so
		; the criterion decides per press whether this layout is a Kana one.
		HotIf((*) => ScriptAltGrKanaChordIsLive(GetKeyState("SC138", "P")))
		Hotkey(_ScriptAltGrHookKey("SC01C"), _ScriptAltGrEnterHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC00E"), _ScriptAltGrBackSpaceHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC153"), _ScriptAltGrDeleteHandler, opts)
		Hotkey(_ScriptAltGrHookKey("SC001"), _ScriptAltGrEscapeHandler, opts)
		HotIf()
		; While paused the AltGr combinations cannot arm (the prefix anchor is
		; suspended with every hotkey), so the chords run from the suffix alone.
		; With * they also match under the LCtrl+RAlt an AltGr layout holds:
		; without it, AltGr+Enter could not unpause there.
		HotIf((*) => ScriptAltGrChordIsLive(A_IsSuspended and GetKeyState("SC138", "P")))
		Hotkey(_ScriptAltGrHookKey("*SC01C"), _ScriptAltGrEnterHandler, opts)
		Hotkey(_ScriptAltGrHookKey("*SC00E"), _ScriptAltGrBackSpaceHandler, opts)
		Hotkey(_ScriptAltGrHookKey("*SC153"), _ScriptAltGrDeleteHandler, opts)
		Hotkey(_ScriptAltGrHookKey("*SC001"), _ScriptAltGrEscapeHandler, opts)
		HotIf()
}
