; tests/unit/test_config_transition_runtime.ahk

; ==============================================================================
; MODULE: Configuration Transition Runtime Tests
; DESCRIPTION:
; Exercises strict result typing, runtime target builders, retained terminal
; ownership, real-path reset intention order, and non-Critical lifecycle entry.
;
; FEATURES & RATIONALE:
; 1. Truthy/malformed values never authorize a transition outcome.
; 2. Reset specs carry one present placeholder followed by two deletions.
; 3. Runtime callbacks prove inherited Critical is disabled around I/O seams.
; 4. Failed terminal acquisition remains a typed retry with no leaked barrier.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../test_framework.ahk
#Include ../../infra/config_write_lease.ahk
#Include ../../infra/config_transition.ahk
#Include ../../infra/config_transition_runtime.ahk





; =======================================
; =======================================
; ======= 1/ Strict Typed Results =======
; =======================================
; =======================================

_CTRT_ResultPredicateIsStrict() {
	AssertTrue(ConfigTransitionResultIs(
		Map("status", "ok", "kind", "committed_new"), "committed_new"))
	for Candidate in [
		false,
		Map(),
		Map("status", 1, "kind", "committed_new"),
		Map("status", "ok", "kind", 1),
		Map("status", "OK", "kind", "committed_new"),
		Map("status", "ok", "kind", "COMMITTED_NEW")
	] {
		AssertFalse(ConfigTransitionResultIs(Candidate, "committed_new"),
			"malformed/case-drifted result unexpectedly authorized success")
	}
	AssertFalse(ConfigTransitionResultIs(
		Map("status", "ok", "kind", "committed_new"), 1),
		"a non-string expected kind must never authorize success")
}
Test("config transition runtime: result predicate is type and case strict "
	. "(config-transition-runtime-strict-result)",
	_CTRT_ResultPredicateIsStrict)

_CTRT_TargetBuildersUseExactSchema() {
	Present := ConfigTransitionPresentTarget("C:\cfg\config.toml", "new")
	Guarded := ConfigTransitionPresentTarget("C:\cfg\guarded.toml", "new",
		Map("present", 1, "hash",
			"0000000000000000000000000000000000000000000000000000000000000000"))
	Absent := ConfigTransitionAbsentTarget("C:\cfg\tap_hold.toml")
	AssertEqual(3, Present.Count)
	AssertEqual("C:\cfg\config.toml", Present["path"])
	AssertTrue((Present["new_present"] is Integer)
		&& Present["new_present"] == 1)
	AssertEqual("new", Present["new_content"])
	AssertEqual(4, Guarded.Count)
	AssertEqual(64, StrLen(Guarded["expected_old"]["hash"]))
	AssertEqual(3, Absent.Count)
	AssertTrue((Absent["new_present"] is Integer)
		&& Absent["new_present"] == 0)
	AssertEqual("", Absent["new_content"])
	for InvalidExpected in ["0", 1, []]
		AssertThrows(() => ConfigTransitionPresentTarget(
			"C:\cfg\invalid.toml", "new", InvalidExpected),
			"malformed expected-old authority must fail fast")
}
Test("config transition runtime: target builders match strict core schema "
	. "(config-transition-runtime-target-schema)",
	_CTRT_TargetBuildersUseExactSchema)

_CTRT_ResetSpecsAreCompleteAndOrdered() {
	ConfigPath := "C:\cfg\config.toml"
	TapHoldPath := "C:\cfg\tap_hold.toml"
	ApiPath := "C:\cfg\api_entries.json"
	Specs := _ConfigResetTransitionTargets(ConfigPath, TapHoldPath, ApiPath)
	AssertEqual(3, Specs.Length)
	AssertEqual(ConfigPath, Specs[1]["path"])
	AssertTrue(Specs[1]["new_present"] == 1)
	AssertContains(Specs[1]["new_content"], "[_meta]")
	AssertContains(Specs[1]["new_content"], "schema_version = 2")
	AssertEqual(TapHoldPath, Specs[2]["path"])
	AssertTrue(Specs[2]["new_present"] == 0)
	AssertEqual(ApiPath, Specs[3]["path"])
	AssertTrue(Specs[3]["new_present"] == 0)
}
Test("config transition runtime: reset declares placeholder then two deletes "
	. "(config-transition-runtime-reset-specs)",
	_CTRT_ResetSpecsAreCompleteAndOrdered)

_CTRT_ConfigDirValidationIsCanonicalAndStrict() {
	AssertEqual("C:\Config\",
		ConfigTransitionNormalizeConfigDir("C:/Config"))
	AssertEqual("C:\Config\",
		ConfigTransitionNormalizeConfigDir("C:\Config\"))
	AssertEqual("\\server\share\Config\",
		ConfigTransitionNormalizeConfigDir("\\server\share\Config"))
	for Invalid in [
		"relative", "..\config", "C:\safe\..\escape",
		'C:\bad"quote', "C:\bad" . Chr(10) . "line",
		"C:\CON", "C:\trailing.", "C:\trailing "
	] {
		AssertFalse(ConfigTransitionNormalizeConfigDir(Invalid) is String,
			"invalid config directory unexpectedly accepted: " . Invalid)
		AssertThrows(() => ConfigTransitionPathsTomlContent(Invalid,
			"C:\Default\"),
			"invalid config directory must never reach paths.toml bytes")
	}
	Content := ConfigTransitionPathsTomlContent("C:\Config",
		"C:\Default\")
	AssertContains(Content, 'ConfigDirPath = "C:/Config/"')
}
Test("config transition runtime: user config paths are absolute and TOML-safe "
	. "(config-transition-runtime-config-dir-validation)",
	_CTRT_ConfigDirValidationIsCanonicalAndStrict)





; ===========================================
; ===========================================
; ======= 2/ Critical and Acquisition =======
; ===========================================
; ===========================================

_CTRT_MinimalPort(State) {
	return Map(
		"exists", (Path) => 0,
		"read", (Path) => false,
		"read_bounded", (Path, MaxBytes) => false,
		"write_create_durable", (Path, Content) => 0,
		"move_create", (Source, Destination) => 0,
		"move_replace", (Source, Destination) => 0,
		"delete", (Path) => 1,
		"hash", (Content) => "0000000000000000000000000000000000000000000000000000000000000000")
}

_CTRT_AcquireProbe(State, Paths) {
	State["acquire_critical"] := A_IsCritical
	return _ConfigWriteTerminalTryAcquire(Paths)
}

_CTRT_SettleProbe(State, Bundle) {
	State["settle_critical"] := A_IsCritical
	return 1
}

_CTRT_AcquisitionDisablesInheritedCritical() {
	State := Map("acquire_critical", -1, "settle_critical", -1)
	Locator := "C:\stable\paths.toml"
	Target := "D:\cfg\config.toml"
	PreviousCritical := Critical("On")
	try Result := ConfigTransitionAcquireLifecycleBundle(Locator, [Target],
		_CTRT_MinimalPort(State), _CTRT_AcquireProbe.Bind(State),
		_CTRT_SettleProbe.Bind(State))
	finally Critical(PreviousCritical)
	AssertTrue(ConfigTransitionResultIs(Result, "bundle_acquired"))
	try {
		AssertFalse(State["acquire_critical"],
			"terminal acquisition inherited Critical across filesystem work")
		AssertFalse(State["settle_critical"],
			"pending-save settlement inherited Critical across writer I/O")
	} finally _ConfigWriteTerminalRelease(Result["bundle"])
}
Test("config transition runtime: lifecycle acquisition drops inherited Critical "
	. "(config-transition-runtime-noncritical-io)",
	_CTRT_AcquisitionDisablesInheritedCritical)

_CTRT_AcquireRefusalIsTyped() {
	State := Map()
	Locator := "C:\stable\paths.toml"
	Target := "D:\cfg\config.toml"
	Held := _ConfigWriteLeaseTryAcquire("E:\other\sibling.toml")
	AssertTrue(Held is Object, "test prerequisite: ordinary writer owns a path")
	try {
		Result := ConfigTransitionAcquireLifecycleBundle(Locator, [Target],
			_CTRT_MinimalPort(State), _ConfigWriteTerminalTryAcquire,
			_CTRT_SettleProbe.Bind(State))
		AssertEqual("retry", Result["status"])
		AssertEqual("terminal_barrier_busy", Result["kind"])
		AssertFalse(_ConfigWriteTerminalIsActive(),
			"a refused acquisition must not leak a terminal barrier")
	} finally _ConfigWriteLeaseRelease(Held)
}
Test("config transition runtime: busy barrier returns a typed retry "
	. "(config-transition-runtime-busy-result)",
	_CTRT_AcquireRefusalIsTyped)

_CTRT_RetainedBarrierValidatesRealOwnership() {
	global _ConfigTransitionRetainedBarrier
	_ConfigTransitionRetainedBarrier := false
	Fake := { kind: "terminal_bundle", id: 99, tokens: [],
		authorized: false, shutdown_claimed: false }
	AssertFalse(ConfigTransitionRetainBarrier(Fake),
		"a detached lookalike bundle must never become retained authority")
	Bundle := _ConfigWriteTerminalTryAcquire(["C:\stable\paths.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(ConfigTransitionRetainBarrier(Bundle))
		AssertTrue(ConfigTransitionRetainedBarrier() == Bundle)
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		_ConfigTransitionRetainedBarrier := false
	}
}
Test("config transition runtime: retained barrier requires live exact owners "
	. "(config-transition-runtime-retained-owner)",
	_CTRT_RetainedBarrierValidatesRealOwnership)

_CTRT_FailedRollbackRetainsBarrier() {
	global _ConfigTransitionRetainedBarrier
	_ConfigTransitionRetainedBarrier := false
	Bundle := _ConfigWriteTerminalTryAcquire([
		"C:\stable\paths.toml", "D:\cfg\config.toml"])
	AssertTrue(Bundle is Object)
	try {
		Primary := Map("status", "retry", "kind", "target_replace_failed",
			"detail", "", "record", false)
		Rollback := Map("status", "retry", "kind", "target_delete_failed",
			"detail", "", "record", false)
		Result := _ConfigTransitionProtectFailedResolution(Primary, Rollback,
			Bundle)
		AssertTrue(Result.Has("barrier_retained")
			&& Result["barrier_retained"] == 1,
			"unsafe rollback must tell caller not to release the barrier")
		AssertTrue(Result["rollback"] == Rollback,
			"the primary failure must retain its exact rollback evidence")
		AssertTrue(ConfigTransitionRetainedBarrier() == Bundle)
		AssertFalse(_ConfigWriteLeaseTryAcquire("E:\sibling\setting.toml")
			is Object,
			"an unresolved mixed image must block every sibling writer")
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		_ConfigTransitionRetainedBarrier := false
	}
}
Test("config transition runtime: failed rollback keeps global admission closed "
	. "(config-transition-runtime-rollback-retains-barrier)",
	_CTRT_FailedRollbackRetainsBarrier)





; ===================================
; ===================================
; ======= 3/ Direct-run Entry =======
; ===================================
; ===================================

if A_LineFile = A_ScriptFullPath
	RunTests()
