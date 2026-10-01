; platform/remap/backspace.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Backspace
; DESCRIPTION:
; Backspace tap-hold: any action from GESTURE_ACTIONS on tap (default:
; backspace), any hold modifier or nav layer on hold. Scancode SC00E.
;
; Modifier or layer ownership begins synchronously on physical key-down. The
; owner is balanced on release before a quick isolated press emits the tap.
;
; Note: the physical Backspace key is also used by CapsLock and LAlt modules
; as their tap output — those are output actions, not remappings of the
; physical Backspace key. This module remaps the physical Backspace key itself.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================
; =============================
; ======= 10/ BACKSPACE =======
; =============================
; =============================

; Helper predicates -------------------------------------------------------

_BackspaceHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "backspace"), "backspace")
}







; ===========================================
; ===========================================
; ======= 10.1) Hold-modifier variant =======
; ===========================================
; ===========================================

#HotIf TapHoldHoldModifier(TapHold, "backspace") != "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC00E:: {
	Result := TapHoldOwnHoldModifier("backspace", "BackSpace",
		_BackspaceHoldModKey(), TapHoldDuration(TapHold, "backspace"), _BackspaceDispatch)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("backspace"))
		_BackspaceDispatch()
}
#HotIf







; ========================================
; ========================================
; ======= 10.2) Hold-layer variant =======
; ========================================
; ========================================

#HotIf TapHoldHoldLayer(TapHold, "backspace") != "" and TapHoldHoldModifier(TapHold, "backspace") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC00E:: {
	Result := TapHoldOwnHoldLayer("backspace", "BackSpace", TapHoldDuration(TapHold, "backspace"), _BackspaceDispatch)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("backspace"))
		_BackspaceDispatch()
}
#HotIf







; =====================================
; =====================================
; ======= 10.3) Own auto-repeat =======
; =====================================
; =====================================

; The hold variants fire only with no modifier held, so the key stays itself
; under a held modifier, as on every driver. Its own auto-repeat arrives under
; the modifier or layer the hold owns and matches none of them: swallow it for
; as long as the owner resolves the press (see TapHoldPressIsOwned).
; An exact chord beats the wildcard: Space held as Shift repeated the layout
; emulation's Shift+Space hotkey. The bare key and every chord of Ctrl, Alt,
; Shift and Win are therefore declared too; a static variant is created before
; every Hotkey() one, and the first eligible variant of an identity fires.
#HotIf TapHoldPressIsOwned("backspace")
*SC00E::
SC00E::
^SC00E::
!SC00E::
^!SC00E::
+SC00E::
^+SC00E::
!+SC00E::
^!+SC00E::
#SC00E::
^#SC00E::
!#SC00E::
^!#SC00E::
+#SC00E::
^+#SC00E::
!+#SC00E::
^!+#SC00E::
{
	return
}
#HotIf







; =================================================================================
; =================================================================================
; ======= 10.4) Tap-only (tap action set to something other than backspace) =======
; =================================================================================
; =================================================================================

; $ prevents re-entry. Fire immediately on key-down — no KeyWait or A_PriorKey
; guard needed since there is no hold behaviour. No ~ needed: the action replaces
; the native key entirely; ~ would send both BackSpace and the action.
#HotIf TapHoldTapAction(TapHold, "backspace") != "" and TapHoldTapAction(TapHold, "backspace") != "backspace" and TapHoldHoldModifier(TapHold, "backspace") == "" and TapHoldHoldLayer(TapHold, "backspace") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC00E:: _BackspaceDispatch()
#HotIf







; ==================================
; ==================================
; ======= 10.5) Tap dispatch =======
; ==================================
; ==================================

_BackspaceDispatch() {
	local action := TapHoldTapAction(TapHold, "backspace")
	; No tap configured or tap = backspace itself → native key behaviour.
	if (action == "" or action == "backspace") {
		TapHoldDispatchTap("backspace", TapHoldEmitKeyTap.Bind("BackSpace"))
		return
	}
	_TapHoldFireAction("backspace")
}
