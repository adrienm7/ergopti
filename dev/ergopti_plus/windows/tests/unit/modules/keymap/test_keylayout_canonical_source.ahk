; tests/unit/modules/keymap/test_keylayout_canonical_source.ahk

; ==============================================================================
; MODULE: Keylayout Canonical Source Owner
; DESCRIPTION:
; The canonical keylayout source owner loads, replaces and detaches the
; original graphs, replays the fixed families, and keeps historical copies
; and normal graphs when helpers or constructors are withdrawn.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Actual original-loader source receiving. No native registration or output. */
_KSO_Load() {
	AssertEqual(49, _KLT_Load("ergol"), "the original registry loader owns49 physical keys")
	Lease := KeylayoutEmulation_CaptureCanonicalSource()
	AssertTrue(Lease["current"].Call(), "the genuine source is current")
	AssertEqual(392, Lease["read"].Call("info")["transitions"], "the complete base family includes dead transitions")
	return Lease
}

_KSO_Reject(Fn, Expected) {
	try Fn.Call()
	catch as Failure {
		AssertContains(Failure.Message, Expected, "the refusal reaches its exact cause")
		return
	}
	throw Error("The private source operation unexpectedly succeeded: " . Expected)
}

_KSO_Scans() {
	global KLE_KeyCodes
	Result := Map()
	for Scan, Code in KLE_KeyCodes {
		if Code == 31
			Result["dead"] := Scan
		if Code == 0
			Result["a"] := Scan
	}
	AssertEqual(2, Result.Count, "literal Ergol anchors have actual canonical physical keys")
	return Result
}

_KSO_Lifetime() {
	global KLE_Model, KLE_State
	A := _KSO_Load(), Keys := _KSO_Scans()
	Again := KeylayoutEmulation_CaptureCanonicalSource()
	AssertEqual(A["epoch"], Again["epoch"], "recapture preserves the exact source epoch")
	Starter := A["read"].Call("find", "none", Keys["dead"], 0)
	Bridge := A["read"].Call("find", "1dk", Keys["dead"], 0)
	Final := A["read"].Call("find", "diaeresis", Keys["a"], 0)
	States := A["read"].Call("states"), RecapturedStates := Again["read"].Call("states")
	AssertEqual(4, States.Length, "the actual Ergol base family has four reachable states")
	AssertEqual(States.Length, RecapturedStates.Length, "recapture preserves the complete state table")
	for Index, State in States
		AssertEqual(State, RecapturedStates[Index], "recapture preserves each exact state identity")
	for Row in [Starter, Bridge, Final] {
		Recaptured := Again["read"].Call("find", Row["before"], Row["scan"], Row["shift"])
		AssertEqual(Row["before_id"], Recaptured["before_id"], "recapture preserves the literal transition's before ID")
		AssertEqual(Row["after_id"], Recaptured["after_id"], "recapture preserves the literal transition's after ID")
	}
	AssertEqual(0, Starter["before_id"], "neutral has the exact zero ID")
	AssertEqual("1dk", States[Starter["after_id"] + 1], "starter ID names the actual1dk state")
	AssertEqual(Starter["after_id"], Bridge["before_id"], "the retained starter and bridge share one exact state ID")
	AssertEqual(Bridge["after_id"], Final["before_id"], "the retained bridge and final share one exact state ID")
	AssertEqual(0, Final["after_id"], "completion names the same exact neutral ID")
	AssertEqual("", Starter["output"], "the starter owns an empty canonical transition")
	AssertEqual("1dk", Starter["after"], "the starter selects literal1dk")
	AssertEqual("diaeresis", Bridge["after"], "the second original key selects literal diaeresis")
	AssertEqual(Chr(0xE4), Final["output"], "the final canonical text is literal a-diaeresis")
	AssertEqual("none", Final["after"], "completion returns to literal neutral")
	Copied := A["read"].Call("find", "diaeresis", Keys["a"], 0)
	Copied["output"] := "foreign"
	AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "a detached row cannot mutate the retained graph")
	ModelA := KLE_Model
	AssertEqual(49, _KLT_Load("ergopti_plus"), "a genuine successor loads normally")
	B := KeylayoutEmulation_CaptureCanonicalSource()
	AssertFalse(A["current"].Call(), "the old lease cannot admit successor input")
	AssertTrue(B["current"].Call(), "the successor owns its new source")
	AssertTrue(B["epoch"] > A["epoch"], "successful replacement advances exact source identity")
	AssertFalse(KLE_Model == ModelA, "the successor has its own parsed model")
	AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "historical rows do not borrow the successor")
	AssertEqual("none", KLE_State, "historical reads leave live composition untouched")
	KeylayoutEmulation_Unload()
	AssertFalse(B["current"].Call(), "Unload withdraws live admission")
	AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "Unload preserves independently retained historical data")
	Inactive := KeylayoutEmulation_CaptureCanonicalSource()
	AssertFalse(Inactive["active"], "the original owner reports inactive data explicitly")
	AssertTrue(Inactive["current"].Call(), "the inactive receipt matches the genuine owner")
}

_KSO_InvalidLoad() {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex
	A := _KSO_Load(), Before := [KLE_Model, KLE_KeyCodes, KLE_LevelIndex]
	Entry := _KLT_Entry("ergol")
	_KSO_Reject(() => KeylayoutEmulation_Load("broken", "<keyboard>", Entry["keycode_convention"], LayoutRegistry_Keycodes()), "keylayout")
	AssertTrue(A["current"].Call(), "failed preparation preserves the original current source")
	AssertTrue(KLE_Model == Before[1] && KLE_KeyCodes == Before[2] && KLE_LevelIndex == Before[3], "failed preparation changes no public source roots")
	AssertEqual(A["epoch"], KeylayoutEmulation_CaptureCanonicalSource()["epoch"], "failed preparation does not advance the source epoch")
}

_KSO_ExplicitReplacement() {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions, KLE_State
	A := _KSO_Load()
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	_KLT_Load("ergopti_plus")
	KLE_Model := Saved[1], KLE_Id := Saved[2], KLE_State := Saved[3]
	KLE_KeyCodes := Saved[4], KLE_LevelIndex := Saved[5], KLE_Compositions := Saved[6]
	_KSO_Reject(KeylayoutEmulation_CaptureCanonicalSource, "changed during capture")
	Fresh := _KSO_Load()
	AssertTrue(Fresh["current"].Call(), "explicit genuine Load reparses after a legacy fixture restoration")
	AssertTrue(Fresh["epoch"] > A["epoch"], "replacement issues a new identity instead of adopting restored globals")
}

_KSO_InputObserver() {
	global KLE_Id
	A := _KSO_Load(), OldId := KLE_Id
	Table := LayoutRegistry_Keycodes().Clone(), Facts := {Calls: 0, ReentryRefused: 0}
	Table.DefineProp("__Item", {Get: Observe})
	Entry := _KLT_Entry("ergol")
	try {
		_KSO_Reject(() => KeylayoutEmulation_Load("ergol", _KLT_LayoutText("ergol"), Entry["keycode_convention"], Table), "starting canonical source changed")
		AssertTrue(Facts.Calls >= 2, "the real keycode constructor reached the supplied input observer")
		AssertEqual(1, Facts.ReentryRefused, "Busy refuses the actual recursive owner operation")
		AssertEqual("foreign-during-preparation", KLE_Id, "publication does not overwrite intervening public state")
	} finally {
		Table.DeleteProp("__Item")
		KLE_Id := OldId
	}
	AssertTrue(_KSO_Load()["current"].Call(), "genuine replacement remains available after refused preparation")

	Observe(Self, Key) {
		Facts.Calls += 1
		if Facts.Calls == 1 {
			_KSO_Reject(() => KeylayoutEmulation_Unload(), "unavailable")
			Facts.ReentryRefused += 1
			KLE_Id := "foreign-during-preparation"
		}
		return Map.Prototype.Get.Call(Self, Key)
	}
}

_KSO_BusyPreparationFailure() {
	A := _KSO_Load(), Table := LayoutRegistry_Keycodes().Clone(), Facts := {Calls: 0, ObservedBusy: 0}
	Table.DefineProp("__Item", {Get: Observe})
	Entry := _KLT_Entry("ergol")
	try {
		_KSO_Reject(() => KeylayoutEmulation_Load("broken", "<keyboard>", Entry["keycode_convention"], Table), "keylayout")
		AssertTrue(Facts.Calls >= 2, "actual keycode acquisition precedes the malformed parser input")
		AssertEqual(1, Facts.ObservedBusy, "the retained lease observes transient preparation exactly once")
	} finally Table.DeleteProp("__Item")
	AssertTrue(A["current"].Call(), "a transient Busy refusal does not revoke a source after failed preparation")
	AssertEqual(A["epoch"], KeylayoutEmulation_CaptureCanonicalSource()["epoch"], "failed preparation retains its old source identity")

	Observe(Self, Key) {
		Facts.Calls += 1
		if Facts.Calls == 1 {
			AssertFalse(A["current"].Call(), "Busy blocks fresh admission during actual preparation")
			_KSO_Reject(KeylayoutEmulation_CaptureCanonicalSource, "unavailable")
			Facts.ObservedBusy += 1
		}
		return Map.Prototype.Get.Call(Self, Key)
	}
}

_KSO_HelperWithdrawal(Name) {
	A := _KSO_Load(), Keys := _KSO_Scans(), Facts := {Calls: 0}
	Helper := Name == "load" ? KeylayoutEmulation_Load : Name == "step" ? Keylayout_Step : _KLE_BuildReplayGraph
	Helper.DefineProp("Call", {Call: Observe})
	try {
		AssertFalse(A["current"].Call(), "helper withdrawal refuses new source admission")
		AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "historical data needs neither withdrawn loader nor parser")
		AssertEqual(0, Facts.Calls, "the source guard never invokes a withdrawn own.Call")
	} finally Helper.DeleteProp("Call")
	AssertFalse(A["current"].Call(), "observed withdrawal cannot reactivate the same lease after restoration")
	AssertTrue(_KSO_Load()["current"].Call(), "explicit reparse can issue a fresh source after helper restoration")

	Observe(*) {
		Facts.Calls += 1
		throw Error("A withdrawn helper callback must not run")
	}
}

_KSO_DuplicateInitialize() {
	A := _KSO_Load()
	_KSO_Reject(() => _KLE_CanonicalSourceOwner("initialize"), "cannot initialize twice")
	AssertTrue(A["current"].Call(), "duplicate initialization cannot replace the original source")
}

_KSO_Mutation(Kind) {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE
	global KEYLAYOUT_MODIFIER_TOKENS, KEYLAYOUT_MAX_BASE_DEPTH, _KEYLAYOUT_TAG_RE
	A := _KSO_Load(), Keys := _KSO_Scans()
	Before := [KLE_Model, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE,
		KEYLAYOUT_MODIFIER_TOKENS, KEYLAYOUT_MAX_BASE_DEPTH, _KEYLAYOUT_TAG_RE]
	Restore := 0
	try {
		switch Kind {
			case "nested-action":
				for _, Action in KLE_Model["Actions"] {
					for _, Step in Action {
						Target := Step, Prior := Step["Output"]
						break
					}
					break
				}
				Restore := () => Target["Output"] := Prior
				Target["Output"] := "mutated"
			case "model-clone": KLE_Model := KLE_Model.Clone()
			case "keys-clone": KLE_KeyCodes := KLE_KeyCodes.Clone()
			case "keycode":
				Scan := Keys["a"], Prior := KLE_KeyCodes[Scan]
				Restore := () => KLE_KeyCodes[Scan] := Prior
				KLE_KeyCodes[Scan] := Prior + 1
			case "levels-scalar":
				Prior := KLE_LevelIndex[""], Restore := () => KLE_LevelIndex[""] := Prior
				KLE_LevelIndex[""] := Prior + 1
			case "array-hole":
				Target := KLE_Model["Selects"], Prior := Target[1]
				Restore := () => Target[1] := Prior
				Target.Delete(1)
			case "own-property":
				KLE_Model.DefineProp("foreign", {Value: 1})
				Restore := () => KLE_Model.DeleteProp("foreign")
			case "neutral":
				KEYLAYOUT_NEUTRAL_STATE := "withdrawn-neutral"
				Actual := Keylayout_Step(KLE_Model, "diaeresis", KLE_LevelIndex[""], KLE_KeyCodes[Keys["a"]])
				AssertEqual("withdrawn-neutral", Actual["Next"], "the actual live Step observes the changed declaration")
			case "vocabulary-token":
				Prior := KEYLAYOUT_MODIFIER_TOKENS["shift"]
				Restore := () => KEYLAYOUT_MODIFIER_TOKENS["shift"] := Prior
				KEYLAYOUT_MODIFIER_TOKENS["shift"] := "option"
			case "vocabulary-map": KEYLAYOUT_MODIFIER_TOKENS := KEYLAYOUT_MODIFIER_TOKENS.Clone()
			case "vocabulary-regex": _KEYLAYOUT_TAG_RE .= " "
			case "base-depth": KEYLAYOUT_MAX_BASE_DEPTH += 1
			default: throw Error("Unknown exact source mutation")
		}
		AssertFalse(A["current"].Call(), "actual mutation withdraws original source admission")
		AssertEqual("none", A["read"].Call("find", "diaeresis", Keys["a"], 0)["after"], "the historical graph retains its literal neutral identity")
		AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "the historical graph retains its literal output")
	} finally {
		if IsObject(Restore)
			Restore.Call()
		KLE_Model := Before[1], KLE_KeyCodes := Before[2], KLE_LevelIndex := Before[3]
		KEYLAYOUT_NEUTRAL_STATE := Before[4], KEYLAYOUT_MODIFIER_TOKENS := Before[5]
		KEYLAYOUT_MAX_BASE_DEPTH := Before[6], _KEYLAYOUT_TAG_RE := Before[7]
	}
	AssertFalse(A["current"].Call(), "restoration cannot revive an observed withdrawn lease")
	AssertTrue(_KSO_Load()["current"].Call(), "fresh original loading recovers through parsing")
}

_KSO_Image(Kind) {
	Child := Map("value", Kind == "map-value-type" ? "1" : "one")
	ArrayData := [1, "two"], Empty := Map()
	Root := Map("child", Child, "shared", Child, "array", ArrayData, "empty", Empty)
	if Kind == "map-value-type"
		AssertEqual("String", Type(Child["value"]), "the equal-valued map control begins with a String")
	if Kind == "array-value-type"
		AssertEqual("Integer", Type(ArrayData[1]), "the equal-valued array control begins with an Integer")
	Current := _KLE_CaptureCanonicalImage([Root])
	AssertTrue(Current.Call(), "the original typed shared source image is current")
	switch Kind {
		case "map-value-type": Child["value"] := 1
		case "map-policy":
			AssertEqual("On", Empty.CaseSense, "the actual empty Map starts case-sensitive")
			Empty.CaseSense := "Off"
		case "nested-container": Root["child"] := Child.Clone()
		case "array-hole": ArrayData.Delete(1)
		case "own-property": Child.DefineProp("foreign", {Value: 1})
		case "key-insert": Child["other"] := "two"
		case "scalar-case": Child["value"] := "ONE"
		case "array-value-type": ArrayData[1] := "1"
		case "shared-subtree": Root["shared"] := Child.Clone()
		default: throw Error("Unknown exact image mutation")
	}
	if Kind == "map-value-type"
		AssertEqual("Integer", Type(Child["value"]), "only the equal-valued map scalar type changes")
	if Kind == "array-value-type"
		AssertEqual("String", Type(ArrayData[1]), "only the equal-valued array scalar type changes")
	AssertFalse(Current.Call(), "the exact typed data image detects the independent mutation")
}

Test("canonical-source-owner: lifetime", () => _KLT_WithEmulation(_KSO_Lifetime))
Test("canonical-source-owner: invalid-load-atomic", () => _KLT_WithEmulation(_KSO_InvalidLoad))
Test("canonical-source-owner: explicit-replacement", () => _KLT_WithEmulation(_KSO_ExplicitReplacement))
Test("canonical-source-owner: input-observer-reentry", () => _KLT_WithEmulation(_KSO_InputObserver))
Test("canonical-source-owner: busy-preparation-failure", () => _KLT_WithEmulation(_KSO_BusyPreparationFailure))
Test("canonical-source-owner: duplicate-initialize", () => _KLT_WithEmulation(_KSO_DuplicateInitialize))
Test("canonical-source-owner: helper-load", () => _KLT_WithEmulation(_KSO_HelperWithdrawal.Bind("load")))
Test("canonical-source-owner: helper-step", () => _KLT_WithEmulation(_KSO_HelperWithdrawal.Bind("step")))
Test("canonical-source-owner: helper-graph", () => _KLT_WithEmulation(_KSO_HelperWithdrawal.Bind("graph")))
Test("canonical-source-owner: source-nested-action", () => _KLT_WithEmulation(_KSO_Mutation.Bind("nested-action")))
Test("canonical-source-owner: source-model-clone", () => _KLT_WithEmulation(_KSO_Mutation.Bind("model-clone")))
Test("canonical-source-owner: source-keys-clone", () => _KLT_WithEmulation(_KSO_Mutation.Bind("keys-clone")))
Test("canonical-source-owner: source-keycode", () => _KLT_WithEmulation(_KSO_Mutation.Bind("keycode")))
Test("canonical-source-owner: source-levels-scalar", () => _KLT_WithEmulation(_KSO_Mutation.Bind("levels-scalar")))
Test("canonical-source-owner: source-array-hole", () => _KLT_WithEmulation(_KSO_Mutation.Bind("array-hole")))
Test("canonical-source-owner: source-own-property", () => _KLT_WithEmulation(_KSO_Mutation.Bind("own-property")))
Test("canonical-source-owner: source-neutral", () => _KLT_WithEmulation(_KSO_Mutation.Bind("neutral")))
Test("canonical-source-owner: source-vocabulary-token", () => _KLT_WithEmulation(_KSO_Mutation.Bind("vocabulary-token")))
Test("canonical-source-owner: source-vocabulary-map", () => _KLT_WithEmulation(_KSO_Mutation.Bind("vocabulary-map")))
Test("canonical-source-owner: source-vocabulary-regex", () => _KLT_WithEmulation(_KSO_Mutation.Bind("vocabulary-regex")))
Test("canonical-source-owner: source-base-depth", () => _KLT_WithEmulation(_KSO_Mutation.Bind("base-depth")))
Test("canonical-source-owner: image-map-value-type", () => _KLT_WithEmulation(_KSO_Image.Bind("map-value-type")))
Test("canonical-source-owner: image-map-policy", () => _KLT_WithEmulation(_KSO_Image.Bind("map-policy")))
Test("canonical-source-owner: image-nested-container", () => _KLT_WithEmulation(_KSO_Image.Bind("nested-container")))
Test("canonical-source-owner: image-array-hole", () => _KLT_WithEmulation(_KSO_Image.Bind("array-hole")))
Test("canonical-source-owner: image-own-property", () => _KLT_WithEmulation(_KSO_Image.Bind("own-property")))
Test("canonical-source-owner: image-key-insert", () => _KLT_WithEmulation(_KSO_Image.Bind("key-insert")))
Test("canonical-source-owner: image-scalar-case", () => _KLT_WithEmulation(_KSO_Image.Bind("scalar-case")))
Test("canonical-source-owner: image-array-value-type", () => _KLT_WithEmulation(_KSO_Image.Bind("array-value-type")))
Test("canonical-source-owner: image-shared-subtree", () => _KLT_WithEmulation(_KSO_Image.Bind("shared-subtree")))

/** Requires an exact detached copy of every original graph field. */
_KRG_SameRecord(Left, Right) {
	AssertEqual(Left.Count, Right.Count, "a detached graph record retains its field inventory")
	for Name, Value in Left {
		AssertTrue(Right.Has(Name), "a detached graph record retains every field")
		AssertTrue(Type(Value) == Type(Right[Name]) && Value == Right[Name],
			"a detached graph field retains its exact type and value")
	}
}

/** Receives all four fixed graph families against independently walked parser states. */
_KRG_Receive(Id, BaseCount) {
	Entry := _KLT_Entry(Id)
	Model := Keylayout_Parse(_KLT_LayoutText(Id))
	Keys := KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), Entry["keycode_convention"])
	AssertEqual(49, Keys.Count, "the graph receives the complete canonical physical inventory")
	for Caps in [0, 1] {
		for Option in [0, 1] {
			Levels := []
			for Shift in [0, 1] {
				Pressed := Map()
				if Shift
					Pressed["shift"] := true
				if Caps
					Pressed["caps"] := true
				if Option
					Pressed["option"] := true
				Levels.Push(Keylayout_KeyMapIndex(Model, Pressed))
			}
			ExpectedLevels := Levels.Clone(), SuppliedKeys := Keys.Clone()
			OracleStates := Map()
			OracleStates.CaseSense := "On"
			OracleStates["none"] := true
			Loop {
				Added := false
				for Before in OracleStates.Clone() {
					for Shift in [0, 1] {
						for Scan, Code in Keys {
							Step := Keylayout_Step(Model, Before, ExpectedLevels[Shift + 1], Code)
							if !OracleStates.Has(Step["Next"]) {
								OracleStates[Step["Next"]] := true
								Added := true
							}
						}
					}
				}
				if !Added
					break
			}
			Graph := _KLE_BuildReplayGraph(Model, SuppliedKeys, Levels, Id, Caps, Option)
			AssertTrue(Graph is BoundFunc, "the actual graph retains its private data through a closure")
			Info := Graph.Call("info"), States := Graph.Call("states")
			AssertEqual(49, Info["physical_keys"], "the graph omits no physical key")
			AssertEqual(States.Length * 98, Info["transitions"], "each state retains both complete levels")
			AssertEqual(OracleStates.Count, States.Length, "an independent reachability walk finds the same state inventory")
			AssertTrue(Info["caps"] == Caps && Info["option"] == Option,
				"the fixed family does not claim event-time modifier ownership")
			AssertTrue(Info["layout_name"] == Id && Info["model_key"] == ObjPtr(Model),
				"the graph retains its original source identity")
			AssertTrue(Graph.Call("matches_model", Model), "the graph recognizes its own model")
			AssertFalse(Graph.Call("matches_model", Map()), "a foreign model grants no graph identity")
			if !Caps && !Option
				AssertEqual(BaseCount, Info["transitions"], "the shipped base family matches its measured full size")
			for Before in States
				AssertTrue(OracleStates.Has(Before), "every retained state is canonically reachable")
			Seen := Map()
			Seen.CaseSense := "On"
			Loop Info["transitions"] {
				Row := Graph.Call("row", A_Index)
				Expected := Keylayout_Step(Model, Row["before"], ExpectedLevels[Row["shift"] + 1], Keys[Row["scan"]])
				AssertTrue(Row["index"] == ExpectedLevels[Row["shift"] + 1] && Row["keycode"] == Keys[Row["scan"]],
					"each row retains its exact physical and canonical level identity")
				AssertTrue(Row["output"] == Expected["Output"] && Row["after"] == Expected["Next"],
					"each row agrees with the independent parser step")
				AssertTrue(Row["before"] == States[Row["before_id"] + 1] && Row["after"] == States[Row["after_id"] + 1],
					"state IDs name the exact retained state strings")
				Selector := Row["before"] . "|" . Row["scan"] . "|" . Row["shift"]
				AssertFalse(Seen.Has(Selector), "the graph cannot repeat a selector")
				Seen[Selector] := true
				Found := Graph.Call("find", Row["before"], Row["scan"], Row["shift"])
				_KRG_SameRecord(Row, Found)
				Kind := Row["before_id"] || Row["after_id"] ? 3
					: Expected["Output"] == "" ? 0 : RegExMatch(Expected["Output"], "^[0-9]$") ? 2 : 1
				AssertEqual(Kind, Row["kind"], "empty composition and nonprinting neutral rows keep their exact data kind")
				Saved := Row.Clone()
				for Name in Row
					Row[Name] := "foreign row mutation"
				Found["output"] := "foreign find mutation"
				_KRG_SameRecord(Saved, Graph.Call("row", A_Index))
				_KRG_SameRecord(Saved, Graph.Call("find", Saved["before"], Saved["scan"], Saved["shift"]))
			}
			AssertEqual(Info["transitions"], Seen.Count, "every row has one unique selector")
			Saved := Graph.Call("row", 1), SavedInfo := Info.Clone()
			Info["transitions"] := 0, Info["layout_name"] := "foreign info"
			_KRG_SameRecord(SavedInfo, Graph.Call("info"))
			Levels[1] := -99, SuppliedKeys.Clear(), States.Push("foreign-state")
			AssertEqual(SavedInfo["states"], Graph.Call("states").Length,
				"a detached state array cannot extend the graph")
			_KRG_SameRecord(Saved, Graph.Call("row", 1))
			_KRG_SameRecord(Saved, Graph.Call("find", Saved["before"], Saved["scan"], Saved["shift"]))
		}
	}
	Saved := Graph.Call("row", 1)
	Model.Clear()
	_KRG_SameRecord(Saved, Graph.Call("row", 1))
	_KRG_SameRecord(Saved, Graph.Call("find", Saved["before"], Saved["scan"], Saved["shift"]))
}

/** Exercises the actual ambiguous-string selector and undefined-level predecessors. */
_KRG_Malformed(Mode) {
	Xml := '<keyboard><layouts><layout first="0" last="0" modifiers="mods" mapSet="maps"/></layouts>'
		. '<modifierMap id="mods" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>'
		. '<keyMapSet id="maps"><keyMap index="0"><key code="0" action="dead"/></keyMap></keyMapSet>'
		. '<actions><action id="dead"><when state="none" next="x|y"/><when state="x|y" output="a"/></action></actions></keyboard>'
	Model := Keylayout_Parse(Xml), Keys := Map("SC002", 0)
	if Mode == "levels" {
		_KSO_Reject(() => _KLE_BuildReplayGraph(Model, Keys, [1, 1], "missing-level", 0, 0),
			"canonical graph level identity is invalid")
		return
	}
	AssertEqual("selectors", Mode, "the test control selection must be exact")
	Graph := _KLE_BuildReplayGraph(Model, Keys, [0, 0], "separator-control", 0, 0)
	Row := Graph.Call("find", "x|y", "SC002", 0)
	AssertTrue(Row["before"] == "x|y" && Row["output"] == "a", "a legitimate separator state remains readable")
	_KSO_Reject(() => Graph.Call("find", "x", "y|SC002", 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "NONE", "SC002", 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC003", 0), "does not own that transition")
	_KSO_Reject(() => Graph.Call("row", 0), "row identity is invalid")
	_KSO_Reject(() => Graph.Call("info", 1), "info takes no arguments")
	_KSO_Reject(() => Graph.Call("foreign-operation"), "Unknown canonical graph operation")
}

for _KrgCase in [["ergol", 392], ["ergopti", 294], ["ergopti_ansi", 294],
	["ergopti_plus", 196], ["ergopti_plus_ansi", 196]]
	Test("canonical-replay-graph: complete fixed families for " . _KrgCase[1], _KRG_Receive.Bind(_KrgCase*))
for _KrgMode in ["selectors", "levels"]
	Test("canonical-replay-graph: exact " . _KrgMode . " refusal", _KRG_Malformed.Bind(_KrgMode))

/** Rejected public activation cannot discard the original admitted source. */
_KSO_PublicActivationFailure() {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions
	Lease := _KSO_Load()
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	Keycodes := LayoutRegistry_Keycodes(), Convention := _KLT_Entry("ergol")["keycode_convention"]
	_KSO_Reject(() => KeylayoutEmulation_Load("broken", "<keyboard>", Convention, Keycodes), "keylayout")
	AssertTrue(Lease["current"].Call(), "actual failed parser preparation retains the original direct loader source")
	LocalCopy := Map("Text", "<keyboard>", "Entry", Map("keycode_convention", Convention, "version", "invalid-fixture"))
	AssertFalse(_KLE_Activate("broken", LocalCopy, Keycodes), "the actual public activation wrapper reports failure")
	AssertTrue(KLE_Model == Saved[1] && KLE_Id == Saved[2] && KLE_State == Saved[3]
		&& KLE_KeyCodes == Saved[4] && KLE_LevelIndex == Saved[5] && KLE_Compositions == Saved[6],
		"public activation failure preserves every original source root")
	AssertTrue(Lease["current"].Call(), "the original source remains genuinely admitted after wrapper failure")
	AssertEqual(Lease["epoch"], KeylayoutEmulation_CaptureCanonicalSource()["epoch"],
		"the rejected public activation cannot issue a replacement or an unload epoch")
}
Test("canonical-source-owner: failed public activation preserves the original source",
	() => _KLT_WithEmulation(_KSO_PublicActivationFailure))

/** Historical copies cannot borrow a replacement container method or constructor. */
_KSO_IntrinsicWithdrawal(Mode) {
	Lease := _KSO_Load(), Keys := _KSO_Scans(), Facts := {Calls: 0}
	OriginalInfo := Lease["read"].Call("info")
	OriginalStateCount := Lease["read"].Call("states").Length
	IsArray := InStr(Mode, "array-") == 1
	IsConstructor := Mode == "map-constructor"
	IsOwnCall := InStr(Mode, "own-call") > 0
	AssertTrue(IsConstructor || Mode == "map-clone-value" || Mode == "array-clone-value"
		|| Mode == "map-clone-own-call" || Mode == "array-clone-own-call", "the intrinsic withdrawal selection is exact")
	Target := IsConstructor ? Map : IsArray ? Array.Prototype : Map.Prototype
	Property := IsConstructor ? "Call" : "Clone"
	Original := IsConstructor ? Map.Call : IsArray ? Array.Prototype.Clone : Map.Prototype.Clone
	HadOwn := Object.Prototype.HasOwnProp.Call(Target, Property)
	Descriptor := HadOwn ? Target.GetOwnPropDesc(Property) : 0
	Installed := false
	try {
		if IsOwnCall {
			AssertFalse(Object.Prototype.HasOwnProp.Call(Original, "Call"), "the original intrinsic starts without an own.Call observer")
			Original.DefineProp("Call", {Call: Observe})
		} else
			Target.DefineProp(Property, {Value: Observe})
		Installed := true
		_TestPrint("# canonical-source-intrinsic phase=installed kind=" . Mode)
		Info := Lease["read"].Call("info"), States := Lease["read"].Call("states")
		Row := Lease["read"].Call("find", "diaeresis", Keys["a"], 0)
		_TestPrint("# canonical-source-intrinsic phase=read kind=" . Mode
			. " info_type=" . Type(Info) . " states_type=" . Type(States) . " row_type=" . Type(Row) . " calls=" . Facts.Calls)
		AssertTrue(Info is Map && States is Array && Row is Map,
			"historical reads retain their actual native container types")
		AssertEqual(Chr(0xE4), Row["output"], "the historical row retains its literal canonical output")
		AssertEqual("ergol", Info["layout_name"], "the historical information retains its original layout identity")
		AssertEqual(OriginalStateCount, States.Length, "the historical state inventory remains complete")
		Row["output"] := "foreign row", Info["layout_name"] := "foreign information", States.Push("foreign state")
		AssertEqual(Chr(0xE4), Lease["read"].Call("find", "diaeresis", Keys["a"], 0)["output"],
			"a historical copy cannot expose the private row through a withdrawn clone")
		AssertEqual("ergol", Lease["read"].Call("info")["layout_name"],
			"a historical copy cannot expose private information through a withdrawn constructor")
		AssertEqual(OriginalStateCount, Lease["read"].Call("states").Length,
			"a historical copy cannot expose the private state array through a withdrawn clone")
		AssertEqual(0, Facts.Calls, "historical reads never invoke the replaced method or its own.Call observer")
		AssertFalse(Lease["current"].Call(), "intrinsic withdrawal refuses new original-source admission")
	} finally {
		if Installed {
			if IsOwnCall
				Original.DeleteProp("Call")
			else if HadOwn
				Target.DefineProp(Property, Descriptor)
			else
				Target.DeleteProp(Property)
		}
	}
	AssertFalse(Lease["current"].Call(), "restoring an observed withdrawn intrinsic cannot resurrect the old source")
	AssertTrue(_KSO_Load()["current"].Call(), "genuine reparsing can issue a fresh source after intrinsic restoration")

	Observe(Values*) {
		Facts.Calls += 1
		for Value in Values
			if Value is Map || Value is Array
				return Value
		return 0
	}
}
for _KsoIntrinsic in ["map-clone-value", "array-clone-value", "map-clone-own-call", "array-clone-own-call", "map-constructor"]
	Test("canonical-source-owner: historical copies retain original " . _KsoIntrinsic,
		_KLT_WithEmulation.Bind(_KSO_IntrinsicWithdrawal.Bind(_KsoIntrinsic)))

/** Supplied keycode observers cannot lend a self-restoring parser constructor. */
_KSO_InputParserSubstitution() {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions
	Lease := _KSO_Load(), OriginalParser := Keylayout_Parse
	OriginalCall := Func.Prototype.Call
	AssertFalse(Object.Prototype.HasOwnProp.Call(OriginalParser, "Call"), "the parser starts without a supplied observer")
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	Table := LayoutRegistry_Keycodes().Clone(), Entry := _KLT_Entry("ergol")
	Facts := {ObserverCalls: 0, ParserCalls: 0}, Failure := 0
	Table.DefineProp("__Item", {Get: Observe})
	try {
		try KeylayoutEmulation_Load("ergol", _KLT_LayoutText("ergol"), Entry["keycode_convention"], Table)
		catch as Err
			Failure := Err
		ForeignAdmitted := KLE_Model is Map && KLE_Model.Has("foreign_parser_origin")
		_TestPrint("# canonical-source-input-dispatch observer_calls=" . Facts.ObserverCalls
			. " parser_calls=" . Facts.ParserCalls . " foreign_admitted=" . (ForeignAdmitted ? 1 : 0))
		AssertTrue(Facts.ObserverCalls >= 2, "the actual keycode reader reaches the supplied observer")
		AssertEqual(0, Facts.ParserCalls, "the source owner never dispatches a parser supplied by an input observer")
		AssertTrue(Failure is Error && Failure.Message == "The original canonical source constructor was withdrawn.",
			"observed constructor withdrawal refuses before parsing or publication")
		AssertTrue(KLE_Model == Saved[1] && KLE_Id == Saved[2] && KLE_State == Saved[3]
			&& KLE_KeyCodes == Saved[4] && KLE_LevelIndex == Saved[5] && KLE_Compositions == Saved[6],
			"the rejected input boundary preserves every original source root")
	} finally {
		if Object.Prototype.HasOwnProp.Call(OriginalParser, "Call")
			OriginalParser.DeleteProp("Call")
		Table.DeleteProp("__Item")
	}
	AssertFalse(Lease["current"].Call(), "observed constructor withdrawal cannot resurrect its old source")
	Fresh := _KSO_Load()
	AssertTrue(Fresh["current"].Call(), "actual reparsing remains available after input observer restoration")
	AssertEqual(Lease["epoch"] + 1, Fresh["epoch"], "rejected preparation issues no intermediate source epoch")

	Observe(Self, Key) {
		Facts.ObserverCalls += 1
		OriginalParser.DefineProp("Call", {Call: ForeignParser})
		return Map.Prototype.Get.Call(Self, Key)
	}

	ForeignParser(Receiver, Text) {
		Facts.ParserCalls += 1
		OriginalParser.DeleteProp("Call")
		Foreign := OriginalCall.Call(OriginalParser, Text)
		Foreign["foreign_parser_origin"] := "supplied observer"
		return Foreign
	}
}
Test("canonical-source-owner: supplied input cannot lend a self-restoring parser",
	() => _KLT_WithEmulation(_KSO_InputParserSubstitution))

/** A literal chain whose middle states cannot occur in any fixed family. */
_KNG_Fixture() {
	Xml := '<keyboard><layouts><layout first="0" last="0" modifiers="mods" mapSet="maps"/></layouts>'
		. '<modifierMap id="mods" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>'
		. '<keyMapSet id="maps">'
		. '<keyMap index="0"><key code="18" action="start"/><key code="19" output="n"/></keyMap>'
		. '<keyMap index="1"><key code="18" output="a"/><key code="19" output="b"/></keyMap>'
		. '<keyMap index="2"><key code="18" output="c"/><key code="19" action="bridge"/></keyMap>'
		. '<keyMap index="3"><key code="18" output="d"/><key code="19" output="e"/></keyMap>'
		. '<keyMap index="4"><key code="18" action="cap_bridge"/><key code="19" output="f"/></keyMap>'
		. '<keyMap index="5"><key code="18" output="g"/><key code="19" output="h"/></keyMap>'
		. '<keyMap index="6"><key code="18" output="i"/><key code="19" output="j"/></keyMap>'
		. '<keyMap index="7"><key code="18" output="k"/><key code="19" action="finish"/></keyMap>'
		. '</keyMapSet><actions>'
		. '<action id="start"><when state="none" next="A"/></action>'
		. '<action id="bridge"><when state="none" output="y"/><when state="A" next="B"/></action>'
		. '<action id="cap_bridge"><when state="none" output="x"/><when state="B" next="C"/></action>'
		. '<action id="finish"><when state="none" output="z"/><when state="C" output="Z"/></action>'
		. '</actions></keyboard>'
	return [Keylayout_Parse(Xml), Map("SC002", 18, "SC003", 19),
		Map("", 0, "s", 1, "o", 2, "so", 3, "c", 4, "sc", 5, "co", 6, "sco", 7)]
}

/** Receives mixed reachability from literal expected states and output. */
_KNG_MixedChain() {
	Fixture := _KNG_Fixture(), Model := Fixture[1], Keys := Fixture[2], Levels := Fixture[3]
	FixedStates := Map()
	for Caps in [0, 1] {
		for Option in [0, 1] {
			Fixed := _KLE_BuildReplayGraph(Model, Keys,
				[Levels[_KLE_ComboKey(0, Caps, Option)], Levels[_KLE_ComboKey(1, Caps, Option)]],
				"mixed-chain", Caps, Option)
			for State in Fixed.Call("states")
				FixedStates[State] := true
		}
	}
	AssertFalse(FixedStates.Has("B") || FixedStates.Has("C"),
		"even the union of fixed-family closures misses the mixed-only states")
	Graph := _KLE_BuildNormalReplayGraph(Model, Keys, Levels, "mixed-chain")
	Info := Graph.Call("info"), States := Graph.Call("states")
	AssertEqual(8, Info["selectors"], "the normal graph retains every modifier selector")
	AssertEqual(4, Info["states"], "the literal chain reaches exactly none, A, B and C")
	AssertEqual(64, Info["transitions"], "four states own two keys across all eight selectors")
	AssertFalse(Info.Has("caps") || Info.Has("option"), "normal information does not claim a fixed family")
	Starter := Graph.Call("find", "none", "SC002", 0, 0, 0)
	Bridge := Graph.Call("find", "A", "SC003", 0, 0, 1)
	CapsBridge := Graph.Call("find", "B", "SC002", 0, 1, 0)
	Final := Graph.Call("find", "C", "SC003", 1, 1, 1)
	for Row in [Starter, Bridge, CapsBridge]
		AssertEqual("", Row["output"], "each literal prefix is an empty composition transition")
	AssertTrue(Starter["after"] == "A" && Bridge["after"] == "B" && CapsBridge["after"] == "C",
		"modifier changes retain the literal mixed-only composition states")
	AssertTrue(Starter["before_id"] == 0 && Starter["after_id"] == Bridge["before_id"]
		&& Bridge["after_id"] == CapsBridge["before_id"] && CapsBridge["after_id"] == Final["before_id"],
		"one exact state namespace joins all four modifier families")
	AssertTrue(Final["output"] == "Z" && Final["after"] == "none" && Final["after_id"] == 0,
		"the final selector emits literal capital Z and returns to the same neutral ID")
	Seen := Map()
	Loop Info["transitions"] {
		Row := Graph.Call("row", A_Index)
		Selector := Row["before"] . "|" . Row["scan"] . "|" . Row["shift"] . "|" . Row["caps"] . "|" . Row["option"]
		AssertFalse(Seen.Has(Selector), "every normal transition selector occurs exactly once")
		Seen[Selector] := true
		AssertEqual(Levels[_KLE_ComboKey(Row["shift"], Row["caps"], Row["option"])], Row["index"],
			"each row carries its exact literal keyMap selector")
		AssertTrue(Row["before"] == States[Row["before_id"] + 1]
			&& Row["after"] == States[Row["after_id"] + 1], "all rows use the same state IDs")
		_KRG_SameRecord(Row, Graph.Call("find", Row["before"], Row["scan"], Row["shift"], Row["caps"], Row["option"]))
	}
	AssertEqual(64, Seen.Count, "the complete mixed graph omits no selector")
	Saved := Final.Clone(), SavedInfo := Info.Clone()
	Final["output"] := "foreign", Info["selectors"] := 0, States.Push("foreign")
	Model.Clear(), Keys.Clear(), Levels.Clear()
	_KRG_SameRecord(Saved, Graph.Call("find", "C", "SC003", 1, 1, 1))
	_KRG_SameRecord(SavedInfo, Graph.Call("info"))
	AssertEqual(4, Graph.Call("states").Length, "detached arrays cannot alter historical states")
}

/** Joins the shipped Option and base families through the original source. */
_KNG_OriginalSource() {
	global KLE_State
	_KLT_Load("ergol")
	Lease := KeylayoutEmulation_CaptureCanonicalSource()
	AssertTrue(Lease.Has("normal_read"), "the genuine source retains a coherent normal graph reader")
	Read := Lease["normal_read"], Info := Read.Call("info")
	AssertEqual(8, Info["selectors"], "all eight source selectors were prepared before publication")
	AssertEqual(Info["states"] * 49 * 8, Info["transitions"], "the original source has complete normal rows")
	Starter := Read.Call("find", "none", "SC010", 1, 0, 1)
	Final := Read.Call("find", "circumflex", "SC002", 0, 0, 0)
	AssertTrue(Starter["index"] == 4 && Starter["keycode"] == 12 && Starter["output"] == ""
		&& Starter["after"] == "circumflex", "the shipped Option-Shift key starts literal circumflex")
	AssertTrue(Final["index"] == 0 && Final["keycode"] == 18 && Final["output"] == Chr(0xB9)
		&& Final["after"] == "none", "the shipped base key completes literal superscript one")
	AssertEqual(Starter["after_id"], Final["before_id"], "the source shares one state ID across families")
	AssertEqual(0, Final["after_id"], "the mixed completion retains exact neutral identity")
	Saved := Final.Clone(), Final["output"] := "foreign"
	KLE_State := "retained-live-state"
	_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
	AssertEqual("retained-live-state", KLE_State, "graph reads leave live composition untouched")
	_KLT_Load("ergopti_plus")
	AssertFalse(Lease["current"].Call(), "source replacement withdraws old live admission")
	_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
	KeylayoutEmulation_Unload()
	_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
	Inactive := KeylayoutEmulation_CaptureCanonicalSource()
	_KSO_Reject(() => Inactive["normal_read"].Call("info"), "no admitted graph reader")
}

/** Typed refusals must reach their selector checks. */
_KNG_InvalidSelector() {
	Fixture := _KNG_Fixture()
	Graph := _KLE_BuildNormalReplayGraph(Fixture[1], Fixture[2], Fixture[3], "selector-control")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0, 0, 0, 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", "0", 0, 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0, "0", 0), "lookup modifier is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0, 0, 2), "lookup modifier is invalid")
	_KSO_Reject(() => Graph.Call("find", "NONE", "SC002", 0, 0, 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC004", 0, 0, 0), "does not own that transition")
	Fixture[3].Delete("sco")
	_KSO_Reject(() => _KLE_BuildNormalReplayGraph(Fixture[1], Fixture[2], Fixture[3], "missing-selector"),
		"selector table is incomplete")
}

/** New graph constructors share source withdrawal without revoking historical rows. */
_KNG_WithdrawHelper(Helper) {
	_KLT_Load("ergol")
	Lease := KeylayoutEmulation_CaptureCanonicalSource(), Read := Lease["normal_read"]
	Saved := Read.Call("find", "circumflex", "SC002", 0, 0, 0), Facts := {Calls: 0}
	Helper.DefineProp("Call", {Call: Observe})
	try {
		AssertFalse(Lease["current"].Call(), "graph constructor withdrawal refuses live source admission")
		_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
		AssertEqual(0, Facts.Calls, "historical rows invoke neither replaced constructor")
	} finally Helper.DeleteProp("Call")
	AssertFalse(Lease["current"].Call(), "restoration cannot reactivate a withdrawn source lease")
	AssertTrue(_KSO_Load()["current"].Call(), "a genuine reparse issues a fresh source after restoration")

	Observe(*) {
		Facts.Calls += 1
		throw Error("A withdrawn normal graph constructor must not run.")
	}
}

Test("canonical-normal-graph: mixed-only states share one modifier namespace", _KNG_MixedChain)
Test("canonical-normal-graph: original source retains mixed-family historical rows",
	() => _KLT_WithEmulation(_KNG_OriginalSource))
Test("canonical-normal-graph: exact selector arity and types", _KNG_InvalidSelector)
Test("canonical-normal-graph: normal constructor withdrawal preserves historical data",
	() => _KLT_WithEmulation(_KNG_WithdrawHelper.Bind(_KLE_BuildNormalReplayGraph)))
Test("canonical-normal-graph: shared constructor withdrawal preserves historical data",
	() => _KLT_WithEmulation(_KNG_WithdrawHelper.Bind(_KLE_BuildReplayGraphOwned)))
