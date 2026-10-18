; tests/unit/infra/config/persistence/test_config_full_save_startup_intent.ahk

; ==============================================================================
; MODULE: Config Full Save Startup and Direct Intent
; DESCRIPTION:
; The startup acknowledgment drains a pending boot generation exactly once,
; and a direct explicit intent survives a boot refusal or a missing selected
; path without native writes.
; ==============================================================================

#Requires AutoHotkey v2.0





_CFGFS_StartupObserverDrain() {
	return _ConfigDrainFullSave(_CFGFS_Writer, _CFGFS_Timer, 0, _CFGFS_Collect)
}

_CFGFS_StartupObserver(Kind) {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls, _CFGFS_CollectCalls
	Runtime := _CFGFS_CaptureRuntime(), SavedCoordinator := _ConfigFullSaveCoordinator()
	Path := A_Temp . "\ergopti_startup_save_observer_" . A_ScriptHwnd . ".toml"
	Bundle := false
	_CFGFS_Prepare(Path)
	try {
		AssertEqual(1, _ConfigFullSaveRequest(false))
		if Kind == "writer-refused"
			_CFGFS_WriterResult := false
		if Kind == "optional-abandoned" {
			Bundle := _ConfigWriteTerminalTryAcquire([Path])
			Assert(Bundle is Object)
			AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer, _CFGFS_Timer, _CFGFS_Collect))
			_ConfigWriteTerminalRelease(Bundle)
			Bundle := false
			AssertFalse(_ConfigFullSaveHasPending())
		}
		if Kind == "complete" {
			AssertTrue(_StartupSmokeRequireFullSaveAcknowledged(_CFGFS_StartupObserverDrain))
			AssertEqual(1, _CFGFS_WriterCalls)
			AssertEqual(1, _CFGFS_CollectCalls)
			AssertFalse(_ConfigFullSaveHasPending())
		} else {
			Refusal := false
			try _StartupSmokeRequireFullSaveAcknowledged(_CFGFS_StartupObserverDrain)
			catch as Err {
				Expected := Kind == "writer-refused"
					? "The startup smoke full-save drain did not acknowledge its existing generation."
					: "The startup smoke boot full-save generation is not committed."
				if Type(Err) != "Error" || !(Err.Message == Expected)
					throw Err
				Refusal := true
			}
			AssertTrue(Refusal, "startup readiness must refuse without an actual committed generation")
			AssertEqual(Kind == "writer-refused" ? 1 : 0, _CFGFS_WriterCalls, "no rejected writer is retried")
		}
		State := _ConfigFullSaveCoordinator()
		AssertEqual(1, State.requested_generation, "the observer must not create another request")
		AssertEqual(Kind == "complete" ? 1 : 0, State.committed_generation)
		AssertEqual(Kind == "writer-refused" ? 0 : 1, State.settled_generation)
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
		_ConfigFullSaveCoordinator(SavedCoordinator)
	}
}

Test("startup full-save acknowledgment: pending boot generation drains exactly once", _CFGFS_StartupObserver.Bind("complete"))
Test("startup full-save acknowledgment: actual writer refusal cannot publish ready", _CFGFS_StartupObserver.Bind("writer-refused"))
Test("startup full-save acknowledgment: dropped optional boot generation cannot publish ready", _CFGFS_StartupObserver.Bind("optional-abandoned"))

; Exercise the public producer rather than pre-registering its obligation.
; Keep genuine native leases live, and use the ordinary native writer on repair.
_CFGFS_DirectIntentBeforeBootRefusal(Explicit) {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	global _ParseTomlCache, _TomlReadFailures, _TomlUnreadableFiles
	global CONFIG_SAVE_FAILED, CONFIG_SAVE_OK
	Runtime := _CFGFS_CaptureRuntime(), SavedCoordinator := _ConfigFullSaveCoordinator()
	HadRejected := IsSet(_ConfigBootRejectedOverrides)
	SavedRejected := HadRejected ? _ConfigBootRejectedOverrides : 0
	HadOutdated := IsSet(_ConfigBootOutdatedEntries)
	SavedOutdated := HadOutdated ? _ConfigBootOutdatedEntries : 0
	SavedParse := _ParseTomlCache, SavedFailures := _TomlReadFailures
	SavedUnreadable := _TomlUnreadableFiles
	NativeState := _ConfigWriteLeaseState(), NativeOwners := NativeState.owners
	AssertEqual(0, NativeOwners.Count, "the fixture never replaces a live native lease")
	AssertFalse(NativeState.terminal is Object, "the fixture never resets an issued terminal owner")
	Folder := A_Temp . "\ergopti_direct_intent_" . A_ScriptHwnd . "_" . A_TickCount
	AssertTrue(DllCall("CreateDirectoryW", "Str", Folder, "Ptr", 0, "Int"),
		"the fixture exclusively owns its physical source directory")
	Path := Folder . "\config.toml", Bundle := false, Collected := 0, TimerCalls := 0
	Refusals := _TOML_WriteRefusals(), RefusalKey := _TOML_WriteRefusalKey(Path)
	Collect() {
		Collected += 1
		return [{ Section: "full_save_test", Key: "value", Value: "after" }]
	}
	Timer(Callback, Delay) {
		TimerCalls += 1
		return true
	}
	try {
		AssertFalse(Refusals.Has(RefusalKey), "the unique fixture cannot borrow a prior read-only entry")
		Registry := ConfigMigrateShippedRegistry()
		Source := "[_meta]`nschema_version = " . Registry["current"]
			. "`n[full_save_test]`n" . 'value = "before"' . "`n"
		Expected := Chr(0xFEFF) . "[_meta]`nschema_version = " . Registry["current"]
			. "`n[full_save_test]`n" . 'value = "after"' . "`n"
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		AssertEqual(Source, FSReadUtf8Exact(Path))
		ConfigurationFile := Path, _DriverReady := true, _ConfigBootReadFailed := true
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		_ParseTomlCache := Map(), _TomlReadFailures := Map(), _TomlUnreadableFiles := Map()
		_ConfigFullSaveCoordinator({ requested_generation: 0, committed_generation: 0,
			settled_generation: 0, terminal_required_generation: 0, bound_path: "",
			bound_path_key: "", reload_required: false, timer_armed: false,
			reported_failure_generation: 0 })
		Generation := -99
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(0, Timer, Explicit, 0, Collect, &Generation))
		AssertEqual(Explicit ? 1 : 0, Generation, "only an explicit request owns a generation")
		State := _ConfigFullSaveCoordinator()
		AssertEqual(Explicit ? 1 : 0, State.requested_generation)
		AssertEqual(Explicit ? 1 : 0, State.terminal_required_generation)
		AssertEqual(0, State.committed_generation)
		AssertEqual(0, State.settled_generation)
		AssertEqual(0, Collected, "boot-read refusal precedes the native writer's collector")
		AssertEqual(0, TimerCalls, "refusal does not schedule a speculative retry")
		AssertEqual(Source, FSReadUtf8Exact(Path), "refusal preserves the complete physical source")
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object, "the real constructor supplies terminal ownership")
		AssertEqual(!Explicit, _ConfigFullSaveSettleTerminal(Bundle, 0, Timer, Collect),
			"a refused explicit obligation survives; an implicit drain creates none")
		SealedGeneration := -99
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(0, Timer, true, 0, Collect, &SealedGeneration))
		AssertEqual(0, SealedGeneration, "a live terminal bundle refuses fresh intent")
		AssertEqual(Explicit ? 1 : 0, State.requested_generation, "sealed admission adds no generation")
		AssertEqual(0, Collected)
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		Bundle := false
		if Explicit {
			Boot := ConfigMigrateBoot(Path)
			AssertEqual("current", Boot["status"], "actual typed source Boot performs the repair handoff")
			AssertEqual(0, Boot["read_only"])
			_ConfigBootReadFailed := false
			AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, Timer, 0, Collect))
			AssertEqual(1, Collected, "repair drains the original obligation exactly once")
			AssertEqual(1, State.requested_generation, "repair never invents another request")
			AssertEqual(1, State.committed_generation)
			AssertEqual(1, State.settled_generation)
			AssertEqual(Expected, FSReadUtf8Exact(Path), "the ordinary native writer publishes the handwritten source")
			AssertFalse(_ConfigFullSaveHasPending())
		} else {
			AssertEqual(1, _ConfigFullSaveRequest(false), "optional boot intent keeps its separate contract")
			Bundle := _ConfigWriteTerminalTryAcquire([Path])
			AssertTrue(Bundle is Object)
			AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, 0, Timer, Collect))
			AssertEqual(0, State.committed_generation, "optional abandonment claims no native commit")
			AssertEqual(1, State.settled_generation)
			AssertEqual(0, Collected)
			AssertEqual(Source, FSReadUtf8Exact(Path))
		}
	} finally {
		try {
			if Bundle is Object
				AssertTrue(_ConfigWriteTerminalRelease(Bundle), "the exact native bundle must be released")
		} finally {
			_CFGFS_RestoreRuntime(Runtime)
			_ConfigFullSaveCoordinator(SavedCoordinator)
			if HadRejected
				_ConfigBootRejectedOverrides := SavedRejected
			else
				_ConfigBootRejectedOverrides := unset
			if HadOutdated
				_ConfigBootOutdatedEntries := SavedOutdated
			else
				_ConfigBootOutdatedEntries := unset
			_ParseTomlCache := SavedParse, _TomlReadFailures := SavedFailures
			_TomlUnreadableFiles := SavedUnreadable
			try {
				AssertTrue(_ConfigWriteLeaseState() == NativeState)
				AssertTrue(NativeState.owners == NativeOwners)
				AssertEqual(0, NativeOwners.Count, "native owner admission is restored without resetting issuer IDs")
				AssertFalse(NativeState.terminal is Object)
			} finally {
				DirDelete(Folder, true)
				; Only the deleted, exclusively owned fixture path is retired.
				if Refusals.Has(RefusalKey)
					Refusals.Delete(RefusalKey)
			}
		}
	}
}

Test("config full save: direct explicit intent survives boot refusal without native writes",
	() => _CPL_WithIsolatedLogger(() => _CFGFS_DirectIntentBeforeBootRefusal(true)))
Test("config full save: implicit drain and optional boot create no mandatory refused intent",
	() => _CPL_WithIsolatedLogger(() => _CFGFS_DirectIntentBeforeBootRefusal(false)))

; An unresolved destination is not accepted intent, even before boot refusal.
_CFGFS_DirectIntentWithoutSelectedPath(UnsetPath) {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed, CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	BeforeProperties := Map(), FixtureCoordinator := {}
	for Name in ObjOwnProps(Coordinator) {
		BeforeProperties[Name] := Object.Prototype.GetOwnPropDesc.Call(Coordinator, Name).Value
		FixtureCoordinator.%Name% := BeforeProperties[Name]
	}
	NativeState := _ConfigWriteLeaseState(), NativeOwners := NativeState.owners
	BeforeOwnerCount := NativeOwners.Count, BeforeTerminal := NativeState.terminal
	BeforeIssuerId := NativeState.next_id, Collected := 0, TimerCalls := 0
	Collect() {
		Collected += 1
		throw Error("an unresolved path must never enter the collector")
	}
	Timer(Callback, Delay) {
		TimerCalls += 1
		throw Error("an unresolved path must never schedule persistence")
	}
	try {
		_ConfigFullSaveCoordinator(FixtureCoordinator)
		if UnsetPath
			ConfigurationFile := unset
		else
			ConfigurationFile := ""
		_DriverReady := true, _ConfigBootReadFailed := true
		Generation := -99
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(0, Timer, true, 0, Collect, &Generation))
		AssertEqual(0, Generation, "an unresolved destination creates no accepted generation")
		AssertEqual(0, Collected)
		AssertEqual(0, TimerCalls)
		AssertTrue(_ConfigFullSaveCoordinator() == FixtureCoordinator)
		AfterPropertyCount := 0
		for Name in ObjOwnProps(FixtureCoordinator) {
			AfterPropertyCount += 1
			AssertTrue(BeforeProperties.Has(Name), "an invalid path adds no coordinator property")
			AssertTrue(FixtureCoordinator.%Name% == BeforeProperties[Name],
				"every original coordinator field survives invalid-path refusal")
		}
		AssertEqual(BeforeProperties.Count, AfterPropertyCount)
		AssertTrue(_ConfigWriteLeaseState() == NativeState)
		AssertTrue(NativeState.owners == NativeOwners)
		AssertEqual(BeforeOwnerCount, NativeOwners.Count)
		AssertTrue(NativeState.terminal == BeforeTerminal)
		AssertEqual(BeforeIssuerId, NativeState.next_id, "refusal never invokes the native issuer")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}

Test("config full save: unset selected path refuses before generation and native effects",
	() => _CPL_WithIsolatedLogger(() => _CFGFS_DirectIntentWithoutSelectedPath(true)))
Test("config full save: empty selected path refuses before generation and native effects",
	() => _CPL_WithIsolatedLogger(() => _CFGFS_DirectIntentWithoutSelectedPath(false)))
