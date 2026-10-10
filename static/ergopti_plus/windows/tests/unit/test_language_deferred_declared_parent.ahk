; tests/unit/test_language_deferred_declared_parent.ahk

; ==============================================================================
; MODULE: Deferred Declared Language Parent
; DESCRIPTION:
; Genuine native Menu controls pin the original translated caption, position,
; child identity and dispatcher callbacks. Declaration withdrawal or a stale
; placeholder must refuse before changing the current native root.
; ==============================================================================

#Requires AutoHotkey v2.0

_LDDP_WithLocale(Code, Body) {
	global _I18nCache, _I18nCacheLoaded, _SharedDir
	HadCache := IsSet(_I18nCache), OldCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), OldLoaded := HadLoaded ? _I18nCacheLoaded : false
	try {
		_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Code . ".json", "UTF-8"))
		_I18nCacheLoaded := true
		Body.Call()
	} finally {
		if HadCache
			_I18nCache := OldCache
		else
			_I18nCache := unset
		if HadLoaded
			_I18nCacheLoaded := OldLoaded
		else
			_I18nCacheLoaded := unset
	}
}

_LDDP_NativeReplacement(Code, ExpectedCaption) {
	global _MenuDispatchCallbacks
	Target := Menu(), Previous := Menu(), Replacement := Menu()
	Hits := Map("first", 0, "last", 0, "child", 0)
	First := (*) => Hits["first"] += 1
	Last := (*) => Hits["last"] += 1
	ChildAction := (*) => Hits["child"] += 1
	try {
		AssertEqual(ExpectedCaption, t("menu.global.language"), "the independent original caption is retained")
		AssertEqual(1, RegisterMenuItem(Target, "first", First))
		Target.Add(ExpectedCaption, Previous)
		Target.Disable(ExpectedCaption)
		Target.Check(ExpectedCaption)
		AssertEqual(1, RegisterMenuItem(Target, "last", Last))
		Target.Disable("last")
		Target.Check("last")
		AssertEqual(1, RegisterMenuItem(Replacement, "child", ChildAction))
		FirstId := DllCall("GetMenuItemID", "ptr", Target.Handle, "int", 0, "uint")
		LastId := DllCall("GetMenuItemID", "ptr", Target.Handle, "int", 2, "uint")
		ChildId := DllCall("GetMenuItemID", "ptr", Replacement.Handle, "int", 0, "uint")
		Assert(_MenuDispatchCallbacks.Has(FirstId) && _MenuDispatchCallbacks.Has(LastId)
			&& _MenuDispatchCallbacks.Has(ChildId), "actual native command IDs have dispatcher owners")
		LastState := DllCall("GetMenuState", "ptr", Target.Handle, "uint", 2, "uint", 0x400, "uint")
		Publish := MenuRenderer_GroupReplacement(Target, "top_level", "language", Previous)
		Assert(HasMethod(Publish, "Call"), "the actual parent is admitted before child production")
		AssertTrue(Publish.Call(Replacement))
		AssertEqual(3, TrayMenuItemCount(Target), "replacement does not insert or reorder a root row")
		AssertEqual("first", TrayMenuItemCaption(Target, 0))
		AssertEqual(ExpectedCaption, TrayMenuItemCaption(Target, 1))
		AssertEqual("last", TrayMenuItemCaption(Target, 2))
		AssertEqual(Replacement.Handle, TrayMenuSubmenuHandle(Target.Handle, 1), "the completed genuine child is retained")
		AssertEqual(1, TrayMenuItemCount(Replacement))
		ParentState := DllCall("GetMenuState", "ptr", Target.Handle, "uint", 1, "uint", 0x400, "uint")
		AssertEqual(0, ParentState & 0xB, "only the completed language parent is enabled and unchecked")
		AssertEqual(LastState, DllCall("GetMenuState", "ptr", Target.Handle, "uint", 2, "uint", 0x400, "uint"),
			"the adjacent lifecycle disabled and checked states are preserved")
		AssertEqual(FirstId, DllCall("GetMenuItemID", "ptr", Target.Handle, "int", 0, "uint"))
		AssertEqual(LastId, DllCall("GetMenuItemID", "ptr", Target.Handle, "int", 2, "uint"))
		AssertEqual(ChildId, DllCall("GetMenuItemID", "ptr", Replacement.Handle, "int", 0, "uint"))
		Assert(_MenuDispatchCallbacks[FirstId] == First && _MenuDispatchCallbacks[LastId] == Last
			&& _MenuDispatchCallbacks[ChildId] == ChildAction, "all original callback identities are retained")
		_MenuDispatchCallbacks[FirstId].Call()
		_MenuDispatchCallbacks[LastId].Call()
		_MenuDispatchCallbacks[ChildId].Call()
		AssertEqual(1, Hits["first"])
		AssertEqual(1, Hits["last"])
		AssertEqual(1, Hits["child"], "the exact retained command still has a concrete effect")
	} finally {
		_CTC_ReleaseMenu(Target)
		_CTC_ReleaseMenu(Previous)
		_CTC_ReleaseMenu(Replacement)
	}
}

_LDDP_IndependentCaptions() {
	; Handwritten expectations predate this implementation; no generated corpus.
	for Scenario in [Map("code", "en", "caption", "🌐 Language"), Map("code", "fr", "caption", "🌐 Langue")] {
		Code := Scenario["code"], Caption := Scenario["caption"]
		_LDDP_WithLocale(Code, _LDDP_NativeReplacement.Bind(Code, Caption))
	}
}
Test("declared language parent: original English and French native replacement", _LDDP_IndependentCaptions)

_LDDP_Withdrawal(Scenario) {
	Root := _MR_GetManifestRoot(), Rows := Root["top_level"]
	Target := Menu(), Previous := Menu(), Replacement := Menu(), Foreign := Menu()
	Label := t("menu.global.language"), Selected := false
	for Item in Rows {
		if Item.Get("id", "") == "language"
			Selected := Item
	}
	Assert(Selected is Map, "the actual current shared Language declaration exists")
	OriginalType := Selected["type"], OriginalI18n := Selected["i18n"]
	try {
		Target.Add(Label, Previous)
		Target.Disable(Label)
		Publish := MenuRenderer_GroupReplacement(Target, "top_level", "language", Previous)
		Assert(HasMethod(Publish, "Call"), "the genuine parent cohort is admitted before withdrawal")
		if Scenario == "kind"
			Selected["type"] := "dynamic"
		else if Scenario == "caption"
			Selected["i18n"] := "menu.about.title"
		else if Scenario == "duplicate"
			Rows.Push(ManifestCloneValue(Selected))
		else if Scenario == "source"
			Root["top_level"] := []
		else if Scenario == "stale"
			Target.Add(Label, Foreign)
		else if Scenario == "duplicate_child"
			Target.Add("another parent", Previous)
		else if Scenario == "duplicate_caption"
			Target.Insert("1&", Label, Foreign)
		else if Scenario == "detached"
			Target.Delete(Label)
		Count := TrayMenuItemCount(Target)
		BeforeHandle := Count ? TrayMenuSubmenuHandle(Target.Handle, 0) : 0
		BeforeState := Count ? DllCall("GetMenuState", "ptr", Target.Handle, "uint", 0, "uint", 0x400, "uint") : 0
		AssertFalse(Publish.Call(Replacement),
			"actual source or native owner withdrawal must refuse: " . Scenario)
		AssertEqual(Count, TrayMenuItemCount(Target), "refusal never creates a promised root row")
		if Count {
			AssertEqual(BeforeHandle, TrayMenuSubmenuHandle(Target.Handle, 0))
			AssertEqual(BeforeState, DllCall("GetMenuState", "ptr", Target.Handle, "uint", 0, "uint", 0x400, "uint"))
			AssertEqual(Label, TrayMenuItemCaption(Target, 0))
		}
	} finally {
		Selected["type"] := OriginalType
		Selected["i18n"] := OriginalI18n
		if Scenario == "duplicate"
			Rows.Pop()
		Root["top_level"] := Rows
		_CTC_ReleaseMenu(Target)
		_CTC_ReleaseMenu(Previous)
		_CTC_ReleaseMenu(Replacement)
		_CTC_ReleaseMenu(Foreign)
	}
}

for Scenario in ["kind", "caption", "duplicate", "source", "stale", "duplicate_child", "duplicate_caption", "detached"]
	Test("declared language parent: refuses actual withdrawal " . Scenario, _LDDP_Withdrawal.Bind(Scenario))


_LDDP_ActualProductionCohort(Scenario) {
	Root := _MR_GetManifestRoot(), Rows := Root["top_level"]
	Target := Menu(), Previous := Menu(), Replacement := Menu(), Successor := Menu()
	Label := t("menu.global.language")
	try {
		Target.Add(Label, Previous)
		Target.Disable(Label)
		Publish := MenuRenderer_GroupReplacement(Target, "top_level", "language", Previous)
		Assert(HasMethod(Publish, "Call"), "capture the genuine owner before the real locale producer")
		I18nBuildLanguageMenu(Replacement)
		AssertEqual(21, TrayMenuItemCount(Replacement), "the genuine native locale producer completed all original choices")
		if Scenario == "source_cohort"
			Root["top_level"] := ManifestCloneValue(Rows)
		else if Scenario == "native_cohort"
			Target.Add(Label, Successor)
		else if Scenario == "caption_cohort" {
			global _I18nCache, _SharedDir
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\fr.json", "UTF-8"))
		}
		Before := TrayMenuSubmenuHandle(Target.Handle, 0)
		AssertFalse(Publish.Call(Replacement), "a completed old native child cannot adopt the successor " . Scenario)
		AssertEqual(1, TrayMenuItemCount(Target))
		AssertEqual(Before, TrayMenuSubmenuHandle(Target.Handle, 0), "the successor native owner remains attached")
		AssertEqual(Label, TrayMenuItemCaption(Target, 0))
		AssertEqual(21, TrayMenuItemCount(Replacement), "refusal does not destroy a caller-owned completed child")
	} finally {
		Root["top_level"] := Rows
		_CTC_ReleaseMenu(Target)
		_CTC_ReleaseMenu(Previous)
		_CTC_ReleaseMenu(Replacement)
		_CTC_ReleaseMenu(Successor)
	}
}

_LDDP_ActualProductionWithdrawal(Scenario) {
	_LDDP_WithLocale("en", _LDDP_ActualProductionCohort.Bind(Scenario))
}
for Scenario in ["source_cohort", "native_cohort", "caption_cohort"]
	Test("declared language parent: real producer interval withdrawal " . Scenario, _LDDP_ActualProductionWithdrawal.Bind(Scenario))

_LDDP_OwnerWithdrawal(Owner) {
	Target := Menu(), Previous := Menu(), Replacement := Menu()
	Label := t("menu.global.language"), Counter := Map("hits", 0)
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	Descriptor := HadCall ? Owner.GetOwnPropDesc("Call") : false
	Observer := (*) => Counter["hits"] += 1
	try {
		Target.Add(Label, Previous)
		Target.Disable(Label)
		Publish := MenuRenderer_GroupReplacement(Target, "top_level", "language", Previous)
		Assert(HasMethod(Publish, "Call"), "genuine initial renderer custody precedes the observer")
		Owner.DefineProp("Call", {Call: Observer})
		AssertFalse(Publish.Call(Replacement), "a same-object raw producer observer withdraws admitted renderer custody")
		AssertEqual(0, Counter["hits"], "the withdrawn observer must never dispatch")
		; Restore the observer owner before using it as a genuine native reader.
		if HadCall
			Owner.DefineProp("Call", Descriptor)
		else
			Owner.DeleteProp("Call")
		AssertEqual(Previous.Handle, TrayMenuSubmenuHandle(Target.Handle, 0))
		AssertEqual(1, TrayMenuItemCount(Target))
		AssertTrue(Publish.Call(Replacement), "repair of the exact descriptor restores the original captured native owner")
		AssertEqual(Replacement.Handle, TrayMenuSubmenuHandle(Target.Handle, 0))
		AssertEqual(0, Counter["hits"], "restored native reads and publication execute no withdrawn observer")
	} finally {
		if HadCall
			Owner.DefineProp("Call", Descriptor)
		else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			Owner.DeleteProp("Call")
		_CTC_ReleaseMenu(Target)
		_CTC_ReleaseMenu(Previous)
		_CTC_ReleaseMenu(Replacement)
	}
}

for Owner in [MenuRenderer_GroupReplacement, MenuRenderer_GroupRow, _MR_GetManifestRoot, _MR_GetMenuDef,
	_MR_ReasonedGroupSnapshot, _MR_ReasonedGroupCurrent, TrayMenuItemCaption, TrayMenuHandleItemCount,
	TrayMenuSubmenuHandle, _MR_RenderRows]
	Test("declared language parent: retained raw owner refusal " . Owner.Name, _LDDP_OwnerWithdrawal.Bind(Owner))


for Owner in [t, _MR_Get, _MR_IsForAhk, MenuRenderer_ResolveDisabledWhen,
	MenuRenderer_ResolveCheckedWhen, _MR_ReportDriverDialect, _MM_GetManifestRoot, TrayMenuItemCount]
	Test("declared language parent: retained nested owner refusal " . Owner.Name, _LDDP_OwnerWithdrawal.Bind(Owner))

_LDDP_NativeMethodWithdrawal(Name) {
	Target := Menu(), Previous := Menu(), Replacement := Menu()
	Label := t("menu.global.language"), Counter := Map("hits", 0)
	Observer := (*) => Counter["hits"] += 1
	try {
		Target.Add(Label, Previous)
		Target.Disable(Label)
		Publish := MenuRenderer_GroupReplacement(Target, "top_level", "language", Previous)
		Assert(HasMethod(Publish, "Call"), "the original native method owner is captured")
		Target.DefineProp(Name, {Call: Observer})
		AssertFalse(Publish.Call(Replacement), "a native target method observer withdraws admitted custody")
		AssertEqual(0, Counter["hits"], "no native method observer may dispatch")
		AssertEqual(Previous.Handle, TrayMenuSubmenuHandle(Target.Handle, 0))
		Target.DeleteProp(Name)
		AssertTrue(Publish.Call(Replacement), "repair restores the original genuine native receiver")
		AssertEqual(Replacement.Handle, TrayMenuSubmenuHandle(Target.Handle, 0))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Target, Name)
			Target.DeleteProp(Name)
		_CTC_ReleaseMenu(Target)
		_CTC_ReleaseMenu(Previous)
		_CTC_ReleaseMenu(Replacement)
	}
}
for Name in ["Add", "Enable", "Uncheck", "Check"]
	Test("declared language parent: native destination method withdrawal " . Name, _LDDP_NativeMethodWithdrawal.Bind(Name))


for Owner in [_MR_FindItemById, _MR_IsForPlatform, I18nLookup, _I18nEnsureActiveLoaded, _I18nEnsureFallbacksLoaded]
	Test("declared language parent: actual nested alias refusal " . Owner.Name, _LDDP_OwnerWithdrawal.Bind(Owner))

_LDDP_ChildHandleWithdrawal(Which) {
	Target := Menu(), Previous := Menu(), Replacement := Menu()
	Label := t("menu.global.language"), Counter := Map("hits", 0)
	Child := Which == "previous" ? Previous : Replacement
	NativeHandle := Child.Handle
	Observer := (*) => (Counter["hits"] += 1, NativeHandle)
	try {
		Target.Add(Label, Previous)
		Target.Disable(Label)
		Publish := MenuRenderer_GroupReplacement(Target, "top_level", "language", Previous)
		Assert(HasMethod(Publish, "Call"), "the original native child is admitted before handle mutation")
		Child.DefineProp("Handle", {Get: Observer})
		AssertFalse(Publish.Call(Replacement), "a native child handle getter withdraws actual menu custody")
		AssertEqual(0, Counter["hits"], "the child handle observer must never dispatch")
		AssertEqual(1, TrayMenuItemCount(Target))
		AssertEqual(Label, TrayMenuItemCaption(Target, 0))
		AssertEqual(Which == "previous" ? NativeHandle : Previous.Handle, TrayMenuSubmenuHandle(Target.Handle, 0))
		Child.DeleteProp("Handle")
		AssertTrue(Publish.Call(Replacement), "exact original native handle descriptor repair permits publication")
		AssertEqual(Replacement.Handle, TrayMenuSubmenuHandle(Target.Handle, 0))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Child, "Handle")
			Child.DeleteProp("Handle")
		_CTC_ReleaseMenu(Target)
		_CTC_ReleaseMenu(Previous)
		_CTC_ReleaseMenu(Replacement)
	}
}
for Which in ["previous", "replacement"]
	Test("declared language parent: actual child handle withdrawal " . Which, _LDDP_ChildHandleWithdrawal.Bind(Which))
