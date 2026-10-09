; ui/healthcheck/init.ahk

; ==============================================================================
; MODULE: Healthcheck
; DESCRIPTION:
; The diagnostics window of the Debug menu. It collects a version 2 snapshot
; (_shared/modules/diagnostics/schema.json) and shows it in the shared page
; (_shared/ui/healthcheck/), which renders every section, keeps the preview of
; what is shared and asks the host for each action by message.
;
; FEATURES & RATIONALE:
; 1. Two phases: phase A reads registry values, Win32 calls, memory and small
;    files under the schema's 5 ms budget, on the thread that also serves the
;    keyboard hook; phase B runs the network probes as curl children harvested
;    by timers, and pushes each answer into the open page.
; 2. Every page message goes through HealthCheck_ValidateAction: the host opens
;    only the paths it collected, by field id.
; 3. Everything copied, saved or sent to GitHub is redacted again by
;    Redact_Apply, whatever the page did.
; 4. Without WebView2 the window shows the snapshot as plain text in a
;    read-only field.
; ==============================================================================

#Requires AutoHotkey v2.0

; INDEX: this file declares nothing itself; it #Include-s the healthcheck
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant.
;   healthcheck/core.ahk    -- Session counters, the snapshot, the window and its messages.
;   healthcheck/helpers.ahk -- One synchronous collector per section, and the recent issues.
;   healthcheck/probes.ahk  -- The asynchronous probes (api.github.com, the local AI backend).
;   healthcheck/report.ahk  -- The page's actions and the Debug menu's reports.
;   healthcheck/actions.ahk -- Validation of the diagnostics page's actions.

#Include core.ahk
#Include helpers.ahk
#Include probes.ahk
#Include report.ahk
#Include actions.ahk
