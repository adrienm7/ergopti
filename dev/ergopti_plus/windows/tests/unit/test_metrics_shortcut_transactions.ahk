; tests/unit/test_metrics_shortcut_transactions.ahk

; ==============================================================================
; MODULE: Metrics shortcut transactions
; DESCRIPTION:
; Behavioural regressions for AHK-15 metrics callers. A false config writer
; must leave live preferences untouched. Shortcut edits must additionally
; preserve the exact previous Hotkey binding while an inert reservation is
; written, activated and then handed off transactionally.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MPTU_WriteOk := true
global _MPTU_RollbackWriteOk := true
global _MPTU_WriteCalls := 0
global _MPTU_NotifyCalls := 0
global _MPTU_Events := []
global _MPTU_ObservedTyping := ""
global _MPTU_ObservedApps := ""
global _MPTU_LastUpdates := []
global _MPTU_FailOldOff := false
global _MPTU_FailNewOn := false
global _MPTU_OwnedHotkeys := Map()
global _MPTU_ReenterShortcut := false
global _MPTU_ReenterResult := false
global _MPTU_BuildCalls := 0
global _MPTU_LastPath := ""
global _MPTU_ToggleCalls := 0
global _MPTU_ProbeThrows := false
global _MPTU_RetireOldDuringWrite := false
global _MPTU_RetireCandidateDuringWrite := false
global _MPTU_FireCandidateDuringWrite := false
global _MPTU_FireOldDuringWrite := false
global _MPTU_TypingToggleCalls := 0
global _MPTU_AppsToggleCalls := 0
global _MPTU_RecoveryCalls := 0

_MPTU_Reset(WriteOk := true) {
	global _MPTU_WriteOk, _MPTU_RollbackWriteOk, _MPTU_WriteCalls, _MPTU_NotifyCalls
	global _MPTU_Events, _MPTU_ObservedTyping, _MPTU_ObservedApps
	global _MPTU_LastUpdates, _MPTU_FailOldOff
	global _MPTU_FailNewOn, _MPTU_OwnedHotkeys
	global _MPTU_ReenterShortcut, _MPTU_ReenterResult
	global _MPTU_BuildCalls, _MPTU_LastPath
	global _MPTU_ToggleCalls, _MPTU_ProbeThrows
	global _MPTU_RetireOldDuringWrite, _MPTU_RetireCandidateDuringWrite
	global _MPTU_FireCandidateDuringWrite, _MPTU_FireOldDuringWrite
	global _MPTU_TypingToggleCalls, _MPTU_AppsToggleCalls
	global _MPTU_RecoveryCalls
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	_MPTU_WriteOk := WriteOk
	_MPTU_RollbackWriteOk := true
	_MPTU_WriteCalls := 0
	_MPTU_NotifyCalls := 0
	_MPTU_Events := []
	_MPTU_ObservedTyping := ""
	_MPTU_ObservedApps := ""
	_MPTU_LastUpdates := []
	_MPTU_FailOldOff := false
	_MPTU_FailNewOn := false
	_MPTU_OwnedHotkeys := Map()
	_MPTU_ReenterShortcut := false
	_MPTU_ReenterResult := false
	_MPTU_BuildCalls := 0
	_MPTU_LastPath := ""
	_MPTU_ToggleCalls := 0
	_MPTU_ProbeThrows := false
	_MPTU_RetireOldDuringWrite := false
	_MPTU_RetireCandidateDuringWrite := false
	_MPTU_FireCandidateDuringWrite := false
	_MPTU_FireOldDuringWrite := false
	_MPTU_TypingToggleCalls := 0
	_MPTU_AppsToggleCalls := 0
	_MPTU_RecoveryCalls := 0
	HOTKEY_REGISTRAR_BINDINGS := Map()
	HOTKEY_REGISTRAR_SPECS := Map()
	HOTKEY_REGISTRAR_NEXT_TOKEN := 0
	MetricsShortcuts.typing_handle := ""
	MetricsShortcuts.apps_handle := ""
	MetricsShortcuts.typing_status := _MS_StatusForAhk(MetricsShortcuts.typing_ahk)
	MetricsShortcuts.apps_status := _MS_StatusForAhk(MetricsShortcuts.apps_ahk)
	MetricsShortcuts.typing_recovery_handles := []
	MetricsShortcuts.apps_recovery_handles := []
	if (MetricsShortcuts.typing_str != "") {
		MetricsShortcuts.typing_handle := _HotkeyRegistrarBindOwned(
			MetricsShortcuts.typing_str, _MPTU_Toggle, "metrics:typing",
			_MPTU_Hotkey, _MPTU_Probe)
	}
	if (MetricsShortcuts.apps_str != "") {
		MetricsShortcuts.apps_handle := _HotkeyRegistrarBindOwned(
			MetricsShortcuts.apps_str, _MPTU_Toggle, "metrics:apps",
			_MPTU_Hotkey, _MPTU_Probe)
	}
	; Seeding is setup, not part of the transaction trace.
	_MPTU_Events := []
}

_MPTU_Writer(Path, Updates) {
	global _MPTU_WriteOk, _MPTU_WriteCalls, _MPTU_Events, _MPTU_ObservedTyping
	global _MPTU_ObservedApps, _MPTU_LastUpdates, _MPTU_ReenterShortcut
	global _MPTU_ReenterResult, _MPTU_LastPath
	global _MPTU_RetireOldDuringWrite, _MPTU_RetireCandidateDuringWrite
	global _MPTU_FireCandidateDuringWrite, _MPTU_FireOldDuringWrite
	global _MPTU_RollbackWriteOk
	global HOTKEY_REGISTRAR_SPECS
	_MPTU_WriteCalls += 1
	_MPTU_LastPath := Path
	_MPTU_Events.Push("write")
	_MPTU_ObservedTyping := MetricsShortcuts.typing_str
	_MPTU_ObservedApps := MetricsShortcuts.apps_str
	_MPTU_LastUpdates := Updates
	if _MPTU_ReenterShortcut {
		_MPTU_ReenterShortcut := false
		_MPTU_ReenterResult := MS_CommitShortcutCandidate("apps", "ctrl+alt+p",
				_MPTU_Toggle, _MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey,
				_MPTU_Probe)
	}
	if _MPTU_RetireOldDuringWrite {
		_MPTU_RetireOldDuringWrite := false
		_HotkeyRegistrarRetire(MetricsShortcuts.typing_handle, _MPTU_Hotkey)
	}
	if _MPTU_RetireCandidateDuringWrite && HOTKEY_REGISTRAR_SPECS.Has("^!n") {
		_MPTU_RetireCandidateDuringWrite := false
		Candidate := HOTKEY_REGISTRAR_SPECS["^!n"]
		_HotkeyRegistrarRetire(Candidate["handle"], _MPTU_Hotkey)
	}
	if _MPTU_FireOldDuringWrite
		_MPTU_Fire("^!m")
	if _MPTU_FireCandidateDuringWrite
		_MPTU_Fire("^!n")
	return (_MPTU_WriteCalls = 1) ? _MPTU_WriteOk : _MPTU_RollbackWriteOk
}

_MPTU_Notify(Message, Options) {
	global _MPTU_NotifyCalls, _MPTU_Events
	_MPTU_NotifyCalls += 1
	_MPTU_Events.Push("notify")
}

_MPTU_Toggle(*) {
	global _MPTU_ToggleCalls
	_MPTU_ToggleCalls += 1
}

_MPTU_TypingToggle(*) {
	global _MPTU_TypingToggleCalls
	_MPTU_TypingToggleCalls += 1
}

_MPTU_AppsToggle(*) {
	global _MPTU_AppsToggleCalls
	_MPTU_AppsToggleCalls += 1
}

_MPTU_Hotkey(Name, Action := unset, Options := unset) {
	global _MPTU_Events, _MPTU_FailOldOff, _MPTU_FailNewOn
	global _MPTU_OwnedHotkeys
	if !IsSet(Action)
		return _MPTU_OwnedHotkeys.Has(Name)
	if IsSet(Options) {
		_MPTU_Events.Push(Name . " " . Options)
		if (Options != "Off" && Options != "On")
			throw Error("unexpected fake Hotkey registration option")
		; AHK Hotkey registration and action calls are exception-atomic. Every
		; injected failure below therefore occurs before this fake mutates state.
		if (_MPTU_FailNewOn && Options = "On" && Name = "^!n")
			throw Error("injected activation failure before native mutation")
		_MPTU_OwnedHotkeys[Name] := {
			callback: Action,
			enabled: Options = "On"
		}
		return true
	}
	if (Action == "Off") {
		_MPTU_Events.Push(Name . " Off")
		if (_MPTU_FailOldOff && Name = "^!m")
			throw Error("injected previous-binding failure before mutation")
		if _MPTU_OwnedHotkeys.Has(Name)
			_MPTU_OwnedHotkeys[Name].enabled := false
		return true
	}
	if (Action == "On") {
		_MPTU_Events.Push(Name . " On")
		if (_MPTU_FailNewOn && Name = "^!n")
			throw Error("injected activation failure before native mutation")
		if _MPTU_OwnedHotkeys.Has(Name)
			_MPTU_OwnedHotkeys[Name].enabled := true
		return true
	}
	throw Error("unexpected fake Hotkey action")
}

_MPTU_Recovery() {
	global _MPTU_Events, _MPTU_RecoveryCalls
	_MPTU_RecoveryCalls += 1
	_MPTU_Events.Push("recover")
	return true
}

_MPTU_Probe(Name) {
	global _MPTU_OwnedHotkeys, _MPTU_ProbeThrows
	if _MPTU_ProbeThrows
		throw Error("injected probe failure")
	return _MPTU_OwnedHotkeys.Has(Name)
}

_MPTU_Fire(Name) {
	global _MPTU_OwnedHotkeys
	if _MPTU_OwnedHotkeys.Has(Name) && _MPTU_OwnedHotkeys[Name].enabled
			&& _MPTU_OwnedHotkeys[Name].HasOwnProp("callback")
		_MPTU_OwnedHotkeys[Name].callback.Call("fake-hotkey")
}

_MPTU_WithConfigState(Callback) {
	global ConfigurationFile, _SaveFullConfigReady
	HadPath := IsSet(ConfigurationFile)
	if HadPath
		SavedPath := ConfigurationFile
	HadReady := IsSet(_SaveFullConfigReady)
	if HadReady
		SavedReady := _SaveFullConfigReady
	ConfigurationFile := A_Temp . "\ergopti_metrics_transaction.toml"
	_SaveFullConfigReady := true
	try {
		return Callback.Call()
	} finally {
		if HadPath
			ConfigurationFile := SavedPath
		else
			ConfigurationFile := unset
		if HadReady
			_SaveFullConfigReady := SavedReady
		else
			_SaveFullConfigReady := unset
	}
}

_MPTU_AssertEvents(Expected, Message) {
	global _MPTU_Events
	AssertEqual(Expected.Length, _MPTU_Events.Length, Message . " (event count)")
	for Index, Event in Expected
		AssertEqual(Event, _MPTU_Events[Index], Message . " (event " . Index . ")")
}

_MPTU_SaveShortcutState() {
	return {
		typing_str: MetricsShortcuts.typing_str,
		typing_ahk: MetricsShortcuts.typing_ahk,
		apps_str: MetricsShortcuts.apps_str,
		apps_ahk: MetricsShortcuts.apps_ahk,
		typing_handle: MetricsShortcuts.typing_handle,
		apps_handle: MetricsShortcuts.apps_handle,
		typing_status: MetricsShortcuts.typing_status,
		apps_status: MetricsShortcuts.apps_status,
		typing_recovery_handles: MetricsShortcuts.typing_recovery_handles,
		apps_recovery_handles: MetricsShortcuts.apps_recovery_handles
	}
}

_MPTU_RestoreShortcutState(State) {
	MetricsShortcuts.typing_str := State.typing_str
	MetricsShortcuts.typing_ahk := State.typing_ahk
	MetricsShortcuts.apps_str := State.apps_str
	MetricsShortcuts.apps_ahk := State.apps_ahk
	MetricsShortcuts.typing_handle := State.typing_handle
	MetricsShortcuts.apps_handle := State.apps_handle
	MetricsShortcuts.typing_status := State.typing_status
	MetricsShortcuts.apps_status := State.apps_status
	MetricsShortcuts.typing_recovery_handles := State.typing_recovery_handles
	MetricsShortcuts.apps_recovery_handles := State.apps_recovery_handles
}

_MPTU_SiblingShortcutCollisionIsRejectedCore() {
	global _MPTU_WriteCalls, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	MetricsShortcuts.apps_str := "ctrl+alt+n"
	MetricsShortcuts.apps_ahk := "^!n"
	_MPTU_Reset(true)
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey))
		AssertEqual(0, _MPTU_WriteCalls,
			"a chord owned by the sibling metrics action must be rejected before persistence")
		AssertEqual(1, _MPTU_NotifyCalls,
			"a rejected sibling collision must be visible exactly once")
		_MPTU_AssertEvents(["notify"],
			"a sibling collision must not overwrite either native callback")
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_SiblingShortcutCollisionIsRejected() {
	return _MPTU_WithConfigState(_MPTU_SiblingShortcutCollisionIsRejectedCore)
}
Test("metrics transactions: sibling shortcut collision changes nothing",
	_MPTU_SiblingShortcutCollisionIsRejected)

_MPTU_ShortcutWriteFailureRollsBackCore() {
	global _MPTU_ObservedTyping
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(false)
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey))
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str,
			"failed persistence must not publish the candidate string")
		AssertEqual("^!m", MetricsShortcuts.typing_ahk,
			"failed persistence must not publish the candidate native binding")
		AssertEqual("ctrl+alt+m", _MPTU_ObservedTyping,
			"the writer must observe the old live state, not a prematurely published candidate")
		_MPTU_AssertEvents(["^!n Off", "write", "notify"],
			"a failed write must discard an inert reservation without native activation")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ShortcutWriteFailureRollsBack() {
	return _MPTU_WithConfigState(_MPTU_ShortcutWriteFailureRollsBackCore)
}
Test("metrics transactions: shortcut write failure rolls back the native binding",
	_MPTU_ShortcutWriteFailureRollsBack)

_MPTU_ShortcutSuccessPublishesAfterWriterCore() {
	global ConfigurationFile, _MPTU_ObservedTyping, _MPTU_LastPath, _MPTU_LastUpdates
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	try {
		AssertTrue(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey))
		AssertEqual("ctrl+alt+m", _MPTU_ObservedTyping,
			"the durable writer must run before the candidate is published")
		AssertEqual(ConfigurationFile, _MPTU_LastPath,
			"the typing edit must target the configured config.toml path")
		AssertEqual(1, _MPTU_LastUpdates.Length)
		AssertEqual("metrics", _MPTU_LastUpdates[1].Section)
		AssertEqual("metrics_shortcut_typing", _MPTU_LastUpdates[1].Key)
		AssertEqual("ctrl+alt+n", _MPTU_LastUpdates[1].Value)
		AssertEqual("ctrl+alt+n", MetricsShortcuts.typing_str)
		AssertEqual("^!n", MetricsShortcuts.typing_ahk)
		AssertEqual(MetricsShortcuts.STATUS_ACTIVE, MetricsShortcuts.typing_status)
		AssertEqual(0, MetricsShortcuts.typing_recovery_handles.Length)
		_MPTU_AssertEvents(["^!n Off", "write", "^!n On", "^!m Off"],
			"successful shortcut edit must reserve Off, write, activate, then retire")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ShortcutSuccessPublishesAfterWriter() {
	return _MPTU_WithConfigState(_MPTU_ShortcutSuccessPublishesAfterWriterCore)
}
Test("metrics transactions: shortcut success publishes only after the writer",
	_MPTU_ShortcutSuccessPublishesAfterWriter)

_MPTU_ClearFailureRestoresOldBindingCore() {
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(false)
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey))
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
		_MPTU_AssertEvents(["write", "notify"],
			"a failed clear must leave the previous shortcut armed throughout")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ClearFailureRestoresOldBinding() {
	return _MPTU_WithConfigState(_MPTU_ClearFailureRestoresOldBindingCore)
}
Test("metrics transactions: failed shortcut clear restores the old binding",
	_MPTU_ClearFailureRestoresOldBinding)

_MPTU_ReservedCandidateCannotFireInsideWriterCore() {
	global _MPTU_FireCandidateDuringWrite, _MPTU_FireOldDuringWrite
	global _MPTU_ToggleCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	_MPTU_FireCandidateDuringWrite := true
	_MPTU_FireOldDuringWrite := true
	try {
		AssertTrue(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey))
		AssertEqual(1, _MPTU_ToggleCalls,
			"only the old callback may fire while the durable writer is running")
		_MPTU_AssertEvents(["^!n Off", "write", "^!n On", "^!m Off"],
			"the candidate must remain reserved-Off until the writer returns")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ReservedCandidateCannotFireInsideWriter() {
	return _MPTU_WithConfigState(_MPTU_ReservedCandidateCannotFireInsideWriterCore)
}
Test("metrics transactions: reserved candidate cannot fire inside the durable writer",
	_MPTU_ReservedCandidateCannotFireInsideWriter)

_MPTU_StaleCandidateRollbackIsSurfacedCore() {
	global _MPTU_RetireCandidateDuringWrite, _MPTU_NotifyCalls, _MPTU_ToggleCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(false)
	_MPTU_RetireCandidateDuringWrite := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual(1, _MPTU_NotifyCalls,
			"a refused compensation must be reported instead of being returned as success")
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
		AssertEqual(MetricsShortcuts.STATUS_ERROR, MetricsShortcuts.typing_status)
		AssertEqual(1, MetricsShortcuts.typing_recovery_handles.Length,
			"a refused Abort must retain the opaque candidate handle")
		_MPTU_Fire("^!m")
		_MPTU_Fire("^!n")
		AssertEqual(1, _MPTU_ToggleCalls,
			"the old callback alone remains authoritative after the failed write")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_StaleCandidateRollbackIsSurfaced() {
	return _MPTU_WithConfigState(_MPTU_StaleCandidateRollbackIsSurfacedCore)
}
Test("metrics transactions: a stale candidate compensation is surfaced",
	_MPTU_StaleCandidateRollbackIsSurfaced)

_MPTU_InvalidRawNeverReachesAnySideEffectCore() {
	global _MPTU_WriteCalls, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "crtl+alt+m", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual(0, _MPTU_WriteCalls,
				"a malformed non-empty shortcut must stop before config.toml")
		AssertEqual(1, _MPTU_NotifyCalls,
			"a malformed shortcut must be visible exactly once")
		_MPTU_AssertEvents(["notify"],
			"a malformed shortcut must not touch Hotkey")
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_InvalidRawNeverReachesAnySideEffect() {
	return _MPTU_WithConfigState(_MPTU_InvalidRawNeverReachesAnySideEffectCore)
}
Test("metrics transactions: malformed raw shortcut has zero side effects",
	_MPTU_InvalidRawNeverReachesAnySideEffect)

_MPTU_ModifierAliasIsAConfigOnlyEditCore() {
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	try {
		AssertTrue(MS_CommitShortcutCandidate("typing", "alt+ctrl+m", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		_MPTU_AssertEvents(["write"],
				"an AHK-equivalent modifier permutation must not disable its own binding")
		AssertEqual("alt+ctrl+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ModifierAliasIsAConfigOnlyEdit() {
	return _MPTU_WithConfigState(_MPTU_ModifierAliasIsAConfigOnlyEditCore)
}
Test("metrics transactions: modifier aliases never rebind the same AHK chord",
	_MPTU_ModifierAliasIsAConfigOnlyEdit)

_MPTU_ExternalOwnerIsNeverOverwrittenCore() {
	global _MPTU_OwnedHotkeys, _MPTU_WriteCalls, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	_MPTU_OwnedHotkeys["^b"] := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+b", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual(0, _MPTU_WriteCalls,
				"a chord owned by Ctrl+B must be rejected before persistence")
		AssertEqual(1, _MPTU_NotifyCalls,
			"a foreign-owner collision must be visible exactly once")
		_MPTU_AssertEvents(["notify"],
			"collision probing must not mutate the foreign callback")
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ExternalOwnerIsNeverOverwritten() {
	return _MPTU_WithConfigState(_MPTU_ExternalOwnerIsNeverOverwrittenCore)
}
Test("metrics transactions: an existing Ctrl+B owner is never overwritten",
	_MPTU_ExternalOwnerIsNeverOverwritten)

_MPTU_BootReplayPreservesExternalOwnerCore() {
	global _MPTU_OwnedHotkeys
	_MPTU_Reset(true)
	_MPTU_OwnedHotkeys["^b"] := true
	Remaining := MS_BindHotkey.Call("", "", "ctrl+b", _MPTU_Toggle,
		"metrics:typing", _MPTU_Hotkey, _MPTU_Probe)
	AssertFalse(Remaining.ok, "boot replay must leave the colliding metrics slot unbound")
	AssertEqual("", Remaining.handle)
	AssertEqual("", Remaining.ahk)
	_MPTU_AssertEvents([], "boot replay must not replace the existing Ctrl+B callback")
}

_MPTU_BootReplayPreservesExternalOwner() {
	return _MPTU_WithConfigState(_MPTU_BootReplayPreservesExternalOwnerCore)
}
Test("metrics transactions: boot replay preserves an existing hotkey owner",
	_MPTU_BootReplayPreservesExternalOwner)

_MPTU_ActivationFailureRestoresDurableOldValueCore() {
	global _MPTU_FailNewOn, _MPTU_WriteCalls, _MPTU_ToggleCalls
	global _MPTU_LastUpdates
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	_MPTU_FailNewOn := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual(2, _MPTU_WriteCalls,
				"failed post-write activation must reverse the durable value synchronously")
		AssertEqual("ctrl+alt+m", _MPTU_LastUpdates[1].Value,
			"the reverse batch must use the old value captured under the lease")
		_MPTU_AssertEvents(["^!n Off", "write", "^!n On", "write", "notify"],
			"activation failure must Abort the still-Off candidate and rewrite the old value")
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str)
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
		AssertEqual(MetricsShortcuts.STATUS_ACTIVE, MetricsShortcuts.typing_status)
		_MPTU_Fire("^!m")
		_MPTU_Fire("^!n")
		AssertEqual(1, _MPTU_ToggleCalls,
			"exception-before-mutation On failure must leave only the old callback live")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ActivationFailureRestoresDurableOldValue() {
	return _MPTU_WithConfigState(_MPTU_ActivationFailureRestoresDurableOldValueCore)
}
Test("metrics transactions: activation failure restores the old durable value",
	_MPTU_ActivationFailureRestoresDurableOldValue)

_MPTU_RollbackWriteFailureQueuesDurableRecoveryCore() {
	global _MPTU_FailNewOn, _MPTU_RollbackWriteOk, _MPTU_WriteCalls
	global _MPTU_RecoveryCalls, _MPTU_ToggleCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	_MPTU_FailNewOn := true
	_MPTU_RollbackWriteOk := false
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe,
			_MPTU_Recovery))
		AssertEqual(2, _MPTU_WriteCalls)
		AssertEqual(1, _MPTU_RecoveryCalls,
			"a failed reverse write must queue one full-state durable repair")
		AssertEqual(MetricsShortcuts.STATUS_ROLLBACK_PENDING,
			MetricsShortcuts.typing_status)
		AssertEqual("ctrl+alt+m", MetricsShortcuts.typing_str,
			"the old live callback remains authoritative until recovery persists it")
		AssertEqual("^!m", MetricsShortcuts.typing_ahk)
		_MPTU_AssertEvents(["^!n Off", "write", "^!n On", "write",
			"recover", "notify"],
			"rollback failure must retain explicit state before yielding notification")
		_MPTU_Fire("^!m")
		_MPTU_Fire("^!n")
		AssertEqual(1, _MPTU_ToggleCalls)

		_MPTU_FailNewOn := false
		_MPTU_RollbackWriteOk := true
		AssertTrue(MS_RetryShortcutRecovery("typing", _MPTU_Writer,
			_MPTU_Notify, _MPTU_Hotkey),
			"an explicit retry must durably republish the live old authority")
		AssertEqual(MetricsShortcuts.STATUS_ACTIVE, MetricsShortcuts.typing_status)
		AssertEqual(0, MetricsShortcuts.typing_recovery_handles.Length)
		AssertTrue(MS_CommitShortcutCandidate("typing", "ctrl+alt+p", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe),
			"a recovered rollback must not permanently block later edits")
		AssertEqual("ctrl+alt+p", MetricsShortcuts.typing_str)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_RollbackWriteFailureQueuesDurableRecovery() {
	return _MPTU_WithConfigState(_MPTU_RollbackWriteFailureQueuesDurableRecoveryCore)
}
Test("metrics transactions: failed reverse write queues explicit durable recovery",
	_MPTU_RollbackWriteFailureQueuesDurableRecovery)

_MPTU_PostCommitOldOffFailureRetainsBothHandlesCore() {
	global _MPTU_FailOldOff
	global _MPTU_ToggleCalls, _MPTU_WriteCalls, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	OldHandle := MetricsShortcuts.typing_handle
	_MPTU_FailOldOff := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		_MPTU_AssertEvents(["^!n Off", "write", "^!n On", "^!m Off", "notify"],
				"cleanup failure must retain the forward candidate and surface partial failure")
		AssertEqual("ctrl+alt+n", MetricsShortcuts.typing_str)
		AssertEqual("^!n", MetricsShortcuts.typing_ahk)
		AssertTrue(MetricsShortcuts.typing_handle != "")
		AssertEqual(MetricsShortcuts.STATUS_CLEANUP_PENDING,
			MetricsShortcuts.typing_status)
		AssertEqual(1, MetricsShortcuts.typing_recovery_handles.Length,
			"the still-live old handle must remain addressable")
		AssertEqual(OldHandle, MetricsShortcuts.typing_recovery_handles[1],
			"cleanup failure must retain the exact opaque old token")
		AssertEqual(1, InStr(MS_GetDisplayLabel("typing"), Chr(0x26A0)),
			"the tray projection must expose cleanup-pending state")
		WritesBeforeRecoveryEdit := _MPTU_WriteCalls
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+p", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe),
			"a new edit must not overwrite an unresolved old-handle token")
		AssertEqual(WritesBeforeRecoveryEdit, _MPTU_WriteCalls)
		AssertEqual(OldHandle, MetricsShortcuts.typing_recovery_handles[1])
		AssertEqual(2, _MPTU_NotifyCalls,
			"a refused recovery edit must add one visible failure")
		_MPTU_Fire("^!m")
		_MPTU_Fire("^!n")
		AssertEqual(2, _MPTU_ToggleCalls,
			"exception-before-mutation old Off leaves both tracked callbacks live")

		_MPTU_FailOldOff := false
		AssertTrue(MS_RetryShortcutRecovery("typing", _MPTU_Writer,
			_MPTU_Notify, _MPTU_Hotkey),
			"a later recovery pass must retire the retained old handle")
		AssertEqual(MetricsShortcuts.STATUS_ACTIVE, MetricsShortcuts.typing_status)
		AssertEqual(0, MetricsShortcuts.typing_recovery_handles.Length)
		_MPTU_ToggleCalls := 0
		_MPTU_Fire("^!m")
		_MPTU_Fire("^!n")
		AssertEqual(1, _MPTU_ToggleCalls,
			"only the forward authority may fire after recovery")
		AssertTrue(MS_CommitShortcutCandidate("typing", "ctrl+alt+p", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe),
			"cleanup recovery must make later edits reachable again")
		AssertEqual("ctrl+alt+p", MetricsShortcuts.typing_str)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_PostCommitOldOffFailureRetainsBothHandles() {
	return _MPTU_WithConfigState(_MPTU_PostCommitOldOffFailureRetainsBothHandlesCore)
}
Test("metrics transactions: post-commit old-Off failure retains both live handles",
	_MPTU_PostCommitOldOffFailureRetainsBothHandles)

_MPTU_StaleOldHandleAfterDurabilityIsSurfacedCore() {
	global _MPTU_RetireOldDuringWrite, _MPTU_NotifyCalls, _MPTU_ToggleCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	_MPTU_RetireOldDuringWrite := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe),
			"a stale previous token is a reported partial failure")
		AssertEqual(1, _MPTU_NotifyCalls)
		AssertEqual("ctrl+alt+n", MetricsShortcuts.typing_str,
			"the durable candidate remains authoritative despite stale old bookkeeping")
		AssertEqual("^!n", MetricsShortcuts.typing_ahk)
		AssertTrue(MetricsShortcuts.typing_handle != "")
		AssertEqual(MetricsShortcuts.STATUS_CLEANUP_PENDING,
			MetricsShortcuts.typing_status)
		AssertEqual(1, MetricsShortcuts.typing_recovery_handles.Length,
			"even a stale recovery token must remain explicit instead of being lost")
		_MPTU_AssertEvents(["^!n Off", "write", "^!m Off", "^!n On", "notify"],
			"stale cleanup must publish the forward authority and surface recovery")
		_MPTU_Fire("^!m")
		_MPTU_Fire("^!n")
		AssertEqual(1, _MPTU_ToggleCalls,
			"only the durable candidate may fire after partial finalization")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_StaleOldHandleAfterDurabilityIsSurfaced() {
	return _MPTU_WithConfigState(_MPTU_StaleOldHandleAfterDurabilityIsSurfacedCore)
}
Test("metrics transactions: stale old-handle finalization is not silently green",
	_MPTU_StaleOldHandleAfterDurabilityIsSurfaced)

_MPTU_ReentrantEditIsRefusedCore() {
	global _MPTU_ReenterShortcut, _MPTU_ReenterResult, _MPTU_WriteCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	MetricsShortcuts.apps_str := "ctrl+alt+t"
	MetricsShortcuts.apps_ahk := "^!t"
	_MPTU_Reset(true)
	_MPTU_ReenterShortcut := true
	try {
		AssertTrue(MS_CommitShortcutCandidate("typing", "ctrl+alt+n", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertFalse(_MPTU_ReenterResult,
				"a second slot edit re-entering from the writer must be refused")
		AssertEqual(1, _MPTU_WriteCalls,
				"the nested edit must not issue a second config write")
		_MPTU_AssertEvents(["^!n Off", "write", "notify", "^!n On", "^!m Off"],
				"the nested edit must not arm an orphan candidate")
		AssertEqual("ctrl+alt+n", MetricsShortcuts.typing_str)
		AssertEqual("ctrl+alt+t", MetricsShortcuts.apps_str)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ReentrantEditIsRefused() {
	return _MPTU_WithConfigState(_MPTU_ReentrantEditIsRefusedCore)
}
Test("metrics transactions: reentrant cross-slot edit is refused without side effects",
	_MPTU_ReentrantEditIsRefused)

_MPTU_AppsSlotPublishesExactPayloadCore() {
	global ConfigurationFile, _MPTU_LastUpdates, _MPTU_ObservedApps, _MPTU_LastPath
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.apps_str := "ctrl+alt+t"
	MetricsShortcuts.apps_ahk := "^!t"
	_MPTU_Reset(true)
	try {
		AssertTrue(MS_CommitShortcutCandidate("apps", "ctrl+shift+f9", _MPTU_Toggle,
				_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual("ctrl+alt+t", _MPTU_ObservedApps,
			"the apps writer must observe the old live value")
		AssertEqual(ConfigurationFile, _MPTU_LastPath,
			"the apps edit must target the configured config.toml path")
		AssertEqual(1, _MPTU_LastUpdates.Length)
		AssertEqual("metrics", _MPTU_LastUpdates[1].Section)
		AssertEqual("metrics_shortcut_apps", _MPTU_LastUpdates[1].Key)
		AssertEqual("ctrl+shift+f9", _MPTU_LastUpdates[1].Value)
		AssertEqual("ctrl+shift+f9", MetricsShortcuts.apps_str)
		AssertEqual("^+f9", MetricsShortcuts.apps_ahk)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_AppsSlotPublishesExactPayload() {
	return _MPTU_WithConfigState(_MPTU_AppsSlotPublishesExactPayloadCore)
}
Test("metrics transactions: apps slot writes and publishes the exact candidate",
	_MPTU_AppsSlotPublishesExactPayload)

_MPTU_AppsToTypingCollisionIsRejectedCore() {
	global _MPTU_WriteCalls, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	MetricsShortcuts.apps_str := "ctrl+alt+n"
	MetricsShortcuts.apps_ahk := "^!n"
	_MPTU_Reset(true)
	try {
		AssertFalse(MS_CommitShortcutCandidate("apps", "alt+ctrl+m", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual(0, _MPTU_WriteCalls)
		AssertEqual(1, _MPTU_NotifyCalls)
		_MPTU_AssertEvents(["notify"],
			"apps-to-typing collision must stop before native mutation")
		AssertEqual("ctrl+alt+n", MetricsShortcuts.apps_str)
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_AppsToTypingCollisionIsRejected() {
	return _MPTU_WithConfigState(_MPTU_AppsToTypingCollisionIsRejectedCore)
}
Test("metrics transactions: sibling collision is rejected in the apps-to-typing direction",
	_MPTU_AppsToTypingCollisionIsRejected)

_MPTU_ProbeExceptionFailsClosedCore() {
	global _MPTU_ProbeThrows, _MPTU_WriteCalls, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	_MPTU_ProbeThrows := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "ctrl+b", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		AssertEqual(0, _MPTU_WriteCalls,
			"an indeterminate native owner must stop before persistence")
		AssertEqual(1, _MPTU_NotifyCalls,
			"an indeterminate native owner must be visible exactly once")
		_MPTU_AssertEvents(["notify"],
			"a throwing probe must never install a callback")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ProbeExceptionFailsClosed() {
	return _MPTU_WithConfigState(_MPTU_ProbeExceptionFailsClosedCore)
}
Test("metrics transactions: a throwing collision probe fails closed",
	_MPTU_ProbeExceptionFailsClosed)

_MPTU_ClearOldOffFailureRetainsRecoveryCore() {
	global _MPTU_FailOldOff, _MPTU_ToggleCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+m"
	MetricsShortcuts.typing_ahk := "^!m"
	_MPTU_Reset(true)
	OldHandle := MetricsShortcuts.typing_handle
	_MPTU_FailOldOff := true
	try {
		AssertFalse(MS_CommitShortcutCandidate("typing", "", _MPTU_Toggle,
			_MPTU_Writer, _MPTU_Notify, _MPTU_Hotkey, _MPTU_Probe))
		_MPTU_AssertEvents(["write", "^!m Off", "notify"],
			"a refused old Off must be surfaced after the clear is published")
		AssertEqual("", MetricsShortcuts.typing_str)
		AssertEqual("", MetricsShortcuts.typing_ahk)
		AssertEqual("", MetricsShortcuts.typing_handle)
		AssertEqual(MetricsShortcuts.STATUS_CLEANUP_PENDING,
			MetricsShortcuts.typing_status)
		AssertEqual(1, MetricsShortcuts.typing_recovery_handles.Length,
			"clear must not discard the still-live old handle")
		AssertEqual(OldHandle, MetricsShortcuts.typing_recovery_handles[1])
		_MPTU_Fire("^!m")
		AssertEqual(1, _MPTU_ToggleCalls,
			"exception-before-mutation old Off remains live and explicitly tracked")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}

_MPTU_ClearOldOffFailureRetainsRecovery() {
	return _MPTU_WithConfigState(_MPTU_ClearOldOffFailureRetainsRecoveryCore)
}
Test("metrics transactions: clear old-Off failure retains the still-live handle",
	_MPTU_ClearOldOffFailureRetainsRecovery)

_MPTU_BootActivationFailureContinuesSibling() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN, _MPTU_OwnedHotkeys
	global _MPTU_FailNewOn, _MPTU_TypingToggleCalls, _MPTU_AppsToggleCalls
	global _MPTU_Events, _MPTU_NotifyCalls
	Saved := _MPTU_SaveShortcutState()
	MetricsShortcuts.typing_str := "ctrl+alt+n"
	MetricsShortcuts.typing_ahk := ""
	MetricsShortcuts.apps_str := "ctrl+alt+t"
	MetricsShortcuts.apps_ahk := ""
	_MPTU_Reset(true)
	; Reset the setup bindings so MS_ApplyAll performs the actual boot replay.
	HOTKEY_REGISTRAR_BINDINGS := Map()
	HOTKEY_REGISTRAR_SPECS := Map()
	HOTKEY_REGISTRAR_NEXT_TOKEN := 0
	_MPTU_OwnedHotkeys := Map()
	MetricsShortcuts.typing_handle := ""
	MetricsShortcuts.apps_handle := ""
	_MPTU_Events := []
	_MPTU_FailNewOn := true
	try {
		AssertFalse(MS_ApplyAll.Call(_MPTU_TypingToggle, _MPTU_AppsToggle,
			_MPTU_Hotkey, _MPTU_Probe, _MPTU_Notify),
			"aggregate boot status must report one refused slot")
		AssertEqual("", MetricsShortcuts.typing_handle)
		AssertTrue(MetricsShortcuts.apps_handle != "",
			"typing failure must not suppress apps registration")
		AssertEqual(1, _MPTU_NotifyCalls,
			"incomplete boot activation must emit exactly one non-modal notice")
		_MPTU_AssertEvents(["^!n Off", "^!n On", "^!t Off", "^!t On", "notify"],
			"boot must continue the sibling before surfacing one aggregate failure")
		_MPTU_Fire("^!n")
		_MPTU_Fire("^!t")
		AssertEqual(0, _MPTU_TypingToggleCalls,
			"the callback installed before the injected On throw must be inert")
		AssertEqual(1, _MPTU_AppsToggleCalls,
			"the sibling slot must retain its distinct callback identity")
	} finally {
		_MPTU_RestoreShortcutState(Saved)
	}
}
Test("metrics transactions: boot activation failure continues sibling and notifies once",
	_MPTU_BootActivationFailureContinuesSibling)
