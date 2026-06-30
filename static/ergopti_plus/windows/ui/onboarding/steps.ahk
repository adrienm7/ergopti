; ui/onboarding/steps.ahk

; ==============================================================================
; MODULE: Onboarding / Wizard Step Implementations (shim)
; DESCRIPTION:
; Thin entry point that composes all wizard step sub-modules. The five wizard
; steps and their sub-steps are split into three focused files by theme:
;   - steps_config.ahk   — locale selection, config-folder picker, pre-fill
;   - steps_keyboard.ahk — Ergopti layout choice, magic-key binding
;   - steps_metrics.ahk  — typing metrics opt-in, trackpad gestures setup
;
; Split out of the former lib/onboarding.ahk (P5 refactor); see
; ui/onboarding/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the onboarding/*.ahk files is irrelevant.
; ==============================================================================

#Include steps_config.ahk
#Include steps_keyboard.ahk
#Include steps_metrics.ahk
