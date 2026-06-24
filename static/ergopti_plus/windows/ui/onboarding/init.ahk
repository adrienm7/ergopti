; ui/onboarding/init.ahk

; ==============================================================================
; MODULE: Onboarding Wizard
; DESCRIPTION:
; Displays a multi-step first-run wizard that guides the user through the
; initial configuration of ErgoptiPlus when no config.toml is found.
;
; FEATURES & RATIONALE:
; 1. First-Run Detection: Called by ErgoptiPlus.ahk before any feature is
;    activated — if ConfigurationFile does not exist, the wizard must run
;    before the script can operate.
; 2. Page-as-Destroy Pattern: Each wizard step destroys the current Gui and
;    creates a fresh one. This avoids the complexity of hiding/showing groups
;    of controls and keeps each page self-contained.
; 3. Locale-Live-Switch: Selecting a language on step 1 immediately re-renders
;    the title, heading and Next button in the previewed locale via the
;    transient cache-swap helper, so the user sees the wizard in their language
;    before even reaching step 2.
; 4. Atomic Write: All user choices are applied in a single TOML_BatchWrite
;    call at the end, then Reload is called once.
; ==============================================================================






; INDEX: this file declares nothing itself; it #Include-s the onboarding
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant.
;   onboarding/core.ahk   -- Constants, entry points, i18n preview helpers.
;   onboarding/steps.ahk  -- The five wizard step implementations.
;   onboarding/finish.ahk -- Config write/reload + shared GUI utilities.

#Include core.ahk
#Include steps.ahk
#Include finish.ahk
#Include webview.ahk
