; static/ergopti_plus/windows/tests/unit/test_manifest_menu_checked_when.ahk

; ==============================================================================
; MODULE: Declarative checked_when resolver
; DESCRIPTION:
; The first of the manifest capabilities Lot 5 needs: a row's checkmark is
; declared beside the row instead of restated in its handler.
;
; Before this, the three metrics filter handlers each carried their own
; `if MetricsFilters.<field>` line. The manifest described when the row was
; DISABLED but said nothing about when it was CHECKED, so half of each row's
; state lived in the description and half in the code — and only the half in the
; code actually decided anything.
;
; WHY THIS FAILS OPEN WHERE disabled_when FAILS CLOSED:
; A checkmark is an assertion to the user that something is currently on.
; Inventing one when the state cannot be read tells them a privacy filter is
; active when it is not: they stop looking for the setting, and the data they
; believed excluded keeps being recorded. Its sibling fails CLOSED for the same
; underlying reason — in both directions the safe answer is the one that does
; not overstate what is enabled. These tests pin that asymmetry, because
; "make it consistent with disabled_when" is the obvious-looking change that
; would break it.
; ==============================================================================





; ==================================================
; ==================================================
; ======= 1/ The predicate decides the check =======
; ==================================================
; ==================================================

Test("checked_when: all getters truthy checks the row", () => (
	AssertTrue(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "filter_private", Map(
			"metrics_filter_private", () => true
		)),
		"a row whose checked_when getter returns true must be checked"
	)
))

Test("checked_when: a falsy getter leaves the row unchecked", () => (
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "filter_private", Map(
			"metrics_filter_private", () => false
		)),
		"a row whose checked_when getter returns false must not be checked"
	)
))

Test("checked_when: a row that declares none is never checked", () => (
	; keylogger_enabled has disabled_when but no checked_when. It must not
	; inherit a checkmark from the sibling predicate.
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "show_apps", Map()),
		"a row with no checked_when array must resolve to unchecked"
	)
))




; ==========================================================
; ==========================================================
; ======= 2/ Failing OPEN, unlike disabled_when ============
; ==========================================================
; ==========================================================

Test("checked_when: an unknown item id resolves UNCHECKED", () => (
	; The mirror case of test_manifest_menu_resolve_disabled_when_failclosed,
	; and deliberately the opposite answer.
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "_no_such_item_xyz_", Map()),
		"an unknown id must not produce a checkmark asserting state nobody read"
	)
))

Test("checked_when: a missing getter resolves UNCHECKED", () => (
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "filter_private", Map()),
		"a declared key with no getter must not produce a checkmark"
	)
))

Test("checked_when: an unknown menu key resolves UNCHECKED", () => (
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("_no_such_menu_key_", "filter_private", Map()),
		"an unknown menu key must not produce a checkmark"
	)
))




; ================================================
; ================================================
; ======= 3/ The three rows are declared ==========
; ================================================
; ================================================

; The capability is only real if a row uses it. These pin the migration itself:
; each filter row must carry the predicate its handler used to hardcode.

Test("checked_when: the three metrics filters declare their predicate", () => (
	AssertTrue(
		_MMC_DeclaresCheckedWhen("filter_private")
			and _MMC_DeclaresCheckedWhen("filter_secure")
			and _MMC_DeclaresCheckedWhen("filter_sysauth"),
		"each metrics filter row must declare checked_when — without it the handler "
			. "silently stops checking the box and the filter looks off while being on"
	)
))

; Returns true when the named metrics_menu row carries a non-empty checked_when.
_MMC_DeclaresCheckedWhen(ItemId) {
	for Row in _MR_GetMenuDef("metrics_menu") {
		if (_MR_Get(Row, "id") == ItemId) {
			Keys := _MR_Get(Row, "checked_when", 0)
			return (Keys is Array) and Keys.Length > 0
		}
	}
	return false
}

; The template branch delegates the existing native check owner; it must not
; invent a new checked/readiness policy or lose a retained refusal receipt.
_MMC_TemplateProbe() {
	Root := _MR_GetManifestRoot()
	ProbeKey := "__checked_template_probe"
	Assert(!Root.Has(ProbeKey), "independent fixture owns its exact temporary section")
	Root[ProbeKey] := [Map("type", "check", "id", "probe_check", "i18n", "menu.gestures.mode_single",
		"checked_when", ["probe_checked"], "disabled_when", ["probe_ready"])]
	State := Map("ready", true, "checked", true, "calls", 0)
	Commands := Map("probe_check", () => _MMC_TemplateRefusal(State))
	Getters := Map("probe_checked", () => State["checked"], "probe_ready", () => State["ready"])
	Rendered := Menu()
	try {
		Rows := MenuRenderer_TemplateRows(ProbeKey, Commands, Getters, Map())
		Assert(Rows is Array && Rows.Length == 1, "real native template returns one check row")
		Assert(Rows[1]["checked"], "declared checked getter reaches provider data")
		AssertEqual(1, _MR_RenderRows(Rendered, Rows, ProbeKey, 1), "actual native renderer consumes check template")
		NativeFlags := DllCall("GetMenuState", "ptr", Rendered.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(NativeFlags != 0xFFFFFFFF && (NativeFlags & 0x8), "actual Win32 item is checked")
		State["ready"] := false
		AssertEqual(false, Rows[1]["action"].Call(), "held callback refuses current readiness withdrawal")
		AssertEqual(0, State["calls"], "withdrawal never delivers to command")
		State["ready"] := true
		AssertEqual(false, Rows[1]["action"].Call(), "native command refusal receipt is propagated")
		AssertEqual(1, State["calls"], "ready command delivered exactly once")
		AssertEqual(false, MenuRenderer_TemplateRows(ProbeKey, Map(), Getters, Map()), "missing command refuses entire template")
		Root[ProbeKey][1]["platforms"] := ["hs", "linux"]
		Hidden := MenuRenderer_TemplateRows(ProbeKey, Commands, Getters, Map())
		Assert(Hidden is Array && Hidden.Length == 0, "template hides unavailable native check rows")
	} finally {
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
		Root.Delete(ProbeKey)
	}
}
_MMC_TemplateRefusal(State) {
	State["calls"] += 1
	return false
}
Test("checked_when: real check template preserves native flags, current readiness and refusal", _MMC_TemplateProbe)


; The actual fourth port supplies lazy canonical data; shared includes own the
; frame ordering and predicate. The ordinary native renderer remains unchanged.
_MMC_FrameNative(State) {
	State["calls"] += 1
	return false
}
_MMC_FrameList(State, Rows, Phase, Args*) {
	AssertEqual(0, Args.Length, "template list provider receives no synthetic context")
	State["phases"].Push(Phase)
	return Rows
}
_MMC_FramePresence(State) {
	State["phases"].Push("custom_present")
	return State["present"]
}
_MMC_FrameThrow() {
	throw Error("Independent native provider refusal")
}
_MMC_FrameProbe(Mode) {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_frame_template_api.json"))
	Root := _MR_GetManifestRoot()
	Keys := ["frame", "conditional", "commands"]
	for Key in Keys
		Assert(!Root.Has(Key), "independent temporary frame must not replace a production declaration")
	for Key in Keys
		Root[Key] := Corpus[Key]
	State := Map("ready", true, "present", true, "calls", 0, "phases", [])
	Builtin := Map("label", "Builtin native", "checked", true, "action", _MMC_FrameNative.Bind(State))
	Custom := Map("label", "Custom native", "items", [Map("label", "Native child", "action", _MMC_FrameNative.Bind(State))])
	Commands := Map("create", _MMC_FrameNative.Bind(State), "clone", _MMC_FrameNative.Bind(State))
	Getters := Map("ready", () => State["ready"], "custom_present", _MMC_FramePresence.Bind(State))
	Children := Map("builtins", _MMC_FrameList.Bind(State, [Builtin], "builtins"),
		"customs", _MMC_FrameList.Bind(State, [Custom], "customs"))
	NativeMenu := Menu()
	try {
		if Mode == "absent"
			State["present"] := false
		else if Mode == "empty"
			Children := Map("builtins", () => [], "customs", () => [])
		else if Mode == "missing-provider"
			Children.Delete("builtins")
		else if Mode == "noncallable-provider"
			Children["builtins"] := []
		else if Mode == "throw-provider"
			Children["builtins"] := _MMC_FrameThrow
		else if Mode == "wrong-result"
			Children["builtins"] := () => false
		else if Mode == "sparse-result" {
			Sparse := []
			Sparse.Length := 2
			Sparse[2] := Builtin
			Children["builtins"] := () => Sparse
		} else if Mode == "scalar-child"
			Children["builtins"] := () => [false]
		else if Mode == "driver-dialect"
			Children["builtins"] := () => [Map("title", "wrong", "fn", _MMC_FrameThrow)]
		else if Mode == "missing-label"
			Children["builtins"] := () => [Map("action", _MMC_FrameThrow)]
		else if Mode == "missing-getter"
			Getters.Delete("custom_present")
		else if Mode == "noncallable-getter"
			Getters["custom_present"] := true
		else if Mode == "throw-getter"
			Getters["custom_present"] := _MMC_FrameThrow
		else if Mode == "integer-getter"
			Getters["custom_present"] := () => 2
		else if Mode == "float-getter"
			Getters["custom_present"] := () => 1.0
		else if Mode == "string-getter"
			Getters["custom_present"] := () => "true"
		else if Mode == "empty-getter"
			Root["frame"][3]["present_when"] := ""
		else if Mode == "missing-selector"
			Root["frame"][4]["row_id"] := "missing"
		else if Mode == "empty-selector"
			Root["frame"][4]["row_id"] := ""
		else if Mode == "wrong-selector"
			Root["frame"][4]["row_id"] := false
		else if Mode == "duplicate-selector"
			Root["commands"][1]["id"] := "clone"
		else if Mode == "absent-target-when-false" {
			State["present"] := false
			Root["frame"][3]["section"] := "missing"
		} else if Mode == "include-metadata"
			Root["frame"][4]["i18n"] := "competing native caption"
		else if Mode == "list-metadata"
			Root["frame"][2]["i18n"] := "competing native caption"
		Rows := MenuRenderer_TemplateRows("frame", Commands, Getters, Children)
		if Mode != "present" && Mode != "absent" && Mode != "empty" {
			AssertEqual(false, Rows, "invalid native ports or shared policy refuse the whole frame")
			AssertEqual(0, State["calls"], "no command owner receives a refused frame")
			return
		}
		Assert(Rows is Array, "actual template supplies canonical native row array")
		if Mode == "empty" {
			AssertEqual(6, Rows.Length, "empty provider arrays do not remove fixed shared rows")
			return
		}
		Expected := Corpus["_expected"][Mode]
		AssertEqual(Expected.Length, Rows.Length, "all independent frame positions are consumed")
		for Index, Label in Expected {
			if Label == "---"
				Assert(Rows[Index].Get("separator", false), "independently declared separator position")
			else
				AssertEqual(InStr(Label, "menu.") == 1 ? t(Label) : Label, Rows[Index]["label"], "exact independent native frame label")
		}
		Assert(Rows[2] == Builtin, "list keeps exact native row identity")
		AssertEqual("builtins", State["phases"][1], "native builtins run at their source position")
		AssertEqual("custom_present", State["phases"][2], "presence observes the later native phase")
		if Mode == "present" {
			Assert(Rows[5] == Custom, "custom native subtree identity is retained")
			AssertEqual("customs", State["phases"][3], "custom provider follows presence")
			Assert(_MR_RenderRows(NativeMenu, Rows, "frame", 1) > 0, "actual Win32 menu consumes the canonical full frame")
			Flags := DllCall("GetMenuState", "ptr", NativeMenu.Handle, "uint", 1, "uint", 0x400, "uint")
			Assert(Flags != 0xFFFFFFFF && (Flags & 0x8), "native builtin checkmark survives list composition")
			AssertEqual(false, Rows[6]["action"].Call(), "native refusal receipt remains false")
			AssertEqual(1, State["calls"])
			State["ready"] := false
			AssertEqual(false, Rows[6]["action"].Call(), "retained declared command checks current readiness")
			AssertEqual(1, State["calls"])
			State["ready"] := true
			Root["commands"][2]["id"] := "withdrawn"
			AssertEqual(false, Rows[6]["action"].Call(), "selected declaration withdrawal refuses delivery")
			AssertEqual(1, State["calls"])
		} else
			AssertEqual(2, State["phases"].Length, "absent fragment never invokes its native list")
	} finally {
		NativeMenu.Delete()
		MenuDispatcher_PruneMenu(NativeMenu)
		for Key in Keys
			Root.Delete(Key)
	}
}
for Mode in ["present", "absent", "empty", "missing-provider", "noncallable-provider", "throw-provider",
	"wrong-result", "sparse-result", "scalar-child", "driver-dialect", "missing-label", "missing-getter",
	"noncallable-getter", "throw-getter", "integer-getter", "float-getter", "string-getter", "empty-getter",
	"missing-selector", "empty-selector", "wrong-selector", "duplicate-selector", "absent-target-when-false",
	"include-metadata", "list-metadata"]
	Test("ordered template frame: " . Mode, _MMC_FrameProbe.Bind(Mode))


_MMC_LazyGroupAuto(State) {
	State["phases"].Push("autodetect")
	return true
}
_MMC_LazyGroupProbe(Mode) {
	Root := _MR_GetManifestRoot()
	ProbeKey := "__lazy_group_frame_probe"
	Assert(!Root.Has(ProbeKey), "lazy group fixture never overwrites production data")
	Root[ProbeKey] := [
		Map("type", "list", "id", "builtins"), Map("type", "list", "id", "customs"),
		Map("type", "check", "id", "auto", "i18n", "menu.profiles.auto_detect", "checked_when", ["auto_checked"]),
		Map("type", "group", "id", "apps", "i18n", "menu.profiles.per_app_overrides", "disabled_when", ["group_ready"])]
	State := Map("calls", 0, "phases", [])
	NativeRow := Map("label", "Native application", "action", _MMC_FrameNative.Bind(State))
	ExistingChildren := [NativeRow]
	Children := Map("builtins", _MMC_FrameList.Bind(State, [Map("label", "Builtin")], "builtins"),
		"customs", _MMC_FrameList.Bind(State, [Map("label", "Custom")], "customs"),
		"apps", _MMC_FrameList.Bind(State, ExistingChildren, "perapp"))
	Commands := Map("auto", _MMC_FrameNative.Bind(State))
	Getters := Map("auto_checked", _MMC_LazyGroupAuto.Bind(State), "group_ready", () => Mode != "eager")
	NativeMenu := Menu()
	try {
		if Mode == "eager"
			Children["apps"] := ExistingChildren
		else if Mode == "missing"
			Children.Delete("apps")
		else if Mode == "noncallable"
			Children["apps"] := true
		else if Mode == "throw"
			Children["apps"] := _MMC_FrameThrow
		else if Mode == "wrongtype"
			Children["apps"] := () => false
		else if Mode == "sparse" {
			Sparse := []
			Sparse.Length := 2
			Sparse[2] := NativeRow
			Children["apps"] := () => Sparse
		} else if Mode == "scalar"
			Children["apps"] := () => [false]
		else if Mode == "dialect"
			Children["apps"] := () => [Map("title", "wrong", "fn", _MMC_FrameThrow)]
		else if Mode == "missing-label"
			Children["apps"] := () => [Map("action", _MMC_FrameThrow)]
		Rows := MenuRenderer_TemplateRows(ProbeKey, Commands, Getters, Children)
		if Mode != "present" && Mode != "eager" {
			AssertEqual(false, Rows, "invalid lazy group data refuses whole frame")
			AssertEqual(0, State["calls"], "refused frame has no command effects")
			return
		}
		Assert(Rows is Array && Rows.Length == 4, "actual native phase frame has all four positions")
		AssertEqual("builtins", State["phases"][1])
		AssertEqual("customs", State["phases"][2])
		AssertEqual("autodetect", State["phases"][3])
		Assert(Rows[4]["items"][1] == NativeRow, "native child row identity survives lazy group")
		if Mode == "eager" {
			Assert(Rows[4]["items"] == ExistingChildren, "existing eager Array identity remains exact")
			Assert(Rows[4]["disabled"], "existing group readiness policy still disables")
			AssertEqual(3, State["phases"].Length, "eager data does not fabricate a lazy read")
		} else {
			AssertEqual("perapp", State["phases"][4], "actual per-app data reads last")
			Assert(_MR_RenderRows(NativeMenu, Rows, ProbeKey, 1) > 0, "actual native renderer consumes lazy group")
			Handle := DllCall("GetSubMenu", "ptr", NativeMenu.Handle, "int", 3, "ptr")
			Assert(Handle != 0 && DllCall("GetMenuItemCount", "ptr", Handle, "int") == 1, "actual Win32 submenu contains native child")
			AssertEqual(false, Rows[4]["items"][1]["action"].Call(), "native child refusal receipt remains false")
			AssertEqual(1, State["calls"])
		}
	} finally {
		NativeMenu.Delete()
		MenuDispatcher_PruneMenu(NativeMenu)
		Root.Delete(ProbeKey)
	}
}
for Mode in ["present", "eager", "missing", "noncallable", "throw", "wrongtype", "sparse", "scalar", "dialect", "missing-label"]
	Test("ordered template lazy native group: " . Mode, _MMC_LazyGroupProbe.Bind(Mode))


_MMC_RawProviderShapeProbe(Mode) {
	Root := _MR_GetManifestRoot()
	ProbeKey := "__raw_provider_shape_probe"
	Assert(!Root.Has(ProbeKey), "raw-provider fixture owns a fresh declaration")
	Child := InStr(Mode, "empty") ? Map("label", "") : Map("label", "Native", "separator", "true")
	Group := InStr(Mode, "group") > 0
	Root[ProbeKey] := [Group
		? Map("type", "group", "id", "data", "i18n", "menu.profiles.per_app_overrides")
		: Map("type", "list", "id", "data")]
	try AssertEqual(false, MenuRenderer_TemplateRows(ProbeKey, Map(), Map(), Map("data", () => [Child])),
		"malformed physical provider row cannot become a partial or silently skipped menu")
	finally Root.Delete(ProbeKey)
}
for Mode in ["empty-list", "separator-list", "empty-group", "separator-group"]
	Test("ordered template raw provider shape: " . Mode, _MMC_RawProviderShapeProbe.Bind(Mode))

; An opted-in inert fragment is preflighted before clicked/getter metadata can run.
_MMC_PresentationGetter(State) {
	State["getters"] += 1
	return true
}
_MMC_PresentationProbe(Mode) {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_frame_presentation_omission.json"))
	Root := _MR_GetManifestRoot()
	Keys := ["frame", "presentation", "nested"]
	for Key in Keys
		Assert(!Root.Has(Key), "inert presentation probe owns its temporary declarations")
	for Key in Keys
		Root[Key] := Corpus[Key]
	State := Map("calls", 0, "getters", 0, "phases", [])
	Builtin := Map("label", "Builtin native", "checked", true, "action", _MMC_FrameNative.Bind(State))
	Custom := Map("label", "Custom native", "items", [Map("label", "Native child", "action", _MMC_FrameNative.Bind(State))])
	Commands := Map("forbidden", _MMC_FrameNative.Bind(State))
	Getters := Map("forbidden", _MMC_PresentationGetter.Bind(State))
	Children := Map("builtins", _MMC_FrameList.Bind(State, [Builtin], "builtins"),
		"customs", _MMC_FrameList.Bind(State, [Custom], "customs"))
	NativeMenu := Menu()
	try {
		switch Mode {
			case "missing": Root["frame"][1]["section"] := "missing"
			case "empty": Root["presentation"] := []
			case "caption": Root["presentation"][1]["i18n"] := ""
			case "command": Root["presentation"][3] := Map("type", "command", "id", "forbidden", "i18n", "caption", "disabled_when", ["forbidden"])
			case "group": Root["presentation"][3] := Map("type", "group", "id", "customs", "i18n", "caption")
			case "getter": Root["nested"][1]["caption_getter"] := "forbidden"
			case "callback": Root["presentation"][1]["action"] := _MMC_FrameThrow
			case "nested-presence": Root["presentation"][3]["present_when"] := "forbidden"
			case "cycle": Root["presentation"][3]["section"] := "presentation"
			case "platforms": Root["presentation"][1]["platforms"] := "ahk"
			case "sparse": Root["presentation"].Delete(2)
			case "selected-clicked":
				Root["frame"][1]["row_id"] := "safe"
				Root["presentation"][1]["id"] := "safe"
				Root["presentation"][3] := Map("type", "command", "id", "forbidden", "i18n", "caption", "disabled_when", ["forbidden"])
			case "enum": Root["frame"][1]["on_refusal"] := "ignore"
			case "wrong-case-enum": Root["frame"][1]["on_refusal"] := "OMIT_PRESENTATION"
			case "selector": Root["frame"][1]["row_id"] := "missing"
			case "presence": Root["frame"][1]["present_when"] := "missing"
			case "provider": Children["customs"] := _MMC_FrameThrow
			case "ordinary":
				Root["frame"][1].Delete("on_refusal")
				Root["frame"][1]["section"] := "missing"
		}
		Rows := MenuRenderer_TemplateRows("frame", Commands, Getters, Children)
		AssertEqual(0, State["calls"], "preflight never delivers a mutated command")
		AssertEqual(0, State["getters"], "preflight never evaluates a mutated target getter")
		if Mode == "enum" || Mode == "wrong-case-enum" || Mode == "selector" || Mode == "presence" || Mode == "provider" || Mode == "ordinary" {
			AssertEqual(false, Rows, "identity, presence and native failures stay strict refusals")
			return
		}
		Assert(Rows is Array, "native data survives refusal of opted-in presentation")
		Offset := Mode == "present" ? 3 : 0
		AssertEqual(Offset + 2, Rows.Length, "complete inert fragment or both unchanged native data rows")
		Assert(Rows[Offset + 1] == Builtin && Rows[Offset + 2] == Custom, "physical native rows keep their identity")
		AssertEqual("builtins", State["phases"][1])
		AssertEqual("customs", State["phases"][2])
		if Mode == "present" {
			AssertEqual(MenuSectionTitle(t("menu.profiles.header_default_profiles")), Rows[1]["label"])
			Assert(Rows[1]["disabled"] && !Rows[1].Has("action"), "heading stays inert")
			Assert(Rows[2]["separator"])
			AssertEqual(t("menu.profiles.header_custom_profiles"), Rows[3]["label"])
		}
		Assert(_MR_RenderRows(NativeMenu, Rows, "frame", 1) > 0, "actual Win32 menu consumes surviving native rows")
		Flags := DllCall("GetMenuState", "ptr", NativeMenu.Handle, "uint", Offset, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x8), "native check survives an omitted presentation fragment")
		AssertEqual(false, Rows[Offset + 1]["action"].Call(), "native false receipt remains unchanged")
		AssertEqual(1, State["calls"])
	} finally {
		NativeMenu.Delete()
		MenuDispatcher_PruneMenu(NativeMenu)
		for Key in Keys
			Root.Delete(Key)
	}
}
for Mode in ["present", "missing", "empty", "caption", "command", "group", "getter", "callback", "nested-presence", "cycle", "platforms", "sparse", "selected-clicked", "enum", "wrong-case-enum", "selector", "presence", "provider", "ordinary"]
	Test("inert presentation omission retains native data: " . Mode, _MMC_PresentationProbe.Bind(Mode))

_MMC_SelectedMalformedPresentation() {
	Root := _MR_GetManifestRoot()
	FrameKey := "__selected_malformed_presentation_frame"
	TargetKey := "__selected_malformed_presentation_target"
	Assert(!Root.Has(FrameKey) && !Root.Has(TargetKey), "selected malformed target probe owns fresh source identities")
	Root[FrameKey] := [Map("type", "include", "section", TargetKey, "row_id", "safe", "on_refusal", "omit_presentation"),
		Map("type", "list", "id", "native")]
	Root[TargetKey] := [Map("type", "section_header", "id", "safe", "i18n", "menu.profiles.header_default_profiles"), false]
	Native := Map("label", "Native survivor", "checked", true)
	Built := Menu()
	try {
		Rows := MenuRenderer_TemplateRows(FrameKey, Map(), Map(), Map("native", () => [Native]))
		Assert(Rows is Array, "a valid exact selector does not index a malformed sibling before inert omission")
		AssertEqual(1, Rows.Length)
		Assert(Rows[1] == Native, "malformed whole target omission retains the original native row")
		Assert(_MR_RenderRows(Built, Rows, FrameKey, 1) > 0)
		State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF && (State & 0x8), "actual native check survives selected presentation refusal")
	} finally {
		Built.Delete()
		MenuDispatcher_PruneMenu(Built)
		Root.Delete(FrameKey)
		Root.Delete(TargetKey)
	}
}
Test("selected inert presentation: malformed sibling omits heading and retains actual native row", _MMC_SelectedMalformedPresentation)


_MMC_ReasonedToggleData() {
	Root := _MR_GetManifestRoot(), Key := "__reasoned_toggle_behavior_fixture"
	AssertFalse(Root.Has(Key), "the fixture requires an unoccupied declaration")
	Item := Map("type", "toggle", "id", "power", "category", "LLM", "i18n", "menu.llm.enable",
		"checked_when", ["on"], "disabled_when", ["ready"], "disabled_reason_key", "menu.llm.save_unavailable")
	Root[Key] := [Item]
	Ready := false, Calls := 0
	Action(*) => Calls += 1
	Commands := Map("power", Action), Getters := Map("on", () => true, "ready", () => Ready)
	try {
		Disabled := _MR_ToggleRowData(Item, Key, Commands, Getters)
		Assert(Disabled is Map)
		AssertEqual(t("menu.llm.enable"), Disabled["label"])
		AssertTrue(Disabled["checked"])
		AssertTrue(Disabled["disabled"])
		AssertEqual("menu.llm.save_unavailable", Disabled["disabled_reason_key"])
		AssertFalse(Disabled.Has("action"), "a reasoned disabled switch has no delivery callback")
		Ready := true
		Enabled := _MR_ToggleRowData(Item, Key, Commands, Getters)
		AssertEqual(t("menu.llm.enable"), Enabled["label"])
		AssertTrue(Enabled["checked"])
		AssertFalse(Enabled.Has("disabled_reason_key"))
		AssertFalse(Enabled.Has("disabled"))
		Assert(Enabled["action"] == Action, "the enabled switch retains its exact callback")
		Enabled["action"].Call()
		AssertEqual(1, Calls)
	} finally Root.Delete(Key)
}
Test("reasoned-toggle: actual Windows row data removes disabled delivery and preserves enabled identity", _MMC_ReasonedToggleData)
