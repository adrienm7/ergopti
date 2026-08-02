; platform/remap.ahk

; ==============================================================================
; MODULE: Tap-Holds, One-Shot Shift and Navigation Layer
; DESCRIPTION:
; Implements tap-hold behaviours for CapsLock, LShift, LCtrl, LAlt, Space,
; AltGr, RCtrl, RShift, Tab, Enter, Backspace, Escape, Delete and Win keys.
; Also contains the One-Shot Shift mechanism and the full navigation layer
; (arrows, window management, volume...).
;
; ARCHITECTURE:
; This file is the entry-point only. Implementation is split across sub-modules
; under platform/remap/ for navigability.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Sub-module includes =======
; ======================================
; ======================================

; Explicitly own the tap-hold configuration API used by every sub-module below.
; The aggregate driver includes this first already; normal #Include include-once
; semantics preserve that order while modular validation resolves TapHoldDuration.
#Include ../platform/remap/tap_hold_loader.ahk

#Include remap/constants.ahk
#Include remap/one_shot_shift.ahk
#Include remap/capslock.ahk
#Include remap/lshift_lctrl.ahk
#Include remap/lalt.ahk
#Include remap/space.ahk
#Include remap/altgr.ahk
#Include remap/rctrl.ahk
#Include remap/rshift.ahk
#Include remap/tab.ahk
#Include remap/enter.ahk
#Include remap/backspace.ahk
#Include remap/escape.ahk
#Include remap/delete.ahk
#Include remap/win.ahk
#Include remap/nav_layer.ahk
