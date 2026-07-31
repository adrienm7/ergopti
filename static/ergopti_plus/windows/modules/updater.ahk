; modules/updater.ahk

; ==============================================================================
; MODULE: Updater
; DESCRIPTION:
; Provides version display, one-click self-update, and background polling
; against GitHub Releases. The "Check / Update" menu item is dynamic: it
; reads as "Vérifier les mises à jour" at rest, "Mettre à jour vers vX.Y.Z"
; when a newer version is cached, and is disabled while a check is in
; progress. Clicking it always does the right thing in one action.
;
; FEATURES & RATIONALE:
; 1. One-click update: a single menu item handles check → download → swap.
;    No intermediate dialog is shown when an update is already cached.
; 2. Background polling: optional periodic silent check; surfaces a TrayTip
;    on new releases and updates the menu label immediately.
; 3. Channel-aware: the user can switch between the "main" (stable) and "dev"
;    (pre-release) channels. The setting is persisted in the shared config TOML.
; 4. GitHub Releases API: WinHttp synchronous call gated behind user click or
;    background timer — never on startup.
; ==============================================================================

; INDEX: this file declares nothing itself; it #Include-s the updater
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant.
;   updater/core.ahk        -- Config, version compare, release fetch + parse.
;   updater/changelog.ahk   -- Menu actions, one-click update, changelog window.
;   updater/self_update.ahk -- Download, executable swap, background polling.

#Include updater/core.ahk
#Include updater/changelog.ahk
#Include updater/self_update.ahk
