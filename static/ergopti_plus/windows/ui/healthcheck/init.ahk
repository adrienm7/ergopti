; ui/healthcheck/init.ahk

; ==============================================================================
; MODULE: Healthcheck
; DESCRIPTION:
; Diagnostic probe that snapshots the runtime state of the AutoHotkey driver
; and returns it in both structured (Map) and human-readable (string) form.
; Designed to be triggered from the tray Debug submenu or via a command-line
; flag so operators can verify the driver is properly wired without log files.
;
; FEATURES & RATIONALE:
; 1. Adapter probing: checks each adapter module file is present on disk and
;    that the expected public function names are defined in the global scope,
;    without calling or altering any of them.
; 2. Port validation: records which adapters expose their full contract surface
;    (load + all required functions present) vs which are partially broken.
; 3. Last error capture: reads the module-level _HealthCheckLastError variable
;    set by HealthCheck_RecordError() so callers can surface the most recent
;    failure without parsing log files.
; 4. Uptime: computes milliseconds elapsed since this module was loaded
;    (captured in _HealthCheckStartMs at parse time) and converts to whole seconds.
; 5. System info: captures OS version (including build number), CPU, RAM, AHK
;    runtime, screen resolution, locale, and config directory for a complete
;    at-a-glance snapshot.
; 6. Recent log entries: pulls the last 50 WARNING/ERROR lines from the in-memory
;    ring buffer so diagnosis is possible without opening log files.
; 7. Selectable window: displays the report in a WebView2 window (text is
;    selectable and copyable) with a fallback read-only Edit control.
; ==============================================================================

#Requires AutoHotkey v2.0

; INDEX: this file declares nothing itself; it #Include-s the healthcheck
; sub-modules below. Functions and globals are hoisted into the global
; namespace, so load order is irrelevant.
;   healthcheck/core.ahk    -- Probe, public API, WebView2 report window.
;   healthcheck/helpers.ahk -- State-gathering probes + snapshot rendering.

#Include core.ahk
#Include helpers.ahk
