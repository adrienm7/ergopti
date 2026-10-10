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

; One malformed authority per call, so the refused call reads a parameter. A
; closure never sees a for-loop variable: built in the loop, it threw an
; UnsetError that AssertThrows accepted whatever the builder did.
; @param InvalidExpected {Any} Neither a Map nor the integer sentinel 0.
_CTRT_MalformedExpectedOldIsRefused(InvalidExpected) {
	AssertThrows(() => ConfigTransitionPresentTarget(
		"C:\cfg\invalid.toml", "new", InvalidExpected),
		"malformed expected-old authority must fail fast: " . Type(InvalidExpected))
}

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
		_CTRT_MalformedExpectedOldIsRefused(InvalidExpected)
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
	AssertContains(Specs[1]["new_content"], "schema_version = " . ConfigMigrateCurrentVersion() . "`n",
		"the placeholder carries the version the boot migration reads")
	AssertEqual(TapHoldPath, Specs[2]["path"])
	AssertTrue(Specs[2]["new_present"] == 0)
	AssertEqual(ApiPath, Specs[3]["path"])
	AssertTrue(Specs[3]["new_present"] == 0)
}
Test("config transition runtime: reset declares placeholder then two deletes "
	. "(config-transition-runtime-reset-specs)",
	_CTRT_ResetSpecsAreCompleteAndOrdered)

; One invalid directory per call, so the refused call reads a parameter, for
; the same reason as _CTRT_MalformedExpectedOldIsRefused.
; @param Invalid {String} A directory the absolute Windows-path grammar rejects.
_CTRT_InvalidConfigDirIsRefused(Invalid) {
	AssertFalse(ConfigTransitionNormalizeConfigDir(Invalid) is String,
		"invalid config directory unexpectedly accepted: " . Invalid)
	AssertThrows(() => ConfigTransitionPathsTomlContent(Invalid,
		"C:\Default\"),
		"invalid config directory must never reach paths.toml bytes: " . Invalid)
}

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
		_CTRT_InvalidConfigDirIsRefused(Invalid)
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










; Checks the exact refusal type without accepting unrelated fixture errors.
; @param Overrides {Map} The selected locator state under test.
_CTRT_BootDefaultRefused(Overrides) {
	Refused := false
	try ConfigTransitionSelectBootConfigDir(Overrides,
		"\.config\ergopti_plus\")
	catch ValueError {
		Refused := true
	}
	AssertTrue(Refused,
		"a selected root-relative default must be refused before filesystem use")
}

Test("config transition runtime: absent override refuses invalid boot default "
	. "(config-transition-runtime-boot-absent-default)",
	(*) => _CTRT_BootDefaultRefused(Map()))
Test("config transition runtime: empty override refuses invalid boot default "
	. "(config-transition-runtime-boot-empty-default)",
	(*) => _CTRT_BootDefaultRefused(Map("ConfigDirPath", "")))
Test("config transition runtime: unrelated locator cannot authorize boot default "
	. "(config-transition-runtime-boot-unrelated-default)",
	(*) => _CTRT_BootDefaultRefused(Map("LogsDirPath", "D:\Logs\")))

_CTRT_BootDefaultIsExact() {
	DefaultDir := "C:\Users\OwnedFixture\.config\ergopti_plus\"
	AssertEqual(DefaultDir, ConfigTransitionSelectBootConfigDir(Map(), DefaultDir))
	AssertEqual(DefaultDir, ConfigTransitionSelectBootConfigDir(
		Map("ConfigDirPath", ""), DefaultDir))
}
Test("config transition runtime: ordinary boot default bytes are preserved "
	. "(config-transition-runtime-boot-exact-default)",
	_CTRT_BootDefaultIsExact)

_CTRT_BootUncDefaultIsExact() {
	DefaultDir := "\\server\profiles\OwnedFixture\.config\ergopti_plus\"
	AssertEqual(DefaultDir, ConfigTransitionSelectBootConfigDir(Map(), DefaultDir))
}
Test("config transition runtime: absolute UNC boot default stays supported "
	. "(config-transition-runtime-boot-unc-default)",
	_CTRT_BootUncDefaultIsExact)

_CTRT_BootSmokeDefaultIsExact() {
	DefaultDir := "D:\OwnedSmokeFixture\config\"
	AssertEqual(DefaultDir, ConfigTransitionSelectBootConfigDir(Map(), DefaultDir))
}
Test("config transition runtime: isolated smoke default remains authoritative "
	. "(config-transition-runtime-boot-smoke-default)",
	_CTRT_BootSmokeDefaultIsExact)

_CTRT_BootOverrideIgnoresUnusedDefault() {
	Override := "D:\OwnedExplicitFixture"
	AssertEqual(Override, ConfigTransitionSelectBootConfigDir(
		Map("ConfigDirPath", Override), "\.config\ergopti_plus\"),
		"an unused invalid default must not reject the explicit root")
	AssertEqual(Override, ConfigTransitionSelectBootConfigDir(
		Map("ConfigDirPath", Override), ""))
}
Test("config transition runtime: explicit boot override bypasses unused default "
	. "(config-transition-runtime-boot-unused-default)",
	_CTRT_BootOverrideIgnoresUnusedDefault)





; =====================================================
; =====================================================
; ======= Closed native retained-bundle custody =======
; =====================================================
; =====================================================

_CTRT_ClosedRetainPath(Tag) {
	static Sequence := 0
	Sequence += 1
	return A_Temp . "\ergopti-retained-issuer-" . A_ScriptHwnd . "-" . Sequence . "-" . Tag . ".toml"
}

_CTRT_ClosedRetainCounterfactual(Kind, Name := "") {
	global _ConfigTransitionRetainedBarrier
	PreviousRetained := _ConfigTransitionRetainedBarrier
	AssertFalse(PreviousRetained is Object, "the independent custody case cannot borrow another retained owner")
	Path := _CTRT_ClosedRetainPath("first")
	OtherPath := _CTRT_ClosedRetainPath("second")
	Bundle := _ConfigWriteTerminalTryAcquire([Path, OtherPath])
	AssertTrue(Bundle is Object)
	Tokens := Bundle.tokens
	First := Tokens[1], Second := Tokens[2]
	FirstKey := First.key
	State := _ConfigWriteLeaseState()
	Subject := Bundle
	Observed := 0, Descriptor := 0
	Hits := { count: 0 }
	Released := false, Withdrawn := false
	Fresh := 0
	PreviousCritical := Critical("On")
	try {
		switch Kind {
			case "clone":
				Subject := { kind: Bundle.kind, id: Bundle.id, tokens: Tokens,
					authorized: Bundle.authorized, shutdown_claimed: Bundle.shutdown_claimed }
			case "extra":
				Bundle.UnexpectedRetainedMetadata := true
			case "getter", "token-getter":
				Observed := Kind == "getter" ? Bundle : First
				Descriptor := Object.Prototype.GetOwnPropDesc.Call(Observed, Name)
				Original := Descriptor.Value
				Observed.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
			case "array-observer":
				Observed := Tokens
				if Name == "__Enum"
					Tokens.DefineProp(Name, { Call: (This, Arity) =>
						(Hits.count += 1, Array.Prototype.__Enum.Call(This, Arity)) })
				else {
					OriginalLength := Tokens.Length
					Tokens.DefineProp(Name, { Get: (*) => (Hits.count += 1, OriginalLength) })
				}
			case "reordered":
				Tokens[1] := Second, Tokens[2] := First
			case "substituted":
				Tokens[1] := { key: First.key, id: First.id, kind: First.kind }
			case "withdrawn":
				State.owners.Delete(FirstKey)
				State.terminal := false
				Withdrawn := true
			case "retired":
				AssertTrue(_ConfigWriteTerminalRelease(Bundle))
				Released := true
				State.owners[First.key] := First
				State.owners[Second.key] := Second
				State.terminal := Bundle
			default:
				throw ValueError("Unknown closed retained-bundle counterfactual")
		}
		AssertFalse(ConfigTransitionRetainBarrier(Subject),
			"retention must refuse the exact controlled native custody defect: " . Kind . " " . Name)
		AssertTrue(_ConfigTransitionRetainedBarrier == PreviousRetained,
			"refused retention must leave the original borrowed lifecycle holder unchanged")
		AssertEqual(0, Hits.count, "retention checks native descriptors before public getters or array observers")
		if Descriptor is Object
			Observed.DefineProp(Name, Descriptor)
		else if Kind == "array-observer"
			Tokens.DeleteProp(Name)
		if Kind == "extra"
			Bundle.DeleteProp("UnexpectedRetainedMetadata")
		Tokens[1] := First, Tokens[2] := Second
		if Withdrawn {
			AssertTrue(_ConfigWriteTerminalIsActive(), "public withdrawal did not retire the real private issuer")
			State.owners[FirstKey] := First
			State.terminal := Bundle
			Withdrawn := false
		}
		if Released {
			AssertFalse(_ConfigWriteTerminalIsActive(), "public reinsertion cannot resurrect retired native issuance")
			State.owners.Delete(First.key)
			State.owners.Delete(Second.key)
			State.terminal := false
			Fresh := _ConfigWriteTerminalTryAcquire([Path, OtherPath])
			AssertTrue(Fresh is Object)
			AssertFalse(Fresh == Bundle)
			AssertTrue(ConfigTransitionRetainBarrier(Fresh), "a real fresh issuer remains retainable after exact cleanup")
			AssertTrue(ConfigTransitionRetainedBarrier() == Fresh)
			AssertFalse(ConfigTransitionRetainBarrier(Bundle), "the retired predecessor cannot replace the genuine retained successor")
			AssertTrue(ConfigTransitionRetainedBarrier() == Fresh)
		} else {
			AssertTrue(_ConfigWriteLeaseOwns(First, First.key))
			AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, First.key) == First)
			AssertTrue(ConfigTransitionRetainBarrier(Bundle), "exact repair retains the same still-issued original")
			AssertTrue(ConfigTransitionRetainedBarrier() == Bundle)
			AssertTrue(ConfigTransitionRetainBarrier(Bundle), "same live original retention remains idempotent")
			AssertTrue(_ConfigWriteLeaseOwns(Second, Second.key))
		}
		AssertEqual(0, Hits.count)
	} finally {
		try {
			if Descriptor is Object
				Observed.DefineProp(Name, Descriptor)
			else if Kind == "array-observer" && Object.Prototype.HasOwnProp.Call(Tokens, Name)
				Tokens.DeleteProp(Name)
			if Object.Prototype.HasOwnProp.Call(Bundle, "UnexpectedRetainedMetadata")
				Bundle.DeleteProp("UnexpectedRetainedMetadata")
			Tokens[1] := First, Tokens[2] := Second
			if _ConfigTransitionRetainedBarrier == Subject || _ConfigTransitionRetainedBarrier == Bundle
					|| ((Fresh is Object) && _ConfigTransitionRetainedBarrier == Fresh)
				_ConfigTransitionRetainedBarrier := PreviousRetained
			if !Released {
				if Withdrawn {
					State.owners[FirstKey] := First
					State.terminal := Bundle
				}
				AssertTrue(_ConfigWriteTerminalRelease(Bundle))
			} else {
				for Token in [First, Second] {
					if State.owners.Has(Token.key) && State.owners[Token.key] == Token
						State.owners.Delete(Token.key)
				}
				if State.terminal == Bundle
					State.terminal := false
			}
			if Fresh is Object
				AssertTrue(_ConfigWriteTerminalRelease(Fresh))
		} finally Critical(PreviousCritical)
	}
}
Test("config transition retention: copied wrapper cannot borrow genuine native tokens", _CTRT_ClosedRetainCounterfactual.Bind("clone"))
Test("config transition retention: extra native metadata refuses before retention", _CTRT_ClosedRetainCounterfactual.Bind("extra"))
for Name in ["kind", "id", "tokens", "authorized", "shutdown_claimed"]
	Test("config transition retention: actual whole bundle getter refuses without invocation " . Name,
		_CTRT_ClosedRetainCounterfactual.Bind("getter", Name))
for Name in ["key", "id", "kind"]
	Test("config transition retention: actual member token getter refuses without invocation " . Name,
		_CTRT_ClosedRetainCounterfactual.Bind("token-getter", Name))
for Name in ["__Enum", "Length"]
	Test("config transition retention: original token array observer refuses without invocation " . Name,
		_CTRT_ClosedRetainCounterfactual.Bind("array-observer", Name))
Test("config transition retention: reordered actual tokens refuse before retention", _CTRT_ClosedRetainCounterfactual.Bind("reordered"))
Test("config transition retention: copied member token refuses before retention", _CTRT_ClosedRetainCounterfactual.Bind("substituted"))
Test("config transition retention: refused public custody preserves the real native issuer", _CTRT_ClosedRetainCounterfactual.Bind("withdrawn"))
Test("config transition retention: same retired original cannot replace its retained successor", _CTRT_ClosedRetainCounterfactual.Bind("retired"))

_CTRT_ClosedRetainOrdinaryRefuses() {
	global _ConfigTransitionRetainedBarrier
	PreviousRetained := _ConfigTransitionRetainedBarrier
	AssertFalse(PreviousRetained is Object)
	Path := _CTRT_ClosedRetainPath("ordinary")
	Token := _ConfigWriteLeaseTryAcquire(Path, "retention ordinary owner")
	AssertTrue(Token is Object)
	Copied := { key: Token.key, id: Token.id, kind: Token.kind }
	Wrapped := { kind: "terminal_bundle", id: Token.id, tokens: [Token],
		authorized: false, shutdown_claimed: false }
	PreviousCritical := Critical("On")
	try {
		AssertFalse(ConfigTransitionRetainBarrier(Token))
		AssertFalse(ConfigTransitionRetainBarrier(Copied))
		AssertFalse(ConfigTransitionRetainBarrier(Wrapped))
		AssertTrue(_ConfigTransitionRetainedBarrier == PreviousRetained)
		AssertTrue(_ConfigWriteLeaseOwns(Token, Path), "refused ordinary copies leave the genuine issuer untouched")
		AssertTrue(_ConfigWriteLeaseSelectOwner(Token, Path) == Token)
		AssertFalse(_ConfigWriteLeaseOwns(Copied, Path))
		AssertFalse(_ConfigWriteTerminalTryAcquire([Path]) is Object)
	} finally {
		try {
			if _ConfigTransitionRetainedBarrier == Token || _ConfigTransitionRetainedBarrier == Copied
					|| _ConfigTransitionRetainedBarrier == Wrapped
				_ConfigTransitionRetainedBarrier := PreviousRetained
			AssertTrue(_ConfigWriteLeaseRelease(Token))
		} finally Critical(PreviousCritical)
	}
}
Test("config transition retention: ordinary and copied owners never become retained terminal authority", _CTRT_ClosedRetainOrdinaryRefuses)

_CTRT_ClosedRetainRollback(State, Expected, Retain, Bundle) {
	State.calls += 1
	AssertTrue(Bundle == Expected, "the raw refusal callback receives the exact originally borrowed native bundle")
	AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, State.path) == State.token)
	return Retain ? ConfigTransitionRetainBarrier(Bundle) : false
}

_CTRT_ClosedRetainRawRollback(Retain) {
	global _ConfigTransitionRetainedBarrier
	PreviousRetained := _ConfigTransitionRetainedBarrier
	AssertFalse(PreviousRetained is Object)
	Path := _CTRT_ClosedRetainPath("raw-rollback")
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	State := { calls: 0, path: Path, token: Bundle.tokens[1] }
	PreviousCritical := Critical("On")
	try {
		ConfigTransitionSettleRefusedReload(_CTRT_ClosedRetainRollback.Bind(State, Bundle, Retain), Bundle)
		AssertEqual(1, State.calls)
		if Retain {
			AssertTrue(ConfigTransitionRetainedBarrier() == Bundle)
			AssertTrue(_ConfigWriteTerminalIsActive(), "the pending rollback keeps its genuinely retained native owner")
			AssertTrue(_ConfigWriteLeaseOwns(State.token, Path))
			AssertTrue(ConfigTransitionRetainBarrier(Bundle))
		} else {
			AssertTrue(_ConfigTransitionRetainedBarrier == PreviousRetained)
			AssertFalse(_ConfigWriteTerminalIsActive(), "settled rollback releases through the actual native owner")
			AssertFalse(_ConfigWriteLeaseOwns(State.token, Path))
			AssertFalse(_ConfigWriteTerminalRelease(Bundle), "already settled native release is not a synthetic acknowledgment")
		}
	} finally {
		try {
			if _ConfigTransitionRetainedBarrier == Bundle
				_ConfigTransitionRetainedBarrier := PreviousRetained
			if Retain || _ConfigWriteTerminalTryAcquire([], Bundle)
				AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		} finally Critical(PreviousCritical)
	}
}
Test("config transition retention: pending raw rollback borrows and retains its original native owner", _CTRT_ClosedRetainRawRollback.Bind(true))
Test("config transition retention: settled raw rollback releases its original native owner once", _CTRT_ClosedRetainRawRollback.Bind(false))





; ===================================
; ===================================
; ======= 3/ Direct-run Entry =======
; ===================================
; ===================================

if A_LineFile = A_ScriptFullPath
	RunTests()
