; static/drivers/autohotkey/modules/tap_holds.ahk

; ==============================================================================
; MODULE: Tap-Holds, One-Shot Shift and Navigation Layer
; DESCRIPTION:
; Implements tap-hold behaviours for CapsLock, LShift, LCtrl, LAlt, Space,
; AltGr, RCtrl and Tab keys. Also contains the One-Shot Shift mechanism and
; the full navigation layer (arrows, window management, volume...).
;
; ARCHITECTURE:
; This file is the entry-point only. Implementation is split across sub-modules
; under modules/tap_holds/ for navigability.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================
; ======= 1/ Sub-module includes =======
; ======================================
; ======================================================

#Include tap_holds/constants.ahk
#Include tap_holds/one_shot_shift.ahk
#Include tap_holds/capslock.ahk
#Include tap_holds/lshift_lctrl.ahk
#Include tap_holds/lalt.ahk
#Include tap_holds/space.ahk
#Include tap_holds/altgr.ahk
#Include tap_holds/rctrl.ahk
#Include tap_holds/tab.ahk
#Include tap_holds/nav_layer.ahk
