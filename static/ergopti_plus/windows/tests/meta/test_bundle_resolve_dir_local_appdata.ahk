; tests/meta/test_bundle_resolve_dir_local_appdata.ahk

; ==============================================================================
; MODULE: Bundle ResolveDir LocalAppData Regression Test
; DESCRIPTION:
; Guards the startup crash where ``_Bundle_ResolveDir()`` referenced a
; nonexistent ``A_LocalAppData`` built-in directly. AHK v2 has no such
; variable — only ``EnvGet("LOCALAPPDATA")`` resolves it — so AHK silently
; auto-declared ``A_LocalAppData`` as an unassigned local and threw
; "This local variable has not been assigned a value" the instant
; ``Bundle_Init()`` ran, which is the very first call in ErgoptiPlus.ahk's
; auto-execute section (before Logger even exists to record the failure).
; Every compiled launch crashed on this line.
;
; The previous version of this test only grepped the raw source text for the
; substring "A_LocalAppData" — it never called the function, so it could not
; have caught the crash; worse, it actively enforced the buggy pattern by
; asserting the substring's presence. lib/bundle.ahk was also never
; #Include'd into run_all.ahk, so nothing here ever executed at runtime. Both
; gaps are fixed: bundle.ahk is now wired into the runner (see run_all.ahk)
; and these tests call the real functions.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_BRDL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}



; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

; The real regression guard: calling the function must not throw and must
; return a plausible, non-empty path. Before the fix this line threw
; "This local variable has not been assigned a value" on every call.
; No exception expected — call directly rather than wrapping in try, so a
; regression to a throwing built-in (e.g. bare A_LocalAppData) fails this
; test loudly instead of being swallowed.
_BRDL_CheckResolveDirExecutesAndReturnsPath() {
	BundleDir := _Bundle_ResolveDir()
	AssertTrue(BundleDir != "", "_Bundle_ResolveDir() must return a non-empty path — got empty "
		. "(Local AppData could not be resolved in this environment)")
	AssertContains(BundleDir, "\Ergopti\bundle", "_Bundle_ResolveDir() must end with \Ergopti\bundle")
	; The prefix before "\Ergopti\bundle" must be a real filesystem root
	; (drive letter or UNC), not an empty/garbage prefix — this is exactly
	; what the unassigned-variable bug used to produce once caught by a bare
	; try (empty string concatenated with the suffix).
	Prefix := StrReplace(BundleDir, "\Ergopti\bundle", "")
	AssertTrue(Prefix != "", "_Bundle_ResolveDir() prefix (Local AppData root) must not be empty")
	AssertTrue(RegExMatch(Prefix, "^[A-Za-z]:\\") || SubStr(Prefix, 1, 2) == "\\",
		"_Bundle_ResolveDir() prefix must look like a real path, got: " . Prefix)
}

; ResolveLocalAppDataDir() is the single shared helper — verify it agrees
; with EnvGet("LOCALAPPDATA") directly, which is always set on any real
; Windows environment (dev machine or CI runner).
_BRDL_CheckResolveLocalAppDataDirMatchesEnv() {
	Expected := EnvGet("LOCALAPPDATA")
	AssertTrue(Expected != "", "test environment must have %LOCALAPPDATA% set for this assertion to be meaningful")
	AssertEqual(Expected, ResolveLocalAppDataDir(),
		'ResolveLocalAppDataDir() must return EnvGet("LOCALAPPDATA") when it is set')
}

_BRDL_CheckNoDoubleDot() {
	Src := _BRDL_ReadSource("lib/bundle.ahk")
	Assert(Src != "", "lib/bundle.ahk must be readable")

	Body := _DriverFuncBody("_Bundle_ResolveDir")
	Assert(Body != "", "_Bundle_ResolveDir must be present in lib/bundle.ahk")

	Assert(!InStr(Body, '".."') && !InStr(Body, '"\.."'),
		"_Bundle_ResolveDir must not use A_AppData with a '..' segment to reach LocalAppData")
}

; Regression guard against reintroducing the exact crash: _Bundle_ResolveDir
; must delegate to the shared, EnvGet-based resolver rather than referencing
; the nonexistent A_LocalAppData built-in directly.
_BRDL_CheckUsesSharedResolver() {
	Src := _BRDL_ReadSource("lib/bundle.ahk")
	Assert(Src != "", "lib/bundle.ahk must be readable")

	Body := _DriverFuncBody("_Bundle_ResolveDir")
	Assert(Body != "", "_Bundle_ResolveDir must be present in lib/bundle.ahk")

	Assert(!InStr(Body, "A_LocalAppData"),
		"_Bundle_ResolveDir must not reference the nonexistent A_LocalAppData built-in "
		. "directly — it threw on every compiled launch; use ResolveLocalAppDataDir() instead")

	Assert(InStr(Body, "ResolveLocalAppDataDir"),
		"_Bundle_ResolveDir must resolve Local AppData via the shared ResolveLocalAppDataDir() helper")
}


Test("meta bundle-resolve-dir: _Bundle_ResolveDir() executes without throwing and returns a real path",
	_BRDL_CheckResolveDirExecutesAndReturnsPath)

Test('meta bundle-resolve-dir: ResolveLocalAppDataDir() matches EnvGet("LOCALAPPDATA")',
	_BRDL_CheckResolveLocalAppDataDirMatchesEnv)

Test("meta bundle-resolve-dir: does not use A_AppData with '..' traversal",
	_BRDL_CheckNoDoubleDot)

Test("meta bundle-resolve-dir: uses the shared ResolveLocalAppDataDir() helper, not A_LocalAppData",
	_BRDL_CheckUsesSharedResolver)
