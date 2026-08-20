; tests/unit/test_feature_io_global_barrier.ahk

; ==============================================================================
; MODULE: Feature I/O Global Barrier Tests
; DESCRIPTION:
; Verifies that both persistent feature writers enter through the process-wide
; configuration transaction gateway before inspecting their explicit target,
; that their live candidate remains detached during durable I/O, and that only
; a successful write publishes into the exact FeaturesMap supplied by the caller.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Transaction test seams =======
; =========================================
; =========================================

global _FIGB_WriteCalls := 0
global _FIGB_NotifyCalls := 0
global _FIGB_EnumCalls := 0
global _FIGB_Target := false
global _FIGB_ObservedDuringWrite := []
global _FIGB_WrittenUpdates := []

_FIGB_Reset(Target := false) {
	global _FIGB_WriteCalls, _FIGB_NotifyCalls, _FIGB_EnumCalls
	global _FIGB_Target, _FIGB_ObservedDuringWrite, _FIGB_WrittenUpdates
	_FIGB_WriteCalls := 0
	_FIGB_NotifyCalls := 0
	_FIGB_EnumCalls := 0
	_FIGB_Target := Target
	_FIGB_ObservedDuringWrite := []
	_FIGB_WrittenUpdates := []
}

_FIGB_Writer(Path, Updates) {
	global _FIGB_WriteCalls, _FIGB_Target
	global _FIGB_ObservedDuringWrite, _FIGB_WrittenUpdates
	_FIGB_WriteCalls += 1
	_FIGB_WrittenUpdates := Updates
	_FIGB_ObservedDuringWrite := [
		_FIGB_Target["layout"]["ergopti_base"],
		_FIGB_Target["shortcuts"]["microsoft_bold"]
	]
	return 1
}

_FIGB_RefusingWriter(Path, Updates) {
	global _FIGB_WriteCalls
	_FIGB_WriteCalls += 1
	return 0
}

_FIGB_Notify(Message, Options) {
	global _FIGB_NotifyCalls
	_FIGB_NotifyCalls += 1
}

_FIGB_EmptyEnumerator(&Entry) {
	return false
}

class _FIGB_ObservedEntries {
	__Enum(NumberOfVars) {
		global _FIGB_EnumCalls
		_FIGB_EnumCalls += 1
		return _FIGB_EmptyEnumerator
	}
}

_FIGB_Fixture() {
	return Map(
		"layout", Map("ergopti_base", false),
		"shortcuts", Map("microsoft_bold", false)
	)
}





; =============================================
; =============================================
; ======= 2/ Barrier admission ordering =======
; =============================================
; =============================================

_FIGB_SingleWriterRefusesSiblingTerminalBarrier() {
	global ConfigurationFile, _FIGB_WriteCalls, _FIGB_NotifyCalls
	OriginalPath := ConfigurationFile
	Target := _FIGB_Fixture()
	_FIGB_Reset(Target)
	ConfigurationFile := "C:\ergopti-tests\feature-io-single.toml"
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\unrelated-paths.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(WriteFeatureV2(Target, "layout.ergopti_base", true, "",
			_FIGB_Writer, _FIGB_Notify),
			"a terminal owner on any path must refuse the single writer")
		AssertEqual(0, _FIGB_WriteCalls,
			"terminal refusal must happen before durable feature I/O")
		AssertFalse(Target["layout"]["ergopti_base"],
			"terminal refusal must not publish the explicit feature target")
		AssertEqual(1, _FIGB_NotifyCalls,
			"the refused user mutation must remain visible")
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		ConfigurationFile := OriginalPath
	}
}
Test("feature_io gateway: sibling terminal barrier refuses the single writer "
	. "(feature-io-global-barrier-single)",
	_FIGB_SingleWriterRefusesSiblingTerminalBarrier)

_FIGB_BatchRefusalDoesNotEnumerateEntries() {
	global ConfigurationFile, _FIGB_WriteCalls, _FIGB_NotifyCalls, _FIGB_EnumCalls
	OriginalPath := ConfigurationFile
	Target := _FIGB_Fixture()
	_FIGB_Reset(Target)
	ConfigurationFile := "C:\ergopti-tests\feature-io-batch.toml"
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\unrelated-paths.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertEqual(0, WriteFeatureBatchV2(Target, _FIGB_ObservedEntries(),
			_FIGB_Writer, _FIGB_Notify),
			"a terminal owner on any path must refuse the batch writer")
		AssertEqual(0, _FIGB_EnumCalls,
			"barrier admission must precede even reading the requested batch")
		AssertEqual(0, _FIGB_WriteCalls)
		AssertFalse(Target["layout"]["ergopti_base"])
		AssertEqual(1, _FIGB_NotifyCalls)
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		ConfigurationFile := OriginalPath
	}
}
Test("feature_io gateway: terminal refusal precedes batch enumeration "
	. "(feature-io-global-barrier-before-read)",
	_FIGB_BatchRefusalDoesNotEnumerateEntries)





; ============================================
; ============================================
; ======= 3/ Detached live publication =======
; ============================================
; ============================================

_FIGB_DurableSuccessPublishesExplicitTargetAfterWrite() {
	global ConfigurationFile, _FIGB_ObservedDuringWrite, _FIGB_WrittenUpdates
	global _FIGB_WriteCalls, _FIGB_NotifyCalls
	OriginalPath := ConfigurationFile
	Target := _FIGB_Fixture()
	_FIGB_Reset(Target)
	ConfigurationFile := "C:\ergopti-tests\feature-io-order.toml"
	try {
		AssertTrue(WriteFeatureV2(Target, "layout.ergopti_base", true, "",
			_FIGB_Writer, _FIGB_Notify))
		AssertEqual(1, _FIGB_WriteCalls)
		AssertFalse(_FIGB_ObservedDuringWrite[1],
			"the single candidate must remain detached during durable I/O")
		AssertFalse(_FIGB_ObservedDuringWrite[2])
		AssertTrue(Target["layout"]["ergopti_base"],
			"durable success must publish into the exact supplied FeaturesMap")
		AssertEqual(1, _FIGB_WrittenUpdates.Length)
		AssertFalse(_FIGB_WrittenUpdates[1].HasOwnProp("Node"),
			"live Map references must not leak into the durable TOML batch")

		Target["layout"]["ergopti_base"] := false
		_FIGB_Reset(Target)
		Entries := [
			Map("path", "layout.ergopti_base", "value", true),
			Map("path", "shortcuts.microsoft_bold", "value", true)
		]
		AssertEqual(2, WriteFeatureBatchV2(Target, Entries,
			_FIGB_Writer, _FIGB_Notify))
		AssertEqual(1, _FIGB_WriteCalls)
		AssertFalse(_FIGB_ObservedDuringWrite[1],
			"the batch candidate must remain detached during durable I/O")
		AssertFalse(_FIGB_ObservedDuringWrite[2])
		AssertTrue(Target["layout"]["ergopti_base"])
		AssertTrue(Target["shortcuts"]["microsoft_bold"])
		AssertEqual(0, _FIGB_NotifyCalls)
	} finally ConfigurationFile := OriginalPath
}
Test("feature_io gateway: durable success publishes detached explicit candidates "
	. "(feature-io-global-barrier-publish-order)",
	_FIGB_DurableSuccessPublishesExplicitTargetAfterWrite)

_FIGB_DurableFailurePublishesNothing() {
	global ConfigurationFile, _FIGB_WriteCalls
	OriginalPath := ConfigurationFile
	Target := _FIGB_Fixture()
	_FIGB_Reset(Target)
	ConfigurationFile := "C:\ergopti-tests\feature-io-failure.toml"
	Entries := [
		Map("path", "layout.ergopti_base", "value", true),
		Map("path", "shortcuts.microsoft_bold", "value", true)
	]
	try {
		AssertEqual(0, WriteFeatureBatchV2(Target, Entries,
			_FIGB_RefusingWriter, _FIGB_Notify))
		AssertEqual(1, _FIGB_WriteCalls)
		AssertFalse(Target["layout"]["ergopti_base"])
		AssertFalse(Target["shortcuts"]["microsoft_bold"],
			"a refused durable batch must publish no live leaf")
	} finally ConfigurationFile := OriginalPath
}
Test("feature_io gateway: refused durable batch publishes nothing "
	. "(feature-io-global-barrier-write-failure)",
	_FIGB_DurableFailurePublishesNothing)
