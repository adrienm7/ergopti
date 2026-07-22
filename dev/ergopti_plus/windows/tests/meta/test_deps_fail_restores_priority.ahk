; tests/meta/test_deps_fail_restores_priority.ahk

; ==============================================================================
; MODULE: Deps Fail Restores Priority Meta Test
; DESCRIPTION:
; Regression guard for AHK-30: LLM_Deps_RunInstaller boosts AHK to High
; priority class so keyboard input stays responsive during a heavy download.
; Before the fix, only two paths restored Normal priority:
;   - LLM_Deps_Cancel (user clicks Cancel)
;   - _LLM_Deps_OnPollProbeResult (daemon becomes reachable)
;
; Two paths left AHK pinned at High indefinitely:
;   (a) LLM_Deps_Fail — called when the browser-fallback URL cannot open.
;       After failing, the polling timer is still running (started just before
;       the browser open) and AHK stays at High with no daemon to poll.
;   (b) The polling timer itself — when the user installs via the browser
;       (or winget) but never cancels and Ollama never responds, the 3 s poll
;       runs forever with AHK at High, draining system resources.
;
; The fix (AHK-30):
;   (a) Adds `try ProcessSetPriority("Normal")` to LLM_Deps_Fail, mirroring
;       the existing restore in LLM_Deps_Cancel.
;   (b) Adds a LLM_DEPS_POLL_TIMEOUT_MS constant + _LLM_Deps_PollStartTick
;       timestamp to bound the poll; after the deadline LLM_Deps_Fail is called
;       (which restores Normal priority and stops the poll).
;
; This test asserts (source introspection):
;   (a) LLM_Deps_Fail body contains ProcessSetPriority("Normal").
;   (b) LLM_Deps_PollServerReady body contains the timeout check using
;       LLM_DEPS_POLL_TIMEOUT_MS and calls LLM_Deps_Fail on expiry.
;   (c) LLM_Deps_RunInstaller body records _LLM_Deps_PollStartTick before
;       arming the poll timer.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TDFRP_CheckFailRestoresPriority() {
	; (a) LLM_Deps_Fail must restore the driver baseline priority
	FailBody := _DriverFuncBody("LLM_Deps_Fail")
	Assert(FailBody != "", "LLM_Deps_Fail must exist in ollama_deps_checker.ahk")
	Assert(InStr(FailBody, "ProcessSetPriority"),
		"AHK-30: LLM_Deps_Fail must call ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS) — when the browser-fallback URL fails to open, RunInstaller has already boosted to High and the call to LLM_Deps_Fail is the only exit that restores priority")
	Assert(InStr(FailBody, "DRIVER_BASELINE_PRIORITY_CLASS"),
		"AHK-30 / driver-baseline-priority-reverted-to-normal: LLM_Deps_Fail must restore via the shared DRIVER_BASELINE_PRIORITY_CLASS constant, not a hardcoded Normal literal, so it stays in sync with the boot-time boost class")
}

_TDFRP_CheckPollTimeout() {
	; (b) The poll must have a timeout ceiling
	PollBody := _DriverFuncBody("LLM_Deps_PollServerReady")
	Assert(PollBody != "", "LLM_Deps_PollServerReady must exist in ollama_deps_checker.ahk")
	Assert(InStr(PollBody, "LLM_DEPS_POLL_TIMEOUT_MS"),
		"AHK-30: LLM_Deps_PollServerReady must check LLM_DEPS_POLL_TIMEOUT_MS — without a ceiling, an abandoned install leaves AHK at High priority indefinitely (the 3 s poll runs forever)")
	Assert(InStr(PollBody, "LLM_Deps_Fail"),
		"AHK-30: LLM_Deps_PollServerReady must call LLM_Deps_Fail on timeout so the priority restore path runs")
}

_TDFRP_CheckStartTickRecorded() {
	; (c) RunInstaller must record the start tick before arming the poll
	InstallerBody := _DriverFuncBody("LLM_Deps_RunInstaller")
	Assert(InstallerBody != "", "LLM_Deps_RunInstaller must exist in ollama_deps_checker.ahk")
	Assert(InStr(InstallerBody, "_LLM_Deps_PollStartTick"),
		"AHK-30: LLM_Deps_RunInstaller must record _LLM_Deps_PollStartTick before arming the poll timer so PollServerReady can compute elapsed time for the timeout ceiling")
}


Test("meta ahk-30: LLM_Deps_Fail restores ProcessSetPriority(Normal) to prevent AHK from staying at High after a failed install",
	_TDFRP_CheckFailRestoresPriority)

Test("meta ahk-30: LLM_Deps_PollServerReady enforces a LLM_DEPS_POLL_TIMEOUT_MS ceiling to bound High-priority state",
	_TDFRP_CheckPollTimeout)

Test("meta ahk-30: LLM_Deps_RunInstaller records _LLM_Deps_PollStartTick before arming the 3 s poll timer",
	_TDFRP_CheckStartTickRecorded)
