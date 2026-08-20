; tests/unit/test_metrics_preferences_global_barrier_20260813.ahk

; ==============================================================================
; MODULE: Metrics Preference Global Barrier Tests
; DESCRIPTION:
; Proves that every legacy metrics preference path loses cleanly to an
; unrelated terminal configuration transition. No writer, live publisher or
; reload may run after refusal, including filters, encryption, app exclusions,
; the master toggle and the retained color preference.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MPGB_WriteCalls := 0
global _MPGB_NotifyCalls := 0
global _MPGB_ReloadCalls := 0
global _MPGB_EncryptionEvents := []
global _MPGB_FakeNativeEncryption := false
global _MPGB_Notifications := []
global _MPGB_NotifyCritical := []
global _MPGB_ReloadCritical := []

_MPGB_ResetFakes() {
	global _MPGB_WriteCalls, _MPGB_NotifyCalls, _MPGB_ReloadCalls
	global _MPGB_EncryptionEvents, _MPGB_FakeNativeEncryption
	global _MPGB_Notifications
	global _MPGB_NotifyCritical, _MPGB_ReloadCritical
	_MPGB_WriteCalls := 0
	_MPGB_NotifyCalls := 0
	_MPGB_ReloadCalls := 0
	_MPGB_EncryptionEvents := []
	_MPGB_FakeNativeEncryption := false
	_MPGB_Notifications := []
	_MPGB_NotifyCritical := []
	_MPGB_ReloadCritical := []
}

_MPGB_Writer(Path, Updates) {
	global _MPGB_WriteCalls
	_MPGB_WriteCalls += 1
	return 1
}

_MPGB_Notify(Message, Options) {
	global _MPGB_NotifyCalls, _MPGB_Notifications, _MPGB_NotifyCritical
	_MPGB_NotifyCalls += 1
	_MPGB_NotifyCritical.Push(A_IsCritical)
	_MPGB_Notifications.Push({ message: Message, options: Options })
	return 1
}

_MPGB_ThrowingNotify(Message, Options) {
	global _MPGB_NotifyCalls
	_MPGB_NotifyCalls += 1
	throw Error("injected notification failure")
}

_MPGB_Reload() {
	global _MPGB_ReloadCalls, _MPGB_ReloadCritical
	_MPGB_ReloadCalls += 1
	_MPGB_ReloadCritical.Push(A_IsCritical)
	return 1
}

_MPGB_EncryptionWriter(Path, Updates) {
	global _MPGB_WriteCalls, _MPGB_EncryptionEvents
	global _MPGB_FakeNativeEncryption
	_MPGB_WriteCalls += 1
	Value := !!Updates[1].Value
	Event := Value ? "write:new" : (_MPGB_FakeNativeEncryption
		? "write:old-before-compensation" : "write:old")
	_MPGB_EncryptionEvents.Push(Event)
	return 1
}

_MPGB_RefusingEncryptionApply(Target) {
	global _MPGB_EncryptionEvents, _MPGB_FakeNativeEncryption
	_MPGB_EncryptionEvents.Push(Target ? "native:new" : "native:old")
	_MPGB_FakeNativeEncryption := !!Target
	return Target ? 0 : 1
}

_MPGB_EncryptionAvailable() {
	return 1
}

_MPGB_EncryptionUnavailable() {
	return false
}

_MPGB_UnexpectedEncryptionApply(Target) {
	global _MPGB_EncryptionEvents
	_MPGB_EncryptionEvents.Push("unexpected-native-apply")
	return 1
}

_MPGB_ThrowingReload() {
	global _MPGB_ReloadCalls
	_MPGB_ReloadCalls += 1
	throw Error("injected reload failure")
}

_MPGB_UnrelatedTerminalRefusesEveryPreferenceBeforeEffects() {
	global ConfigurationFile, _SaveFullConfigReady
	global _MPGB_WriteCalls, _MPGB_NotifyCalls, _MPGB_ReloadCalls
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	SavedPrivate := MetricsFilters.private_browsing
	SavedSecure := MetricsFilters.secure_field
	SavedSystemAuth := MetricsFilters.system_auth
	SavedEncrypt := MetricsFilters.encrypt
	SavedApps := MetricsFilters.disabled_apps
	SavedEnabled := MetricsShortcuts.enabled
	SavedColors := MetricsShortcuts.wpm_menubar_colors
	SavedCipher := KL_Enc_IsEnabled()
	Bundle := false
	try {
		ConfigurationFile := A_Temp . "\ergopti_metrics_preferences.toml"
		_SaveFullConfigReady := true
		MetricsFilters.private_browsing := true
		MetricsFilters.secure_field := false
		MetricsFilters.system_auth := true
		MetricsFilters.encrypt := false
		MetricsFilters.disabled_apps := Map("retained.exe", true)
		MetricsShortcuts.enabled := false
		MetricsShortcuts.wpm_menubar_colors := false
		KL_Enc_SetEnabled(false)
		_MPGB_ResetFakes()
		Bundle := _ConfigWriteTerminalTryAcquire(
			[A_Temp . "\ergopti_unrelated_terminal_paths.toml"])
		AssertTrue(Bundle is Object)

		for Prop in ["private_browsing", "secure_field", "system_auth"] {
			AssertFalse(_MetricsToggleFilterAndReload(Prop, _MPGB_Writer,
				_MPGB_Notify, _MPGB_Reload))
		}
		AssertFalse(_MetricsToggleEncryptionAndReload(_MPGB_Writer,
			_MPGB_Notify, _MPGB_Reload))
		AssertFalse(_MetricsSaveAppPickerAndReload(["candidate.exe"],
			_MPGB_Writer, _MPGB_Notify, _MPGB_Reload))
		AssertFalse(_MetricsSetEnabledAndReload(true, _MPGB_Writer,
			_MPGB_Notify, _MPGB_Reload))
		AssertFalse(_MetricsSetPreferenceAndReload("wpm_menubar_colors", true,
			_MPGB_Writer, _MPGB_Notify, _MPGB_Reload))

		AssertEqual(0, _MPGB_WriteCalls,
			"the unrelated terminal barrier must refuse before every metrics writer")
		AssertEqual(0, _MPGB_ReloadCalls,
			"a refused metrics commit must never request a nested reload")
		AssertEqual(7, _MPGB_NotifyCalls,
			"every refused user preference must surface one visible failure")
		AssertTrue(MetricsFilters.private_browsing)
		AssertFalse(MetricsFilters.secure_field)
		AssertTrue(MetricsFilters.system_auth)
		AssertFalse(MetricsFilters.encrypt)
		AssertFalse(KL_Enc_IsEnabled(),
			"terminal refusal must not finalize the encryption candidate")
		AssertEqual(1, MetricsFilters.disabled_apps.Count)
		AssertTrue(MetricsFilters.disabled_apps.Has("retained.exe"))
		AssertFalse(MetricsFilters.disabled_apps.Has("candidate.exe"))
		AssertFalse(MetricsShortcuts.enabled)
		AssertFalse(MetricsShortcuts.wpm_menubar_colors)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		MetricsFilters.private_browsing := SavedPrivate
		MetricsFilters.secure_field := SavedSecure
		MetricsFilters.system_auth := SavedSystemAuth
		MetricsFilters.encrypt := SavedEncrypt
		MetricsFilters.disabled_apps := SavedApps
		MetricsShortcuts.enabled := SavedEnabled
		MetricsShortcuts.wpm_menubar_colors := SavedColors
		KL_Enc_SetEnabled(SavedCipher)
		_MPGB_ResetFakes()
	}
}

Test("metrics-preferences-global-barrier-20260813: unrelated terminal refusal "
	. "has zero writer, unchanged live state and no reload",
	_MPGB_UnrelatedTerminalRefusesEveryPreferenceBeforeEffects)

_MPGB_EncryptionRefusalCompensatesBeforeDurableRollback() {
	global ConfigurationFile, _SaveFullConfigReady
	global _MPGB_WriteCalls, _MPGB_NotifyCalls, _MPGB_EncryptionEvents
	global _MPGB_FakeNativeEncryption
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	SavedEncrypt := MetricsFilters.encrypt
	try {
		ConfigurationFile := A_Temp . "\ergopti_metrics_encryption_rollback.toml"
		_SaveFullConfigReady := true
		MetricsFilters.encrypt := false
		_MPGB_ResetFakes()
		AssertFalse(MF_CommitEncryptionToggle(_MPGB_EncryptionWriter,
			_MPGB_Notify, _MPGB_RefusingEncryptionApply,
			_MPGB_EncryptionAvailable))
		AssertEqual(2, _MPGB_WriteCalls,
			"native refusal must reverse the durable candidate exactly once")
		AssertEqual(1, _MPGB_NotifyCalls)
		Expected := ["write:new", "native:new", "native:old", "write:old"]
		AssertEqual(Expected.Length, _MPGB_EncryptionEvents.Length)
		for Index, Event in Expected
			AssertEqual(Event, _MPGB_EncryptionEvents[Index],
				"encryption rollback order differs at event " . Index)
		AssertFalse(MetricsFilters.encrypt,
			"a rejected native encryption candidate must never publish to RAM")
		AssertFalse(_MPGB_FakeNativeEncryption,
			"compensation must restore native encryption before disk rollback")
	} finally {
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		MetricsFilters.encrypt := SavedEncrypt
		_MPGB_ResetFakes()
	}
}

Test("metrics-preferences-global-barrier-20260813: native encryption refusal "
	. "compensates before writing the exact old value",
	_MPGB_EncryptionRefusalCompensatesBeforeDurableRollback)

_MPGB_EncryptionUnavailableIsVisibleWithoutSideEffects() {
	global ConfigurationFile, _SaveFullConfigReady
	global _MPGB_WriteCalls, _MPGB_NotifyCalls, _MPGB_ReloadCalls
	global _MPGB_EncryptionEvents, _MPGB_Notifications
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	SavedEncrypt := MetricsFilters.encrypt
	try {
		ConfigurationFile := A_Temp . "\ergopti_metrics_encryption_unavailable.toml"
		_SaveFullConfigReady := true
		MetricsFilters.encrypt := false
		_MPGB_ResetFakes()
		AssertFalse(_MetricsToggleEncryptionAndReload(_MPGB_Writer,
			_MPGB_Notify, _MPGB_Reload, _MPGB_UnexpectedEncryptionApply,
			_MPGB_EncryptionUnavailable))
		AssertEqual(0, _MPGB_WriteCalls,
			"an unavailable encryption candidate must not reach the writer")
		AssertEqual(0, _MPGB_EncryptionEvents.Length,
			"an unavailable encryption candidate must not reach native state")
		AssertEqual(0, _MPGB_ReloadCalls,
			"an unavailable encryption candidate must not request reload")
		AssertFalse(MetricsFilters.encrypt,
			"an unavailable encryption candidate must leave RAM unchanged")
		AssertEqual(1, _MPGB_NotifyCalls,
			"encryption unavailability must be visible exactly once")
		AssertEqual(1, _MPGB_Notifications.Length)
		AssertEqual(t("dialog.metrics.encryption_unavailable"),
			_MPGB_Notifications[1].message)
		AssertEqual("error", _MPGB_Notifications[1].options.Get("level", ""))
	} finally {
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		MetricsFilters.encrypt := SavedEncrypt
		_MPGB_ResetFakes()
	}
}

Test("metrics-preferences-global-barrier-20260813: unavailable encryption "
	. "reports once without writer, native state or reload",
	_MPGB_EncryptionUnavailableIsVisibleWithoutSideEffects)

_MPGB_EncryptionUnavailableNotifierFailureIsConfined() {
	global ConfigurationFile, _SaveFullConfigReady
	global _MPGB_WriteCalls, _MPGB_NotifyCalls, _MPGB_ReloadCalls
	global _MPGB_EncryptionEvents
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	SavedEncrypt := MetricsFilters.encrypt
	try {
		ConfigurationFile := A_Temp . "\ergopti_metrics_encryption_notify_failure.toml"
		_SaveFullConfigReady := true
		MetricsFilters.encrypt := false
		_MPGB_ResetFakes()
		AssertFalse(_MetricsToggleEncryptionAndReload(_MPGB_Writer,
			_MPGB_ThrowingNotify, _MPGB_Reload,
			_MPGB_UnexpectedEncryptionApply, _MPGB_EncryptionUnavailable))
		AssertEqual(1, _MPGB_NotifyCalls,
			"a failing notification adapter must be attempted exactly once")
		AssertEqual(0, _MPGB_WriteCalls)
		AssertEqual(0, _MPGB_EncryptionEvents.Length)
		AssertEqual(0, _MPGB_ReloadCalls)
		AssertFalse(MetricsFilters.encrypt)
	} finally {
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		MetricsFilters.encrypt := SavedEncrypt
		_MPGB_ResetFakes()
	}
}

Test("metrics-preferences-global-barrier-20260813: unavailable notification "
	. "failure cannot escape the menu callback",
	_MPGB_EncryptionUnavailableNotifierFailureIsConfined)

_MPGB_ThrownReloadIsConfined() {
	global _MPGB_ReloadCalls
	_MPGB_ResetFakes()
	AssertFalse(_MetricsReloadAfterCommit(1, _MPGB_ThrowingReload),
		"a thrown reload adapter must be reported as a false callback result")
	AssertEqual(1, _MPGB_ReloadCalls)
}

Test("metrics-preferences-global-barrier-20260813: thrown reload callback "
	. "cannot escape the menu action",
	_MPGB_ThrownReloadIsConfined)

_MPGB_InheritedCriticalStopsAtMetricsEffects() {
	global ConfigurationFile, _SaveFullConfigReady
	global _MPGB_NotifyCritical, _MPGB_ReloadCritical
	SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	SavedEncrypt := MetricsFilters.encrypt
	SavedCritical := A_IsCritical
	try {
		ConfigurationFile := A_Temp . "\ergopti_metrics_critical.toml"
		_SaveFullConfigReady := true
		MetricsFilters.encrypt := false
		_MPGB_ResetFakes()
		Critical("On")
		AssertFalse(MF_CommitEncryptionToggle(_MPGB_Writer, _MPGB_Notify,
			_MPGB_UnexpectedEncryptionApply, _MPGB_EncryptionUnavailable))
		AssertTrue(A_IsCritical,
			"the encryption callback must restore inherited Critical")
		Critical("Off")
		AssertEqual(1, _MPGB_NotifyCritical.Length)
		AssertEqual(0, _MPGB_NotifyCritical[1],
			"encryption-unavailable notification must run interruptibly")

		_MPGB_ResetFakes()
		Critical("On")
		AssertTrue(_MetricsReloadAfterCommit(1, _MPGB_Reload))
		AssertTrue(A_IsCritical,
			"the metrics reload action must restore inherited Critical")
		Critical("Off")
		AssertEqual(1, _MPGB_ReloadCritical.Length)
		AssertEqual(0, _MPGB_ReloadCritical[1],
			"the post-commit metrics reload must run interruptibly")
	} finally {
		Critical("Off")
		ConfigurationFile := SavedPath
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		MetricsFilters.encrypt := SavedEncrypt
		_MPGB_ResetFakes()
		Critical(SavedCritical)
	}
}
Test("metrics-preferences-global-barrier-20260813: notification and reload "
	. "defuse inherited Critical (metrics-postcommit-inherited-critical)",
	_MPGB_InheritedCriticalStopsAtMetricsEffects)
