; tests/unit/llm_nav_event_owner/test_terminal_route_metadata.ahk

; ==============================================================================
; MODULE: Terminal Route Metadata Adapter Tests
; DESCRIPTION:
; Independent ABI vectors and injected registration/peek boundaries exercise
; actual KLE model recipes. No hook, SendInput or Windows native qualification
; is simulated. Native execution of these AHK cases remains a separate gate.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNTR_WithState(Fn) {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_State
	global _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteUnknown
	global _LLM_NavEventOwnerTerminalRouteNextRecipe, _LLM_NavEventOwnerTerminalRouteNextLayout
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	global _LLM_NavEventOwnerTerminalRouteCoverage, _LLM_NavEventOwnerTerminalRouteRefreshing
	Saved := [KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_State,
		_LLM_NavEventOwnerTerminalRouteGeneration, _LLM_NavEventOwnerTerminalRouteNextRecipe,
		_LLM_NavEventOwnerTerminalRouteNextLayout, _LLM_NavEventOwnerTerminalRouteRecipes,
		_LLM_NavEventOwnerTerminalRouteModels, _LLM_NavEventOwnerTerminalRouteCoverage,
		_LLM_NavEventOwnerTerminalRouteRefreshing, _LLM_NavEventOwnerTerminalRouteOwner,
		_LLM_NavEventOwnerTerminalRouteUnknown]
	try {
		_LLM_NavEventOwnerTerminalRouteGeneration := 0
		_LLM_NavEventOwnerTerminalRouteNextRecipe := 0
		_LLM_NavEventOwnerTerminalRouteNextLayout := 1
		_LLM_NavEventOwnerTerminalRouteRecipes := Map()
		_LLM_NavEventOwnerTerminalRouteModels := Map()
		_LLM_NavEventOwnerTerminalRouteRefreshing := false
		_LLM_NavEventOwnerTerminalRouteUnknown := 0
		_LNTR_LoadFixture("a")
		Fn()
	} finally {
		KLE_Model := Saved[1], KLE_Id := Saved[2], KLE_KeyCodes := Saved[3]
		KLE_LevelIndex := Saved[4], KLE_State := Saved[5]
		_LLM_NavEventOwnerTerminalRouteGeneration := Saved[6]
		_LLM_NavEventOwnerTerminalRouteNextRecipe := Saved[7]
		_LLM_NavEventOwnerTerminalRouteNextLayout := Saved[8]
		_LLM_NavEventOwnerTerminalRouteRecipes := Saved[9]
		_LLM_NavEventOwnerTerminalRouteModels := Saved[10]
		_LLM_NavEventOwnerTerminalRouteCoverage := Saved[11]
		_LLM_NavEventOwnerTerminalRouteRefreshing := Saved[12]
		_LLM_NavEventOwnerTerminalRouteOwner := Saved[13]
		_LLM_NavEventOwnerTerminalRouteUnknown := Saved[14]
	}
}

_LNTR_LoadFixture(Base) {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_State
	Text := '<?xml version="1.0" encoding="UTF-8"?><keyboard group="0" id="1" name="Replay">'
		. '<layouts><layout first="0" last="0" mapSet="S" modifiers="M"/></layouts>'
		. '<modifierMap id="M" defaultIndex="0">'
		. '<keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect>'
		. '<keyMapSelect mapIndex="1"><modifier keys="anyShift"/></keyMapSelect></modifierMap>'
		. '<keyMapSet id="S"><keyMap index="0"><key code="0" output="' . Base . '"/>'
		. '<key code="1" output="1"/><key code="2" action="dead"/></keyMap>'
		. '<keyMap index="1" baseMapSet="S" baseIndex="0">'
		. '<key code="0" output="' . StrUpper(Base) . '"/><key code="1" output="!"/></keyMap></keyMapSet>'
		. '<actions><action id="dead"><when state="none" next="acute"/>'
		. '<when state="acute" output="^"/></action></actions></keyboard>'
	KLE_Model := Keylayout_Parse(Text)
	KLE_Id := "replay-fixture-" . Base
	KLE_KeyCodes := Map("SC010", 0, "SC011", 1, "SC012", 2)
	KLE_LevelIndex := Map(_KLE_ComboKey(false, false, false), 0,
		_KLE_ComboKey(true, false, false), 1)
	KLE_State := "none"
}

_LNTR_Source(State) {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_State
	return Map("active", 1, "caps", State.Caps, "model", KLE_Model,
		"layout_name", KLE_Id, "keys", KLE_KeyCodes.Clone(), "composition_state", KLE_State,
		"capture", KeylayoutEmulation_CaptureReplayRoute, "eligible", (Sc, Shift) => true)
}

_LNTR_Register(State, Owner, Generation, Layout, Bindings, Count) {
	State.Calls.Push(Map("owner", Owner, "generation", Generation,
		"layout", Layout, "bindings", Bindings, "count", Count))
	return State.Status
}

_LNTR_Held(State, Owner, Ids, Capacity) {
	AssertEqual(64, Capacity), AssertEqual(512, Ids.Size)
	if State.HeldThrows
		throw Error("Injected held-query failure.")
	if State.HeldStatus == 0 {
		for Index, RecipeId in State.HeldIds
			NumPut("UInt64", RecipeId, Ids, (Index - 1) * 8)
	}
	return Map("status", State.HeldStatus, "count",
		State.HeldCount == -1 ? State.HeldIds.Length : State.HeldCount)
}

_LNTR_PortState() {
	State := {Status: 0, Caps: 0, Calls: [], HeldStatus: 0, HeldIds: [],
		HeldCount: -1, HeldThrows: false}
	State.Port := Map("terminal_route_source", _LNTR_Source.Bind(State),
		"register_terminal_routes", _LNTR_Register.Bind(State),
		"list_terminal_held_recipes", _LNTR_Held.Bind(State))
	return State
}

; Literal x64 receipt, independent of production encoding/registration helpers.
_LNTR_Receipt(Recipe := 17, RouteId := 17, Generation := 1, Layout := 2,
		Modifiers := 0, Status := 0) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	Receipt := Buffer(184, 0)
	NumPut("UInt64", 901, "UInt64", 3, Receipt, 0)
	NumPut("UInt64", _LLM_NavEventOwnerTerminalRouteOwner,
		"UInt64", Generation, "UInt64", Layout,
		"UInt64", Generation, "UInt64", Layout, Receipt, 16)
	NumPut("Int", Status, Receipt, 64)
	NumPut("UChar", Modifiers ? 0x10 : 0, "UChar", Modifiers ? 0x10 : 0, Receipt, 68)
	NumPut("UInt64", 100, "UInt64", 1, "UShort", 0x51, "UShort", 0x10,
		"UChar", 1, "UChar", 0, "UChar", 0, Receipt, 120)
	NumPut("UInt64", Recipe, "UInt", RouteId, "UInt", 0, "UInt", 0,
		"UInt", 0, "UInt", 0, "UShort", 0x10, "UShort", 0, "UShort", 0,
		"UChar", 2, "UChar", 1, "UChar", Modifiers, "UChar", 0, Receipt, 144)
	return Receipt
}

_LNTR_MarshalCase() {
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(1, State.Calls.Length)
	Call := State.Calls[1]
	AssertEqual(20, Call["count"], "16 natural identities and four plain KLE routes are admitted")
	AssertEqual(800, Call["bindings"].Size, "the exact native descriptor stride is 40 bytes")
	BufferSource := Call["bindings"]
	AssertEqual(1, NumGet(BufferSource, 0, "UInt64"))
	AssertEqual(0x1D, NumGet(BufferSource, 28, "UShort"))
	AssertEqual(0x1D, NumGet(BufferSource, 32, "UShort"))
	AssertEqual(2, NumGet(BufferSource, 34, "UChar"))
	AssertEqual(4, NumGet(BufferSource, 35, "UChar"))
	AssertEqual(1, NumGet(BufferSource, 37, "UChar"))
	AssertEqual(0xA2, NumGet(BufferSource, 40 + 28, "UShort"))
	AssertEqual(0xA2, NumGet(BufferSource, 40 + 30, "UShort"))
	AssertEqual(1, NumGet(BufferSource, 40 + 34, "UChar"))
	AssertEqual(17, NumGet(BufferSource, 640, "UInt64"))
	AssertEqual(0x10, NumGet(BufferSource, 640 + 28, "UShort"))
	AssertEqual(0, NumGet(BufferSource, 640 + 30, "UShort"), "opaque KLE text never guesses native VK")
	AssertEqual(0, NumGet(BufferSource, 640 + 32, "UShort"), "opaque KLE text never guesses native scan")
	AssertEqual(0, NumGet(BufferSource, 640 + 36, "UChar"))
	AssertEqual(4, NumGet(BufferSource, 680 + 36, "UChar"), "Shift recipe records event-time generic Shift")
	AssertEqual(2, NumGet(BufferSource, 720 + 35, "UChar"), "the neutral digit has its actual resolved category")
	Coverage := LLM_NavEventOwner_TerminalRouteCoverage()
	AssertEqual(false, Coverage["cohort_complete"])
	AssertEqual(false, Coverage["transformed_output_enabled"])
	AssertTrue(Coverage["unconverted"].Length >= 10, "unsupported dead keys and cohorts stay explicit")
	Coverage["unconverted"].Push("test-only mutation")
	AssertTrue(LLM_NavEventOwner_TerminalRouteCoverage()["unconverted"].Length
		< Coverage["unconverted"].Length, "coverage does not expose its retained array")
}

_LNTR_RefusalCase() {
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteUnknown
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	State.Status := -11
	AssertEqual(false, LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count, "busy candidates are not published")
	AssertEqual(1, LLM_NavEventOwner_TerminalRouteCoverage()["generation"])
	State.Status := "0"
	AssertThrows(() => LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "a string ACK cannot certify native publication")
	AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map, "The malformed ACK retains its exact candidate.")
	Calls := State.Calls.Length
	AssertThrows(() => LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "Unknown custody prevents another registration.")
	AssertEqual(Calls, State.Calls.Length, "The retry never reaches a successor/native callback.")
	; Isolate the following original known-error vector after this explicit mock
	; boundary. This is not a production settlement/reset mechanism.
	_LLM_NavEventOwnerTerminalRouteUnknown := 0
	State.Status := -5
	AssertThrows(() => LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "invalid native registrations stay errors")
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	AssertEqual(1, LLM_NavEventOwner_TerminalRouteCoverage()["generation"])
}

_LNTR_RetainedRecipeCase() {
	global KLE_State
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	Base := _LLM_NavEventOwnerTerminalRouteDecode(_LNTR_Receipt(), 901)
	Shift := _LLM_NavEventOwnerTerminalRouteDecode(_LNTR_Receipt(18, 18, 1, 2, 4), 901)
	_LNTR_LoadFixture("z")
	State.HeldIds := [17, 18]
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	KLE_State := "unrelated live composition"
	AssertEqual("a", LLM_NavEventOwner_StepTerminalRoute(Base, "none")["Output"])
	AssertEqual("A", LLM_NavEventOwner_StepTerminalRoute(Shift, "none")["Output"])
	AssertEqual("unrelated live composition", KLE_State, "queued model stepping cannot mutate live KLE state")
	Current := _LLM_NavEventOwnerTerminalRouteDecode(_LNTR_Receipt(37, 17, 2, 3), 901)
	AssertEqual("z", LLM_NavEventOwner_StepTerminalRoute(Current, "none")["Output"])
	AssertEqual(false, LLM_NavEventOwner_StepTerminalRoute(Base, "none")["transformed_output_enabled"])
	AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Base, "acute"), "composition outside this subset is refused")
	Corrupt := Base.Clone()
	Corrupt["route_generation"] := 2
	AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Corrupt, "none"), "recipe IDs retain exact generation ownership")
	Corrupt := Base.Clone()
	Corrupt["route"] := Base["route"].Clone()
	Corrupt["route"]["code"] := 0x11
	AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Corrupt, "none"), "a captured recipe cannot change its key")
}

_LNTR_RetirementCase() {
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	Old := _LLM_NavEventOwnerTerminalRouteDecode(_LNTR_Receipt(), 901)
	State.HeldIds := [17]
	_LNTR_LoadFixture("z")
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(21, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	AssertEqual(2, _LLM_NavEventOwnerTerminalRouteModels.Count)
	AssertEqual("a", LLM_NavEventOwner_StepTerminalRoute(Old, "none")["Output"])
	State.HeldIds := []
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	AssertEqual(1, _LLM_NavEventOwnerTerminalRouteModels.Count)
	AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Old, "none"),
		"retired diagnostic copies cannot prolong native recipe ownership")
	Loop 12 {
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count,
			"successful debt-free refresh retains only the current registry")
		AssertEqual(1, _LLM_NavEventOwnerTerminalRouteModels.Count)
	}
}

_LNTR_RetirementFailureCase() {
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	Old := _LLM_NavEventOwnerTerminalRouteDecode(_LNTR_Receipt(), 901)
	_LNTR_LoadFixture("z")
	; Busy, wrong owner, malformed typed ACK/count, unknown/duplicate identities,
	; and query exceptions all preserve both recipe and layout references.
	Cases := [{Status: 5, Count: -1, Ids: [], Throws: false},
		{Status: 8, Count: -1, Ids: [], Throws: false},
		{Status: "0", Count: -1, Ids: [], Throws: false},
		{Status: 0, Count: 65, Ids: [], Throws: false},
		{Status: 0, Count: "0", Ids: [], Throws: false},
		{Status: 0, Count: -1, Ids: [999999], Throws: false},
		{Status: 0, Count: -1, Ids: [17, 17], Throws: false},
		{Status: 0, Count: -1, Ids: [], Throws: true}]
	for Index, Vector in Cases {
		State.HeldStatus := Vector.Status, State.HeldCount := Vector.Count
		State.HeldIds := Vector.Ids, State.HeldThrows := Vector.Throws
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port),
			"retirement failure cannot undo a successful native registration")
		AssertEqual(20 * (Index + 1), _LLM_NavEventOwnerTerminalRouteRecipes.Count)
		AssertEqual(2, _LLM_NavEventOwnerTerminalRouteModels.Count)
		AssertEqual("a", LLM_NavEventOwner_StepTerminalRoute(Old, "none")["Output"])
	}
	State.HeldStatus := 0, State.HeldCount := -1, State.HeldIds := [], State.HeldThrows := false
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count,
		"a later authoritative query retires all deferred references")
	AssertEqual(1, _LLM_NavEventOwnerTerminalRouteModels.Count)
}

_LNTR_DecodeCase() {
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	Receipt := _LNTR_Receipt()
	Decoded := _LLM_NavEventOwnerTerminalRouteDecode(Receipt, 901)
	AssertEqual(901, Decoded["token"]), AssertEqual(3, Decoded["sequence"])
	AssertEqual(100, Decoded["event"]["timestamp"])
	AssertEqual(1, Decoded["event"]["source_id"])
	AssertEqual(0x10, Decoded["event"]["scan"])
	AssertEqual(17, Decoded["route"]["recipe_id"])
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteDecode(Buffer(168, 0)), "a pure snapshot is not a FIFO receipt")
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteDecode(Receipt, 902), "wrong capture token is rejected")
	NumPut("UChar", 4, Receipt, 140)
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteDecode(Receipt, 901), "lower integrity cannot become a supported recipe")
	Receipt := _LNTR_Receipt(17, 17, 1, 2, 0, 2)
	Unsupported := _LLM_NavEventOwnerTerminalRouteDecode(Receipt, 901)
	AssertEqual(17, Unsupported["route"]["recipe_id"], "uncertain recipes remain available as diagnostic evidence")
	AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Unsupported, "none"), "uncertainty never authorizes queued text")
	Receipt := _LNTR_Receipt()
	NumPut("UChar", 1, "UChar", 1, Receipt, 141)
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteDecode(Receipt), "an up cannot also be a repeat")
}

_LNTR_CohortCase() {
	global KLE_State
	State := _LNTR_PortState()
	State.Caps := 1
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(16, State.Calls[1]["count"], "CapsLock-on never publishes neutral KLE recipes")
	State.Caps := 0
	KLE_State := "acute"
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(16, State.Calls[2]["count"], "active composition never publishes neutral KLE recipes")
	AssertEqual(false, LLM_NavEventOwner_TerminalRouteCoverage()["cohort_complete"])
}

_LNTR_Peek(State, Token, Index, Receipt) {
	State.Calls.Push(Map("token", Token, "index", Index, "size", Receipt.Size))
	if State.Status == 0 {
		Source := _LNTR_Receipt()
		Loop 184
			NumPut("UChar", NumGet(Source, A_Index - 1, "UChar"), Receipt, A_Index - 1)
	}
	return State.Status
}

_LNTR_PeekCase() {
	State := {Status: 0, Calls: []}
	Port := Map("peek_terminal_route", _LNTR_Peek.Bind(State))
	Snapshot := LLM_NavEventOwner_PeekTerminalRoute(901, 0, Port)
	AssertEqual(3, Snapshot["sequence"])
	AssertEqual(0, State.Calls[1]["index"], "peek uses the native zero-based index")
	AssertEqual(184, State.Calls[1]["size"])
	State.Status := 4
	AssertEqual(0, LLM_NavEventOwner_PeekTerminalRoute(901, 9, Port))
	State.Status := 8
	AssertEqual(0, LLM_NavEventOwner_PeekTerminalRoute(902, 0, Port))
	State.Status := 1
	AssertThrows(() => LLM_NavEventOwner_PeekTerminalRoute(901, 0, Port), "invalid native peek is an error")
	AssertThrows(() => LLM_NavEventOwner_PeekTerminalRoute(901, -1, Port), "negative index never reaches native code")
}

_LNTR_TypedMarshalCase() {
	Route := Map("recipe_id", 1, "route_id", 1, "required_prefixes", 0,
		"prefix_bit", 0, "required_dead_key_id", 0, "next_dead_key_id", 0,
		"code", 0x10, "target_vk", 0, "target_scan", 0,
		"axis", 2, "kind", 1, "required_modifiers", 0, "effective_modifiers_lr", 0)
	AssertEqual(40, _LLM_NavEventOwnerTerminalRouteMarshal([Route]).Size)
	Missing := Route.Clone(), Missing.Delete("axis")
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteMarshal([Missing]), "missing fields are not defaulted")
	StringValue := Route.Clone(), StringValue["code"] := "16"
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteMarshal([StringValue]), "numeric-looking strings are not typed codes")
	Duplicate := Route.Clone(), Duplicate["recipe_id"] := 2, Duplicate["route_id"] := 2
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteMarshal([Route, Duplicate]), "duplicate selectors are rejected before native publication")
	Hole := [Route, Route.Clone()], Hole.Delete(1)
	AssertThrows(() => _LLM_NavEventOwnerTerminalRouteMarshal(Hole), "holes cannot become zeroed native registrations")
}

Test("terminal route metadata: authoritative subset marshals exact x64 descriptors (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_MarshalCase))
Test("terminal route metadata: refusal preserves admitted recipes and coverage (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_RefusalCase))
Test("terminal route metadata: retained model survives layout and live-state changes (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_RetainedRecipeCase))
Test("terminal route metadata: FIFO ABI and provenance reject malformed receipts (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_DecodeCase))
Test("terminal route metadata: Caps and composition remain unconverted cohorts (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_CohortCase))
Test("terminal route metadata: zero-based peek keeps native debt ownership (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_PeekCase))
Test("terminal route metadata: complete typed registry rejects holes and ambiguity (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_TypedMarshalCase))
Test("terminal route metadata: debt-free retirement bounds recipes and layout ownership (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_RetirementCase))
Test("terminal route metadata: held-query failures preserve all references until retry (todo49-route-adapter)",
	() => _LNTR_WithState(_LNTR_RetirementFailureCase))

/** Original registration authority survives callback replacement and actual effects. */
_LNTR_RegistrationCustody(Phase, Mutation, Outcome) {
	_LNTR_WithState(Body)
	Body() {
		global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteGeneration
		global _LLM_NavEventOwnerTerminalRouteNextRecipe, _LLM_NavEventOwnerTerminalRouteNextLayout
		global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
		global _LLM_NavEventOwnerTerminalRouteCoverage, _LLM_NavEventOwnerTerminalRouteUnknown
		State := _LNTR_PortState()
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		Owner := _LLM_NavEventOwnerTerminalRouteOwner
		Recipes := _LLM_NavEventOwnerTerminalRouteRecipes, Models := _LLM_NavEventOwnerTerminalRouteModels
		Route := Recipes[17]["route"], Recipe := Recipes[17]["recipe"], Model := Recipe["model"]
		Changed := 0, HeldCalls := 0, OriginalCoverage := _LLM_NavEventOwnerTerminalRouteCoverage
		if Phase == "source"
			State.Port["terminal_route_source"] := Source
		else if Phase == "register"
			State.Port["register_terminal_routes"] := Register
		else
			State.Port["list_terminal_held_recipes"] := Held
		AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
		AssertEqual(1, Changed)
		AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map)
		Unknown := _LLM_NavEventOwnerTerminalRouteUnknown
		AssertEqual(Owner, Unknown["owner"], "A foreign successor cannot inherit the old native owner.")
		AssertTrue(Unknown["recipes"] == Recipes), AssertTrue(Unknown["models"] == Models)
		AssertTrue(Unknown["route_objects"][17]["route"] == Route)
		AssertTrue(Unknown["route_objects"][17]["recipe"] == Recipe)
		AssertTrue(Unknown["route_objects"][17]["model"] == Model)
		AssertEqual(Phase != "source", Unknown["native_attempted"])
		if Phase != "source" {
			AssertTrue(Unknown["candidate"] is Map)
			AssertEqual(20, Unknown["candidate"]["recipes"].Count)
			AssertEqual(800, Unknown["bindings"].Size)
			AssertEqual(Owner, State.Calls[2]["owner"])
		}
		AssertEqual(Phase == "source" ? 1 : 2, State.Calls.Length)
		AssertEqual(Phase == "held" ? 1 : 0, HeldCalls)
		AssertEqual(Phase == "held" ? 2 : 1, Unknown["coverage"]["generation"])
		Calls := State.Calls.Length
		; Restoring public pointers never settles an unknown real registration.
		_LLM_NavEventOwnerTerminalRouteOwner := Owner
		_LLM_NavEventOwnerTerminalRouteGeneration := Unknown["generation"]
		_LLM_NavEventOwnerTerminalRouteRecipes := Recipes
		_LLM_NavEventOwnerTerminalRouteModels := Models
		_LLM_NavEventOwnerTerminalRouteCoverage := Unknown["coverage"]
		AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
		AssertEqual(Calls, State.Calls.Length), AssertEqual(Phase == "held" ? 1 : 0, HeldCalls)
		AssertFalse(LLM_NavEventOwner_TerminalRouteCoverage()["cohort_complete"])
		AssertFalse(LLM_NavEventOwner_TerminalRouteCoverage()["transformed_output_enabled"])
		Source() {
			Result := _LNTR_Source(State)
			Change()
			return Result
		}
		Register(OwnerArg, Generation, Layout, Bindings, Count) {
			AssertEqual(Owner, OwnerArg)
			_LNTR_Register(State, OwnerArg, Generation, Layout, Bindings, Count)
			if Mutation == "bindings-byte"
				NumPut("UChar", NumGet(Bindings, 0, "UChar") ^ 1, Bindings, 0)
			else if Mutation == "bindings-size"
				Bindings.Size := 1
			Change()
			return Outcome == "busy" ? -11 : Outcome == "unknown" ? "0" : 0
		}
		Held(OwnerArg, BufferArg, Capacity) {
			HeldCalls += 1
			AssertEqual(Owner, OwnerArg)
			Result := _LNTR_Held(State, OwnerArg, BufferArg, Capacity)
			Change()
			return Result
		}
		Change() {
			Changed += 1
			switch Mutation {
				case "owner": _LLM_NavEventOwnerTerminalRouteOwner += 7
				case "generation": _LLM_NavEventOwnerTerminalRouteGeneration += 7
				case "next-recipe": _LLM_NavEventOwnerTerminalRouteNextRecipe += 7
				case "next-layout": _LLM_NavEventOwnerTerminalRouteNextLayout += 7
				case "recipes": _LLM_NavEventOwnerTerminalRouteRecipes := Recipes.Clone()
				case "models": _LLM_NavEventOwnerTerminalRouteModels := Models.Clone()
				case "coverage": _LLM_NavEventOwnerTerminalRouteCoverage := _LLM_NavEventOwnerTerminalRouteCoverage.Clone()
				case "recipe-cell": Recipes[17] := Recipes[17].Clone()
				case "route-object": Recipes[17]["route"] := Route.Clone()
				case "route-field": Route["code"] += 1
				case "recipe-object": Recipes[17]["recipe"] := Recipe.Clone()
				case "recipe-field": Recipe["index"] += 1
				case "recipe-model": Recipe["model"] := Model.Clone()
			}
			if Outcome == "throw"
				throw Error("Injected callback failure after possible native registration.")
		}
	}
}
for _LNTR_CustodyPhase in ["source", "register", "held"]
	for _LNTR_CustodyMutation in ["owner", "generation", "next-recipe", "next-layout", "recipes", "models", "coverage", "recipe-cell",
		"route-object", "route-field", "recipe-object", "recipe-field", "recipe-model"]
		for _LNTR_CustodyOutcome in ["normal", "throw"]
			Test("terminal registration custody: " . _LNTR_CustodyPhase . ":" . _LNTR_CustodyMutation
				. ":" . _LNTR_CustodyOutcome . " (todo49-registration-custody)",
				_LNTR_RegistrationCustody.Bind(_LNTR_CustodyPhase, _LNTR_CustodyMutation, _LNTR_CustodyOutcome))
for _LNTR_RefusedMutation in ["owner", "recipes", "generation", "bindings-byte", "bindings-size"]
	for _LNTR_RefusedOutcome in ["busy", "unknown"]
		Test("terminal registration custody: refused " . _LNTR_RefusedMutation . ":" . _LNTR_RefusedOutcome
			. " (todo49-registration-custody)", _LNTR_RegistrationCustody.Bind("register", _LNTR_RefusedMutation, _LNTR_RefusedOutcome))
for _LNTR_ByteMutation in ["bindings-byte", "bindings-size"]
	Test("terminal registration custody: acknowledged " . _LNTR_ByteMutation . " (todo49-registration-custody)",
		_LNTR_RegistrationCustody.Bind("register", _LNTR_ByteMutation, "normal"))

_LNTR_RegistrationBuildFailureIsRetryable() {
	_LNTR_WithState(Body)
	Body() {
		global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerTerminalRouteRecipes
		State := _LNTR_PortState()
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		State.Port["terminal_route_source"] := Source
		AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
		AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown, "An ordinary failed pure build creates no native registration debt.")
		AssertEqual(1, State.Calls.Length), AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
		State.Port["terminal_route_source"] := _LNTR_Source.Bind(State)
		State.HeldIds := [17]
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		AssertEqual(2, State.Calls.Length)
		AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes.Has(17), "Fresh native census still retains its original held recipe.")
		Source() {
			Result := _LNTR_Source(State)
			Result["capture"] := Capture
			return Result
		}
		Capture(*) {
			throw Error("A pure KLE capture failed before native registration.")
		}
	}
}
Test("terminal registration custody: pure build error stays retryable without ACK guess (todo49-registration-custody)",
	_LNTR_RegistrationBuildFailureIsRetryable)

/** Reentrant builders cannot replace retained models while allocating a new one. */
_LNTR_ModelBuildCustody(Phase, Mutation, Outcome) {
	_LNTR_WithState(Body)
	Body() {
		global KLE_Model, _LLM_NavEventOwnerTerminalRouteModels
		global _LLM_NavEventOwnerTerminalRouteUnknown
		State := _LNTR_PortState()
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		Models := _LLM_NavEventOwnerTerminalRouteModels
		Id := ObjPtr(KLE_Model), Identity := Models[Id]
		OriginalModel := Identity["model"], OriginalLayout := Identity["id"]
		_LNTR_LoadFixture("b")
		Changed := 0
		State.Port["terminal_route_source"] := Source
		AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
		AssertEqual(1, Changed)
		AssertEqual(1, State.Calls.Length, "Withdrawn model custody refuses before native registration.")
		AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map)
		Unknown := _LLM_NavEventOwnerTerminalRouteUnknown
		AssertTrue(Unknown["models"] == Models)
		AssertTrue(Unknown["model_refs"][Id] == Identity, "Retain the original cell after an uncertain builder.")
		AssertTrue(Unknown["model_objects"][Id]["model"] == OriginalModel)
		AssertEqual(OriginalLayout, Unknown["model_objects"][Id]["id"])
		AssertFalse(Unknown["native_attempted"])
		AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
		AssertEqual(1, State.Calls.Length, "An unknown builder cannot retry through a successor owner.")
		Source() {
			Result := _LNTR_Source(State)
			CaptureFn := Result["capture"], EligibleFn := Result["eligible"]
			Result["capture"] := CaptureFnWithMutation
			Result["eligible"] := EligibleFnWithMutation
			return Result
			CaptureFnWithMutation(Args*) {
				if Phase == "capture"
					Change()
				return CaptureFn.Call(Args*)
			}
			EligibleFnWithMutation(Args*) {
				if Phase == "eligible"
					Change()
				return EligibleFn.Call(Args*)
			}
		}
		Change() {
			if Changed
				return
			Changed += 1
			switch Mutation {
				case "cell": Models[Id] := Identity.Clone()
				case "model": Identity["model"] := OriginalModel.Clone()
				case "layout": Identity["id"] += 1
				case "delete": Models.Delete(Id)
				case "insert": Models[0] := Identity.Clone()
			}
			if Outcome == "throw"
				throw Error("Injected model custody withdrawal during recipe build.")
		}
	}
}
for _LNTR_ModelPhase in ["eligible", "capture"]
	for _LNTR_ModelMutation in ["cell", "model", "layout", "delete", "insert"]
		for _LNTR_ModelOutcome in ["normal", "throw"]
			Test("terminal model build custody: " . _LNTR_ModelPhase . ":" . _LNTR_ModelMutation
				. ":" . _LNTR_ModelOutcome . " (todo49-model-build-custody)",
				_LNTR_ModelBuildCustody.Bind(_LNTR_ModelPhase, _LNTR_ModelMutation, _LNTR_ModelOutcome))
