; tests/unit/test_llm_nav_event_owner.ahk

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
#Include llm_nav_event_owner/native_port.ahk
#Include llm_nav_event_owner/presentation_fixtures.ahk
#Include llm_nav_event_owner/test_surface_ownership.ahk
#Include llm_nav_event_owner/test_start_admission.ahk
#Include llm_nav_event_owner/test_quarantine_lifecycle.ahk
#Include llm_nav_event_owner/test_suspend_fences.ahk
#Include llm_nav_event_owner/test_receipt_repaint.ahk
#Include llm_nav_event_owner/test_health_recovery.ahk
#Include llm_nav_event_owner/test_route_binding.ahk
#Include llm_nav_event_owner/test_native_abi.ahk
#Include llm_nav_event_owner/test_profile_receipts.ahk
#Include llm_nav_event_owner/test_stop_diagnostics.ahk
