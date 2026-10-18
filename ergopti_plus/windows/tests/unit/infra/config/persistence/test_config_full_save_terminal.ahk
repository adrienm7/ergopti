; tests/unit/infra/config/persistence/test_config_full_save_terminal.ahk

; ==============================================================================
; MODULE: Config Full Save Terminal Generations
; DESCRIPTION:
; Boot-only and boot-read generations cannot brick a restart or abandon a
; repair, rejected generations are never retried, Reload restores them, the
; terminal seal refuses new ones, and collection never runs under inherited
; Critical or mutates live features.
; ==============================================================================

#Requires AutoHotkey v2.0





_CFGFS_BootOnlyGenerationCannotBrickRestart() {
	global _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_boot_terminal.toml"
	; Production queues this optional canonicalization only after a successful
	; boot read. Its optional provenance, not an unreachable boot-failed flag,
	; is what permits terminal abandonment.
	_CFGFS_Prepare(Path, true, false)
	Bundle := false
	try {
		AssertEqual(1, _ConfigFullSaveRequest(false))
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_WriterCalls,
			"terminal-optional boot canonicalization may die with the process")
		AssertFalse(_ConfigFullSaveHasPending())
		State := _ConfigFullSaveCoordinator()
		AssertEqual(0, State.committed_generation,
			"abandonment must not masquerade as durable commit")
		AssertEqual(1, State.settled_generation)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: boot-only generation cannot brick restart "
	. "(config-full-save-terminal-boot-abandon)",
	_CFGFS_BootOnlyGenerationCannotBrickRestart)

_CFGFS_BootReadFailureCannotAbandonRequiredRepair() {
	global _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_boot_required.toml"
	_CFGFS_Prepare(Path, true, true)
	Bundle := false
	try {
		AssertEqual(1, _ConfigFullSaveRequest(true))
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertFalse(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect),
			"an unsafe serializer must refuse exit rather than erase a user repair")
		AssertEqual(0, _CFGFS_WriterCalls,
			"boot-read failure must still prevent serialization of default-derived RAM")
		AssertTrue(_ConfigFullSaveHasPending(),
			"the mandatory repair must remain owned by the surviving process")
		State := _ConfigFullSaveCoordinator()
		AssertEqual(0, State.committed_generation)
		AssertEqual(0, State.settled_generation,
			"refusal must not masquerade as either commit or optional abandonment")
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: boot-read failure cannot abandon a required repair "
	. "(config-full-save-terminal-required-boot-read)",
	_CFGFS_BootReadFailureCannotAbandonRequiredRepair)

_CFGFS_RejectedExactGenerationIsNeverRetried() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls
	global CONFIG_SAVE_FAILED, CONFIG_SAVE_RESOLVE_RELOAD
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_exact_reject.toml"
	_CFGFS_Prepare(Path)
	Bundle := false
	try {
		_CFGFS_WriterResult := false
		Generation := 0
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertEqual(CONFIG_SAVE_RESOLVE_RELOAD,
			_ConfigFullSaveResolveFailure(Generation, _CFGFS_Timer))
		_CFGFS_WriterResult := true
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls,
			"a disk-authoritative rejected generation must never resurrect at exit")
		AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: rejected exact generation is never terminally retried "
	. "(config-full-save-exact-reject)",
	_CFGFS_RejectedExactGenerationIsNeverRetried)

; Models the later OnExit(Reload) that claims the launched reload and then
; meets a refusal gate: the hand-off must give control back to the live driver.
_CFGFS_ClaimReloadWithoutFinishing() {
	Claimed := ReloadTerminalHandoffClaim("Reload")
	AssertTrue(Claimed is Map,
		"the simulated OnExit path must claim the exact Reload authorization")
	AssertTrue(ReloadTerminalHandoffRefuseForShutdown("Reload", "test gate"),
		"a vetoed close request must refuse the launched reload")
}

_CFGFS_ReturnedReloadRestoresRejectedGeneration() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls, _CFGFS_TimerCalls
	global _CFGFS_CollectValue, _CFGFS_SeenUpdates
	global CONFIG_SAVE_FAILED, CONFIG_SAVE_OK, CONFIG_SAVE_RESOLVE_RELOAD
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_returned_reload.toml"
	_CFGFS_Prepare(Path)
	Bundle := false
	try {
		_CFGFS_WriterResult := false
		Generation := 0
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(CONFIG_SAVE_RESOLVE_RELOAD,
			_ConfigFullSaveResolveFailure(Generation, _CFGFS_Timer))
		AssertTrue(_ConfigFullSaveCoordinator().reload_required)
		AssertFalse(_ConfigFullSaveHasPending(),
			"the exact rejection is settled only while Reload can still finish")

		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		Port := _RTP_NewPort()
		Record := _RTP_Pending(Bundle, Port)
		_CFGFS_ClaimReloadWithoutFinishing()
		AssertFalse(ReloadTerminalHandoffPending(),
			"an OnExit refusal must return control to the live driver")
		; Pending(false) excludes a withdrawing record; it does not acknowledge exit.
		loop 2 {
			AssertTrue(_ReloadTerminalHandoffOwns(Record), "The exact withdrawing record remains published before terminal.")
			AssertEqual(Bundle, Record["bundle"])
			AssertTrue(_ConfigWriteTerminalIsActive() && Bundle.authorized && Bundle.shutdown_claimed,
				"The generation fixture retains the exact claimed bundle while its successor lives.")
			AssertFalse(Record["stop_acknowledged"])
			AssertEqual(0, Port["probe"]["closed"])
			AssertEqual(1, Port["probe"]["terminated"], "The native stop request is issued only once.")
			_RTP_RunArmed(Port)
		}
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		_RTP_RunArmed(Port)
		AssertTrue(Record["stop_acknowledged"] && Record["close_acknowledged"])
		AssertEqual("refused", Record["state"])
		AssertFalse(_ReloadTerminalHandoffOwns(Record), "Full handback precedes the original bundle release and generation restoration.")
		AssertFalse(Bundle.authorized || Bundle.shutdown_claimed)
		AssertEqual(1, Port["probe"]["closed"])
		_ConfigWriteTerminalRelease(Bundle)
		Bundle := false

		AssertTrue(_ConfigFullSaveResumeRejected(Generation, _CFGFS_Timer),
			"a returned Reload must withdraw only its exact disk-authority decision")
		State := _ConfigFullSaveCoordinator()
		AssertFalse(State.reload_required,
			"the surviving driver must accept later save generations")
		AssertTrue(_ConfigFullSaveHasPending(),
			"the still-visible live candidate must again be a terminal obligation")
		AssertEqual(2, _CFGFS_TimerCalls,
			"restoring the obligation must arm a fresh wake-up after rejection canceled the old one")

		_CFGFS_WriterResult := true
		_CFGFS_CollectValue := "still-visible-candidate"
		AssertEqual(CONFIG_SAVE_OK, _SaveFullConfigDeferred(_CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Notify, _CFGFS_Collect))
		AssertEqual("still-visible-candidate", _CFGFS_SeenUpdates[1].Value,
			"the restored obligation must persist the candidate still shown in RAM")
		AssertFalse(_ConfigFullSaveHasPending())

		_CFGFS_CollectValue := "later-action"
		NextGeneration := 0
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &NextGeneration))
		AssertEqual(Generation + 1, NextGeneration,
			"the refusal must not permanently seal later user actions")
		AssertEqual("later-action", _CFGFS_SeenUpdates[1].Value)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Bundle is Object)
			_RTP_Cleanup(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: returned Reload restores exact rejected generation "
	. "(config-full-save-returned-reload)",
	_CFGFS_ReturnedReloadRestoresRejectedGeneration)

_CFGFS_CoalescedFailurePreservesOlderAcceptance() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls, _CFGFS_CollectValue
	global CONFIG_SAVE_DEFERRED, CONFIG_SAVE_FAILED
	global CONFIG_SAVE_RESOLVE_DEFERRED
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_coalesced_failure.toml"
	_CFGFS_Prepare(Path)
	Owner := _ConfigWriteLeaseTryAcquire(Path, "older-accepted")
	Bundle := false
	try {
		FirstGeneration := 0
		AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &FirstGeneration))
		AssertEqual(1, FirstGeneration)
		_ConfigWriteLeaseRelease(Owner)
		Owner := 0
		_CFGFS_WriterResult := false
		SecondGeneration := 0
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &SecondGeneration))
		AssertEqual(2, SecondGeneration)
		AssertEqual(CONFIG_SAVE_RESOLVE_DEFERRED,
			_ConfigFullSaveResolveFailure(SecondGeneration, _CFGFS_Timer),
			"the newer failure cannot select disk authority over an older promise")
		_CFGFS_WriterResult := true
		_CFGFS_CollectValue := "coalesced-latest"
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(2, _CFGFS_WriterCalls)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Owner is Object)
			_ConfigWriteLeaseRelease(Owner)
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: coalesced failure preserves older acceptance "
	. "(config-full-save-coalesced-failure)",
	_CFGFS_CoalescedFailurePreservesOlderAcceptance)

_CFGFS_TerminalSealRefusesNewGeneration() {
	global _CFGFS_CollectCalls, _CFGFS_WriterCalls, _CFGFS_TimerCalls
	global CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_terminal_seal.toml"
	_CFGFS_Prepare(Path)
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	try {
		AssertTrue(Bundle is Object)
		Generation := -1
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(0, Generation)
		AssertEqual(0, _CFGFS_CollectCalls)
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertEqual(0, _CFGFS_TimerCalls)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: terminal seal refuses new accepted generations "
	. "(config-full-save-terminal-seal)",
	_CFGFS_TerminalSealRefusesNewGeneration)

_CFGFS_BootReadFailureNeverAcknowledges() {
	global _CFGFS_WriterCalls
	global CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_boot_read.toml", true, true)
		_ConfigFullSaveRequest()
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(
			_CFGFS_Writer, _CFGFS_Timer, 0, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending(),
			"an unread boot snapshot must remain unacknowledged")
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: boot-read refusal retains its generation (config-full-save-generation)",
	_CFGFS_BootReadFailureNeverAcknowledges)

_CFGFS_InheritedCriticalNeverWrapsSaveWork() {
	global _CFGFS_WriterResult
	global _CFGFS_TimerCritical, _CFGFS_WriterCritical
	global _CFGFS_CollectCritical, _CFGFS_NotifyCritical
	global CONFIG_SAVE_OK, CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_critical_success.toml")
		PreviousCritical := Critical("On")
		try {
			AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(_CFGFS_Writer,
				_CFGFS_Timer, true, 0, _CFGFS_Collect))
			AssertTrue(A_IsCritical,
				"SaveFullConfig must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _CFGFS_CollectCritical,
			"full-save collection may traverse large live maps and must be interruptible")
		AssertEqual(0, _CFGFS_WriterCritical,
			"durable full-config I/O must never inherit caller Critical")

		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_critical_failure.toml")
		_ConfigFullSaveRequest()
		_CFGFS_WriterResult := false
		PreviousCritical := Critical("On")
		try {
			AssertEqual(CONFIG_SAVE_FAILED, _SaveFullConfigDeferred(
				_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Notify, _CFGFS_Collect))
			AssertTrue(A_IsCritical,
				"the deferred boundary must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _CFGFS_CollectCritical)
		AssertEqual(0, _CFGFS_WriterCritical)
		AssertEqual(0, _CFGFS_TimerCritical,
			"SetTimer registration must remain interruptible")
		AssertEqual(0, _CFGFS_NotifyCritical,
			"failure feedback must remain interruptible")
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: inherited Critical cannot wrap collection IO timers or feedback "
	. "(config-full-save-inherited-critical)",
	_CFGFS_InheritedCriticalNeverWrapsSaveWork)

_CFGFS_LlmCollectionDoesNotMutateLiveFeatures() {
	global Features, _LLM_Menu, _LLM_Menu_Loaded
	SavedFeatures := Features
	SavedEnabled := Features["llm"]["enabled"]
	SavedMenu := _LLM_Menu
	HadLoaded := IsSet(_LLM_Menu_Loaded)
	if HadLoaded
		SavedLoaded := _LLM_Menu_Loaded
	try {
		Features := ManifestBuildFeaturesMap()
		Features["llm"]["enabled"] := SavedEnabled
		_LLM_Menu := _HSDeepCloneMap(SavedMenu)
		_LLM_Menu_Loaded := true
		_LLM_Menu["enabled"] := !SavedEnabled
		_LLM_Menu["onboarding_seen"] := false
		_LLM_Menu["app_profile_overrides"] := Map()
		; A filtered run must not depend on profiles seeded by an earlier test.
		_LLM_Menu["user_profiles"] := []
		Updates := _ConfigCollectFullSaveUpdates()
		AssertTrue(Updates is Array and Updates.Length > 0)
		AssertEqual(SavedEnabled, Features["llm"]["enabled"],
			"speculative LLM reconciliation must target only the detached snapshot")
	} finally {
		Features := SavedFeatures
		_LLM_Menu := SavedMenu
		if HadLoaded
			_LLM_Menu_Loaded := SavedLoaded
		else
			_LLM_Menu_Loaded := unset
	}
}

Test("config full save: detached LLM collection leaves live Features unchanged (config-full-save-generation)",
	_CFGFS_LlmCollectionDoesNotMutateLiveFeatures)

_CFGFS_LlmAppendRefusalAbortsWholeCollection() {
	global Features, _LLM_Menu
	CandidateFeatures := _HSDeepCloneMap(Features)
	CandidateMenu := _HSDeepCloneMap(_LLM_Menu)
	CandidateMenu["onboarding_seen"] := false
	CandidateMenu["app_profile_overrides"] := Map()
	CandidateMenu["user_profiles"] := Map("wrong", "container")
	Thrown := false
	Failure := ""
	try _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
	catch as Err {
		Thrown := true
		Failure := Err.Message . " @ " . Err.File . ":" . Err.Line . " " . Err.Stack
	}
	AssertTrue(Thrown,
		"a refused LLM serialization must abort the full-save candidate, not persist a partial image")
	AssertContains(Failure, "LLM menu persistence fields",
		"the collector must consume the append helper's explicit refusal")
}
Test("config full save: LLM append refusal aborts the whole candidate "
	. "(llm-persisted-option-type-boundary-collector-atomic)",
	_CFGFS_LlmAppendRefusalAbortsWholeCollection)
