; tests/unit/modules/llm/navigation/test_llm_nav_event_owner.ahk

; ==============================================================================
; MODULE: LLM Navigation Event Owner Unit Tests
; DESCRIPTION:
; Exercises the production AutoHotkey bridge through an injected native port.
; The port never installs a hook and never derives the expected navigation;
; tests pre-arm native ABI decisions, then independently verify exact-record
; application, receipt completion, retention, and surface-swap ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

; Preserve cohort registration order while keeping each responsibility local.
#Include ../nav_event_owner/native_port.ahk
#Include ../nav_event_owner/presentation_fixtures.ahk
#Include ../nav_event_owner/test_surface_ownership.ahk
#Include ../nav_event_owner/test_start_admission.ahk
#Include ../nav_event_owner/test_quarantine_lifecycle.ahk
#Include ../nav_event_owner/test_suspend_fences.ahk
#Include ../nav_event_owner/test_receipt_repaint.ahk
#Include ../nav_event_owner/test_health_recovery.ahk
#Include ../nav_event_owner/test_route_binding.ahk
#Include ../nav_event_owner/test_native_abi.ahk
#Include ../nav_event_owner/test_profile_receipts.ahk
#Include ../nav_event_owner/test_stop_diagnostics.ahk
#Include ../nav_event_owner/test_val_chord_insert.ahk
#Include ../nav_event_owner/test_terminal_route_metadata.ahk
#Include ../nav_event_owner/test_terminal_output_preview.ahk
#Include ../nav_event_owner/test_terminal_output_custody.ahk
