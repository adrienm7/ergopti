; shortcuts/shortcuts.ahk

; ==============================================================================
; MODULE: Shortcuts
; DESCRIPTION:
; Defines all keyboard shortcuts (Win, Alt, Ctrl) built on top
; of the Ergopti layout. Includes CapsWord helpers and the AddShortcut/
; RetrieveScancode utilities that resolve layout-aware scan codes at runtime.
;
; ARCHITECTURE:
; This file is the entry-point only. Implementation is split across sub-modules
; under shortcuts/engine/ for navigability.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Sub-module includes =======
; ======================================
; ======================================

#Include engine/utils.ahk
#Include engine/win.ahk
#Include engine/capsword_auto_off.ahk
#Include engine/capsword.ahk
