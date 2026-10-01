; platform/remap/enter.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Enter
; DESCRIPTION:
; Enter tap-hold: any action from GESTURE_ACTIONS on tap (default: enter),
; any hold modifier or nav layer on hold. Scancode SC01C.
;
; Modifier and layer ownership begin on physical Enter down. On release the
; hold is balanced first; only a quick, otherwise isolated press dispatches
; the configured tap action.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================
; ========================
; ======= 9/ ENTER =======
; ========================
; ========================

; Helper predicates -------------------------------------------------------

_EnterHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "enter"), "enter")
}







; ==========================================
; ==========================================
; ======= 9.1) Hold-modifier variant =======
; ==========================================
; ==========================================

#HotIf TapHoldHoldModifier(TapHold, "enter") != "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC01C:: {
	Result := TapHoldOwnHoldModifier("enter", "Enter",
		_EnterHoldModKey(), TapHoldDuration(TapHold, "enter"), _EnterDispatch)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("enter"))
		_EnterDispatch()
}
#HotIf







; =======================================
; =======================================
; ======= 9.2) Hold-layer variant =======
; =======================================
; =======================================

#HotIf TapHoldHoldLayer(TapHold, "enter") != "" and TapHoldHoldModifier(TapHold, "enter") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC01C:: {
	Result := TapHoldOwnHoldLayer("enter", "Enter", TapHoldDuration(TapHold, "enter"), _EnterDispatch)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("enter"))
		_EnterDispatch()
}
#HotIf







; ====================================
; ====================================
; ======= 9.3) Own auto-repeat =======
; ====================================
; ====================================

; The hold variants fire only with no modifier held, so the key stays itself
; under a held modifier, as on every driver. Its own auto-repeat arrives under
; the modifier or layer the hold owns and matches none of them: swallow it for
; as long as the owner resolves the press (see TapHoldPressIsOwned).
; An exact chord beats the wildcard: Space held as Shift repeated the layout
; emulation's Shift+Space hotkey. The bare key and every chord of Ctrl, Alt,
; Shift and Win are therefore declared too; a static variant is created before
; every Hotkey() one, and the first eligible variant of an identity fires.
#HotIf TapHoldPressIsOwned("enter")
*SC01C::
SC01C::
^SC01C::
!SC01C::
^!SC01C::
+SC01C::
^+SC01C::
!+SC01C::
^!+SC01C::
#SC01C::
^#SC01C::
!#SC01C::
^!#SC01C::
+#SC01C::
^+#SC01C::
!+#SC01C::
^!+#SC01C::
{
	return
}
#HotIf







; =========================================================
; =========================================================
; ======= 9.4) Tap-only (hold=none, tap action set) =======
; =========================================================
; =========================================================

; $ prevents re-entry. Fire immediately on key-down — no KeyWait needed since
; there is no hold behaviour. No ~ so the native Enter is not also sent.
#HotIf TapHoldTapAction(TapHold, "enter") != "" and TapHoldTapAction(TapHold, "enter") != "enter" and TapHoldHoldModifier(TapHold, "enter") == "" and TapHoldHoldLayer(TapHold, "enter") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC01C:: _EnterDispatch()
#HotIf







; =================================
; =================================
; ======= 9.5) Tap dispatch =======
; =================================
; =================================

_EnterDispatch() {
	local action := TapHoldTapAction(TapHold, "enter")
	; No tap configured or tap = enter itself → native key behaviour.
	if (action == "" or action == "enter") {
		TapHoldDispatchTap("enter", TapHoldEmitKeyTap.Bind("Enter"))
		return
	}
	_TapHoldFireAction("enter")
}
