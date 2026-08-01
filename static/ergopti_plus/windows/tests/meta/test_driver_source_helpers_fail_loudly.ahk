; tests/meta/test_driver_source_helpers_fail_loudly.ahk

; ==============================================================================
; MODULE: Driver-Source Helper Fail-Loudly Meta Test
; DESCRIPTION:
; Guards the safety net that every source-introspection test in this suite is
; built on: _DriverFuncBody() and _DriverDirConcat() must THROW when they find
; nothing, never return "".
;
; ROOT CAUSE THIS ENCODES:
; Both helpers used to return "" when the function or the directory was missing.
; InStr("", Needle) is 0, so a "must NOT contain X" assertion — the dominant
; shape in tests/meta/ — passed VACUOUSLY the moment a symbol was renamed or a
; directory moved. Hundreds of guarantees could be disarmed by a rename that
; left the suite fully green, and test-no-pinned-source-reads.cjs certified the
; callers as move-resilient precisely BECAUSE they routed through these helpers.
; Making the helpers throw converts every such rename from a silent green into a
; named red that says which symbol went missing.
;
; The tolerant variant _DriverFuncBodyOrEmpty() stays available for the handful
; of tests whose assertion IS the absence ("this retired helper must stay
; deleted"); it is covered here so it cannot start throwing by accident either.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Names that can never exist ============
; ==================================================
; ==================================================

; A symbol and a directory chosen so no plausible refactor ever creates them.
global _DSHFL_ABSENT_FUNC := "_DshflNoSuchFunctionEverDefined"
global _DSHFL_ABSENT_DIR := "infra/no_such_directory_ever_created"


_DSHFL_MissingFunctionThrows() {
	AssertThrows(() => _DriverFuncBody(_DSHFL_ABSENT_FUNC),
		'_DriverFuncBody must THROW on a symbol it cannot find — returning "" made every "must not contain" assertion downstream pass vacuously after a rename')
}
Test("meta source-helpers: _DriverFuncBody throws on a missing symbol (driver-source-helpers-return-empty)",
	_DSHFL_MissingFunctionThrows)


_DSHFL_MissingDirectoryThrows() {
	AssertThrows(() => _DriverDirConcat(_DSHFL_ABSENT_DIR),
		"_DriverDirConcat must THROW on a directory holding no .ahk file — the directory name is the one thing the helper hardcodes, so a rename is exactly what it has to catch")
}
Test("meta source-helpers: _DriverDirConcat throws on a missing directory (driver-source-helpers-return-empty)",
	_DSHFL_MissingDirectoryThrows)


; The tolerant variant is the documented escape hatch. If it ever started
; throwing too, the absence assertions that depend on it would turn red with no
; way to express "this symbol must stay deleted".
_DSHFL_TolerantVariantStaysTolerant() {
	AssertEqual("", _DriverFuncBodyOrEmpty(_DSHFL_ABSENT_FUNC),
		'_DriverFuncBodyOrEmpty must return "" for a missing symbol — it is what the deliberate-absence assertions are written against')
}
Test("meta source-helpers: _DriverFuncBodyOrEmpty still tolerates absence (driver-source-helpers-return-empty)",
	_DSHFL_TolerantVariantStaysTolerant)




; ==================================================
; ==================================================
; ======= 2/ Positive controls =====================
; ==================================================
; ==================================================

; Without these, a helper that threw unconditionally would satisfy section 1 and
; take the entire suite down to "everything is missing".
_DSHFL_RealSymbolStillResolves() {
	Body := _DriverFuncBody("HSE_FeedBackspace")
	Assert(InStr(Body, "HSE_FeedBackspace(") > 0,
		"_DriverFuncBody must still return the real body of a function that exists — section 1 alone is satisfied by a helper that throws on everything")
}
Test("meta source-helpers: a real symbol still resolves (driver-source-helpers-return-empty)",
	_DSHFL_RealSymbolStillResolves)


_DSHFL_RealDirectoryStillResolves() {
	Src := _DriverDirConcat("infra/hotstrings")
	Assert(StrLen(Src) > 1000,
		"_DriverDirConcat must still concatenate a directory that exists — a helper that throws on everything would otherwise pass section 1")
}
Test("meta source-helpers: a real directory still resolves (driver-source-helpers-return-empty)",
	_DSHFL_RealDirectoryStillResolves)
