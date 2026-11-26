; tests/meta/settings/persistence/test_window_patch_toml_meta_error.ahk

; ==============================================================================
; MODULE: HCW metadata transaction error handling guard
; DESCRIPTION:
; Guards the original "hcw-patch-toml-meta-bare-try" failure after ownership
; and atomic publication moved into shared personal TOML helpers. The HCW
; wrapper must delegate, and the terminal atomic boundary must still catch and
; log injected writer/replacement failures instead of swallowing them. It also
; guards the HCW mutation-handler class: the WebView handlers must not announce
; success after any persistence backend refuses a write, and a refused write
; must still reconcile the page with canonical state so the rejected candidate
; does not remain visible. The native window and its numeric debounce were
; removed with the native fallback (maintainer decision 2026-11-21).
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../../../hotstrings/ui/hotstrings_config_window/hcw_helpers.ahk
#Include ../../../../hotstrings/ui/hotstrings_config_window/hcw_mutations.ahk
#Include ../../../../hotstrings/ui/hotstrings_config_window/webview.ahk
_PTME_PatchTomlMetaHasCatch() {
	PatcherBody := _DriverFuncBody("_HCW_PatchTomlMeta")
	Assert(InStr(PatcherBody, "_PersonalTomlCommitPatch(") > 0,
		"_HCW_PatchTomlMeta must route failures through the owned transaction helper")
	TransactionBody := _DriverFuncBody("_PersonalTomlCommitPatch")
	Assert(InStr(TransactionBody, "_PersonalTomlWriteAtomic(") > 0,
		"the owned transaction must delegate terminal publication to the atomic writer")
	AtomicBody := _DriverFuncBody("_PersonalTomlWriteAtomic")
	Assert(InStr(AtomicBody, "catch as Err") > 0,
		"the atomic writer must catch injected writer and replacement exceptions")
	Assert(InStr(AtomicBody, "LoggerError") > 0,
		"the atomic writer must log every caught publication failure")
}
Test("hotstrings_config_window: delegated metadata publication logs failures",
	_PTME_PatchTomlMetaHasCatch)

; One invalid value per call, so the formatter closure reads a parameter. A
; closure never sees a for-loop variable: built in the loop, it threw an
; UnsetError that AssertThrows accepted whatever _HCW_TomlValue did.
; @param Invalid {Any} A priority outside the integers 0 through 100.
_PTME_InvalidPriorityCase(Invalid) {
	AssertFalse(_HCW_SetOverride({}, "", "priority", Invalid),
		"the HCW boundary must reject an invalid priority before reading its backend entry: " . String(Invalid))
	AssertThrows(() => _HCW_TomlValue("priority", Invalid),
		"the personal TOML formatter must fail closed on an invalid priority: " . String(Invalid))
}

_PTME_InvalidPriorityCannotReachPersonalBackend() {
	for Invalid in [-1, 101, 1.5, "50", 1.0e300]
		_PTME_InvalidPriorityCase(Invalid)
	AssertEqual("0", _HCW_TomlValue("priority", 0),
		"the lower priority boundary must remain serialisable")
	AssertEqual("100", _HCW_TomlValue("priority", 100),
		"the upper priority boundary must remain serialisable")
}
Test("hotstrings_config_window: invalid priority cannot reach personal persistence",
	_PTME_InvalidPriorityCannotReachPersonalBackend)

; One invalid value per call, for the same reason as _PTME_InvalidPriorityCase.
; @param Invalid {Any} A tooltip value other than the integers 0 and 1.
_PTME_InvalidTooltipBooleanCase(Invalid) {
	AssertFalse(_HCW_SetOverride({}, "", "show_tooltip", Invalid),
		"the HCW boundary must reject an invalid tooltip Boolean before reading its backend entry: " . String(Invalid))
	AssertThrows(() => _HCW_TomlValue("show_tooltip", Invalid),
		"the personal TOML formatter must fail closed on an invalid tooltip Boolean: " . String(Invalid))
}

_PTME_InvalidTooltipBooleanCannotReachPersonalBackend() {
	for Invalid in ["false", "true", 2, -1, 0.5]
		_PTME_InvalidTooltipBooleanCase(Invalid)
	AssertEqual("false", _HCW_TomlValue("show_tooltip", false),
		"the false Boolean must remain serialisable")
	AssertEqual("true", _HCW_TomlValue("show_tooltip", true),
		"the true Boolean must remain serialisable")
}
Test("hotstrings_config_window: tooltip Boolean rejects invalid personal values",
	_PTME_InvalidTooltipBooleanCannotReachPersonalBackend)

_PTME_ColorUsesSharedTomlCodec() {
	AssertFalse(_HCW_SetOverride({}, "", "color", 42),
		"the HCW boundary must reject a non-string color before reading its backend entry")
	Color := '#112233"`n[injected]`ncolor = "#445566'
	AssertEqual(TOML_RenderString(Color), _HCW_TomlValue("color", Color),
		"the personal color formatter must delegate every escape to the shared TOML codec")
}
Test("hotstrings_config_window: color writer uses the shared TOML codec",
	_PTME_ColorUsesSharedTomlCodec)

_PTME_PersonalPatchIdentifiersCannotInjectToml() {
	Path := A_Temp . "\hcw_personal_patch_identifier_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Original := "[_meta]`ndescription = " . TOML_RenderString("Personal") . "`n"
	InjectedSection := "race]`n[injected"
	InjectedField := "color`n[injected]"
	try {
		try FileDelete(Path)
		FileAppend(Original, Path, "UTF-8")
		AssertFalse(_HCW_PatchTomlMeta(Path, InjectedSection,
			"color", "#112233"),
			"a personal section identifier must not inject a sibling TOML header")
		AssertEqual(Original, FileRead(Path, "UTF-8"),
			"section validation must run before the owned patch publishes")
		AssertFalse(_HCW_PatchTomlMeta(Path, "", InjectedField, "#112233"),
			"a personal metadata field must come from the closed field catalogue")
		AssertEqual(Original, FileRead(Path, "UTF-8"),
			"field validation must preserve the durable source byte-exact")
		AssertThrows(() => _HCW_BuildTomlMetaPatch(
			InjectedSection, "color", "#112233", Original),
			"the pure serializer boundary must reject direct invalid section calls")
		AssertThrows(() => _HCW_BuildTomlMetaPatch(
			"", InjectedField, "#112233", Original),
			"the pure serializer boundary must reject direct invalid field calls")
		Valid := _HCW_BuildTomlMetaPatch(
			"race_one", "color", "#112233", Original)
		AssertTrue(InStr(Valid, "[_meta.sections.race_one]") > 0,
			"a valid personal section identifier must remain serialisable")
	} finally {
		try FileDelete(Path)
	}
}
Test("hotstrings_config_window: personal patch identifiers cannot inject TOML",
	_PTME_PersonalPatchIdentifiersCannotInjectToml)

_PTME_WebTooltipPayloadPreservesBooleanType() {
	global _HCW_CATEGORY_LIST, _HCW_GROUP_LIST, _HCW_COLOR_PRESETS
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedCategories := _HCW_CATEGORY_LIST
	SavedGroups := _HCW_GROUP_LIST
	SavedPresets := _HCW_COLOR_PRESETS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hcw_web_tooltip_type_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Entry := {
		Key: "rolls", Label: "Rolls", Group: "common", Path: "",
		IsPersonal: false, IsExtension: false,
	}
	try {
		try FileDelete(Path)
		_HCfgTestReset()
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		_HCW_CATEGORY_LIST := [Entry]
		_HCW_GROUP_LIST := []
		_HCW_COLOR_PRESETS := []

		for Invalid in ["true", "false", 2, -1] {
			Result := _HCWWeb_Dispatch(Map(
				"action", "set_tooltip",
				"category", "rolls",
				"show_tooltip", Invalid))
			AssertFalse(Result,
				"the WebView bridge must reject a non-Boolean tooltip payload")
			AssertFalse(FileExist(Path),
				"an invalid bridge payload must not publish an override file")
			AssertFalse(_HotstringsOverrides.Has("rolls"),
				"an invalid bridge payload must not mutate live state")
		}

		AssertTrue(_HCWWeb_Dispatch(Map(
			"action", "set_tooltip", "category", "rolls",
			"show_tooltip", true)),
			"a real true Boolean must remain writable")
		AssertEqual(true, _HotstringsOverrides["rolls"].ShowTooltip)
		AssertTrue(_HCWWeb_Dispatch(Map(
			"action", "set_tooltip", "category", "rolls",
			"show_tooltip", false)),
			"a real false Boolean must remain writable")
		AssertEqual(false, _HotstringsOverrides["rolls"].ShowTooltip)
	} finally {
		try FileDelete(Path)
		_HCW_CATEGORY_LIST := SavedCategories
		_HCW_GROUP_LIST := SavedGroups
		_HCW_COLOR_PRESETS := SavedPresets
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("hotstrings_config_window: WebView tooltip preserves Boolean type",
	_PTME_WebTooltipPayloadPreservesBooleanType)

_PTME_WebDelayPayloadPreservesIntegerMilliseconds() {
	global _HCW_CATEGORY_LIST, _HCW_GROUP_LIST, _HCW_COLOR_PRESETS
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedCategories := _HCW_CATEGORY_LIST
	SavedGroups := _HCW_GROUP_LIST
	SavedPresets := _HCW_COLOR_PRESETS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hcw_web_delay_type_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Entry := {
		Key: "rolls", Label: "Rolls", Group: "common", Path: "",
		IsPersonal: false, IsExtension: false,
	}
	try {
		try FileDelete(Path)
		_HCfgTestReset()
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		_HCW_CATEGORY_LIST := [Entry]
		_HCW_GROUP_LIST := []
		_HCW_COLOR_PRESETS := []

		for Invalid in ["1000", 1000.5, -1] {
			Result := _HCWWeb_Dispatch(Map(
				"action", "set_delay",
				"category", "rolls",
				"ms", Invalid))
			AssertFalse(Result,
				"the WebView bridge must reject a non-domain delay payload")
			AssertFalse(FileExist(Path),
				"an invalid delay payload must not publish an override file")
			AssertFalse(_HotstringsOverrides.Has("rolls"),
				"an invalid delay payload must not mutate live state")
		}

		AssertTrue(_HCWWeb_Dispatch(Map(
			"action", "set_delay", "category", "rolls", "ms", 1000)),
			"an integer millisecond delay must remain writable")
		AssertEqual(1, _HotstringsOverrides["rolls"].Delay,
			"the bridge must convert a valid millisecond integer exactly once")
	} finally {
		try FileDelete(Path)
		_HCW_CATEGORY_LIST := SavedCategories
		_HCW_GROUP_LIST := SavedGroups
		_HCW_COLOR_PRESETS := SavedPresets
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("hotstrings_config_window: WebView delay preserves millisecond integer type",
	_PTME_WebDelayPayloadPreservesIntegerMilliseconds)



; The shared outcome gate is deliberately behavioural. A source token alone
; could be hidden behind `if false`; these callbacks prove that every write is
; actually evaluated and that only one terminal outcome becomes observable.
global _PTME_BatchEvents := []
global _PTME_BatchRefreshes := 0
global _PTME_BatchCloses := 0
global _PTME_BatchSuccessNotices := 0
global _PTME_BatchFailureNotices := 0
global _PTME_LastBatchOutcome := 0
global _PTME_BatchCallbackEvents := []

_PTME_ResetBatchProbe() {
	global _PTME_BatchEvents, _PTME_BatchRefreshes, _PTME_BatchCloses
	global _PTME_BatchSuccessNotices, _PTME_BatchFailureNotices
	global _PTME_LastBatchOutcome, _PTME_BatchCallbackEvents
	_PTME_BatchEvents := []
	_PTME_BatchRefreshes := 0
	_PTME_BatchCloses := 0
	_PTME_BatchSuccessNotices := 0
	_PTME_BatchFailureNotices := 0
	_PTME_LastBatchOutcome := 0
	_PTME_BatchCallbackEvents := []
}

_PTME_BatchWrite(Label, Result) {
	global _PTME_BatchEvents
	_PTME_BatchEvents.Push(Label)
	return Result
}

_PTME_BatchThrow(Label) {
	global _PTME_BatchEvents
	_PTME_BatchEvents.Push(Label)
	throw Error("injected persistence writer failure")
}

_PTME_BatchReconcile(Outcome) {
	global _PTME_BatchRefreshes, _PTME_LastBatchOutcome, _PTME_BatchCallbackEvents
	_PTME_BatchRefreshes += 1
	_PTME_LastBatchOutcome := Outcome
	_PTME_BatchCallbackEvents.Push("reconcile")
}

_PTME_BatchSuccessEffects(Outcome) {
	global _PTME_BatchCloses, _PTME_BatchSuccessNotices, _PTME_BatchCallbackEvents
	_PTME_BatchCloses += 1
	_PTME_BatchSuccessNotices += 1
	_PTME_BatchCallbackEvents.Push("success")
}

_PTME_BatchFailureNotice(Outcome) {
	global _PTME_BatchFailureNotices, _PTME_BatchCallbackEvents
	_PTME_BatchFailureNotices += 1
	_PTME_BatchCallbackEvents.Push("failure")
}

_PTME_RequireWriteBatchRunner() {
	; In AHK v2 Func is the native class, not a string-to-function resolver.
	; Referencing the included function directly gives us its callable object.
	return _HCW_RunWriteBatch
}

_PTME_WriteBatchFailureSuppressesSuccessEffects() {
	global _PTME_BatchEvents, _PTME_BatchRefreshes, _PTME_BatchCloses
	global _PTME_BatchSuccessNotices, _PTME_BatchFailureNotices
	global _PTME_BatchCallbackEvents
	_PTME_ResetBatchProbe()
	Runner := _PTME_RequireWriteBatchRunner()
	Writes := [
		_PTME_BatchWrite.Bind("first", true),
		_PTME_BatchWrite.Bind("refused", false),
		_PTME_BatchWrite.Bind("string-protocol-violation", "1"),
		_PTME_BatchWrite.Bind("deferred-protocol-violation", 2),
		_PTME_BatchWrite.Bind("negative-protocol-violation", -1),
		_PTME_BatchThrow.Bind("throwing-writer"),
		_PTME_BatchWrite.Bind("last", true)
	]
	Outcome := Runner.Call(Writes, _PTME_BatchReconcile.Bind(),
		_PTME_BatchSuccessEffects.Bind(), _PTME_BatchFailureNotice.Bind())
	AssertFalse(Outcome["ok"],
		"one refused persistence result must make the complete action fail")
	AssertEqual(7, Outcome["attempted"])
	AssertEqual(2, Outcome["succeeded"])
	AssertEqual(5, Outcome["failed"])
	AssertEqual(5, Outcome["failed_indices"].Length)
	for Index, Expected in [2, 3, 4, 5, 6]
		AssertEqual(Expected, Outcome["failed_indices"][Index],
			"the outcome must identify each refused writer so its draft can be requeued")
	AssertEqual(7, _PTME_BatchEvents.Length,
		"the batch must evaluate every persistence result instead of short-circuiting and hiding later failures")
	AssertEqual("first", _PTME_BatchEvents[1])
	AssertEqual("refused", _PTME_BatchEvents[2])
	AssertEqual("string-protocol-violation", _PTME_BatchEvents[3])
	AssertEqual("deferred-protocol-violation", _PTME_BatchEvents[4])
	AssertEqual("negative-protocol-violation", _PTME_BatchEvents[5])
	AssertEqual("throwing-writer", _PTME_BatchEvents[6])
	AssertEqual("last", _PTME_BatchEvents[7])
	AssertEqual(1, _PTME_BatchRefreshes,
		"a failed write must reconcile the UI once with canonical durable state")
	AssertEqual(0, _PTME_BatchCloses,
		"a failed bulk action must not run its success effects")
	AssertEqual(0, _PTME_BatchSuccessNotices,
		"a failed bulk action must never announce success")
	AssertEqual(1, _PTME_BatchFailureNotices,
		"the aggregate failure must be reported exactly once")
	AssertEqual(2, _PTME_BatchCallbackEvents.Length)
	AssertEqual("reconcile", _PTME_BatchCallbackEvents[1],
		"canonical reconciliation must precede the terminal failure signal")
	AssertEqual("failure", _PTME_BatchCallbackEvents[2])
}
Test("hotstrings_config_window: one refused write suppresses every success side effect",
	_PTME_WriteBatchFailureSuppressesSuccessEffects)

_PTME_WriteBatchSuccessRunsTerminalEffectsOnce() {
	global _PTME_BatchEvents, _PTME_BatchRefreshes, _PTME_BatchCloses
	global _PTME_BatchSuccessNotices, _PTME_BatchFailureNotices
	global _PTME_BatchCallbackEvents
	_PTME_ResetBatchProbe()
	Runner := _PTME_RequireWriteBatchRunner()
	Writes := [
		_PTME_BatchWrite.Bind("first", true),
		_PTME_BatchWrite.Bind("second", true)
	]
	Outcome := Runner.Call(Writes, _PTME_BatchReconcile.Bind(),
		_PTME_BatchSuccessEffects.Bind(), _PTME_BatchFailureNotice.Bind())
	AssertTrue(Outcome["ok"],
		"an all-success batch must report a durable successful action")
	AssertEqual(2, Outcome["attempted"])
	AssertEqual(2, Outcome["succeeded"])
	AssertEqual(0, Outcome["failed"])
	AssertEqual(2, _PTME_BatchEvents.Length,
		"every successful persistence callback must run")
	AssertEqual(1, _PTME_BatchRefreshes,
		"the UI must refresh once after the complete batch succeeds")
	AssertEqual(1, _PTME_BatchCloses,
		"the reset success path must run once")
	AssertEqual(1, _PTME_BatchSuccessNotices,
		"the complete batch must announce success once")
	AssertEqual(0, _PTME_BatchFailureNotices,
		"an all-success batch must not emit a failure notice")
	AssertEqual(2, _PTME_BatchCallbackEvents.Length)
	AssertEqual("reconcile", _PTME_BatchCallbackEvents[1],
		"canonical reconciliation must precede terminal success effects")
	AssertEqual("success", _PTME_BatchCallbackEvents[2])
}
Test("hotstrings_config_window: all-success batch runs terminal effects exactly once",
	_PTME_WriteBatchSuccessRunsTerminalEffectsOnce)

_PTME_ResetSections(Entry) {
	return [{ Name: "alpha" }]
}

_PTME_ResetPlanCoversPersonalAndOverrideBackends() {
	Categories := [
		{ Key: "personal:mine", Path: "mine.toml", IsPersonal: true,
			IsExtension: false, ExtId: "" },
		{ Key: "ext:demo:file", Path: "", IsPersonal: false,
			IsExtension: true, ExtId: "demo" },
		{ Key: "magickey", Path: "", IsPersonal: false,
			IsExtension: false, ExtId: "" }
	]
	Fields := ["delay", "color", "priority", "show_tooltip"]
	Plan := _HCW_BuildResetAllPlan(Categories, _PTME_ResetSections, Fields)
	AssertEqual(12, Plan.Length,
		"personal file+section need four writes each; extension and common need one all-fields clear at both levels")
	for Index, Field in Fields {
		AssertEqual("personal", Plan[Index].Kind)
		AssertEqual("", Plan[Index].Sec)
		AssertEqual(Field, Plan[Index].Field)
		SectionItem := Plan[Fields.Length + Index]
		AssertEqual("personal", SectionItem.Kind)
		AssertEqual("alpha", SectionItem.Sec)
		AssertEqual(Field, SectionItem.Field)
	}
	AssertEqual("override", Plan[9].Kind)
	AssertEqual("ext.demo", Plan[9].Category)
	AssertEqual("", Plan[9].Field,
		"extension reset must use the backend's all-fields clear")
	AssertEqual("alpha", Plan[10].Sec)
	AssertEqual("magickey", Plan[11].Category)
	AssertEqual("alpha", Plan[12].Sec)
}
Test("hotstrings_config_window: reset plan clears every personal metadata field (hcw-reset-personal-plan-behavior)",
	_PTME_ResetPlanCoversPersonalAndOverrideBackends)

_PTME_ExistingEditorsRefreshBeforeTheyAreShown() {
	Web := _DriverFuncBody("_HCWWeb_TryOpen")
	WebBuildPos := InStr(Web, "_HCW_BuildCategoryList()")
	WebPushPos := InStr(Web, "_HCWWeb_PushState()")
	ActivatePos := InStr(Web, "WMPresentWindow(_HCWWeb_Gui)")
	Assert(WebBuildPos > 0 and WebPushPos > WebBuildPos
		and ActivatePos > WebPushPos,
		"the WebView singleton must rebuild and push canonical state before activation")
}
Test("hotstrings_config_window: the live singleton refreshes before reopen (hcw-singleton-refresh)",
	_PTME_ExistingEditorsRefreshBeforeTheyAreShown)

; Enumerate the whole class so fixing one handler cannot leave a sibling
; silently dropping `false`.
_PTME_EveryMutationEntrypointUsesTheOutcomeGate() {
	OutcomeGateSites := [
		{ Name: "_HCWWeb_Dispatch", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCWWeb_ResetAll", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCWWeb_SetAllGrey", Gate: "_HCW_RunWriteBatch(" }
	]
	for Site in OutcomeGateSites {
		Body := _DriverFuncBody(Site.Name)
		Assert(InStr(Body, Site.Gate) > 0,
			Site.Name . " must route persistence through the shared behavioural outcome gate")
		Assert(!RegExMatch(Body, "i)\bif\s*\(?\s*(?:false|0)\b"),
			Site.Name . " must not satisfy the outcome contract through dead `if false` code")
	}
	WebDispatchPattern := "s)_HCW_RunWriteBatch\(.*?"
		. "_HCWWeb_ReconcileState\.Bind\(\)\s*,\s*0\s*,\s*"
		. "_HCW_ReportWriteFailure\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCWWeb_Dispatch"), WebDispatchPattern),
		"_HCWWeb_Dispatch must push canonical state before its terminal failure report")
	WebResetPattern := "s)_HCW_RunWriteBatch\(\s*Writes\s*,\s*"
		. "_HCWWeb_ReconcileReset\.Bind\(\)\s*,\s*"
		. "_HCWWeb_ReportResetSuccess\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCWWeb_ResetAll"), WebResetPattern),
		"_HCWWeb_ResetAll must put the positive reset notification in the success slot")
	WebGreyPattern := "s)_HCW_RunWriteBatch\(\s*Writes\s*,\s*"
		. "_HCWWeb_ReconcileState\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCWWeb_SetAllGrey"), WebGreyPattern),
		"_HCWWeb_SetAllGrey must reconcile once and leave terminal failure reporting to its dispatcher")
	Assert(InStr(_DriverFuncBody("_HCWWeb_Dispatch"), "_HCW_ReportWriteFailure") > 0,
		"_HCWWeb_Dispatch must provide an explicit user-visible failure path")
}
Test("hotstrings_config_window: every WebView mutation entrypoint gates its outcome",
	_PTME_EveryMutationEntrypointUsesTheOutcomeGate)

_PTME_NoMutationSiteDropsAResultOrRunsBareSuccessEffects() {
	Sites := [
		"_HCW_SetOverride",
		"_HCW_ClearOverride",
		"_HCWWeb_Dispatch",
		"_HCWWeb_ResetAll",
		"_HCWWeb_SetAllGrey"
	]
	BareWrite := "m)^[ \t]*(?:_HCW_(?:SetOverride|ClearOverride|PatchTomlMeta)"
		. "|_HCWWeb_(?:ResetAll|SetAllGrey)|Hotstrings(?:SetOverride|ClearOverride))\s*\("
	BareSuccessEffect := "m)^[ \t]*(?:try[ \t]+)?(?:TrayTip|NotifierSend)\s*\("
	for Name in Sites {
		Body := _DriverFuncBody(Name)
		SearchBody := RegExReplace(Body, "s)^[^{]*\{", "",, 1)
		Assert(!RegExMatch(Body, "i)\bif\s*\(?\s*(?:false|0)\b"),
			Name . " must not hide an outcome guard in unreachable code")
		Assert(!RegExMatch(SearchBody, BareWrite),
			Name . " must consume every Boolean persistence result instead of invoking a write as a bare statement")
		Assert(!RegExMatch(SearchBody, BareSuccessEffect),
			Name . " must put success notification behind the successful outcome callback")
	}
}
Test("hotstrings_config_window: no mutation site drops a result or runs bare success effects",
	_PTME_NoMutationSiteDropsAResultOrRunsBareSuccessEffects)
