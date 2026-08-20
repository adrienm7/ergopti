; tests/unit/test_config_write_terminal_barrier.ahk

; ==============================================================================
; MODULE: Process-wide configuration terminal barrier
; DESCRIPTION:
; Proves that a relocation/reload owner excludes every sibling configuration
; path, owns each declared target exactly, and cannot be dismantled through an
; ordinary path-token release. Ordinary in-flight writers also prevent entry.
; ==============================================================================

#Requires AutoHotkey v2.0

_CWTB_TerminalExcludesEverySiblingPath() {
	ConfigPath := "C:\ergopti-tests\terminal\config.toml"
	CandidatePath := "C:/ergopti-tests/candidate/config.toml"
	SiblingPath := "C:\ergopti-tests\terminal\hotstrings_overrides.toml"
	Bundle := _ConfigWriteTerminalTryAcquire(
		[ConfigPath, CandidatePath, StrUpper(ConfigPath)])
	AssertTrue(Bundle is Object)
	try {
		AssertEqual(2, Bundle.tokens.Length,
			"case and slash aliases must not create two physical owners")
		ConfigOwner := _ConfigWriteLeaseSelectOwner(Bundle, ConfigPath)
		CandidateOwner := _ConfigWriteLeaseSelectOwner(Bundle, CandidatePath)
		AssertTrue(ConfigOwner is Object)
		AssertTrue(CandidateOwner is Object)
		AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, SiblingPath) is Object,
			"a bundle may borrow only paths it explicitly owns")
		AssertFalse(_ConfigWriteLeaseTryAcquire(SiblingPath,
			"interrupted-writer") is Object,
			"the terminal barrier must exclude even an unrelated sibling path")
		AssertFalse(_ConfigWriteLeaseRelease(ConfigOwner),
			"an ordinary token release must not dismantle one member of a live bundle")
		AssertTrue(_ConfigWriteLeaseOwns(ConfigOwner, ConfigPath))
	} finally {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
	Sibling := _ConfigWriteLeaseTryAcquire(SiblingPath, "after-terminal")
	AssertTrue(Sibling is Object,
		"ordinary writers must become admissible after exact terminal release")
	AssertTrue(_ConfigWriteLeaseRelease(Sibling))
}
Test("config lease: terminal barrier excludes every sibling path "
	. "(config-write-terminal-barrier)",
	_CWTB_TerminalExcludesEverySiblingPath)

_CWTB_ExistingWriterBlocksTerminalEntry() {
	OwnedPath := "C:\ergopti-tests\ordinary\config.toml"
	OtherPath := "C:\ergopti-tests\relocation\config.toml"
	Owner := _ConfigWriteLeaseTryAcquire(OwnedPath, "ordinary")
	AssertTrue(Owner is Object)
	try {
		AssertFalse(_ConfigWriteTerminalTryAcquire([OtherPath]) is Object,
			"terminal entry must never leapfrog an already-admitted writer")
		AssertTrue(_ConfigWriteLeaseOwns(Owner, OwnedPath),
			"a refused terminal attempt must not disturb the existing writer")
	} finally {
		AssertTrue(_ConfigWriteLeaseRelease(Owner))
	}
	Bundle := _ConfigWriteTerminalTryAcquire([OtherPath])
	AssertTrue(Bundle is Object)
	AssertTrue(_ConfigWriteTerminalRelease(Bundle))
}
Test("config lease: an admitted writer blocks terminal entry "
	. "(config-write-terminal-barrier-existing-owner)",
	_CWTB_ExistingWriterBlocksTerminalEntry)

_CWTB_ShutdownClaimNeedsExactAuthorization() {
	Path := "C:\ergopti-tests\terminal\authorized.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"shutdown cannot borrow an unannounced transition")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"the exact terminal authority may be claimed only once")
	} finally {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
}
Test("config lease: terminal shutdown authority is explicit and single-use "
	. "(config-write-terminal-barrier-authorized-claim)",
	_CWTB_ShutdownClaimNeedsExactAuthorization)

_CWTB_RefusedShutdownCanRearmOnlyExactLiveBundle() {
	Path := "C:\ergopti-tests\terminal\rearmed.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		Lookalike := { kind: "terminal_bundle", id: Bundle.id,
			tokens: Bundle.tokens, authorized: true, shutdown_claimed: true }
		AssertFalse(_ConfigWriteTerminalCancelShutdown(Lookalike),
			"a same-id lookalike must not rearm the live shutdown authority")
		AssertTrue(Bundle.shutdown_claimed,
			"a refused lookalike must leave the genuine claim latched")
		AssertTrue(_ConfigWriteTerminalCancelShutdown(Bundle))
		AssertFalse(Bundle.authorized,
			"cancel must require the next handoff to authorize explicitly")
		AssertFalse(Bundle.shutdown_claimed,
			"cancel must make the retained terminal bundle claimable again")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle),
			"the exact retained bundle must support a later Reload attempt")
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("config lease: refusal rearms only the exact live terminal bundle "
	. "(config-write-terminal-barrier-rearm-exact)",
	_CWTB_RefusedShutdownCanRearmOnlyExactLiveBundle)
