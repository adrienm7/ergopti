; tests/unit/test_metrics_shortcut_menu_refresh.ahk

; ==============================================================================
; MODULE: Metrics shortcut tray refresh
; DESCRIPTION:
; Proves that a committed shortcut and a surfaced partial recovery state both
; refresh the tray's snapshotted label, while a strict false/string no-op does not.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MSMR_PromptMode := ""
global _MSMR_PromptCalls := 0
global _MSMR_RefreshCalls := 0

_MSMR_Prompt(which, ToggleFn) {
	global _MSMR_PromptMode, _MSMR_PromptCalls
	_MSMR_PromptCalls += 1
	if (_MSMR_PromptMode = "success") {
		MetricsShortcuts.typing_str := "ctrl+alt+n"
		MetricsShortcuts.typing_status := MetricsShortcuts.STATUS_ACTIVE
		return true
	}
	if (_MSMR_PromptMode = "partial") {
		MetricsShortcuts.typing_status := MetricsShortcuts.STATUS_CLEANUP_PENDING
		return false
	}
	return "1"
}

_MSMR_Refresh() {
	global _MSMR_RefreshCalls
	_MSMR_RefreshCalls += 1
	return true
}

_MSMR_NoopToggle(*) {
}

_MSMR_StrictRefreshOutcomes() {
	global _MSMR_PromptMode, _MSMR_PromptCalls, _MSMR_RefreshCalls
	SavedString := MetricsShortcuts.typing_str
	SavedStatus := MetricsShortcuts.typing_status
	SavedRecovery := MetricsShortcuts.typing_recovery_handles
	try {
		MetricsShortcuts.typing_str := "ctrl+alt+m"
		MetricsShortcuts.typing_status := MetricsShortcuts.STATUS_ACTIVE
		MetricsShortcuts.typing_recovery_handles := []
		_MSMR_PromptCalls := 0
		_MSMR_RefreshCalls := 0

		_MSMR_PromptMode := "success"
		AssertTrue(_MET_PromptShortcutAndRefresh("typing", _MSMR_NoopToggle,
			_MSMR_Prompt, _MSMR_Refresh))
		AssertEqual(1, _MSMR_PromptCalls)
		AssertEqual(1, _MSMR_RefreshCalls,
			"a committed shortcut must refresh its snapshotted tray label once")

		MetricsShortcuts.typing_str := "ctrl+alt+m"
		MetricsShortcuts.typing_status := MetricsShortcuts.STATUS_ACTIVE
		_MSMR_PromptMode := "string-status"
		AssertFalse(_MET_PromptShortcutAndRefresh("typing", _MSMR_NoopToggle,
			_MSMR_Prompt, _MSMR_Refresh),
			"truthy String status must not acknowledge a shortcut commit")
		AssertEqual(1, _MSMR_RefreshCalls,
			"an unchanged refused projection needs no tray refresh")

		_MSMR_PromptMode := "partial"
		AssertFalse(_MET_PromptShortcutAndRefresh("typing", _MSMR_NoopToggle,
			_MSMR_Prompt, _MSMR_Refresh),
			"cleanup-pending remains a surfaced partial failure")
		AssertEqual(2, _MSMR_RefreshCalls,
			"a changed warning projection must refresh despite a false commit")
	} finally {
		MetricsShortcuts.typing_str := SavedString
		MetricsShortcuts.typing_status := SavedStatus
		MetricsShortcuts.typing_recovery_handles := SavedRecovery
	}
}
Test("metrics shortcut tray: strict success and partial state refresh labels "
	. "(metrics-shortcut-tray-refresh)", _MSMR_StrictRefreshOutcomes)
