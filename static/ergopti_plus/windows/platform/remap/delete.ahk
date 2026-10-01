; platform/remap/delete.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Delete (Suppr)
; DESCRIPTION:
; Delete tap-hold: any action from GESTURE_ACTIONS on tap (default: delete),
; any hold modifier or nav layer on hold. Scancode SC153.
;
; Modifier or layer ownership begins synchronously on physical key-down. The
; owner is balanced on release before a quick isolated press emits the tap.
;
; Note: this remaps the physical Delete/Suppr key (SC153 — the EXTENDED scancode).
; SC053 is NumpadDel/NumpadDot, a different physical key: binding it meant the
; nav-cluster Delete never reached this module at all. The LAlt and RCtrl
; modules emit Delete as an *output* action — that is unrelated to this module.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 13/ DELETE =======
; ==========================
; ==========================

; Helper predicates -------------------------------------------------------

_DeleteHoldModKey() {
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "delete"), "delete")
}







; ===========================================
; ===========================================
; ======= 13.1) Hold-modifier variant =======
; ===========================================
; ===========================================

#HotIf TapHoldHoldModifier(TapHold, "delete") != "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC153:: {
	Result := TapHoldOwnHoldModifier("delete", "Delete",
		_DeleteHoldModKey(), TapHoldDuration(TapHold, "delete"), _DeleteDispatch)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("delete"))
		_DeleteDispatch()
}
#HotIf







; ========================================
; ========================================
; ======= 13.2) Hold-layer variant =======
; ========================================
; ========================================

#HotIf TapHoldHoldLayer(TapHold, "delete") != "" and TapHoldHoldModifier(TapHold, "delete") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC153:: {
	Result := TapHoldOwnHoldLayer("delete", "Delete", TapHoldDuration(TapHold, "delete"), _DeleteDispatch)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("delete"))
		_DeleteDispatch()
}
#HotIf







; =====================================
; =====================================
; ======= 13.3) Own auto-repeat =======
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
#HotIf TapHoldPressIsOwned("delete")
*SC153::
SC153::
^SC153::
!SC153::
^!SC153::
+SC153::
^+SC153::
!+SC153::
^!+SC153::
#SC153::
^#SC153::
!#SC153::
^!#SC153::
+#SC153::
^+#SC153::
!+#SC153::
^!+#SC153::
{
	return
}
#HotIf







; ==============================================================================
; ==============================================================================
; ======= 13.4) Tap-only (tap action set to something other than delete) =======
; ==============================================================================
; ==============================================================================

; $ prevents re-entry. Fire immediately on key-down — no KeyWait or A_PriorKey
; guard needed since there is no hold behaviour. No ~ needed: the action replaces
; the native key entirely; ~ would send both Delete and the action.
#HotIf TapHoldTapAction(TapHold, "delete") != "" and TapHoldTapAction(TapHold, "delete") != "delete" and TapHoldHoldModifier(TapHold, "delete") == "" and TapHoldHoldLayer(TapHold, "delete") == "" and not LayerEnabled and not TapHoldKanaAltGrHeld()
$SC153:: _DeleteDispatch()
#HotIf







; ==================================
; ==================================
; ======= 13.5) Tap dispatch =======
; ==================================
; ==================================

_DeleteDispatch() {
	local action := TapHoldTapAction(TapHold, "delete")
	; No tap configured or tap = delete itself → native key behaviour.
	if (action == "" or action == "delete") {
		TapHoldDispatchTap("delete", TapHoldEmitKeyTap.Bind("Delete"))
		return
	}
	_TapHoldFireAction("delete")
}
