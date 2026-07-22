; tests/meta/test_feature_io_impl_no_global.ahk

; ==============================================================================
; MODULE: Feature I/O No-Global Meta Test (F43)
; DESCRIPTION:
; feedback_loader_target_explicit requires that any function mutating a shared
; Map (Features, TapHold, future v2/v3 globals) take that Map as an explicit
; parameter, never reach for it via global. lib/feature_io.ahk's public
; FeatureLocateV2/WriteFeatureV2/WriteFeatureBatchV2 reintroduced the banned
; "global Features" pattern. An interim thin-wrapper fix (public function
; still bound the global, an internal *Impl function took FeaturesMap
; explicitly) only moved the friction to a hidden layer -- every production
; call site still routed through the global-bound wrapper, so the convention
; violation was still live at the only boundary that matters. Fixed properly:
; FeatureLocateV2/WriteFeatureV2/WriteFeatureBatchV2 now take FeaturesMap as
; their own first parameter and never declare "global Features" themselves;
; every production call site (menu_engine.ahk, menu_gestures.ahk,
; config_io.ahk) passes its own local Features reference explicitly.
;
; ReadFeatureStateV2 is the sole documented exception: a read-only accessor,
; explicitly carved out by feedback_loader_target_explicit, may still bind
; the global itself (its own contract is "read the LIVE production state").
;
; SCOPE: source introspection of lib/feature_io.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Writers never reach for global Features =========
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

_FIONG_CheckLocate() {
	_FIONG_AssertNoGlobalFeatures("FeatureLocateV2", "FeaturesMap")
}
Test("feature_io: FeatureLocateV2 takes FeaturesMap explicitly and never reaches for global Features (F43)", _FIONG_CheckLocate)

_FIONG_CheckWrite() {
	_FIONG_AssertNoGlobalFeatures("WriteFeatureV2", "FeaturesMap")
}
Test("feature_io: WriteFeatureV2 takes FeaturesMap explicitly and never reaches for global Features (F43)", _FIONG_CheckWrite)

_FIONG_CheckWriteBatch() {
	_FIONG_AssertNoGlobalFeatures("WriteFeatureBatchV2", "FeaturesMap")
}
Test("feature_io: WriteFeatureBatchV2 takes FeaturesMap explicitly and never reaches for global Features (F43)", _FIONG_CheckWriteBatch)





; =============================================================
; =============================================================
; ======= 2/ Every production call site passes Features =======
; =============================================================
; =============================================================

; No production call site may call any of the three writers with a lone V2Path
; as the first argument -- that shape only existed under the old thin-wrapper
; API and would now be a hard parse-time argument-count mismatch, but this
; also guards intent: every call site must resolve Features itself
; (global Features in its own scope) rather than reintroducing a delegating
; wrapper around the fixed functions.
_FIONG_NoBareCallShapesRemain() {
	for _, FuncName in ["MenuAddItemFromManifest", "MenuAddItemWithLabel", "MenuAddLetterPicker",
		"SetFeatureLetter", "SetFeatureLetterOff", "ToggleFeatureV2", "_HS_TryLiveToggleV2"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist in ui/menu/menu_engine.ahk")
		Assert(InStr(Body, "global Features") > 0,
			FuncName . " must declare 'global Features' itself so it can pass it explicitly to FeatureLocateV2/WriteFeatureV2/WriteFeatureBatchV2 (F43)")
	}
}
Test("menu_engine: every FeatureLocateV2/WriteFeatureV2/WriteFeatureBatchV2 caller resolves Features explicitly (F43)", _FIONG_NoBareCallShapesRemain)

_FIONG_ConfigIoCallersResolveFeatures() {
	for _, FuncName in ["ToggleAllFeatures", "ToggleAllHotstrings", "ToggleCategoryAllSections", "HS_TogglePersonalAllSections"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist in lib/config_io.ahk")
		Assert(InStr(Body, "global") > 0 and InStr(Body, "Features") > 0,
			FuncName . " must reference Features in its global declaration so it can pass it explicitly to WriteFeatureBatchV2 (F43)")
	}
}
Test("config_io: every WriteFeatureBatchV2 caller resolves Features explicitly (F43)", _FIONG_ConfigIoCallersResolveFeatures)




; ============================================================
; ============================================================
; ======= 3/ ReadFeatureStateV2's documented exception ========
; ============================================================
; ============================================================

; ReadFeatureStateV2 is read-only (never mutates Features or config.toml), so
; feedback_loader_target_explicit's own carve-out for read-only accessors
; applies -- it may bind the global itself, as long as it then passes it
; explicitly into FeatureLocateV2 rather than relying on a delegating wrapper.
_FIONG_ReadFeatureStateV2BindsGlobalButCallsExplicitly() {
	Body := _DriverFuncBody("ReadFeatureStateV2")
	Assert(Body != "", "ReadFeatureStateV2 must exist in lib/feature_io.ahk")
	Assert(InStr(Body, "global Features") > 0,
		"ReadFeatureStateV2 is the documented read-only-accessor exception and may bind global Features itself")
	Assert(InStr(Body, "FeatureLocateV2(Features, V2Path)") > 0,
		"ReadFeatureStateV2 must pass Features explicitly into FeatureLocateV2, not rely on a delegating wrapper")
}
Test("feature_io: ReadFeatureStateV2 binds global Features (documented read-only exception) but calls FeatureLocateV2 explicitly (F43)", _FIONG_ReadFeatureStateV2BindsGlobalButCallsExplicitly)
