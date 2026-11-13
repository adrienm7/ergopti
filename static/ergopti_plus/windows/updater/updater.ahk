; updater/updater.ahk

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
; 3. Channel-aware: the user subscribes to one channel of the shared registry
;    (_shared/updater/data/channels.json, most stable first). The choice is
;    persisted in the shared config TOML by Updater_SetChannel, its one owner.
; 4. GitHub Releases API: async WinHTTP requests retain immutable manual or
;    background provenance through their terminal callback.
; ==============================================================================

; INDEX: this file declares nothing itself; it #Include-s the updater
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant.
;   engine/channels.ahk    -- Update-channel registry interpreter (generated data).
;   engine/schedule.ahk    -- Automatic-check schedule port (generated timing).
;   engine/core.ahk        -- Config, version compare, release fetch + parse.
;   engine/changelog.ahk   -- Menu actions, one-click update, changelog window.
;   engine/self_update.ahk -- Download, executable swap, background polling.
;   engine/config_backup.ahk -- Configuration backup and restore (Versions window).
;   engine/release_install.ahk -- One-click install of a chosen release.

#Include ../_generated/update_channels.ahk
#Include engine/channels.ahk
#Include ../_generated/update_schedule.ahk
#Include engine/schedule.ahk
#Include engine/core.ahk
#Include engine/changelog.ahk
#Include engine/self_update.ahk
#Include engine/config_backup.ahk
#Include engine/release_install.ahk
#Include engine/asset_signature.ahk
