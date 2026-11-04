; tests/unit/modules/shortcuts/test_shortcuts_extension_results.ahk

; ==============================================================================
; MODULE: Shortcut Extension Observed Results
; DESCRIPTION:
; A shortcut extension's observed outcome selects its presentation without
; replacing the native producers, and the shared construction placement
; restores after a source refusal.
; ==============================================================================

#Requires AutoHotkey v2.0





; Each helper call owns its parameter cells; no getter reads a rebound for variable.
_SMB_ExtensionObservedResultGetters(Observed, ExtId) {
	return Map("shortcut_extension_name", (*) => ExtId,
		"shortcut_extension_builder_failed", (*) => Observed == "failed",
		"shortcut_extension_builder_empty", (*) => Observed == "empty",
		"shortcut_extension_builder_missing", (*) => Observed == "missing")
}


/** Observed status selects presentation; native producers retain callbacks and menus. */
_SMB_ExtensionObservedResultFrame() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\shortcut_presentation_frames.json", "UTF-8"))
	Oracle := Corpus["native_order"]["windows"]["extension"]
	AssertEqual("menu.extensions.empty", Oracle["missing_builder"][1])
	AssertEqual("common.error_prefix + exact ExtId", Oracle["throw_or_empty_builder"][1])
	AssertEqual("exact supplied native Menu retained", Oracle["nonempty"])
	ExtId := "g1-observed-extension"
	for Outcome in ["failed", "empty", "missing", "populated"] {
		Getters := _SMB_ExtensionObservedResultGetters(Outcome, ExtId)
		Rows := MenuRenderer_TemplateRows("shortcut_extension_result_frame", Map(), Getters, Map())
		Assert(Rows is Array, "the genuine observed-result frame must admit")
		AssertEqual(Outcome == "populated" ? 0 : 1, Rows.Length)
		if Rows.Length {
			AssertEqual(Outcome == "missing" ? t(Oracle["missing_builder"][1]) : t("common.error_prefix") . ExtId, Rows[1]["label"])
			AssertEqual(true, Rows[1]["disabled"])
			AssertFalse(Rows[1].Has("action"), "an observation cannot invent a native callback")
		}
	}
	Getters := Map("shortcut_extension_name", (*) => ExtId,
		"shortcut_extension_builder_failed", (*) => true,
		"shortcut_extension_builder_empty", (*) => false,
		"shortcut_extension_builder_missing", (*) => false)
	Getters.Delete("shortcut_extension_builder_missing")
	AssertFalse(MenuRenderer_TemplateRows("shortcut_extension_result_frame", Map(), Getters, Map()),
		"a missing observed predicate refuses the complete selection")
	Getters["shortcut_extension_builder_missing"] := (*) => "false"
	AssertFalse(MenuRenderer_TemplateRows("shortcut_extension_result_frame", Map(), Getters, Map()),
		"a truthy string cannot supply a boolean observation")
}
Test("shortcut extension frame: actual selection preserves the independent outcome oracle", _SMB_ExtensionObservedResultFrame)


/** Supplies actual native extension outcomes without replacing their producer or renderer. */
_SMB_ExtensionObservedNative(Outcome, Mutation := "") {
	global _ExtensionsDir, _SharedDir, _SMB_ObservedState, _MenuDispatchCallbacks
	SavedDir := _ExtensionsDir
	SavedState := IsSet(_SMB_ObservedState) ? _SMB_ObservedState : unset
	Root := A_Temp . "\ergopti-observed-extension-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	ExtId := "g1-observed-" . Outcome
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\shortcut_presentation_frames.json", "UTF-8"))
	Oracle := Corpus["native_order"]["windows"]["extension"]
	Definition := _MM_GetManifestRoot()
	Frame := _MR_GetMenuDef("shortcut_extension_result_frame")
	Menus := [], Row := false, Selected := 0, OldSection := ""
	RootOwned := false, TeardownFailed := false
	try {
		Assert(Frame is Array && Frame.Length == 3, "the actual source has exactly the three observed result selections")
		Expected := Outcome == "missing" ? t(Oracle["missing_builder"][1]) : t("common.error_prefix") . ExtId
		AssertFalse(DirExist(Root), "this fixture starts with a genuinely absent owned temporary directory")
		_ExtensionsDir := Root
		_SMB_ObservedState := Map("calls", 0, "menus", Menus, "late_withdraw", Mutation == "late_withdraw")
		RootOwned := true
		DirCreate(Root . "\" . ExtId . "\shortcuts")
		FileAppend("; The real compiled fixture builder observes this physical source.`n",
			Root . "\" . ExtId . "\shortcuts\menu.ahk", "UTF-8")
		if Mutation == "withdraw" {
			Definition.Delete("shortcut_extension_result_frame")
		} else if Mutation == "mapping" {
			Selected := Outcome == "failed" ? 1 : (Outcome == "empty" ? 2 : 3)
			OldSection := Frame[Selected]["section"]
			Frame[Selected]["section"] := Outcome == "missing" ? "shortcut_extension_error_frame" : "shortcut_extension_empty_frame"
		}
		if Mutation == "withdraw" {
			AssertEqual(0, _SC_ExtensionRows().Length, "the actual complete result source refuses before the native builder")
			AssertEqual(0, _SMB_ObservedState["calls"])
			AssertEqual(0, Menus.Length)
			return
		}
		if Mutation == "late_withdraw" {
			Caught := false
			try _SC_ExtensionRows()
			catch as Failure {
				Caught := true
				AssertEqual("Shortcut extension error marker was withdrawn during its native builder", Failure.Message)
			}
			AssertTrue(Caught, "the genuine late result withdrawal cannot publish the extension")
			AssertEqual(1, _SMB_ObservedState["calls"])
			AssertEqual(1, Menus.Length)
			AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Menus[1].Handle, "int"), "the actual unpublished native owner was cleared")
			return
		}
		Rows := _SC_ExtensionRows()
		if Outcome == "missing"
			_SMB_ObservedRetainOwnedResultMenus(Rows, Menus)
		AssertEqual(3, Rows.Length, "the genuine physical source retains its boundary and one native submenu")
		Row := Rows[3]
		AssertEqual(ExtId, Row["label"])
		AssertEqual(Outcome == "missing" ? 0 : 1, _SMB_ObservedState["calls"])
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Row["submenu"].Handle, "int"))
		Actual := _CTC_LabelAt(Row["submenu"], 0)
		if Outcome == "populated" {
			Assert(Row["submenu"] == Menus[1], Oracle["nonempty"])
			AssertEqual("Observed real callback", Actual)
			Id := DllCall("GetMenuItemID", "ptr", Row["submenu"].Handle, "int", 0, "uint")
			Assert(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == _SMB_ObservedNativeCallback,
				"the supplied native callback identity remains exact")
		} else if Mutation == "mapping" {
			AssertFalse(Actual == Expected, "altering this actual shared selection makes the frozen original native caption disagree")
			Frame[Selected]["section"] := OldSection
			Selected := 0
			Repaired := _SC_ExtensionRows()
			if Outcome == "missing"
				_SMB_ObservedRetainOwnedResultMenus(Repaired, Menus)
			AssertEqual(Expected, _CTC_LabelAt(Repaired[3]["submenu"], 0), "exact source repair restores the frozen native outcome")
		} else {
			AssertEqual(Expected, Actual, "the real native consumer preserves the independent frozen outcome")
			Flags := DllCall("GetMenuState", "ptr", Row["submenu"].Handle, "uint", 0, "uint", 0x400, "uint")
			Assert(Flags != 0xFFFFFFFF && (Flags & 3) != 0, "the original native marker is inert and disabled")
		}
	} catch Any as Failure {
		TeardownFailed := true
		throw Failure
	} finally {
		CleanupFailures := []
		Cleanup := [
			() => _SMB_ObservedCleanupAttempt(CleanupFailures, "selection restore", () => Selected ? (Frame[Selected]["section"] := OldSection) : false),
			() => _SMB_ObservedCleanupAttempt(CleanupFailures, "result source restore", () => Definition["shortcut_extension_result_frame"] := Frame),
			() => _SMB_ObservedCleanupAttempt(CleanupFailures, "extension directory restore", () => _ExtensionsDir := SavedDir),
			() => _SMB_ObservedCleanupAttempt(CleanupFailures, "fixture state restore", () => _SMB_ObservedState := IsSet(SavedState) ? SavedState : unset)]
		for Native in Menus {
			Cleanup.Push(((Owned) => () => _SMB_ObservedCleanupAttempt(CleanupFailures, "owned menu Delete", () => Owned.Delete()))(Native))
			Cleanup.Push(((Owned) => () => _SMB_ObservedCleanupAttempt(CleanupFailures, "owned menu prune", () => MenuDispatcher_PruneMenu(Owned)))(Native))
		}
		Cleanup.Push(() => _SMB_ObservedCleanupAttempt(CleanupFailures, "owned directory delete", () => RootOwned && DirExist(Root) ? DirDelete(Root, true) : false))
		Cleanup.Push(() => _SMB_ObservedCleanupAttempt(CleanupFailures, "independent cleanup report", () => _TestPrint(
			"# ERGOPTI_EXTENSION_OBSERVED_CLEANUP primary_present=" . TeardownFailed . " secondary_count=" . CleanupFailures.Length)))
		_SMB_FrameRunAllCleanup(TeardownFailed, Cleanup*)
		if !TeardownFailed && CleanupFailures.Length
			throw CleanupFailures[1]["failure"]
	}
}

; Only the missing-builder fixture owns these returned top-level Menus. Never walk borrowed children.
_SMB_ObservedRetainOwnedResultMenus(Rows, Menus) {
	if !(Rows is Array)
		return
	for Row in Rows {
		if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
			Menus.Push(Row["submenu"])
	}
}

; Retain raw secondary identity without letting one refusal stop another owned operation.
_SMB_ObservedCleanupAttempt(Failures, Owner, Operation) {
	try Operation.Call()
	catch Any as Failure {
		Failures.Push(Map("owner", Owner, "failure", Failure))
	}
}

_SMB_ObservedNativeBuilder(Native, Outcome) {
	global _SMB_ObservedState
	_SMB_ObservedState["calls"] += 1
	_SMB_ObservedState["menus"].Push(Native)
	if _SMB_ObservedState["late_withdraw"]
		_MM_GetManifestRoot().Delete("shortcut_extension_result_frame")
	if Outcome == "failed"
		throw Error("The actual observed extension fixture builder throws")
	if Outcome == "populated"
		RegisterMenuItem(Native, "Observed real callback", _SMB_ObservedNativeCallback)
}

BuildExtMenu_g1_observed_failed(Native, ExtName) => _SMB_ObservedNativeBuilder(Native, "failed")
BuildExtMenu_g1_observed_empty(Native, ExtName) => _SMB_ObservedNativeBuilder(Native, "empty")
BuildExtMenu_g1_observed_populated(Native, ExtName) => _SMB_ObservedNativeBuilder(Native, "populated")
_SMB_ObservedNativeCallback(*) => 7

for Outcome in ["failed", "empty", "missing", "populated"]
	Test("shortcut extension observed result: genuine " . Outcome . " native outcome", _SMB_ExtensionObservedNative.Bind(Outcome))
for Outcome in ["failed", "empty", "missing"]
	Test("shortcut extension observed result: changed " . Outcome . " selection disagrees then repairs", _SMB_ExtensionObservedNative.Bind(Outcome, "mapping"))
Test("shortcut extension observed result: withdrawn source refuses before native allocation", (*) => _SMB_ExtensionObservedNative("populated", "withdraw"))
Test("shortcut extension observed result: genuine late withdrawal clears the unpublished native owner", (*) => _SMB_ExtensionObservedNative("failed", "late_withdraw"))


; Reuse the original real file/builder/Win32 oracle; never derive its output from the recipe.
_SMB_ExtensionConstructionSelection(Outcome) {
	Root := _MR_GetManifestRoot(), Recipe := Root["shortcut_extension_construction_ahk"]
	Saved := Recipe["append_outcomes"]
	try {
		Changed := []
		for Existing in Saved
			if Existing != Outcome
				Changed.Push(Existing)
		Recipe["append_outcomes"] := Changed
		AssertThrows(() => _SMB_ExtensionObservedNative(Outcome),
			"changing actual shared placement makes the unchanged independent native oracle red")
		Recipe["append_outcomes"] := Saved
		_SMB_ExtensionObservedNative(Outcome)
	} finally Recipe["append_outcomes"] := Saved
}
for _SMB_ConstructionOutcome in ["failed", "empty", "missing"]
	Test("shortcut extension construction: shared placement disagrees then restores " . _SMB_ConstructionOutcome,
		_SMB_ExtensionConstructionSelection.Bind(_SMB_ConstructionOutcome))

_SMB_ExtensionConstructionSourceRefusal() {
	Root := _MR_GetManifestRoot(), Recipe := Root["shortcut_extension_construction_ahk"]
	try {
		Root.Delete("shortcut_extension_construction_ahk")
		AssertThrows(() => _SMB_ExtensionObservedNative("populated"),
			"missing real construction source cannot satisfy the original native oracle")
		Root["shortcut_extension_construction_ahk"] := Recipe
		_SMB_ExtensionObservedNative("populated")
	} finally Root["shortcut_extension_construction_ahk"] := Recipe
}
Test("shortcut extension construction: source refuses then exact native repair restores",
	_SMB_ExtensionConstructionSourceRefusal)
