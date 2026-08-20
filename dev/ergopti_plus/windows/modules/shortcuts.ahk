; modules/shortcuts.ahk

; ==============================================================================
; MODULE: Shortcuts
; DESCRIPTION:
; Defines all keyboard shortcuts (Win, Alt, Ctrl, AltGr combos) built on top
; of the Ergopti layout. Includes CapsWord helpers and the AddShortcut/
; RetrieveScancode utilities that resolve layout-aware scan codes at runtime.
;
; ARCHITECTURE:
; This file is the entry-point only. Implementation is split across sub-modules
; under modules/shortcuts/ for navigability.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Sub-module includes =======
; ======================================
; ======================================

#Include shortcuts/utils.ahk
#Include shortcuts/base_modifier.ahk
#Include shortcuts/ctrl.ahk
#Include shortcuts/altgr.ahk
#Include shortcuts/win.ahk
#Include shortcuts/capsword.ahk
