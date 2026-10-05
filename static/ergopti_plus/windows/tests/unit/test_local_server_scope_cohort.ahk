; tests/unit/test_local_server_scope_cohort.ahk

; ==============================================================================
; MODULE: Actual Scope Recovery and AI Refusal Cohort
; DESCRIPTION:
; Replays the real scope rollback fixture before each existing private-file or
; JOIN refusal body. No registry value is cleared or substituted by this file.
; The actual assertions, private files, DPAPI, WAL and runtime owners are reused.
; A clean --only cohort proves fixture settlement, not physical UI/network use.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Actual Native Sequence =======
; =========================================
; =========================================

_LSRC_RunNativeRefusalAfterScope(Scenario) {
	PriorRetained := ConfigTransitionRetainedBarrier()
	AssertFalse(_ConfigWriteTerminalIsActive(), "the cohort cannot borrow a live foreign terminal")
	_ScopeOwnerRetainsRollbackDebt()
	; The original private/JOIN body verifies the newly retained exact bundle.
	; Do not replace its writer, source ownership or physical private-file ports.
	Scenario.Call()
	AssertFalse(_ConfigWriteTerminalIsActive(), "the exact fixture terminal must be retired after its assertions")
	AssertTrue(ConfigTransitionRetainedBarrier() == PriorRetained, "the original registry owner must survive the completed sequence")
}

Test("local scope refusal cohort: application debt follows actual recovered scope", _LSRC_RunNativeRefusalAfterScope.Bind((*) => _LSP_WithWorld(_LSP_ApplicationDebt)))
Test("local scope refusal cohort: cleanup debt follows actual recovered scope", _LSRC_RunNativeRefusalAfterScope.Bind((*) => _LSP_WithWorld(_LSP_CleanupDebt)))
Test("local scope refusal cohort: foreign durable bytes follow actual recovered scope", _LSRC_RunNativeRefusalAfterScope.Bind((*) => _LSP_WithWorld(_LSP_PostDurableForeignImage)))
Test("local scope refusal cohort: missing journal follows actual recovered scope", _LSRC_RunNativeRefusalAfterScope.Bind((*) => _LSP_WithWorld(_LSP_MissingWalDebt)))
Test("local scope refusal cohort: joined foreign image follows actual recovered scope", _LSRC_RunNativeRefusalAfterScope.Bind(_LSJ_ForeignImageDebt))
Test("local scope refusal cohort: actual locked journal follows recovered scope", _LSRC_RunNativeRefusalAfterScope.Bind(_LSJ_PhysicalCleanupDebt))
