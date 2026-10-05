; tests/unit/test_local_server_retained_fixture_join.ahk

; ==============================================================================
; MODULE: Sequential Actual Scope and Private Publication Fixture Ownership
; DESCRIPTION:
; Runs the actual recovered scope cohorts before the actual private publisher.
; Exact outer marker equality is observed after each independently owned fixture.
; No production owner, assertion, expected corpus or registry reset is replaced.
; Load after scope fixtures and test_local_server_private_publication.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Sequential Actual Owners =======
; ===========================================
; ===========================================

_LSRFJ_SequentialCohorts() {
	Outer := ConfigTransitionRetainedBarrier()
	AssertFalse(Outer is Object, "the fresh sequential fixture cannot borrow foreign retained debt")
	_ScopeOwnerRetainsRollbackDebt()
	AssertTrue(ConfigTransitionRetainedBarrier() == Outer,
		"the actual scoped recovery must retire only its exact retained marker")
	_HotstringsScopeRecoveryDebt()
	AssertTrue(ConfigTransitionRetainedBarrier() == Outer,
		"the later actual hotstrings cohort must also retire its own recovered marker")
	_GlobalScopeComposition("clear", "debt")
	AssertTrue(ConfigTransitionRetainedBarrier() == Outer,
		"the actual global cohort must not leave its released marker for a successor")
	_LSP_WithWorld(_LSP_ApplicationDebt)
	AssertTrue(ConfigTransitionRetainedBarrier() == Outer,
		"the actual private publisher must retain its own debt and restore its outer owner")
	AssertFalse(_ConfigWriteTerminalIsActive())
}
Test("Local server fixtures: sequential actual scope cohorts cannot lend retired markers to private publication (local-server-retained-fixture-join)",
	_LSRFJ_SequentialCohorts)
