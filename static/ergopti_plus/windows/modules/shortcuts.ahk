; modules/shortcuts.ahk

; ==============================================================================
; MODULE: Shortcuts
; DESCRIPTION:
; Defines all keyboard shortcuts (Win, Alt, Ctrl) built on top
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
#Include shortcuts/win.ahk
#Include shortcuts/auto_click_matcher.ahk
#Include shortcuts/auto_click_policy.ahk
#Include shortcuts/keep_awake_presets.ahk
#Include shortcuts/auto_click_session.ahk
#Include shortcuts/auto_click.ahk
#Include shortcuts/capsword_auto_off.ahk
#Include shortcuts/capsword.ahk
