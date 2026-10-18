; tests/unit/ui/menu/test_manifest_menu_parent_groups.ahk

; ==============================================================================
; MODULE: Manifest Menu Profile, Generic and Fixed Parents
; DESCRIPTION:
; The Windows profile parent, the generic reasoned group and the fixed
; parents keep the original 21-language captions and native children, and
; their captured entries refuse withdrawal, rebinding and own Call.
; ==============================================================================

#Requires AutoHotkey v2.0





; Independent native profile parent/frame checks; the original profile catalogue stays native.
_WPF_WithState(Body) {
	global _I18nCache, _I18nCacheLoaded, _SharedDir
	Root := _MR_GetManifestRoot()
	Keys := ["llm_profile_parent_ahk", "llm_profile_parent_frame_ahk", "llm_after_profile_boundary"]
	Previous := Map()
	for Key in Keys {
		AssertTrue(Root.Has(Key), "the genuine profile presentation declaration exists")
		Previous[Key] := Root[Key]
	}
	HadCache := IsSet(_I18nCache), HadLoaded := IsSet(_I18nCacheLoaded)
	SavedCache := HadCache ? _I18nCache : false
	SavedLoaded := HadLoaded ? _I18nCacheLoaded : false
	try Body.Call(Root)
	finally {
		for Key in Keys
			Root[Key] := Previous[Key]
		_I18nCache := HadCache ? SavedCache : unset
		_I18nCacheLoaded := HadLoaded ? SavedLoaded : unset
	}
}

_WPF_Captions() {
	_WPF_WithState(_WPF_CheckCaptions)
}

_WPF_CheckCaptions(Root) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_llm_profile_parent_captions.json", "UTF-8"))
	AssertEqual(21, Corpus.Count, "the frozen predecessor contains every supported translation")
	Calls := Map("count", 0)
	for Language, Subject in Corpus {
		_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
		_I18nCacheLoaded := true
		Child := Menu(), Target := Menu()
		try {
			Child.Add("Original native profile", (*) => Calls["count"] += 1)
			Rows := _LLM_Menu_ProfileParentRows(Child, Subject["subject"], false)
			AssertTrue(Rows is Array, "the actual native profile parent provider returns data")
			AssertEqual(2, Rows.Length, "the completed parent precedes exactly one boundary")
			AssertEqual(Subject["expected"], Rows[1]["label"], "the frozen old translated caption stays exact")
			AssertTrue(Rows[1]["submenu"] == Child, "the original Menu object is the child, not a reconstructed copy")
			AssertFalse(Rows[1].Get("disabled", false), "enabled settings retain their active parent")
			AssertTrue(Rows[2].Get("separator", false), "the whole frame owns its following boundary")
			AssertEqual(1, MenuRenderer_AppendRows(Target, "llm_menu", "llm_profile_parent_frame_ahk", Rows))
			AssertEqual(2, TrayMenuItemCount(Target), "native Win32 image keeps its literal terminal separator")
			AssertEqual(Subject["expected"], _CLP_NativeCaption(Target, 1))
			AssertEqual(Child.Handle, DllCall("GetSubMenu", "Ptr", Target.Handle, "Int", 0, "Ptr"))
			AssertTrue(TrayMenuIsSeparatorAt(Target, 1), "actual native order agrees with the independent image")
			AssertEqual(0, Calls["count"], "building the parent never executes a profile choice")
		} finally {
			try Target.Delete()
			finally {
				MenuDispatcher_PruneMenu(Target)
				Child.Delete()
			}
		}
	}
}

_WPF_Disabled() {
	_WPF_WithState(_WPF_CheckDisabled)
}

_WPF_CheckDisabled(Root) {
	Child := Menu()
	try {
		Rows := _LLM_Menu_ProfileParentRows(Child, "Native profile", true)
		AssertTrue(Rows is Array)
		AssertTrue(Rows[1].Get("disabled", false), "off state greys the completed native parent")
		AssertTrue(Rows[1]["submenu"] == Child, "disabled state retains even an empty original Menu")
		AssertTrue(Rows[2]["separator"], "disabled state does not remove the boundary")
	} finally Child.Delete()
}

_WPF_Withdrawn() {
	_WPF_WithState(_WPF_CheckWithdrawn)
}

_WPF_CheckWithdrawn(Root) {
	Child := Menu(), Key := "llm_profile_parent_ahk", Frame := "llm_profile_parent_frame_ahk"
	Parent := Root[Key], OriginalFrame := Root[Frame]
	try {
		Root.Delete(Key)
		AssertFalse(_LLM_Menu_ProfileParentRows(Child, "Native profile", false), "withdrawn parent refuses whole provider")
		Root[Key] := Parent
		Root.Delete(Frame)
		AssertFalse(_LLM_Menu_ProfileParentRows(Child, "Native profile", false), "withdrawn frame refuses whole provider")
		Root[Frame] := OriginalFrame
		AssertFalse(_LLM_Menu_ProfileParentRows(Map(), "Native profile", false), "a copied public Map is not the original Menu child")
		AssertTrue(_LLM_Menu_ProfileParentRows(Child, "Native profile", false) is Array, "exact repaired source restores provider")
	} finally Child.Delete()
}

_WPF_Order() {
	_WPF_WithState(_WPF_CheckOrder)
}

_WPF_CheckOrder(Root) {
	Frame := Root["llm_profile_parent_frame_ahk"]
	Root["llm_profile_parent_frame_ahk"] := [Frame[2], Frame[1]]
	Child := Menu(), Target := Menu()
	try {
		Rows := _LLM_Menu_ProfileParentRows(Child, "Native profile", false)
		AssertTrue(Rows[1].Get("separator", false), "declaration order controls genuine first position")
		AssertTrue(Rows[2]["submenu"] == Child, "reordering declaration moves the genuine native child")
		AssertEqual(1, MenuRenderer_AppendRows(Target, "llm_menu", "llm_profile_parent_frame_ahk", Rows))
		AssertTrue(TrayMenuIsSeparatorAt(Target, 0))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "Ptr", Target.Handle, "Int", 1, "Ptr"))
	} finally {
		try Target.Delete()
		finally {
			MenuDispatcher_PruneMenu(Target)
			Child.Delete()
		}
	}
}

; Calls the same original production entry on predecessor and candidate.
; The intentionally absent profile field proves complete frame admission precedes native data reads.
_WPF_ProductionRefusal() {
	_WPF_WithState(_WPF_CheckProductionRefusal)
}

_WPF_CheckProductionRefusal(Root) {
	global _LLM_Menu, _LLM_Menu_Handle
	HadMenu := IsSet(_LLM_Menu), HadHandle := IsSet(_LLM_Menu_Handle)
	SavedMenu := HadMenu ? _LLM_Menu : false
	SavedHandle := HadHandle ? _LLM_Menu_Handle : false
	Target := Menu(), Failure := ""
	try {
		_LLM_Menu := Map()
		_LLM_Menu_Handle := Target
		Root.Delete("llm_profile_parent_frame_ahk")
		try _LLM_Menu_EmitRow(_LLM_Menu_Handle, "llm_profile", false, false)
		catch as Err
			Failure := Err.Message
		AssertEqual("Declared profile parent frame was refused.", Failure,
			"actual preexisting entry refuses the withdrawn frame before reading native profile data")
		AssertEqual(0, TrayMenuItemCount(Target), "no partial detached target may be exposed")
	} finally {
		_LLM_Menu := HadMenu ? SavedMenu : unset
		_LLM_Menu_Handle := HadHandle ? SavedHandle : unset
		try Target.Delete()
		finally MenuDispatcher_PruneMenu(Target)
	}
}

Test("Windows profile parent: all 21 frozen captions retain actual native child and boundary", _WPF_Captions)
Test("Windows profile parent: disabled and empty original Menu identity remain exact", _WPF_Disabled)
Test("Windows profile parent: source withdrawal and fake native identity refuse completely", _WPF_Withdrawn)
Test("Windows profile parent: declaration reorder controls the actual native image", _WPF_Order)
Test("Windows profile parent: actual original entry admits frame before profile data reads", _WPF_ProductionRefusal)

; Keeps frame and boundary admitted while withdrawing only their separate parent owner.
; The absent native profile datum arms the actual-entry ordering regression independently.
_WPF_ProductionParentRefusal() {
	_WPF_WithState(_WPF_CheckProductionParentRefusal)
}

_WPF_CheckProductionParentRefusal(Root) {
	global _LLM_Menu, _LLM_Menu_Handle
	HadMenu := IsSet(_LLM_Menu), HadHandle := IsSet(_LLM_Menu_Handle)
	SavedMenu := HadMenu ? _LLM_Menu : false
	SavedHandle := HadHandle ? _LLM_Menu_Handle : false
	Target := Menu(), Failure := ""
	try {
		_LLM_Menu := Map()
		_LLM_Menu_Handle := Target
		AssertFalse(_LLM_Menu.Has("profile_id"), "missing profile datum is armed before the actual original entry")
		AssertTrue(Root.Has("llm_profile_parent_frame_ahk"), "the complete frame remains present")
		AssertTrue(Root.Has("llm_after_profile_boundary"), "the existing boundary remains present")
		Root.Delete("llm_profile_parent_ahk")
		try _LLM_Menu_EmitRow(_LLM_Menu_Handle, "llm_profile", false, false)
		catch as Err
			Failure := Err.Message
		AssertEqual("Declared profile parent frame was refused.", Failure,
			"actual preexisting entry refuses the withdrawn parent before reading absent native profile data")
		AssertEqual(0, TrayMenuItemCount(Target), "withdrawn parent exposes no partial native rows")
	} finally {
		_LLM_Menu := HadMenu ? SavedMenu : unset
		_LLM_Menu_Handle := HadHandle ? SavedHandle : unset
		try Target.Delete()
		finally MenuDispatcher_PruneMenu(Target)
	}
}

Test("Windows profile parent: actual original entry admits separate parent before profile data reads", _WPF_ProductionParentRefusal)

; The current captured-row production entry must admit the separate parent before data.
_WPF_CurrentCapturedParentRefusal() {
	_WPF_WithState(_WPF_CheckCurrentCapturedParentRefusal)
}

_WPF_CheckCurrentCapturedParentRefusal(Root) {
	global _LLM_Menu, _LLM_Menu_Handle
	HadMenu := IsSet(_LLM_Menu), HadHandle := IsSet(_LLM_Menu_Handle)
	SavedMenu := HadMenu ? _LLM_Menu : false
	SavedHandle := HadHandle ? _LLM_Menu_Handle : false
	Target := Menu(), Failure := ""
	try {
		_LLM_Menu := Map()
		_LLM_Menu_Handle := Target
		AssertFalse(_LLM_Menu.Has("profile_id"), "absent actual profile state arms the read-order regression")
		AssertTrue(Root.Has("llm_profile_parent_frame_ahk"), "the whole frame is still admitted")
		AssertTrue(Root.Has("llm_after_profile_boundary"), "the original following boundary is still admitted")
		Root.Delete("llm_profile_parent_ahk")
		try _LLM_Menu_EmitCapturedRow(_LLM_Menu_Handle, "llm_profile", false, false, false, [], Target, "LLM")
		catch as Err
			Failure := Err.Message
		AssertEqual("Declared profile parent frame was refused.", Failure,
			"the same captured production callback must refuse before any actual profile data read")
		AssertEqual(0, TrayMenuItemCount(Target), "refused captured publication creates no native rows")
	} finally {
		_LLM_Menu := HadMenu ? SavedMenu : unset
		_LLM_Menu_Handle := HadHandle ? SavedHandle : unset
		try Target.Delete()
		finally MenuDispatcher_PruneMenu(Target)
	}
}

Test("Windows profile parent: current captured dispatch refuses missing parent before native profile data", _WPF_CurrentCapturedParentRefusal)


Test("generic group: declared reason/readiness retains the actual native child", _GDR_NativeProjection)
Test("generic group: caller disabled state remains effective", _GDR_CallerDisabled)
Test("generic group: final getter source withdrawal refuses publication", _GDR_SourceWithdrawal)
Test("generic group: final getter callback replacement refuses publication", _GDR_GetterWithdrawal)
Test("generic group: final getter builder replacement refuses publication", _GDR_BuilderWithdrawal)

_GDR_WithReasonedGroup(Body) {
	Root := _MR_GetManifestRoot(), Key := "_test_generic_group_reason"
	Present := Root.Has(Key), Previous := Present ? Root[Key] : false
	Child := Menu(), Calls := Map("count", 0)
	try {
		Child.Add("Native action", (*) => Calls["count"] += 1)
		Root[Key] := [Map("type", "group", "id", "parent", "i18n", "menu.llm.title",
			"disabled_when", ["ready"], "disabled_reason_key", "menu.llm.unavailable")]
		Body.Call(Key, Root, Child, Calls)
	} finally {
		if Present
			Root[Key] := Previous
		else if Root.Has(Key)
			Root.Delete(Key)
		Child.Delete()
	}
}

_GDR_NativeProjection() {
	_GDR_WithReasonedGroup(_GDR_CheckProjection)
}

_GDR_CheckProjection(Key, Root, Child, Calls) {
	for Ready in [true, false] {
		Parent := Menu(), Reads := Map("count", 0)
		try {
			AssertTrue(_MR_RenderGroup(Parent, Root[Key][1], "", Map("parent", () => Child), Key,
				Map("ready", _GDR_ReadReady.Bind(Reads, Ready))))
			AssertEqual(1, TrayMenuItemCount(Parent))
			AssertEqual(1, Reads["count"], "the genuine readiness getter runs once")
			Label := t("menu.llm.title") . (Ready ? "" : " — " . _MR_ReasonHead(t("menu.llm.unavailable")))
			AssertEqual(Label, _MUR_LabelAt(Parent, 0))
			AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"))
			State := DllCall("GetMenuState", "ptr", Parent.Handle, "uint", 0, "uint", 0x400, "uint")
			if Ready
				AssertEqual(0, State & 3)
			else
				AssertTrue((State & 3) != 0)
			AssertEqual(0, Calls["count"], "projection retains and never runs the native child action")
		} finally {
			Parent.Delete()
			MenuDispatcher_PruneMenu(Parent)
		}
	}
}

_GDR_ReadReady(Reads, Ready) {
	Reads["count"] += 1
	return Ready
}

_GDR_CallerDisabled() {
	_GDR_WithReasonedGroup(_GDR_CheckCallerDisabled)
}

_GDR_CheckCallerDisabled(Key, Root, Child, Calls) {
	Parent := Menu()
	try {
		AssertTrue(_MR_RenderGroup(Parent, Root[Key][1], "", Map("parent", () => Child), Key,
			Map("ready", () => true), true))
		AssertEqual(t("menu.llm.title"), _MUR_LabelAt(Parent, 0))
		State := DllCall("GetMenuState", "ptr", Parent.Handle, "uint", 0, "uint", 0x400, "uint")
		AssertTrue((State & 3) != 0)
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"))
	} finally {
		Parent.Delete()
		MenuDispatcher_PruneMenu(Parent)
	}
}

_GDR_SourceWithdrawal() {
	_GDR_WithReasonedGroup(_GDR_CheckWithdrawal.Bind("source"))
}
_GDR_GetterWithdrawal() {
	_GDR_WithReasonedGroup(_GDR_CheckWithdrawal.Bind("getter"))
}
_GDR_BuilderWithdrawal() {
	_GDR_WithReasonedGroup(_GDR_CheckWithdrawal.Bind("builder"))
}

_GDR_CheckWithdrawal(Mutation, Key, Root, Child, Calls) {
	Parent := Menu(), Reads := Map("count", 0), Getters := Map(), Builders := Map("parent", () => Child)
	Getters["ready"] := _GDR_Withdraw.Bind(Mutation, Key, Root, Getters, Builders, Reads)
	try {
		AssertFalse(_MR_RenderGroup(Parent, Root[Key][1], "", Builders, Key, Getters))
		AssertEqual(1, Reads["count"], "the actual last native getter must execute")
		AssertEqual(0, TrayMenuItemCount(Parent), "a withdrawn source/callback cohort cannot publish")
		AssertEqual(0, Calls["count"])
	} finally {
		Parent.Delete()
		MenuDispatcher_PruneMenu(Parent)
	}
}

_GDR_Withdraw(Mutation, Key, Root, Getters, Builders, Reads) {
	Reads["count"] += 1
	if Mutation == "source"
		Root.Delete(Key)
	else if Mutation == "getter"
		Getters["ready"] := () => true
	else
		Builders["parent"] := () => Menu()
	return false
}

; Canonical fixed parents read immutable original locale/count expectations.
Test("manifest_menu: fixed parents preserve original 21-language captions and native children", _FFP_CheckOriginalCaptions)
Test("manifest_menu: translated count rejects untyped or unsafe native receipts", _FFP_CheckCountReceipts)
Test("manifest_menu: captured fixed parent rejects changed canonical source", _FFP_CheckSourceCohort)

_FFP_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\fixed_feature_parents.json", "UTF-8"))
}

_FFP_WithOriginalLocale(Code, Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	HadCache := IsSet(_I18nCache), Cache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), Loaded := HadLoaded ? _I18nCacheLoaded : false
	try {
		_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Code . ".json", "UTF-8"))
		_I18nCacheLoaded := true
		return Body.Call()
	} finally {
		if HadCache
			_I18nCache := Cache
		else
			_I18nCache := unset
		if HadLoaded
			_I18nCacheLoaded := Loaded
		else
			_I18nCacheLoaded := unset
	}
}

_FFP_CheckedReceipt(Reads, Value) {
	Reads["state"] += 1
	return Value
}
_FFP_TotalReceipt(Reads, Value) {
	Reads["total"] += 1
	return Value
}
_FFP_PresentReceipt(Reads, Value) {
	Reads["present"] += 1
	return Value
}
_FFP_Receipts(Reads, Total, Present := true) {
	return Map("hotstrings_enabled", _FFP_CheckedReceipt.Bind(Reads, false),
		"hotstrings_parent_total", _FFP_TotalReceipt.Bind(Reads, Total),
		"hotstrings_parent_count_present", _FFP_PresentReceipt.Bind(Reads, Present))
}
_FFP_CheckOriginalCaptions() {
	Corpus := _FFP_Corpus(), Languages := 0
	AssertEqual("98572fe1a57dde86c6e8591e79112fc5400ec819", Corpus["original_sha"])
	for Code, Expected in Corpus["captions"] {
		Languages += 1
		_FFP_WithOriginalLocale(Code, _FFP_CheckOneLanguage.Bind(Expected, Corpus))
	}
	AssertEqual(21, Languages)
}
_FFP_CheckOneLanguage(Expected, Corpus) {
	States := Map("keyboard_layout", "layout_enabled", "shortcuts", "shortcuts_enabled",
		"tap_holds", "tapholds_enabled", "gestures", "gestures_enabled")
	Child := Menu(), Calls := Map("value", 0)
	Child.Add("Existing native child", (*) => Calls["value"] += 1)
	try {
		for Id, State in States {
			Receiver := MenuRenderer_GroupReceiver("top_level", Id)
			AssertTrue(HasMethod(Receiver, "Call"))
			Reads := Map("state", 0)
			Row := Receiver.Call(Child, Map(State, _FFP_CheckedReceipt.Bind(Reads, false)))
			AssertTrue(Row is Map), AssertEqual(Expected[Id], Row["label"])
			AssertTrue(Row["submenu"] == Child), AssertEqual(false, Row["checked"])
			AssertEqual(1, Reads["state"]), AssertEqual(0, Calls["value"])
		}
		for Vector in Corpus["count_cases"] {
			if Vector["driver"] != "ahk"
				continue
			Reads := Map("state", 0, "total", 0, "present", 0)
			Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
			Row := Receiver.Call(Child, _FFP_Receipts(Reads, Vector["total"], Vector["aggregate_available"]))
			AssertTrue(Row is Map), AssertEqual(Expected["hotstrings"] . Vector["suffix"], Row["label"])
			AssertTrue(Row["submenu"] == Child), AssertEqual(false, Row["checked"])
			AssertEqual(1, Reads["state"]), AssertEqual(1, Reads["total"]), AssertEqual(1, Reads["present"])
			AssertEqual(0, Calls["value"])
		}
	} finally {
		try Child.Delete()
		finally MenuDispatcher_PruneMenu(Child)
	}
}
_FFP_CheckCountReceipts() {
	Child := Menu()
	try {
		for Bad in ["1234", -1, 1.5, 9007199254740992, Map()] {
			Reads := Map("state", 0, "total", 0, "present", 0)
			Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
			AssertTrue(!Receiver.Call(Child, _FFP_Receipts(Reads, Bad)))
			AssertEqual(0, Reads["state"])
		}
		for Bad in ["true", 2, Map()] {
			Reads := Map("state", 0, "total", 0, "present", 0)
			Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
			AssertTrue(!Receiver.Call(Child, _FFP_Receipts(Reads, 1234, Bad)))
			AssertEqual(0, Reads["state"])
		}
		for Missing in ["hotstrings_parent_total", "hotstrings_parent_count_present"] {
			Reads := Map("state", 0, "total", 0, "present", 0), Getters := _FFP_Receipts(Reads, 1234)
			Getters.Delete(Missing)
			AssertTrue(!MenuRenderer_GroupRow("top_level", "hotstrings", Child, Getters))
			AssertEqual(0, Reads["state"])
		}
	} finally {
		try Child.Delete()
		finally MenuDispatcher_PruneMenu(Child)
	}
}
_FFP_CheckSourceCohort() {
	Root := _MR_GetManifestRoot(), Rows := Root["top_level"], Child := Menu()
	for Row in Rows
		if _MR_Get(Row, "id") == "hotstrings"
			Selected := Row
	OriginalId := Selected["id"]
	try {
		Reads := Map("state", 0, "total", 0, "present", 0)
		Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
		Selected["id"] := "unowned"
		AssertTrue(!Receiver.Call(Child, _FFP_Receipts(Reads, 1234)))
		AssertEqual(0, Reads["state"]), AssertEqual(0, Reads["total"]), AssertEqual(0, Reads["present"])
	} finally {
		Selected["id"] := OriginalId
		try Child.Delete()
		finally MenuDispatcher_PruneMenu(Child)
	}
}

; Actual AHK function objects remain the admitted entry/getter owners after binding.
Test("manifest_menu: captured original parent entry refuses own Call before dispatch", _FFPC_EntryBefore)
Test("manifest_menu: captured original parent entry refuses withdrawal during native getters", _FFPC_EntryDuring)
Test("manifest_menu: actual retained getter refuses same-object own Call before invocation", _FFPC_GetterBefore)
Test("manifest_menu: native getter withdrawal blocks every later foreign callable", _FFPC_GetterDuring)
Test("manifest_menu: actual declared entry rejects attempted global rebinding", _FFPC_ReadOnlyEntry)

_FFPC_AddObserver(Owner, Hits) {
	AssertTrue(!Object.Prototype.HasOwnProp.Call(Owner, "Call"), "the original callable has no own Call descriptor")
	Object.Prototype.DefineProp.Call(Owner, "Call", { Call: (*) => (Hits["foreign"] += 1, false) })
}
_FFPC_RepairObserver(Owner) {
	if Object.Prototype.HasOwnProp.Call(Owner, "Call")
		Object.Prototype.DeleteProp.Call(Owner, "Call")
	AssertTrue(!Object.Prototype.HasOwnProp.Call(Owner, "Call"), "exact absent original Call descriptor restored")
}
_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits) {
	Reads["state"] := 0, Reads["total"] := 0, Reads["present"] := 0
	Row := Receiver.Call(Child, Getters)
	AssertTrue(Row is Map), AssertTrue(Row["submenu"] == Child)
	AssertEqual(1, Reads["state"]), AssertEqual(1, Reads["total"]), AssertEqual(1, Reads["present"])
	AssertEqual(0, Hits["foreign"], "no altered callable gets observation credit")
}
_FFPC_DeleteChild(Child) {
	try Child.Delete()
	finally MenuDispatcher_PruneMenu(Child)
}
_FFPC_EntryBefore() {
	Owner := MenuRenderer_GroupRow, Child := Menu(), Hits := Map("foreign", 0)
	Reads := Map("state", 0, "total", 0, "present", 0), Getters := _FFP_Receipts(Reads, 1234)
	Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
	AssertTrue(HasMethod(Receiver, "Call"))
	try {
		_FFPC_AddObserver(Owner, Hits)
		AssertTrue(!MenuRenderer_GroupReceiver("top_level", "hotstrings"), "altered actual entry cannot gain new admission")
		AssertTrue(!Receiver.Call(Child, Getters), "captured original entry is checked before dispatch")
		AssertEqual(0, Hits["foreign"])
		AssertEqual(0, Reads["state"]), AssertEqual(0, Reads["total"]), AssertEqual(0, Reads["present"])
		AssertTrue(MenuRenderer_GroupRow == Owner, "own Call withdrawal retains the same actual function identity")
		_FFPC_RepairObserver(Owner)
		_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits)
	} finally {
		_FFPC_RepairObserver(Owner)
		_FFPC_DeleteChild(Child)
	}
}
_FFPC_WithdrawWhileReading(Context, Reads, Kind, Value) {
	Reads[Kind] += 1
	if Context["armed"]
		_FFPC_AddObserver(Context["target"], Context["hits"])
	return Value
}
_FFPC_EntryDuring() {
	Keys := Map("total", "hotstrings_parent_total", "present", "hotstrings_parent_count_present", "state", "hotstrings_enabled")
	for Kind, Key in Keys {
		Owner := MenuRenderer_GroupRow, Child := Menu(), Hits := Map("foreign", 0)
		Reads := Map("state", 0, "total", 0, "present", 0), Getters := _FFP_Receipts(Reads, 1234)
		Context := Map("armed", true, "target", Owner, "hits", Hits)
		Getters[Key] := _FFPC_WithdrawWhileReading.Bind(Context, Reads, Kind, Kind == "total" ? 1234 : false)
		Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
		try {
			AssertTrue(!Receiver.Call(Child, Getters), "entry withdrawal from a retained real getter refuses the parent")
			AssertEqual(1, Reads[Kind]), AssertEqual(0, Hits["foreign"])
			AssertTrue(MenuRenderer_GroupRow == Owner), AssertTrue(Object.Prototype.HasOwnProp.Call(Owner, "Call"))
			if Kind == "total"
				AssertEqual(0, Reads["present"]), AssertEqual(0, Reads["state"])
			if Kind == "present"
				AssertEqual(0, Reads["state"])
			Context["armed"] := false
			_FFPC_RepairObserver(Owner)
			_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits)
		} finally {
			Context["armed"] := false
			_FFPC_RepairObserver(Owner)
			_FFPC_DeleteChild(Child)
		}
	}
}
_FFPC_GetterBefore() {
	for Key in ["hotstrings_parent_total", "hotstrings_parent_count_present", "hotstrings_enabled"] {
		Child := Menu(), Hits := Map("foreign", 0), Reads := Map("state", 0, "total", 0, "present", 0)
		Getters := _FFP_Receipts(Reads, 1234), Owner := Getters[Key]
		Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
		try {
			_FFPC_AddObserver(Owner, Hits)
			AssertTrue(Getters[Key] == Owner)
			AssertTrue(!Receiver.Call(Child, Getters), "scalar identity cannot acknowledge same-object Call mutation")
			AssertEqual(0, Hits["foreign"])
			AssertEqual(0, Reads["state"]), AssertEqual(0, Reads["total"]), AssertEqual(0, Reads["present"])
			_FFPC_RepairObserver(Owner)
			_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits)
		} finally {
			_FFPC_RepairObserver(Owner)
			_FFPC_DeleteChild(Child)
		}
	}
}
_FFPC_GetterDuring() {
	Keys := Map("total", "hotstrings_parent_total", "present", "hotstrings_parent_count_present", "state", "hotstrings_enabled")
	for Kind, Key in Keys {
		for Target in [Key, Kind == "total" ? "hotstrings_parent_count_present" : Kind == "present" ? "hotstrings_enabled" : "hotstrings_parent_total"] {
			Child := Menu(), Hits := Map("foreign", 0), Reads := Map("state", 0, "total", 0, "present", 0)
			Getters := _FFP_Receipts(Reads, 1234), Context := Map("armed", true, "hits", Hits)
			Getters[Key] := _FFPC_WithdrawWhileReading.Bind(Context, Reads, Kind, Kind == "total" ? 1234 : false)
			Owner := Getters[Target], Context["target"] := Owner
			Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
			try {
				AssertTrue(!Receiver.Call(Child, Getters), "mutation during an actual getter cannot publish a parent")
				AssertTrue(Getters[Target] == Owner), AssertTrue(Object.Prototype.HasOwnProp.Call(Owner, "Call"))
				AssertEqual(1, Reads[Kind]), AssertEqual(0, Hits["foreign"])
				if Kind == "total"
					AssertEqual(0, Reads["present"]), AssertEqual(0, Reads["state"])
				if Kind == "present"
					AssertEqual(0, Reads["state"])
				Context["armed"] := false
				_FFPC_RepairObserver(Owner)
				_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits)
			} finally {
				Context["armed"] := false
				_FFPC_RepairObserver(Owner)
				_FFPC_DeleteChild(Child)
			}
		}
	}
}
; Function definitions create read-only global variables in AHK v2. A dynamic
; attempt exercises that real restriction without an invalid literal assignment.
_FFPC_AttemptEntryRebinding(Foreign) {
	global
	local Name := "MenuRenderer_GroupRow"
	%Name% := Foreign
}
_FFPC_ReadOnlyAttemptWhileReading(Reads, Foreign) {
	Reads["total"] += 1
	AssertThrows(_FFPC_AttemptEntryRebinding.Bind(Foreign), "actual declared global entry is read-only")
	return 1234
}
_FFPC_ReadOnlyEntry() {
	Owner := MenuRenderer_GroupRow, Child := Menu(), Hits := Map("foreign", 0)
	Foreign := (*) => (Hits["foreign"] += 1, false)
	Reads := Map("state", 0, "total", 0, "present", 0), Getters := _FFP_Receipts(Reads, 1234)
	Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")
	try {
		AssertThrows(_FFPC_AttemptEntryRebinding.Bind(Foreign), "actual original entry cannot be rebound before dispatch")
		AssertTrue(MenuRenderer_GroupRow == Owner)
		_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits)
		Getters["hotstrings_parent_total"] := _FFPC_ReadOnlyAttemptWhileReading.Bind(Reads, Foreign)
		_FFPC_CheckRestored(Receiver, Child, Getters, Reads, Hits)
		AssertTrue(MenuRenderer_GroupRow == Owner)
	} finally {
		AssertTrue(MenuRenderer_GroupRow == Owner)
		_FFPC_DeleteChild(Child)
	}
}
