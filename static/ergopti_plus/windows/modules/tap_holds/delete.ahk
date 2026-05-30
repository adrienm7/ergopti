; modules/tap_holds/delete.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Delete (Suppr)
; DESCRIPTION:
; Delete tap-hold: any action from GESTURE_ACTIONS on tap (default: delete),
; any hold modifier or nav layer on hold. Scancode SC053.
;
; Note: this remaps the physical Delete/Suppr key (SC053). The LAlt and RCtrl
; modules emit Delete as an *output* action — that is unrelated to this module.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; =========================
; ======= 13/ DELETE =======
; =========================
; ==============================

; Helper predicates -------------------------------------------------------

_DeleteHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "delete") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 13.1) Hold-modifier variant =======

#HotIf TapHoldHoldModifier(TapHold, "delete") != "" and not LayerEnabled
~$SC053:: {
	ModKey := _DeleteHoldModKey()
	TextPressKey(ModKey, "Down")
	TimeBefore := A_TickCount
	KeyWait("SC053")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "delete") * 1000)
	TextPressKey(ModKey, "Up")
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "Delete"
	) {
		_DeleteDispatch()
	}
}
#HotIf




; ======= 13.2) Hold-layer variant =======

#HotIf TapHoldHoldLayer(TapHold, "delete") != "" and TapHoldHoldModifier(TapHold, "delete") == "" and not LayerEnabled
~$SC053:: {
	UpdateLastSentCharacter("Delete")

	ActivateLayer()
	KeyWait("SC053")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("Delete") ? LastSentCharacterKeyTime["Delete"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "delete") * 1000)
	if (
		tap
		and (Now - CharacterSentTime) >= TapMinDurationMs()
		and A_PriorKey == "Delete"
	) {
		_DeleteDispatch()
	}
}
#HotIf




; ======= 13.3) Tap-only (tap action set to something other than delete) =======

#HotIf TapHoldTapAction(TapHold, "delete") != "" and TapHoldTapAction(TapHold, "delete") != "delete" and TapHoldHoldModifier(TapHold, "delete") == "" and TapHoldHoldLayer(TapHold, "delete") == "" and not LayerEnabled
~$SC053:: {
	TimeBefore := A_TickCount
	KeyWait("SC053")
	TimeAfter := A_TickCount
	tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "delete") * 1000)
	if (
		tap
		and (TimeAfter - TimeBefore) >= TapMinDurationMs()
		and A_PriorKey == "Delete"
	) {
		_DeleteDispatch()
	}
}
#HotIf




; ======= 13.4) Tap dispatch =======

_DeleteDispatch() {
	local action := TapHoldTapAction(TapHold, "delete")
	; No tap configured or tap = delete itself → native key behaviour.
	if (action == "" or action == "delete") {
		TextPressKey("Delete", [])
		return
	}
	_TapHoldFireAction("delete")
}
