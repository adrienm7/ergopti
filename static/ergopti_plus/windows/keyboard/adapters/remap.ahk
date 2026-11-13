; keyboard/adapters/remap.ahk

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
#Include ../../platform/remap/tap_hold_loader.ahk

#Include ../engine/keys/constants.ahk
#Include ../../platform/remap/tap_hold_roll.ahk
; The second key of a key combination, before every other hotkey of a
; tap-hold key: the earliest-created eligible variant fires.
#Include ../engine/keys/combination_keys.ahk
#Include ../../platform/remap/tap_hold_roll_keys.ahk
#Include ../engine/one_shot_shift.ahk
#Include ../engine/keys/capslock.ahk
#Include ../engine/keys/lshift_lctrl.ahk
#Include ../engine/keys/lalt.ahk
#Include ../engine/keys/space.ahk
#Include ../engine/keys/altgr_criteria.ahk
#Include ../engine/keys/altgr.ahk
#Include ../engine/keys/rctrl.ahk
#Include ../engine/keys/rshift.ahk
#Include ../engine/keys/tab.ahk
#Include ../engine/keys/enter.ahk
#Include ../engine/keys/backspace.ahk
#Include ../engine/keys/escape.ahk
#Include ../engine/keys/delete.ahk
#Include ../engine/keys/win.ahk
; The navigation layer is data: layers_loader reads layers.toml, nav_layer_table
; turns it into hotkeys, and nav_layer registers them at its include position.
#Include ../engine/layers/loader.ahk
#Include ../engine/layers/nav_layer_table.ahk
#Include ../engine/layers/nav_layer.ahk
