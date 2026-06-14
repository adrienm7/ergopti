; ui/tray_llm/tab_accept.ahk

; ==============================================================================
; MODULE: LLM Tray — Tab Accept + Nav hotkeys
; DESCRIPTION:
; Owns the context-sensitive Tab hotkey that accepts the visible prediction
; and the slot-navigation hotkeys (~Up / ~Down / Alt+1..9) that move the
; active slot when the tooltip shows multiple predictions. The hotkey
; context is gated by ``LLM_Tooltip_GetText() != ""`` via ``#HotIf`` so the
; Tab key reaches the underlying app unchanged whenever no prediction is on
; screen.
;
; FEATURES & RATIONALE:
; 1. HotIf-gated Tab: when no tooltip is visible, Tab passes through to the
;    active app — the user keeps the OS-native Tab behaviour everywhere
;    except when actively reviewing a prediction.
; 2. Cycle wraps around: ~Up past the first slot loops to the last, and
;    ~Down past the last loops back to the first — feels snappier than a
;    hard stop at the boundary.
; 3. ~ prefix on Up/Down: the tilde tells AHK to let the original keystroke
;    pass through to the app, so the user's cursor still moves while the
;    tooltip slot cycles. Mirrors the HS llm_nav_modifiers default of
;    empty modifiers (bare arrows).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ====================================
; ======= 1/ Tab Accept Hotkey =======
; ====================================
; ==========================================

; Tab accepts the visible suggestion when the tooltip is displayed.
; The hotkey is context-sensitive: active only when the tooltip is shown.
#HotIf LLM_Tooltip_GetText() != ""
Tab:: {
	LLM_Tooltip_TryAcceptTab()
}

; ── Slot navigation ──
; When the tooltip shows multiple predictions, the user can cycle the
; active slot with the configured modifier + Up / Down. The empty
; nav_modifiers case (default) binds bare Up / Down — matches the HS
; default where llm_nav_modifiers = {}. Alt+1..9 jumps directly to a
; slot, mirroring HS's val_modifiers = {"alt"}. Both bindings re-render
; the tooltip in place so the ▶ marker moves without any flicker.
global _LLM_Tray_NavHotkeysBound := []

LLM_Tray_BindNavHotkeys() {
	global _LLM_Tray, _LLM_Tray_NavHotkeysBound
	
	HotIf (*) => LLM_Tooltip_GetText() != ""
	for hk in _LLM_Tray_NavHotkeysBound {
		try Hotkey(hk, "Off")
	}
	_LLM_Tray_NavHotkeysBound := []
	
	nav_mod := _LLM_Tray.Has("nav_modifiers") ? _LLM_Tray["nav_modifiers"] : ""
	val_mod := _LLM_Tray.Has("val_modifiers") ? _LLM_Tray["val_modifiers"] : "alt"
	
	nav_prefix := LLM_Tray_ShortcutToAhk(nav_mod == "" ? "dummy" : nav_mod . "+dummy")
	if (nav_prefix != "")
		nav_prefix := SubStr(nav_prefix, 1, -5)
	
	val_prefix := LLM_Tray_ShortcutToAhk(val_mod == "" ? "dummy" : val_mod . "+dummy")
	if (val_prefix != "")
		val_prefix := SubStr(val_prefix, 1, -5)

	nav_up := "~" . nav_prefix . "Up"
	nav_dn := "~" . nav_prefix . "Down"
	
	try {
		Hotkey(nav_up, (*) => _LLM_Nav_Cycle(-1), "On")
		_LLM_Tray_NavHotkeysBound.Push(nav_up)
	} catch as e {
		LoggerWarn("LLM", "Failed to bind nav_up " nav_up ": " e.Message)
	}
	try {
		Hotkey(nav_dn, (*) => _LLM_Nav_Cycle(1), "On")
		_LLM_Tray_NavHotkeysBound.Push(nav_dn)
	} catch as e {
		LoggerWarn("LLM", "Failed to bind nav_dn " nav_dn ": " e.Message)
	}
	
	if (InStr(val_prefix, "^") || InStr(nav_prefix, "^")) {
		LoggerWarn("LLM", "Nav/Val modifiers contain Ctrl (^), which collides with profile hotkeys (Ctrl+1..9)")
	}

	Loop 9 {
		hk := val_prefix . A_Index
		idx := A_Index
		try {
			Hotkey(hk, _LLM_Tray_MakeNavJump(idx), "On")
			_LLM_Tray_NavHotkeysBound.Push(hk)
		} catch as e {
			LoggerWarn("LLM", "Failed to bind val " hk ": " e.Message)
		}
	}
	HotIf
}

_LLM_Tray_MakeNavJump(idx) {
	return (*) => _LLM_Nav_Jump(idx)
}





; ==========================================
; ==========================================
; ======= 2/ Slot Navigation Helpers =======
; ==========================================
; ==========================================

_LLM_Nav_Cycle(delta) {
	slots := LLM_Tooltip_GetSlots()
	if (slots.Length <= 1)
		return
	cur := LLM_Tooltip_GetActiveIdx()
	new_idx := cur + delta
	; Wrap around for a snappier feel — going past the end loops to the start.
	if (new_idx < 1)
		new_idx := slots.Length
	else if (new_idx > slots.Length)
		new_idx := 1
	LLM_Tooltip_SetActiveIdx(new_idx)
}

_LLM_Nav_Jump(idx) {
	slots := LLM_Tooltip_GetSlots()
	if (idx > slots.Length)
		return
	LLM_Tooltip_SetActiveIdx(idx)
}
