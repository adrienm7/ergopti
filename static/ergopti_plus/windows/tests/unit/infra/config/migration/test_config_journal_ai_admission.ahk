; tests/unit/infra/config/migration/test_config_journal_ai_admission.ahk

; ==============================================================================
; MODULE: Config Journal Read-Only AI Menu Admission
; DESCRIPTION:
; A newer schema disables AI activation without changing settings, the
; classification memo keeps fresh source authority, and registry scalar
; fast leaves keep typed semantics and native owner admission.
; ==============================================================================

#Requires AutoHotkey v2.0





_CMJ_WithAiPersistenceState(Body) {
	global ConfigurationFile, _LLM_Menu, _ConfigBootReadFailed, _ConfigBootRejectedOverrides
	Prior := Map("path", IsSet(ConfigurationFile), "menu", IsSet(_LLM_Menu),
		"read", IsSet(_ConfigBootReadFailed), "rejected", IsSet(_ConfigBootRejectedOverrides))
	if Prior["path"]
		Prior["path_value"] := ConfigurationFile
	if Prior["menu"]
		Prior["menu_value"] := _LLM_Menu
	if Prior["read"]
		Prior["read_value"] := _ConfigBootReadFailed
	if Prior["rejected"]
		Prior["rejected_value"] := _ConfigBootRejectedOverrides
	PriorSuspend := A_IsSuspended
	Dir := _CMG_NewDir()
	try {
		Suspend(false)
		ConfigurationFile := Dir . "\config.toml"
		_LLM_Menu := Map("enabled", false)
		_ConfigBootReadFailed := false
		_ConfigBootRejectedOverrides := 0
		return Body.Call(ConfigurationFile)
	} finally {
		try _CMJ_Cleanup(Dir, Dir . "\config.toml")
		finally {
			ConfigurationFile := Prior["path"] ? Prior["path_value"] : unset
			_LLM_Menu := Prior["menu"] ? Prior["menu_value"] : unset
			_ConfigBootReadFailed := Prior["read"] ? Prior["read_value"] : unset
			_ConfigBootRejectedOverrides := Prior["rejected"] ? Prior["rejected_value"] : unset
			Suspend(PriorSuspend)
		}
	}
}

_CMJ_NewerSchemaAiAdmission(Path) {
	Source := '[_meta]`nschema_version = ' . (ConfigMigrateCurrentVersion() + 1)
		. '`n[layout]`nfuture_layout_owner = "retain exactly"`n'
	AssertTrue(FSWriteDurable(Path, Source))
	AssertEqual("", ConfigSchemaReadOnlyStatus(Path), "observing an unknown destination does not construct it")
	AssertFalse(ConfigMigrateBoot(Path, "known"))
	Prepared := ConfigSchemaPrepareSource(Path)
	AssertEqual("newer", Prepared["status"])
	Result := ConfigMigrateBoot(Path)
	AssertEqual("newer", Result["status"])
	AssertEqual(1, Result["read_only"])
	AssertFalse(ConfigSchemaCanPrepareWrite(Path))
	Getters := _LLM_Menu_StateGetters()
	AssertFalse(Getters["llm_enabled"].Call())
	AssertFalse(Getters["llm_toggle_ready"].Call(), "a paused-independent future-schema toggle is not clickable")
	AssertEqual("newer", ConfigSchemaReadOnlyStatus(Path), "the actual retained classification remains observable without write permission")
	AssertTrue(MenuRenderer_ResolveDisabledWhen("llm_menu", "llm_toggle", Getters),
		"the actual declaration renders protected AI activation disabled")
	Messages := []
	AssertFalse(ConfigReportPersistenceFailure("the AI toggle", (Message, Options) => Messages.Push([Message, Options]),
		"the boot configuration was not completely loaded"))
	AssertEqual(1, Messages.Length)
	AssertEqual(t("config.read_only.newer_schema"), Messages[1][1], "stale callers explain the actual retained newer schema")
	AssertFalse(Messages[1][1] == "config.read_only.newer_schema", "the user sees localized guidance, not a raw key")
	AssertEqual("error", Messages[1][2]["level"])
	AssertTrue(FSUtf8ExactMatches(Path, Source), "observation, menu rendering and failure reporting preserve every source byte")
	AssertFalse(ConfigSchemaCanPrepareWrite(Path), "diagnostic status and notification never grant permission")
	_CMJ_NewerSchemaPersistenceRows(Path, Source, Getters)
}

; The switch and the restore named only the generic "resume or open
; Diagnostics" cause, which neither can lift, and a restore row kept from an
; earlier build still entered its scope transaction.
_CMJ_NewerSchemaPersistenceRows(Path, Source, Getters) {
	AssertTrue(Getters["config_newer_schema"].Call(), "the menus can name the newer configuration")
	AssertFalse(Getters["llm_scope_ready"].Call(), "the restore is not clickable either")
	Commands := Map("llm_toggle", (*) => 0, "scope_restore", (*) => 0)
	Seen := 0
	for Item in _MR_GetMenuDef("llm_menu") {
		Id := _MR_Get(Item, "id", "")
		if Id != "llm_toggle" && Id != "scope_restore"
			continue
		Seen += 1
		Row := Id == "llm_toggle" ? _MR_ToggleRowData(Item, "llm_menu", Commands, Getters)
			: _MR_CommandRowData(Item, "llm_menu", Commands, Getters)
		Assert(Row is Map, Id . " is drawn")
		AssertEqual("menu.read_only.newer_schema", Row["disabled_reason_key"], Id . " names the newer configuration")
		AssertTrue(Row["disabled"], Id . " is greyed")
		AssertFalse(Row.Has("action"), Id . " has nothing to run")
	}
	AssertEqual(2, Seen, "both AI persistence rows are declared")
	Messages := []
	Receipt := (_LLM_ScopeCommands(Map("notify", (Message, Options) => Messages.Push(Message)))["scope_restore"])()
	AssertEqual("refused", Receipt["status"], "a retained restore rechecks the configuration")
	AssertEqual(1, Messages.Length)
	AssertEqual(t("config.read_only.newer_schema"), Messages[1], "the refused restore names the newer configuration")
	AssertTrue(FSUtf8ExactMatches(Path, Source), "the refused restore writes nothing")
	_CMJ_NewerSchemaParents(Path, Source)
}

; The dynamic AI parents (servers, API entries, profiles) are native rows: they
; name the same cause, and a click kept from before a reload rechecks it
; (ai-submenus-newer-config-2026-10-23).
_CMJ_NewerSchemaParents(Path, Source) {
	AssertEqual("menu.read_only.newer_schema", _LLM_Menu_ConfigBlockReason(), "the native parents name the newer configuration")
	Child := Menu()
	Target := Menu()
	try {
		Child.Add("probe", (*) => 0)
		Rows := _LLM_Menu_GreyConfigParents("llm_profile", _LLM_Menu_ProfileParentRows(Child, "Basic", false), false)
		Assert(Rows is Array, "the profile parent frame is drawn")
		AssertTrue(Rows[1].Get("disabled", false), "the profile parent is greyed")
		AssertEqual("menu.read_only.newer_schema", Rows[1].Get("disabled_reason_key", ""), "the profile parent names the cause")
		MenuRenderer_AppendRows(Target, "llm_menu", "llm_profile_parent_frame_ahk", Rows)
		Flags := DllCall("GetMenuState", "ptr", Target.Handle, "uint", 0, "uint", 0x400, "uint")
		AssertTrue((Flags & 0x3) != 0, "the native profile parent is greyed")
		Label := Buffer(2048, 0)
		DllCall("GetMenuStringW", "ptr", Target.Handle, "uint", 0, "ptr", Label, "int", 1024, "uint", 0x400)
		Head := _MR_ReasonHead(t("menu.read_only.newer_schema"))
		Assert(InStr(StrGet(Label, "UTF-16"), Head) > 0, "the native caption names the cause: " . StrGet(Label, "UTF-16"))
		Other := _LLM_Menu_GreyConfigParents("llm_profile", _LLM_Menu_ProfileParentRows(Child, "Basic", true), true)
		AssertFalse(Other[1].Has("disabled_reason_key"), "a parent greyed for another reason keeps its plain greying")
	} finally {
		Target.Delete()
		MenuDispatcher_PruneMenu(Target)
		Child.Delete()
		MenuDispatcher_PruneMenu(Child)
	}
	; Only the parents of the three writing submenus take the cause.
	Model := _LLM_Menu_GreyConfigParents("llm_backend", [Map("label", "Servers", "submenu", Menu())], false)
	AssertTrue(Model[1].Get("disabled", false), "the backend parent names the cause")
	Unrelated := _LLM_Menu_GreyConfigParents("llm_trigger", [Map("label", "Other", "submenu", Menu())], false)
	AssertFalse(Unrelated[1].Has("disabled_reason_key"), "a row outside the three writing submenus is left alone")
	Ran := 0
	Guarded := _LLM_Menu_GuardConfigRows([Map("label", "leaf", "action", (*) => ++Ran,
		"items", [Map("label", "inner", "action", (*) => ++Ran)])])
	AssertFalse(Guarded[1]["action"].Call("leaf", 1, ""), "a retained click rechecks the configuration")
	AssertFalse(Guarded[1]["items"][1]["action"].Call("inner", 1, ""), "a nested retained click rechecks it too")
	AssertEqual(0, Ran, "a refused click never reaches its action")
	AssertTrue(FSUtf8ExactMatches(Path, Source), "the refused clicks write nothing")
}
Test("config journal: newer schema disables AI activation and explains update without changing settings (newer-schema-ai)",
	_CMJ_WithAiPersistenceState.Bind(_CMJ_NewerSchemaAiAdmission))

_CMJ_CurrentSchemaAiAdmission(Path) {
	Source := '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion() . '`n'
	AssertTrue(FSWriteDurable(Path, Source))
	AssertEqual("current", ConfigSchemaPrepareSource(Path)["status"])
	AssertEqual("", ConfigSchemaReadOnlyStatus(Path))
	AssertEqual("current", ConfigMigrateBoot(Path)["status"])
	AssertTrue(ConfigSchemaCanPrepareWrite(Path))
	Getters := _LLM_Menu_StateGetters()
	AssertTrue(Getters["llm_toggle_ready"].Call(), "an admitted ordinary current configuration remains available")
	AssertTrue(Getters["llm_scope_ready"].Call(), "the restore stays available on a current configuration")
	AssertFalse(Getters["config_newer_schema"].Call(), "a current configuration names no newer cause")
	AssertEqual("", _LLM_Menu_ConfigBlockReason(), "a writable configuration names no cause on the native parents")
	Ran := 0
	Guarded := _LLM_Menu_GuardConfigRows([Map("label", "leaf", "action", (*) => ++Ran)])
	Guarded[1]["action"].Call("leaf", 1, "")
	AssertEqual(1, Ran, "a writable configuration runs the retained click")
	AssertFalse(MenuRenderer_ResolveDisabledWhen("llm_menu", "llm_toggle", Getters))
	Suspend(true)
	AssertFalse(Getters["llm_toggle_ready"].Call(), "configuration readiness does not override suspension")
	Suspend(false)
	AssertTrue(Getters["llm_toggle_ready"].Call())
	Messages := []
	AssertFalse(ConfigReportPersistenceFailure("the ordinary failure", (Message, Options) => Messages.Push(Message), "controlled write refusal"))
	AssertEqual(t("dialog.bulk_toggle.save_failed"), Messages[1], "ordinary failure localization is unchanged")
	AssertTrue(FSUtf8ExactMatches(Path, Source))
}
Test("config journal: current schema and pause retain ordinary AI menu and failure semantics (newer-schema-ai-current)",
	_CMJ_WithAiPersistenceState.Bind(_CMJ_CurrentSchemaAiAdmission))


; Repeated classification may reuse only exact source bytes; source reads and
; registry/owner admission remain genuine on every request.
_CMJ_MemoSyntheticSource(VersionText) {
	Source := '[_meta]`nschema_version = ' . VersionText . '`n[llm]`n'
	loop 135
		Source .= Format('memo_field_{1:03} = "value{1:03}"`n', A_Index)
	Padding := 5000 - StrLen(Source)
	AssertTrue(Padding >= 2, "the controlled classification workload has bounded padding")
	Source .= "#"
	loop Padding - 2
		Source .= "x"
	return Source . "`n"
}

_CMJ_MemoFileTimestamp(Path, Stamp := unset) {
	if IsSet(Stamp)
		FileSetTime(Stamp, Path, "M")
	return FileGetTime(Path, "M")
}

_CMJ_ClassificationMemoFreshSource() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := _CMJ_MemoSyntheticSource(String(ConfigMigrateCurrentVersion()))
	try {
		AssertEqual(5000, StrLen(Source), "the workload contains 136 scalar keys in exactly 5000 ASCII bytes")
		AssertTrue(FSWriteDurable(Path, Source))
		Stamp := _CMJ_MemoFileTimestamp(Path)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		loop 3
			AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		Captured := ConfigMigrateBoot(Path, "capture_noop")
		AssertTrue(HasMethod(Captured, "Call"))
		ChangedCase := StrReplace(Source, "schema_version", "SCHEMA_VERSION")
		AssertEqual(StrLen(Source), StrLen(ChangedCase))
		AssertTrue(FSWriteDurable(Path, ChangedCase))
		AssertEqual(Stamp, _CMJ_MemoFileTimestamp(Path, Stamp), "the same-length successor retains the old modification timestamp")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "a same-length case change cannot reuse current metadata classification")
		AssertFalse(Captured.Call(ChangedCase, 1), "a cached classification never becomes stale source authority")
		Future := _CMJ_MemoSyntheticSource(String(ConfigMigrateCurrentVersion() + 1))
		AssertTrue(FSWriteDurable(Path, Future))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "fresh newer metadata remains read-only after a warm hit")
		Invalid := _CMJ_MemoSyntheticSource('"invalid"')
		AssertTrue(FSWriteDurable(Path, Invalid))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "typed invalid metadata cannot borrow the prior current decision")
		Malformed := StrReplace(Source, "schema_version = " . ConfigMigrateCurrentVersion(),
			"schema_version = " . ConfigMigrateCurrentVersion() . "`nschema_version = " . ConfigMigrateCurrentVersion())
		AssertTrue(FSWriteDurable(Path, Malformed))
		loop 2
			AssertFalse(ConfigSchemaCanPrepareWrite(Path), "a parse refusal never grants cached readiness")
		AssertTrue(FSWriteDurable(Path, Source))
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "exact current source repair restores original admission")
		AssertTrue(Captured.Call(Source, 1), "the original source guard remains authoritative after exact repair")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: classification memo preserves fresh source and case-sensitive authority (classification-memo-source)",
	_CMJ_ClassificationMemoFreshSource)

_CMJ_ClassificationMemoRegistry() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	Source := _CMJ_MemoSyntheticSource(String(ConfigMigrateCurrentVersion()))
	Registry := ConfigMigrateShippedRegistry(), Current := Registry["current"]
	Step := Registry["steps"][1], Reason := Step["reason"]
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		Captured := ConfigMigrateBoot(Path, "capture_noop")
		Registry["current"] := Current + 1
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "a warm source memo cannot hide in-place registry mutation")
		AssertFalse(Captured.Call(Source, 1))
		Registry["current"] := Current
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		Step["reason"] := Reason . " altered"
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "nested registry data is still compared against the private shadow on a hit")
		AssertFalse(Captured.Call(Source, 1))
		Step["reason"] := Reason
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "exact nested registry repair restores admission")
		AssertTrue(Captured.Call(Source, 1))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		Registry["current"] := Current
		Step["reason"] := Reason
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: classification memo rechecks genuine registry and exact repair (classification-memo-registry)",
	_CMJ_ClassificationMemoRegistry)

_CMJ_ClassificationMemoPresence() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml"
	try {
		AssertEqual("absent", ConfigMigrateBoot(Path)["status"])
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSWriteDurable(Path, ""))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "a present empty file cannot borrow absent-source default permission")
		AssertTrue(FSDelete(Path))
		AssertFalse(FSStrictExists(Path))
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "the genuine absent-image branch still uses its original readiness rules")
	} finally _CMJ_Cleanup(Dir, Path)
}
Test("config journal: classification memo does not alias missing and present empty source (classification-memo-presence)",
	_CMJ_ClassificationMemoPresence)


_CMJ_RegistryLeafScalarTypes() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	Registry := ConfigMigrateShippedRegistry(), Current := Registry["current"]
	Step := Registry["steps"][1], Reason := Step["reason"]
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Guard := ConfigMigrateBoot(Path, "capture_noop")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		Registry["current"] := Current + 0.0
		AssertTrue(Registry["current"] is Float, "the numeric parity vector must be a real Float")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "native integer and equal Float retain canonical numeric equality")
		AssertTrue(Guard.Call(Source, 1))
		Registry["current"] := String(Current)
		AssertTrue(Registry["current"] is String, "the numeric-looking refusal vector must remain a String")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "numeric-looking strings cannot borrow native numeric registry authority")
		AssertFalse(Guard.Call(Source, 1))
		Registry["current"] := Current
		Step["reason"] := StrUpper(Reason)
		AssertTrue(StrCompare(Step["reason"], Reason, true) != 0, "the actual reason must have a distinct case mutation")
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "registry strings remain exactly case-sensitive")
		AssertFalse(Guard.Call(Source, 1))
		Step["reason"] := Reason
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "exact scalar repair restores observed native registry authority")
		AssertTrue(Guard.Call(Source, 1))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		Registry["current"] := Current
		Step["reason"] := Reason
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: registry scalar fast leaves preserve typed numeric and exact string semantics (registry-leaf-safety)",
	_CMJ_RegistryLeafScalarTypes)

_CMJ_RegistryLeafNativeOwner() {
	Dir := _CMG_NewDir(), Path := Dir . "\config.toml", Source := _CMJ_CurrentSource()
	Invocations := { count: 0 }
	AssertFalse(Object.Prototype.HasOwnProp.Call(ConfigMigrateSameValue, "Call"))
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Guard := ConfigMigrateBoot(Path, "capture_noop")
		AssertTrue(Guard.Call(Source, 1))
		ConfigMigrateSameValue.DefineProp("Call", {Call: (*) => (Invocations.count += 1, true)})
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "direct scalar comparisons cannot skip the exact canonical native owner fence")
		AssertFalse(Guard.Call(Source, 1))
		AssertEqual(0, Invocations.count, "foreign native scalar callbacks are refused before invocation")
		ConfigMigrateSameValue.DeleteProp("Call")
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(Guard.Call(Source, 1))
		AssertEqual(0, Invocations.count)
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		if Object.Prototype.HasOwnProp.Call(ConfigMigrateSameValue, "Call")
			ConfigMigrateSameValue.DeleteProp("Call")
		_CMJ_Cleanup(Dir, Path)
	}
}
Test("config journal: registry scalar fast leaves retain canonical native owner admission (registry-leaf-safety)",
	_CMJ_RegistryLeafNativeOwner)
