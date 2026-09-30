; ui/onboarding/init.ahk

; ==============================================================================
; MODULE: Onboarding Wizard
; DESCRIPTION:
; Displays the first-run wizard that guides the user through the initial
; configuration of ErgoptiPlus when no config.toml is found, and re-runs it
; from the tray over the configuration in force.
;
; FEATURES & RATIONALE:
; 1. First-Run Detection: Called by ErgoptiPlus.ahk before any feature is
;    activated — if ConfigurationFile does not exist, the wizard must run
;    before the script can operate.
; 2. One shared page: the WebView2 host shows the cross-driver page at
;    _shared/ui/onboarding/, one opt-in question per feature category in the
;    order the manifest declares, with the recommended choices to import.
; 3. Manifest answers: every answer is a manifest path validated against the
;    generated catalogue, so the host never invents a key of its own.
; 4. Atomic Write: all answers are applied in one transactional config.toml
;    write (with paths.toml when the folder moves), then Reload is called once.
; ==============================================================================





; INDEX: this file declares nothing itself; it #Include-s the onboarding
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant.
;   onboarding/core.ahk                 -- State, entry points, i18n preview.
;   onboarding/answers.ahk              -- Catalogue index, answer validation, values in force.
;   onboarding/gesture_registration.ahk -- Elevated touchpad gesture registration.
;   onboarding/finish.ahk               -- Transactional config write + reload.
;   onboarding/webview.ahk              -- WebView2 host of the shared page.

#Include core.ahk
#Include answers.ahk
#Include gesture_registration.ahk
#Include finish.ahk
#Include webview.ahk
