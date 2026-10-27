; tests/support/config_journal_fixtures.ahk

; ==============================================================================
; MODULE: Native Configuration Journal Fixture Support
; DESCRIPTION:
; Shares the genuine read-only source preparation between full and isolated
; suites. Fixtures retain original metadata and never forge journal readiness.
; ==============================================================================

#Requires AutoHotkey v2.0

; Native fixtures author their own metadata instead of forging journal READY.
; Read-only legacy corpus bytes remain exact; this helper never migrates them.
_CMJFixtureReadonly(Path) {
	if !ConfigMigrateBoot(Path, "known")
		ConfigSchemaPrepareSource(Path)
}
