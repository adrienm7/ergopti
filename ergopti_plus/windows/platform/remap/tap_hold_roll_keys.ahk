; platform/remap/tap_hold_roll_keys.ahk

; ==============================================================================
; MODULE: Tap-Holds — The Keys Struck While A Typing Key Is Undecided
; DESCRIPTION:
; The static hotkeys that make a key wait while a typing key is neither a tap
; nor a hold yet (tap_hold_roll.ahk holds the logic and the rationale). They
; are eligible only during that wait, and are created before every key file's
; own hotkeys and before every Hotkey() call: the earliest-created eligible
; variant of a hotkey fires. Like every hotkey of a tap-hold key, they stand
; down while another key holds the navigation layer: the layer owns its keys.
;
; FEATURES & RATIONALE:
; 1. A character key is declared bare, under any modifier (*) and under Shift
;    alone: an exact chord beats the wildcard, and the Shift layer of the
;    emulation is declared by exact chord.
; 2. Escape, Backspace, Tab, Enter, Space and Delete are declared bare and
;    under Shift only, and not under the Kana AltGr: under a held modifier
;    they are the key itself on every driver (Ctrl+Tab, Alt+Tab), at once.
; 3. The modifier keys are not here: a modifier struck during the wait types
;    nothing, and the keys after it find their own hotkeys. Neither are the
;    arrows and the other navigation keys: the driver binds them by name, and
;    one scan-code hotkey on a key makes every hotkey naming it dead
;    (project-ahk-scan-code-hotkey-shadows-the-key-name).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ The character keys =======
; =====================================
; =====================================

#HotIf TapHoldRollUndecided() and not LayerEnabled
*SC002::
SC002::
+SC002::
*SC003::
SC003::
+SC003::
*SC004::
SC004::
+SC004::
*SC005::
SC005::
+SC005::
*SC006::
SC006::
+SC006::
*SC007::
SC007::
+SC007::
*SC008::
SC008::
+SC008::
*SC009::
SC009::
+SC009::
*SC00A::
SC00A::
+SC00A::
*SC00B::
SC00B::
+SC00B::
*SC00C::
SC00C::
+SC00C::
*SC00D::
SC00D::
+SC00D::
*SC010::
SC010::
+SC010::
*SC011::
SC011::
+SC011::
*SC012::
SC012::
+SC012::
*SC013::
SC013::
+SC013::
*SC014::
SC014::
+SC014::
*SC015::
SC015::
+SC015::
*SC016::
SC016::
+SC016::
*SC017::
SC017::
+SC017::
*SC018::
SC018::
+SC018::
*SC019::
SC019::
+SC019::
*SC01A::
SC01A::
+SC01A::
*SC01B::
SC01B::
+SC01B::
*SC01E::
SC01E::
+SC01E::
*SC01F::
SC01F::
+SC01F::
*SC020::
SC020::
+SC020::
*SC021::
SC021::
+SC021::
*SC022::
SC022::
+SC022::
*SC023::
SC023::
+SC023::
*SC024::
SC024::
+SC024::
*SC025::
SC025::
+SC025::
*SC026::
SC026::
+SC026::
*SC027::
SC027::
+SC027::
*SC028::
SC028::
+SC028::
*SC029::
SC029::
+SC029::
*SC02B::
SC02B::
+SC02B::
*SC02C::
SC02C::
+SC02C::
*SC02D::
SC02D::
+SC02D::
*SC02E::
SC02E::
+SC02E::
*SC02F::
SC02F::
+SC02F::
*SC030::
SC030::
+SC030::
*SC031::
SC031::
+SC031::
*SC032::
SC032::
+SC032::
*SC033::
SC033::
+SC033::
*SC034::
SC034::
+SC034::
*SC035::
SC035::
+SC035::
*SC056::
SC056::
+SC056::
{
	TapHoldRollOtherKey(ThisHotkey)
}
#HotIf





; =============================================================
; =============================================================
; ======= 2/ The keys that stay native under a modifier =======
; =============================================================
; =============================================================

#HotIf TapHoldRollUndecided() and not LayerEnabled and not TapHoldKanaAltGrHeld()
SC001::
+SC001::
SC00E::
+SC00E::
SC00F::
+SC00F::
SC01C::
+SC01C::
SC039::
+SC039::
SC153::
+SC153::
{
	TapHoldRollOtherKey(ThisHotkey)
}
#HotIf
