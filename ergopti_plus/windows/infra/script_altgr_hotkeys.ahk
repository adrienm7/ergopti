; infra/script_altgr_hotkeys.ahk

; ==============================================================================
; MODULE: Script AltGr Hotkeys
; DESCRIPTION:
; Registration + dispatch for the script's AltGr chord shortcuts (AltGr+Enter/
; BackSpace/Delete/Escape and their Kana-fixup / suspended-state variants).
; The hotkeys and their criteria are data (ScriptAltGrChordPlan, in
; modules/keymap/layout/layout_altgr.ahk); a chord belongs to the driver only
; while its slot runs an action. #Include'd at the position the entry point
; always registered them, so boot order is unchanged.
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
; The trailing parameter swallows the hotkey name AutoHotkey passes to a callback.
_ScriptAltGrDispatch(SuffixSC, Slot, NativeSend, *) {
		if _ScriptAltGrChordDebounce(Slot)
				return
		if !_ScriptAltGrIsPhysical(SuffixSC) {
				SendFinalResult(NativeSend)
				return
		}
		; Run the action even while suspended: _RegisterScriptAltGrHotkeys registers
		; a dedicated set of suffix-only hotkeys gated on the paused criterion
		; (ScriptAltGrPausedChordRunsSlot) precisely so the script-management chords
		; (pause toggle, reload, open personal shortcuts, quit) keep working from the
		; keyboard while paused -- otherwise a user paused via the tray menu or a
		; gesture has no keyboard way back (feedback: AltGr+Enter/BackSpace silently
		; no-op while paused).
		RunScriptShortcutAction(Slot)
		ResetScriptComboKeys(SuffixSC)
}
global _SCRIPT_ALTGR_HOTKEY_OPTS := "I3 S"
; The rows of ScriptAltGrChordPlan once registered, kept so the startup smoke can
; prove every chord exists under its criterion; empty until the boot registers.
global _ScriptAltGrChordRows := []

; Registers the script chords of ScriptAltGrChordPlan, each under the #HotIf
; bound to its slot, so a slot without an action leaves its chord to the system.
_RegisterScriptAltGrHotkeys() {
		global _SCRIPT_ALTGR_HOTKEY_OPTS, _ScriptAltGrChordRows
		global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_SCAN_CODES, SCRIPT_SHORTCUT_FALLBACKS
		if (_ScriptAltGrChordRows.Length != 0)
				throw Error("The script AltGr chords are already registered.")
		Plan := ScriptAltGrChordPlan(SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_SCAN_CODES)
		try {
				for Row in Plan {
						HotIf(Row["criterion"])
						Hotkey(Row["hotkey"], _ScriptAltGrDispatch.Bind(Row["scan_code"], Row["slot"],
								SCRIPT_SHORTCUT_FALLBACKS[Row["slot"]]), _SCRIPT_ALTGR_HOTKEY_OPTS)
				}
		} finally {
				HotIf()
		}
		_ScriptAltGrChordRows := Plan
}
