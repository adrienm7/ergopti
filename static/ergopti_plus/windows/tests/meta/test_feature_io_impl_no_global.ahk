; tests/meta/test_feature_io_impl_no_global.ahk

; ==============================================================================
; MODULE: Feature I/O Impl No-Global Meta Test (F43)
; DESCRIPTION:
; feedback_loader_target_explicit requires that any function mutating a shared
; Map (Features, TapHold, future v2/v3 globals) take that Map as an explicit
; parameter, never reach for it via global. lib/feature_io.ahk's public
; FeatureLocateV2/WriteFeatureV2/WriteFeatureBatchV2 reintroduced the banned
; "global Features" pattern inside the mutating logic itself; fixed by splitting
; each into a thin public wrapper (still reads the global -- zero call-site
; churn for the 11 production callers) and an internal *Impl function that
; takes FeaturesMap explicitly and never touches a global for it.
;
; SCOPE: source introspection of lib/feature_io.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Impl functions never reach for global Features ==
; ============================================================
; ============================================================

_FIONG_AssertNoGlobalFeatures(FuncName, ExplicitParamName) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in lib/feature_io.ahk")
	Assert(InStr(Body, "global Features") = 0,
		FuncName . " must not declare 'global Features' -- the target Map must be an explicit parameter (feedback_loader_target_explicit)")
	Assert(InStr(Body, "(" . ExplicitParamName) > 0 or InStr(Body, ", " . ExplicitParamName) > 0,
		FuncName . " must take " . ExplicitParamName . " as an explicit parameter")
}

_FIONG_CheckLocateImpl() {
	_FIONG_AssertNoGlobalFeatures("_FeatureLocateV2Impl", "FeaturesMap")
}
Test("feature_io: _FeatureLocateV2Impl takes FeaturesMap explicitly and never reaches for global Features (F43)", _FIONG_CheckLocateImpl)

_FIONG_CheckWriteImpl() {
	_FIONG_AssertNoGlobalFeatures("_WriteFeatureV2Impl", "FeaturesMap")
}
Test("feature_io: _WriteFeatureV2Impl takes FeaturesMap explicitly and never reaches for global Features (F43)", _FIONG_CheckWriteImpl)

_FIONG_CheckWriteBatchImpl() {
	_FIONG_AssertNoGlobalFeatures("_WriteFeatureBatchV2Impl", "FeaturesMap")
}
Test("feature_io: _WriteFeatureBatchV2Impl takes FeaturesMap explicitly and never reaches for global Features (F43)", _FIONG_CheckWriteBatchImpl)

; Sanity check the OTHER direction too: the public wrappers ARE still expected
; to read the global (that is the whole point of "thin wrapper, zero call-site
; churn") -- guards against someone "fixing" this by deleting the wrappers'
; global read without rewiring all 11 production call sites.
_FIONG_CheckWrappersStillBindGlobal() {
	LocateWrapper := _DriverFuncBody("FeatureLocateV2")
	Assert(InStr(LocateWrapper, "global Features") > 0,
		"FeatureLocateV2 (the public wrapper) must still bind the production Features global -- it is the thin adapter every existing call site relies on")
	WriteWrapper := _DriverFuncBody("WriteFeatureV2")
	Assert(InStr(WriteWrapper, "global Features") > 0,
		"WriteFeatureV2 (the public wrapper) must still bind the production Features global")
	BatchWrapper := _DriverFuncBody("WriteFeatureBatchV2")
	Assert(InStr(BatchWrapper, "global Features") > 0,
		"WriteFeatureBatchV2 (the public wrapper) must still bind the production Features global")
}
Test("feature_io: public wrappers still bind global Features so no call site needs to change (F43)", _FIONG_CheckWrappersStillBindGlobal)
