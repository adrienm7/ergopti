; platform/remap/key_combination_keys.ahk

; ==============================================================================
; MODULE: Tap-Holds — The Second Key Of A Key Combination
; DESCRIPTION:
; The static hotkeys of « Combinaisons de touches »: every tap-hold key, each
; eligible only while a pair that ends on it is being pressed
; (KeyCombinationOwnsHotkey, in infra/key_combinations.ahk, which holds the
; logic and the rationale; kept apart so the test suites include that logic
; without hooking the keyboard).
;
; FEATURES & RATIONALE:
; 1. Included before every key file, the keys of a rolled typing key and the
;    navigation layer: the earliest-created eligible variant of a hotkey
;    fires, and a static variant is created before every Hotkey() one, so a
;    pair wins over the second key's own tap-hold, the layout emulation and
;    the layer, and only while its first key is held.
; 2. One criterion and one handler for every key: both read the key from the
;    name of the hotkey AutoHotkey is asking about (A_ThisHotkey), its scan
;    code.
; 3. A typing key (Escape, Tab, Space, Enter, Backspace, Delete) is declared
;    bare, under any modifier (*) and under every chord of Ctrl, Alt, Shift
;    and Win: an exact chord beats the wildcard, and the first key of a pair
;    often holds a modifier.
; 4. A modifier key is declared bare and under any modifier: every hotkey the
;    driver binds on those keys is one of the two.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ The pair hotkeys =======
; ===================================
; ===================================

#HotIf KeyCombinationOwnsHotkey()
*SC001::
SC001::
^SC001::
!SC001::
^!SC001::
+SC001::
^+SC001::
!+SC001::
^!+SC001::
#SC001::
^#SC001::
!#SC001::
^!#SC001::
+#SC001::
^+#SC001::
!+#SC001::
^!+#SC001::
*SC00F::
SC00F::
^SC00F::
!SC00F::
^!SC00F::
+SC00F::
^+SC00F::
!+SC00F::
^!+SC00F::
#SC00F::
^#SC00F::
!#SC00F::
^!#SC00F::
+#SC00F::
^+#SC00F::
!+#SC00F::
^!+#SC00F::
*SC039::
SC039::
^SC039::
!SC039::
^!SC039::
+SC039::
^+SC039::
!+SC039::
^!+SC039::
#SC039::
^#SC039::
!#SC039::
^!#SC039::
+#SC039::
^+#SC039::
!+#SC039::
^!+#SC039::
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
*SC03A::
SC03A::
*SC02A::
SC02A::
*SC01D::
SC01D::
*SC15B::
SC15B::
*SC038::
SC038::
*SC138::
SC138::
*SC11D::
SC11D::
*SC036::
SC036::
{
	KeyCombinationFireHotkey()
}
#HotIf
