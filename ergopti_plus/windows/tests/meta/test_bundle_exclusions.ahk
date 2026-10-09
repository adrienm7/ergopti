; tests/meta/test_bundle_exclusions.ahk

; ==============================================================================
; MODULE: Bundle Exclusion Invariants Test
; DESCRIPTION:
; Verifies that machine-specific runtime files are excluded from the static
; bundle declared by tools/build/windows_bundle_manifest.json. Embedding these
; files would bake a developer-machine absolute path into every distributed EXE,
; causing the forwarding stub (personal_shortcuts.ahk) or the config-dir
; override (paths.toml) to point at a non-existent path on any other install.
;
; CHECKED INVARIANTS:
; 1. personal_shortcuts.ahk is excluded wherever it appears. At runtime
;    EnsurePersonalShortcutsFile() writes the stub to
;    %LOCALAPPDATA%\Ergopti\_generated\ — the bundle copy is never loaded via
;    #Include (ErgoptiPlus.ahk resolves it from %LOCALAPPDATA%), so shipping it
;    only adds a stale hardcoded path with no benefit.
; 2. paths.toml is excluded the same way. The file contains a machine-specific
;    ConfigDirPath override and lives under %APPDATA%\Ergopti\ at runtime — a
;    development copy is always the developer's local path.
; tools/test/test-windows-bundle-manifest.cjs proves on the resolved selection
; that neither ships; this test keeps the declaration from being dropped.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckBundleExclusions() {
	; Resolve the bundle manifest relative to the tests/ directory.
	; tests/ sits at  static/ergopti_plus/windows/tests/
	; manifest at     tools/build/windows_bundle_manifest.json
	SplitPath(A_ScriptDir, , &TestsParent)      ; windows/
	SplitPath(TestsParent, , &WindowsParent)    ; ergopti_plus/
	SplitPath(WindowsParent, , &EpParent)       ; static/
	SplitPath(EpParent, , &RepoRoot)            ; repo root
	ManifestPath := RepoRoot . "\tools\build\windows_bundle_manifest.json"

	; The suite runs from a checkout, which always has the manifest: a missing
	; one fails here instead of passing without checking anything.
	Assert(FileExist(ManifestPath) != "", "windows_bundle_manifest.json not found at " . ManifestPath)
	Body := FileRead(ManifestPath, "UTF-8")

	; Each glob matches the file in any included tree, so a later include of the
	; directory that holds a development copy cannot ship it.
	Assert(InStr(Body, '"**/personal_shortcuts.ahk"'),
		"windows_bundle_manifest.json must exclude **/personal_shortcuts.ahk from the bundle "
		. "(machine-specific forwarding stub — baking it in embeds a hardcoded dev path)")

	Assert(InStr(Body, '"**/paths.toml"'),
		"windows_bundle_manifest.json must exclude **/paths.toml from the bundle "
		. "(machine-specific ConfigDirPath override — baking it in embeds a hardcoded dev path)")
}

Test("meta bundle: personal_shortcuts.ahk and paths.toml excluded from static bundle",
	_MetaCheckBundleExclusions)
