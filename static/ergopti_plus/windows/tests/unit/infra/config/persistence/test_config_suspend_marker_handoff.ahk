; tests/unit/infra/config/persistence/test_config_suspend_marker_handoff.ahk

; ==============================================================================
; MODULE: Config Persistence Suspend Marker Hand-Off
; DESCRIPTION:
; AHK-15 and AHK-006: the suspend marker is handed off with the persisted
; state, so a pause during persistence neither loses nor duplicates the
; deferred side effects.
; ==============================================================================

#Requires AutoHotkey v2.0





global _CPT_MarkerExists := false
global _CPT_ClaimExists := false
global _CPT_PendingExists := false
global _CPT_HandoffWriteOk := true
global _CPT_HandoffMoveOk := true
global _CPT_HandoffDeleteOk := true
global _CPT_ReloadCalls := 0
global _CPT_ToggleCalls := 0
global _CPT_HandoffFailures := 0
global _CPT_BeforeToggleCalls := 0
global _CPT_HandoffMoveCalls := 0
global _CPT_HandoffCancelCalls := 0
global _CPT_HandoffProbeThrows := false
global _CPT_HandoffDeleteThrows := false

_CPT_ResetHandoffFakes() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_PendingExists
	global _CPT_HandoffWriteOk, _CPT_HandoffMoveOk
	global _CPT_HandoffDeleteOk, _CPT_ReloadCalls, _CPT_ToggleCalls
	global _CPT_HandoffFailures, _CPT_BeforeToggleCalls, _CPT_HandoffMoveCalls
	global _CPT_HandoffCancelCalls, _CPT_HandoffProbeThrows, _CPT_HandoffDeleteThrows
	_CPT_MarkerExists := false
	_CPT_ClaimExists := false
	_CPT_PendingExists := false
	_CPT_HandoffWriteOk := true
	_CPT_HandoffMoveOk := true
	_CPT_HandoffDeleteOk := true
	_CPT_ReloadCalls := 0
	_CPT_ToggleCalls := 0
	_CPT_HandoffFailures := 0
	_CPT_BeforeToggleCalls := 0
	_CPT_HandoffMoveCalls := 0
	_CPT_HandoffCancelCalls := 0
	_CPT_HandoffProbeThrows := false
	_CPT_HandoffDeleteThrows := false
}

_CPT_HandoffPrepare(Path) {
	global _CPT_HandoffWriteOk, _CPT_PendingExists
	if _CPT_HandoffWriteOk
		_CPT_PendingExists := true
	return _CPT_HandoffWriteOk
}

_CPT_HandoffCommit(Path) {
	global _CPT_PendingExists, _CPT_MarkerExists, _CPT_HandoffMoveOk
	if !_CPT_PendingExists or !_CPT_HandoffMoveOk
		return 0
	_CPT_PendingExists := false
	_CPT_MarkerExists := true
	return 1
}

_CPT_HandoffExists(Path) {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffProbeThrows
	if _CPT_HandoffProbeThrows
		throw OSError(5, A_ThisFunc, "injected access-denied probe")
	return (Path == "marker.claim") ? _CPT_ClaimExists : _CPT_MarkerExists
}

_CPT_HandoffMove(Source, Destination, Overwrite) {
	global _CPT_HandoffMoveOk, _CPT_MarkerExists, _CPT_ClaimExists
	global _CPT_HandoffMoveCalls
	_CPT_HandoffMoveCalls += 1
	if !_CPT_MarkerExists or !_CPT_HandoffMoveOk
		return false
	_CPT_MarkerExists := false
	_CPT_ClaimExists := true
	return true
}

_CPT_HandoffDelete(Path) {
	global _CPT_HandoffDeleteOk, _CPT_MarkerExists, _CPT_ClaimExists
	global _CPT_HandoffDeleteThrows
	if _CPT_HandoffDeleteThrows
		throw OSError(5, A_ThisFunc, "injected access-denied delete")
	if _CPT_HandoffDeleteOk {
		if (Path == "marker.claim")
			_CPT_ClaimExists := false
		else
			_CPT_MarkerExists := false
	}
	return _CPT_HandoffDeleteOk
}

_CPT_Reload() {
	global _CPT_ReloadCalls
	_CPT_ReloadCalls += 1
	return 1
}

_CPT_RefusedReload() {
	global _CPT_ReloadCalls
	_CPT_ReloadCalls += 1
	return false
}

_CPT_HandoffCancel(Path) {
	global _CPT_HandoffCancelCalls, _CPT_PendingExists, _CPT_HandoffDeleteOk
	_CPT_HandoffCancelCalls += 1
	if _CPT_HandoffDeleteOk
		_CPT_PendingExists := false
	return _CPT_HandoffDeleteOk ? 1 : 0
}

_CPT_Toggle() {
	global _CPT_ToggleCalls
	_CPT_ToggleCalls += 1
}

_CPT_HandoffFailure(Stage, Path) {
	global _CPT_HandoffFailures
	_CPT_HandoffFailures += 1
}

_CPT_BeforeToggle() {
	global _CPT_BeforeToggleCalls
	_CPT_BeforeToggleCalls += 1
}

_CPT_MarkerPublicationFailureAbortsReload() {
	global _CPT_HandoffWriteOk, _CPT_ReloadCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_HandoffWriteOk := false
	AssertFalse(SuspendHandoffReload(true, "marker", _CPT_HandoffPrepare, _CPT_Reload,
		0, _CPT_HandoffFailure))
	AssertEqual(0, _CPT_ReloadCalls, "publication failure must abort Reload")
	AssertEqual(1, _CPT_HandoffFailures, "publication failure must be surfaced exactly once")
}
Test("AHK-15-persistence: suspend marker publication failure aborts reload",
	_CPT_MarkerPublicationFailureAbortsReload)

_CPT_ReturnedReloadIsFailureAndRetractsMarker() {
	global _CPT_ReloadCalls, _CPT_MarkerExists, _CPT_PendingExists
	global _CPT_HandoffCancelCalls
	_CPT_ResetHandoffFakes()
	AssertFalse(SuspendHandoffReload(true, "marker", _CPT_HandoffPrepare,
		_CPT_RefusedReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
	AssertEqual(1, _CPT_ReloadCalls)
	AssertEqual(1, _CPT_HandoffCancelCalls,
		"a returned/refused Reload must retract pause intent exactly once")
	AssertFalse(_CPT_MarkerExists,
		"a refused Reload must never publish live pause intent")
	AssertFalse(_CPT_PendingExists,
		"the normal refusal path should clean its inert preparation")
}
Test("AHK-15-persistence: refused reload retracts its suspend marker",
	_CPT_ReturnedReloadIsFailureAndRetractsMarker)

_CPT_SuspendTempMarker(Slug) {
	return A_Temp . "\ergopti_suspend_" . DllCall("GetCurrentProcessId")
		. "_" . A_TickCount . "_" . Slug . ".marker"
}

_CPT_SuspendTempCleanup(Path) {
	for Candidate in [Path . ".pending.stage", Path . ".pending",
			Path . ".claim", Path]
		FSDelete(Candidate)
}

_CPT_SuspendPreparationIsInertAndDurable() {
	Path := _CPT_SuspendTempMarker("prepare")
	_CPT_SuspendTempCleanup(Path)
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		AssertFalse(FSExists(Path),
			"preflight must not create boot-consumable pause authority")
		AssertTrue(FSExists(Path . ".pending"))
		AssertEqual("1", FSRead(Path . ".pending"),
			"the complete durable stage must survive exact readback")
		AssertFalse(FSExists(Path . ".pending.stage"),
			"atomic preparation must retire its scratch path")
	} finally _CPT_SuspendTempCleanup(Path)
}
Test("AHK-15-persistence: suspend preflight creates only durable inert state "
	. "(suspend-handoff-inert-prepare)",
	_CPT_SuspendPreparationIsInertAndDurable)

_CPT_SuspendRefusalCleanupFailureStaysInert() {
	global _CPT_MarkerExists, _CPT_PendingExists, _CPT_HandoffDeleteOk
	global _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_HandoffDeleteOk := false
	AssertFalse(SuspendHandoffReload(true, "marker", _CPT_HandoffPrepare,
		_CPT_RefusedReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
	AssertFalse(_CPT_MarkerExists,
		"even failed refusal cleanup must leave no live pause marker")
	AssertTrue(_CPT_PendingExists,
		"the injected cleanup failure may retain only inert debris")
	AssertEqual(1, _CPT_HandoffFailures,
		"inert cleanup failure must remain visible")
}
Test("AHK-15-persistence: refused reload cleanup debris remains inert "
	. "(suspend-handoff-refusal-inert)",
	_CPT_SuspendRefusalCleanupFailureStaysInert)

_CPT_SuspendTerminalCommitPublishesExactlyOnce() {
	Path := _CPT_SuspendTempMarker("terminal")
	_CPT_SuspendTempCleanup(Path)
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\suspend-terminal.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		Record := _RTP_Pending(Bundle, _RTP_NewPort(), 0,
			SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace),
			SuspendHandoffAbort.Bind(Path, FSExists, FSDelete))
		AssertFalse(FSExists(Path),
			"a launched but unaccepted reload must not publish the live marker")
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertEqual(Record, Claimed)
		AssertTrue(ReloadTerminalHandoffCommit(Claimed))
		AssertTrue(FSExists(Path),
			"only accepted terminal authority may publish the live marker")
		AssertFalse(FSExists(Path . ".pending"))
		AssertFalse(ReloadTerminalHandoffCommit(Claimed),
			"the same terminal record must not publish twice")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed))
	} finally {
		_RTP_Cleanup(Bundle)
		_CPT_SuspendTempCleanup(Path)
	}
}
Test("AHK-15-persistence: terminal acceptance publishes pause exactly once "
	. "(suspend-handoff-terminal-once)",
	_CPT_SuspendTerminalCommitPublishesExactlyOnce)

_CPT_RefusedPausedReloadCanRetrySameTerminalBundle() {
	Path := _CPT_SuspendTempMarker("terminal-retry")
	_CPT_SuspendTempCleanup(Path)
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\suspend-terminal-retry.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		First := _RTP_Pending(Bundle, _RTP_NewPort(), 0,
			SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace),
			SuspendHandoffAbort.Bind(Path, FSExists, FSDelete))
		AssertEqual(First, ReloadTerminalHandoffClaim("Reload"))
		AssertTrue(ReloadTerminalHandoffRefuseForShutdown("Reload", "test"),
			"a late refusal must refuse the first terminal claim")
		AssertTrue(FSExists(Path . ".pending"), "The exact pending marker survives before physical stop.")
		_CPT_ObserveRefusedSuccessorTerminal(First, Bundle)
		AssertFalse(FSExists(Path))
		AssertFalse(FSExists(Path . ".pending"),
			"the refused paused attempt must leave no live or pending marker")

		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		Second := _RTP_Pending(Bundle, _RTP_NewPort(), 0,
			SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace),
			SuspendHandoffAbort.Bind(Path, FSExists, FSDelete))
		AssertEqual(Second, ReloadTerminalHandoffClaim("Reload"),
			"the same retained bundle must be claimable on the second Reload")
		AssertTrue(ReloadTerminalHandoffCommit(Second))
		AssertTrue(FSExists(Path),
			"the retried accepted Reload must publish pause intent")
		AssertTrue(ReloadTerminalHandoffFinish(Second))
	} finally {
		_RTP_Cleanup(Bundle)
		_CPT_SuspendTempCleanup(Path)
	}
}
Test("AHK-15-persistence: refused paused Reload can reuse retained barrier "
	. "(reload-terminal-retained-retry)",
	_CPT_RefusedPausedReloadCanRetrySameTerminalBundle)

; OnExit publishes the live marker at the terminal commit, and the updater's
; FinalExit, swap and recovery gates can still refuse after it. The refusal
; retracts the marker this reload published, through the strict adapters the
; lifecycle wrappers use, but never one holding another transition's intent
; (reload-refusal-retracts-marker).
_CPT_RefusalAfterCommitRetractsOnlyItsMarker() {
	for _, Foreign in [false, true] {
		Path := _CPT_SuspendTempMarker(Foreign ? "late-foreign" : "late-own")
		_CPT_SuspendTempCleanup(Path)
		Content := "1 reload-test-" . (Foreign ? "foreign" : "own")
		Bundle := _ConfigWriteTerminalTryAcquire(
			["C:\ergopti-tests\suspend-late-refusal.toml"])
		AssertTrue(Bundle is Object)
		try {
			AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
				FSAtomicMoveReplace, FSDeleteStrict, Content))
			Record := _RTP_Pending(Bundle, _RTP_NewPort(), 0,
				SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace, Content),
				SuspendHandoffAbort.Bind(Path, FSStrictExists, FSDeleteStrict), 0, 0,
				SuspendHandoffRetract.Bind(Path, Content, FSStrictExists, FSRead,
					FSDeleteStrict))
			AssertEqual(Record, ReloadTerminalHandoffClaim("Reload"))
			AssertTrue(ReloadTerminalHandoffCommit(Record))
			AssertEqual(Content, FSRead(Path), "the accepted commit publishes this reload's intent")
			if Foreign
				AssertTrue(FSWriteDurable(Path, "1"), "another transition republishes the marker")
			AssertTrue(ReloadTerminalHandoffRefuseForShutdown("Reload", "test"),
				"a refusal after the commit must still refuse and clean up")
			AssertEqual(Foreign ? "1" : Content, FSRead(Path), "No live marker is retracted before physical stop.")
			_CPT_ObserveRefusedSuccessorTerminal(Record, Bundle)
			if Foreign {
				AssertEqual("1", FSRead(Path),
					"a marker holding another transition's intent is not this refusal's to retract")
			} else {
				AssertFalse(FSExists(Path),
					"the refused reload must retract the pause intent its commit published")
			}
			AssertFalse(FSExists(Path . ".pending"))
		} finally {
			_RTP_Cleanup(Bundle)
			_CPT_SuspendTempCleanup(Path)
		}
	}
}
Test("AHK-15-persistence: a refusal after the terminal commit retracts only its "
	. "own pause marker (reload-refusal-retracts-marker)",
	_CPT_RefusalAfterCommitRetractsOnlyItsMarker)

_CPT_CriticalProbe(State, Name, Result := 1) {
	State[Name] := A_IsCritical
	return Result
}

_CPT_TerminalCallbacksRunOutsideInheritedCritical() {
	State := Map()
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-critical.toml"])
	AssertTrue(Bundle is Object)
	PreviousCritical := Critical("On")
	try {
		Record := _RTP_Pending(Bundle, _RTP_NewPort(),
			_CPT_CriticalProbe.Bind(State, "success", 1),
			_CPT_CriticalProbe.Bind(State, "commit", 1),
			_CPT_CriticalProbe.Bind(State, "abort", 1))
		AssertTrue(A_IsCritical != 0,
			"the launch wrapper must restore inherited Critical")
		AssertEqual(Record, ReloadTerminalHandoffClaim("Reload"))
		AssertTrue(ReloadTerminalHandoffCommit(Record))
		AssertTrue(ReloadTerminalHandoffFinish(Record,
			_CPT_CriticalProbe.Bind(State, "before_success", 1)))
		AssertEqual(0, State["commit"])
		AssertEqual(0, State["before_success"])
		AssertEqual(0, State["success"])
		AssertTrue(A_IsCritical != 0,
			"terminal callback wrappers must restore inherited Critical")

		Record := ReloadTerminalHandoffPrepare(Bundle, 0, 0,
			_CPT_CriticalProbe.Bind(State, "abort", 1))
		AssertTrue(Record is Map)
		AssertTrue(ReloadTerminalHandoffCancel(Record))
		AssertEqual(0, State["abort"])
		AssertTrue(A_IsCritical != 0)

		InvokeResult := ReloadTerminalInvoke(Bundle, 0,
			_CPT_CriticalProbe.Bind(State, "invoke", 0), _RTP_NewPort())
		AssertFalse(InvokeResult,
			"a launcher that returned no successor launched nothing")
		AssertEqual(0, State["invoke"])
		AssertTrue(A_IsCritical != 0)
	} finally {
		Critical(PreviousCritical)
		_RTP_Cleanup(Bundle)
	}
}
Test("AHK-15-persistence: terminal callbacks drop and restore inherited Critical "
	. "(reload-terminal-critical-boundaries)",
	_CPT_TerminalCallbacksRunOutsideInheritedCritical)

_CPT_SuspendBootDiscardsPendingWithoutToggle() {
	global _CPT_ToggleCalls
	Path := _CPT_SuspendTempMarker("boot-debris")
	_CPT_SuspendTempCleanup(Path)
	_CPT_ToggleCalls := 0
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		AssertTrue(SuspendHandoffDiscardPending(Path, FSExists, FSDelete))
		AssertTrue(SuspendHandoffConsume(Path, false, FSExists, FSMove,
			FSDelete, _CPT_Toggle))
		AssertEqual(0, _CPT_ToggleCalls,
			"boot must never interpret pending debris as pause intent")
	} finally _CPT_SuspendTempCleanup(Path)
}
Test("AHK-15-persistence: boot discards pending pause debris without toggling "
	. "(suspend-handoff-boot-discard)",
	_CPT_SuspendBootDiscardsPendingWithoutToggle)

_CPT_SuspendMarkerFollowsStableLocator() {
	PathsFile := "D:\stable-locator\paths.toml"
	Expected := "D:\stable-locator\suspend_restore.marker"
	AssertEqual(Expected, SuspendHandoffMarkerPath(PathsFile))
	; Config relocation is intentionally absent from this API: only the stable
	; locator decides where both the old and replacement process look.
	AssertEqual(Expected, SuspendHandoffMarkerPath(PathsFile))
}
Test("AHK-15-persistence: suspend marker follows stable paths locator "
	. "(suspend-handoff-stable-locator)",
	_CPT_SuspendMarkerFollowsStableLocator)

global _CPT_TerminalSuccessCalls := 0
global _CPT_TerminalClaimCalls := 0
global _CPT_TerminalEvents := []
global _CPT_TerminalCommitOk := true

_CPT_TerminalSuccess() {
	global _CPT_TerminalSuccessCalls, _CPT_TerminalEvents
	_CPT_TerminalSuccessCalls += 1
	_CPT_TerminalEvents.Push("success")
}

_CPT_TerminalCommit() {
	global _CPT_TerminalEvents, _CPT_TerminalCommitOk
	_CPT_TerminalEvents.Push("commit")
	return _CPT_TerminalCommitOk ? 1 : 0
}

_CPT_TerminalTeardown() {
	global _CPT_TerminalEvents
	_CPT_TerminalEvents.Push("teardown")
}

_CPT_TerminalAbort() {
	global _CPT_TerminalEvents
	_CPT_TerminalEvents.Push("abort")
	return 1
}

; Models the later OnExit(Reload): the successor launched earlier asks this
; instance to close, OnExit claims the pending record and either finishes or
; one of its gates vetoes the request.
_CPT_TerminalOnExit(Outcome) {
	global _CPT_TerminalClaimCalls
	Record := ReloadTerminalHandoffClaim("Reload")
	if !(Record is Map)
		return false
	_CPT_TerminalClaimCalls += 1
	if (Outcome == "accept")
		return ReloadTerminalHandoffFinish(Record)
	if (Outcome == "commit")
		ReloadTerminalHandoffCommit(Record)
	return !ReloadTerminalHandoffRefuseForShutdown("Reload", "test gate")
}

_CPT_TerminalBundleBlocksEverySiblingPath() {
	ConfigPath := "C:\ergopti-tests\A\config.toml"
	CandidatePath := "C:\ergopti-tests\B\config.toml"
	OverridesPath := "C:\ergopti-tests\A\hotstrings_overrides.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([ConfigPath, CandidatePath])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, ConfigPath) is Object)
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, CandidatePath) is Object)
		AssertFalse(_ConfigWriteLeaseTryAcquire(OverridesPath,
			"sibling-writer") is Object,
			"a locator transition must block every sibling-path config writer")
	} finally _ConfigWriteTerminalRelease(Bundle)
	Sibling := _ConfigWriteLeaseTryAcquire(OverridesPath, "after-transition")
	AssertTrue(Sibling is Object)
	AssertTrue(_ConfigWriteLeaseRelease(Sibling))
}
Test("AHK-15-persistence: terminal bundle blocks sibling-path writers",
	_CPT_TerminalBundleBlocksEverySiblingPath)

_CPT_TerminalClaimRequiresAuthorizationAndIsSingleUse() {
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-config.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"shutdown cannot borrow an unannounced transition")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"the exact terminal bundle may be claimed only once")
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("AHK-15-persistence: terminal shutdown claim is authorized and single-use",
	_CPT_TerminalClaimRequiresAuthorizationAndIsSingleUse)

_CPT_UnrelatedExitCannotConsumeReloadAuthorization() {
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\reason-bound-reload.toml"])
	AssertTrue(Bundle is Object)
	try {
		Record := _RTP_Pending(Bundle, _RTP_NewPort())
		AssertFalse(ReloadTerminalHandoffClaim("Exit"),
			"an ordinary ExitApp must not borrow a pending Reload transaction")
		AssertEqual("pending", Record["state"],
			"a wrong reason must leave the exact Reload retry claimable")
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertTrue(Claimed is Map)
		AssertEqual(Record, Claimed)
		AssertFalse(ReloadTerminalHandoffClaim("Reload"),
			"the exact Reload reason may still claim only once")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed))
	} finally _RTP_Cleanup(Bundle)
}
Test("AHK-15-persistence: unrelated Exit cannot consume Reload authorization "
	. "(reload-terminal-reason-bound)",
	_CPT_UnrelatedExitCannotConsumeReloadAuthorization)

_CPT_LateShutdownRefusalCannotReportReloadSuccess() {
	global _CPT_TerminalSuccessCalls, _CPT_TerminalClaimCalls
	_CPT_TerminalSuccessCalls := 0
	_CPT_TerminalClaimCalls := 0
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\refused-reload.toml"])
	AssertTrue(Bundle is Object)
	try {
		TerminalReload := ReloadTerminalInvoke.Bind(Bundle,
			_CPT_TerminalSuccess, _RTP_LaunchReturnsAtOnce, _RTP_NewPort())
		AssertTrue(SuspendHandoffReload(false, "", _CPT_HandoffPrepare,
			TerminalReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel),
			"the launched successor makes the reload pending")
		AssertFalse(_CPT_TerminalOnExit("refuse"),
			"the later OnExit gate vetoes the successor's close request")
		AssertEqual(1, _CPT_TerminalClaimCalls)
		AssertEqual(0, _CPT_TerminalSuccessCalls,
			"late OnExit refusal must leave retry UI untouched")
		AssertFalse(ReloadTerminalHandoffPending(),
			"the refused reload must hand the transition back")
	} finally _RTP_Cleanup(Bundle)
}
Test("AHK-15-persistence: late OnExit refusal never reports success "
	. "(reload-terminal-late-refusal)",
	_CPT_LateShutdownRefusalCannotReportReloadSuccess)

_CPT_TerminalSuccessRunsOnlyAfterClaimFinish() {
	global _CPT_TerminalSuccessCalls, _CPT_TerminalClaimCalls
	_CPT_TerminalSuccessCalls := 0
	_CPT_TerminalClaimCalls := 0
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\accepted-reload.toml"])
	AssertTrue(Bundle is Object)
	try {
		TerminalReload := ReloadTerminalInvoke.Bind(Bundle,
			_CPT_TerminalSuccess, _RTP_LaunchReturnsAtOnce, _RTP_NewPort())
		AssertTrue(SuspendHandoffReload(false, "", _CPT_HandoffPrepare,
			TerminalReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
		AssertEqual(0, _CPT_TerminalSuccessCalls,
			"success belongs to OnExit, not to the launch")
		AssertTrue(_CPT_TerminalOnExit("accept"))
		AssertEqual(1, _CPT_TerminalClaimCalls)
		AssertEqual(1, _CPT_TerminalSuccessCalls)
	} finally _RTP_Cleanup(Bundle)
}
Test("AHK-15-persistence: terminal callback follows the final shutdown gate "
	. "(reload-terminal-success)",
	_CPT_TerminalSuccessRunsOnlyAfterClaimFinish)

_CPT_TerminalCommitPrecedesSuccess() {
	global _CPT_TerminalEvents, _CPT_TerminalCommitOk
	_CPT_TerminalEvents := []
	_CPT_TerminalCommitOk := true
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-commit-order.toml"])
	AssertTrue(Bundle is Object)
	try {
		Record := _RTP_Pending(Bundle, _RTP_NewPort(), _CPT_TerminalSuccess,
			_CPT_TerminalCommit, _CPT_TerminalAbort)
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertEqual(Record, Claimed)
		AssertTrue(ReloadTerminalHandoffCommit(Claimed))
		AssertEqual("committed", Record["state"])
		AssertEqual(1, _CPT_TerminalEvents.Length)
		AssertEqual("commit", _CPT_TerminalEvents[1],
			"durable terminal publication must precede UI success")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed,
			_CPT_TerminalTeardown))
		AssertEqual(3, _CPT_TerminalEvents.Length)
		AssertEqual("teardown", _CPT_TerminalEvents[2],
			"destructive teardown must follow durable commit")
		AssertEqual("success", _CPT_TerminalEvents[3],
			"UI success must follow terminal teardown")
	} finally _RTP_Cleanup(Bundle)
}
Test("AHK-15-persistence: terminal commit precedes success "
	. "(reload-terminal-commit-order)", _CPT_TerminalCommitPrecedesSuccess)

_CPT_TerminalCommitFailureAbortsWithoutSuccess() {
	global _CPT_TerminalEvents, _CPT_TerminalCommitOk
	global _CPT_TerminalSuccessCalls, _CPT_TerminalClaimCalls
	_CPT_TerminalEvents := []
	_CPT_TerminalCommitOk := false
	_CPT_TerminalSuccessCalls := 0
	_CPT_TerminalClaimCalls := 0
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-commit-failure.toml"])
	AssertTrue(Bundle is Object)
	try {
		Record := _RTP_Pending(Bundle, _RTP_NewPort(), _CPT_TerminalSuccess,
			_CPT_TerminalCommit, _CPT_TerminalAbort)
		AssertFalse(_CPT_TerminalOnExit("commit"),
			"a failed terminal commit must make OnExit refuse")
		AssertEqual(1, _CPT_TerminalEvents.Length, "Only commit has run while native stop remains unproven.")
		AssertEqual("commit", _CPT_TerminalEvents[1])
		_CPT_ObserveRefusedSuccessorTerminal(Record, Bundle)
		AssertEqual(1, _CPT_TerminalClaimCalls)
		AssertEqual(0, _CPT_TerminalSuccessCalls,
			"a failed terminal commit must never report success")
		AssertEqual(2, _CPT_TerminalEvents.Length)
		AssertEqual("commit", _CPT_TerminalEvents[1])
		AssertEqual("abort", _CPT_TerminalEvents[2],
			"a refused commit must abort the inert transition")
	} finally {
		_CPT_TerminalCommitOk := true
		_RTP_Cleanup(Bundle)
	}
}
Test("AHK-15-persistence: failed terminal commit aborts without success "
	. "(reload-terminal-commit-failure)",
	_CPT_TerminalCommitFailureAbortsWithoutSuccess)

_CPT_MarkerDeleteFailureNeverToggles() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffDeleteOk, _CPT_ToggleCalls
	global _CPT_HandoffFailures, _CPT_BeforeToggleCalls
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffDeleteOk := false
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(0, _CPT_ToggleCalls, "failed claim consumption must not toggle suspend")
	AssertEqual(0, _CPT_BeforeToggleCalls, "failed claim consumption must not report a restore")
	AssertEqual(1, _CPT_HandoffFailures, "failed claim consumption must be surfaced exactly once")
	AssertTrue(_CPT_ClaimExists, "failed deletion must retain a restart-stable claim for retry")
}
Test("AHK-15-persistence: suspend marker delete failure never toggles",
	_CPT_MarkerDeleteFailureNeverToggles)

_CPT_StrictProbeErrorRetainsSourceForRetry() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffProbeThrows
	global _CPT_ToggleCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffProbeThrows := true
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertTrue(_CPT_MarkerExists, "a failed probe must retain the source intent")
	AssertFalse(_CPT_ClaimExists, "a failed probe must not invent a claim")
	AssertEqual(0, _CPT_ToggleCalls, "a failed probe must never toggle suspend")
	AssertEqual(1, _CPT_HandoffFailures, "a probe error must be surfaced exactly once")

	_CPT_HandoffProbeThrows := false
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "the retained source must remain retryable")
}
Test("AHK-006: strict marker probe errors are loud and retryable",
	_CPT_StrictProbeErrorRetainsSourceForRetry)

_CPT_StrictDeleteErrorRetainsClaimForRetry() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffDeleteThrows
	global _CPT_ToggleCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffDeleteThrows := true
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertFalse(_CPT_MarkerExists, "the source must remain atomically claimed")
	AssertTrue(_CPT_ClaimExists, "a failed delete must retain the stable claim")
	AssertEqual(0, _CPT_ToggleCalls, "a failed delete must never toggle suspend")
	AssertEqual(1, _CPT_HandoffFailures, "a delete error must be surfaced exactly once")

	_CPT_HandoffDeleteThrows := false
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "the retained claim must remain retryable")
}
Test("AHK-006: strict marker delete errors are loud and retryable",
	_CPT_StrictDeleteErrorRetainsClaimForRetry)

_CPT_ConsumedMarkerTogglesExactlyOnce() {
	global _CPT_MarkerExists, _CPT_ToggleCalls, _CPT_HandoffFailures
	global _CPT_BeforeToggleCalls
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	; The atomic move made the source absent, so a repeated boot sees no marker.
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "one published marker must toggle exactly once")
	AssertEqual(1, _CPT_BeforeToggleCalls, "the restore lifecycle must run exactly once")
	AssertEqual(0, _CPT_HandoffFailures)
}
Test("AHK-15-persistence: an atomically consumed marker toggles exactly once",
	_CPT_ConsumedMarkerTogglesExactlyOnce)

_CPT_DeleteFailureRetriesStableClaimExactlyOnce() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffDeleteOk
	global _CPT_ToggleCalls, _CPT_HandoffFailures, _CPT_HandoffMoveCalls
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffDeleteOk := false
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertFalse(_CPT_MarkerExists, "the source must remain atomically claimed")
	AssertTrue(_CPT_ClaimExists, "the durable claim must survive the failed delete")
	AssertEqual(0, _CPT_ToggleCalls, "a failed consume must not restore pause early")

	_CPT_HandoffDeleteOk := true
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_HandoffMoveCalls,
		"retry must resume the retained claim instead of requiring the vanished source")
	AssertEqual(1, _CPT_ToggleCalls, "the retained claim must restore pause exactly once")
	AssertEqual(1, _CPT_HandoffFailures, "only the original failed consume is reported")

	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "a consumed claim must not replay on a later boot")
}
Test("AHK-15-persistence: failed claim deletion retries once on the next boot",
	_CPT_DeleteFailureRetriesStableClaimExactlyOnce)

_CPT_SourceAndClaimCoalesceIntoOneRestore() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_ToggleCalls
	global _CPT_HandoffMoveCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_ClaimExists := true
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertFalse(_CPT_MarkerExists, "the duplicate source intent must be coalesced")
	AssertFalse(_CPT_ClaimExists, "the retained claim must be consumed")
	AssertEqual(0, _CPT_HandoffMoveCalls, "an existing claim already owns the transition")
	AssertEqual(1, _CPT_ToggleCalls, "two suspend intents still describe one desired state")
	AssertEqual(0, _CPT_HandoffFailures)

	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls,
		"coalesced source and claim must not replay on the following boot")
}
Test("AHK-15-persistence: source and retained claim coalesce into one restore",
	_CPT_SourceAndClaimCoalesceIntoOneRestore)

; The recording port cannot infer physical exit from a termination request.
_CPT_ObserveRefusedSuccessorTerminal(Record, Bundle) {
	Port := Record["port"]
	loop 2 {
		AssertTrue(_ReloadTerminalHandoffOwns(Record), "The exact refusal owner stays registered before terminal.")
		AssertEqual(Bundle, Record["bundle"])
		AssertTrue(Bundle.authorized && Bundle.shutdown_claimed, "Claim authority cannot rearm while the child is live.")
		AssertFalse(Record["stop_acknowledged"])
		AssertEqual(0, Port["probe"]["closed"])
		AssertEqual(1, Port["probe"]["terminated"], "The same native request is not retried.")
		_RTP_RunArmed(Port)
	}
	Port["probe"]["alive"] := false
	_RTP_RunArmed(Port)
	_RTP_RunArmed(Port)
	AssertTrue(Record["stop_acknowledged"])
	AssertFalse(_ReloadTerminalHandoffOwns(Record), "The caller gets its bundle only after terminal delivery.")
}
