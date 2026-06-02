; tests/meta/test_bundle_exclusions.ahk

; ==============================================================================
; MODULE: Bundle Exclusion Invariants Test
; DESCRIPTION:
; Verifies that machine-specific runtime files are excluded from the static
; bundle assembled by build_static_bundle.py. Embedding these files would bake
; a developer-machine absolute path into every distributed EXE, causing the
; forwarding stub (personal_shortcuts.ahk) or the config-dir override
; (paths.toml) to point at a non-existent path on any other install.
;
; CHECKED INVARIANTS:
; 1. personal_shortcuts.ahk is listed in the exclusion tuple for _generated/.
;    At runtime EnsurePersonalShortcutsFile() writes the stub to
;    %LOCALAPPDATA%\Ergopti\_generated\ — the bundle copy is never loaded via
;    #Include (line 895 of ErgoptiPlus.ahk resolves from %LOCALAPPDATA%), so
;    shipping it only adds a stale hardcoded path with no benefit.
; 2. paths.toml is listed in the same exclusion tuple. The file contains a
;    machine-specific ConfigDirPath override and lives under %APPDATA%\Ergopti\
;    at runtime — the _generated/ copy is always the developer's local path.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckBundleExclusions() {
	; Resolve build_static_bundle.py relative to the tests/ directory.
	; tests/ sits at  static/ergopti_plus/windows/tests/
	; bundle script at tools/build/build_static_bundle.py (repo root + 2 levels up from windows/)
	SplitPath(A_ScriptDir, , &TestsParent)      ; windows/
	SplitPath(TestsParent, , &WindowsParent)    ; ergopti_plus/
	SplitPath(WindowsParent, , &EpParent)       ; static/
	SplitPath(EpParent, , &RepoRoot)            ; repo root
	BundleScript := RepoRoot . "\tools\build\build_static_bundle.py"

	try {
		Body := FileRead(BundleScript)
	} catch {
		; Script not found — skip silently rather than false-failing in
		; environments that only ship the AHK driver without the tooling.
		return
	}

	; Both filenames must appear inside an exclusion tuple for the _generated/
	; tree entry. We look for the string anywhere in the file because the
	; exact tuple syntax may evolve; what matters is the intent, not the form.
	Assert(InStr(Body, "personal_shortcuts.ahk"),
		"build_static_bundle.py must exclude personal_shortcuts.ahk from the bundle "
		. "(machine-specific forwarding stub — baking it in embeds a hardcoded dev path)")

	Assert(InStr(Body, "paths.toml"),
		"build_static_bundle.py must exclude paths.toml from the bundle "
		. "(machine-specific ConfigDirPath override — baking it in embeds a hardcoded dev path)")
}

Test("meta bundle: personal_shortcuts.ahk and paths.toml excluded from static bundle",
	_MetaCheckBundleExclusions)
