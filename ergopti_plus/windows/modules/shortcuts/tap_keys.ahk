; modules/shortcuts/tap_keys.ahk

; ==============================================================================
; MODULE: Number-Row Tap Key Hotkeys
; DESCRIPTION:
; The static hotkeys of the three number-row tap keys; their logic, their
; assignments and their labels are infra/tap_keys.ahk.
;
; FEATURES & RATIONALE:
; 1. Static, and included before modules/keymap/layout.ahk. AutoHotkey fires the
;    earliest-created eligible #HotIf variant of a hotkey, and the digit-row
;    emulation declares SC029, SC00C and SC00D too: created later, or at run
;    time through Hotkey(), a tap key would never win over it. A #HotIf that
;    answers false hands the key to the emulation, or to the OS.
; 2. No * and no ~: SC029:: fires only with no modifier held, which is exactly
;    "a plain tap" (Shift, Ctrl, Alt, Win and AltGr, which is Ctrl+Alt, all fall
;    through), and it swallows the key.
; ==============================================================================

#Requires AutoHotkey v2.0

#HotIf TapKeyShouldFire("number_row_left")
SC029:: TapKeyFire("number_row_left")
#HotIf TapKeyShouldFire("number_row_right_1")
SC00C:: TapKeyFire("number_row_right_1")
#HotIf TapKeyShouldFire("number_row_right_2")
SC00D:: TapKeyFire("number_row_right_2")
#HotIf
