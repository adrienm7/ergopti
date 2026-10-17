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
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_State, KLE_Compositions
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
		_LLM_NavEventOwnerTerminalRouteUnknown, KLE_Compositions]
	Primary := 0, CleanupFailure := 0
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
	} catch as Err {
		Primary := Err
		throw Err
	} finally {
		; Public fixture restoration cannot release a private source lease. Stop
		; through the original protocol before returning the borrowed globals.
		if IsObject(_LLM_NavEventOwnerTerminalRouteUnknown) {
			try {
				AssertTrue(_LNTR_StopFixtureState(), "owned metadata fixture cleanup must acknowledge Stop")
				AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown)
			} catch as Err {
				CleanupFailure := Err
				if IsObject(Primary) {
					Primary.MetadataCleanupError := Err
					Primary.Message .= "; metadata fixture cleanup failed: " . Err.Message
				}
			}
		}
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
		KLE_Compositions := Saved[15]
		if IsObject(CleanupFailure) && !IsObject(Primary)
			throw CleanupFailure
	}
}

_LNTR_StopFixtureState() {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerPort
	; A preceding real ABI case leaves its DLL intentionally process-resident.
	; Its retained frame requires the unchanged genuine native Stop receipt;
	; the fixture's custom ACK cannot retire that C lifetime.
	Port := _LLM_NavEventOwnerPort
	if !(_LLM_NavEventOwnerModule is Integer) || _LLM_NavEventOwnerModule <= 0
			|| !(Port is Map) || !Port.Has("stop")
		return LLM_NavEventOwner_Stop()
	Stop := Port["stop"]
	Port.Delete("stop")
	try return LLM_NavEventOwner_Stop()
	finally Port["stop"] := Stop
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
	; Registration tests use the original loader, never a supplied source witness.
	Table := Map("conventions", ["iso"], "keys", [
		Map("ahk", "SC010", "mac", 0), Map("ahk", "SC011", "mac", 1),
		Map("ahk", "SC012", "mac", 2)])
	AssertEqual(3, KeylayoutEmulation_Load("replay-fixture-" . Base, Text, "iso", Table))
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
	State := _LNTR_PortState(), KnownFailure := 0
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	State.Status := -11
	AssertEqual(false, LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count, "busy candidates are not published")
	AssertEqual(1, LLM_NavEventOwner_TerminalRouteCoverage()["generation"])
	; A known refusal must reach its registration port before unknown custody
	; intentionally blocks every successor until the fixture acknowledges Stop.
	InvalidCalls := State.Calls.Length
	State.Status := -5
	Calls := State.Calls.Length
	AssertThrows(CaptureKnownFailure, "invalid native registrations stay errors")
	AssertEqual(Calls + 1, State.Calls.Length, "The known refusal reaches its actual registration callback.")
	AssertEqual(InvalidCalls + 1, State.Calls.Length, "the invalid ACK must reach its selected registration boundary")
	AssertTrue(IsObject(KnownFailure) && KnownFailure.HasOwnProp("NativeStatus"),
		"An unrelated admission failure cannot stand in for the known native refusal.")
	AssertEqual(-5, KnownFailure.NativeStatus)
	AssertEqual(0, KnownFailure.NativeErrorCode)
	AssertEqual(20, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	AssertEqual(1, LLM_NavEventOwner_TerminalRouteCoverage()["generation"])
	State.Status := "0"
	AssertThrows(() => LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "a string ACK cannot certify native publication")
	AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map, "The malformed ACK retains its exact candidate.")
	Calls := State.Calls.Length
	AssertThrows(() => LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "Unknown custody prevents another registration.")
	AssertEqual(Calls, State.Calls.Length, "The retry never reaches a successor/native callback.")

	; Keep the original unknown frame visible so _LNTR_WithState retires its
	; private source lease through Stop before the next fixture can register.

	CaptureKnownFailure() {
		try LLM_NavEventOwner_RefreshTerminalRoutes(State.Port)
		catch as Err {
			KnownFailure := Err
			throw Err
		}
	}
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

; Literal kind6 ABI data; this fixture never claims a registered binding source.
_DDBA_Route(Scan) {
	return Map("recipe_id", 301, "route_id", 11, "required_prefixes", 0,
		"prefix_bit", 0, "required_dead_key_id", 0, "next_dead_key_id", 0,
		"code", Scan, "target_vk", 0, "target_scan", 0,
		"axis", 2, "kind", 6, "required_modifiers", 0, "effective_modifiers_lr", 0)
}

_DDBA_Marshal() {
	Loop 10 {
		Scan := A_Index + 1
		Route := _DDBA_Route(Scan)
		Bytes := _LLM_NavEventOwnerTerminalRouteMarshal([Route])
		AssertEqual(40, Bytes.Size)
		AssertEqual(301, NumGet(Bytes, 0, "UInt64"))
		AssertEqual(11, NumGet(Bytes, 8, "UInt"))
		AssertEqual(Scan, NumGet(Bytes, 28, "UShort"))
		AssertEqual(0, NumGet(Bytes, 30, "UShort"), "source intent cannot guess a host VK")
		AssertEqual(0, NumGet(Bytes, 32, "UShort"), "source intent cannot guess a host scan")
		AssertEqual(2, NumGet(Bytes, 34, "UChar"))
		AssertEqual(6, NumGet(Bytes, 35, "UChar"), "direct intent is distinct from KLE Unicode kind2")
		Read := _LLM_NavEventOwnerTerminalRouteRead(Bytes, 0)
		for Name, Value in Route
			AssertEqual(Value, Read[Name], "the exact native descriptor survives AHK ABI transport")
	}
}

_DDBA_Refusals() {
	for Mutation in [Map("axis", 1), Map("code", 1), Map("code", 0x0C),
		Map("target_vk", 0x31), Map("target_scan", 2), Map("required_modifiers", 1),
		Map("required_prefixes", 1), Map("prefix_bit", 1),
		Map("required_dead_key_id", 1), Map("next_dead_key_id", 1),
		Map("effective_modifiers_lr", 1), Map("kind", 7)] {
		Route := _DDBA_Route(2)
		for Name, Value in Mutation
			Route[Name] := Value
		AssertThrows(() => _LLM_NavEventOwnerTerminalRouteMarshal([Route]),
			"direct-digit metadata rejects transforms, guessed targets and out-of-family sources")
	}
}

_DDBA_Decode() {
	Loop 10 {
		Scan := A_Index + 1
		for Edge in [[0, 0], [0, 1], [1, 0]] {
			Receipt := _LNTR_Receipt(301, 11)
			NumPut("UShort", 0x31, "UShort", Scan, Receipt, 136)
			NumPut("UChar", Edge[1], "UChar", Edge[2], Receipt, 141)
			NumPut("UShort", Scan, Receipt, 172)
			NumPut("UChar", 6, Receipt, 179)
			Snapshot := _LLM_NavEventOwnerTerminalRouteDecode(Receipt, 901)
			AssertEqual(6, Snapshot["route"]["kind"])
			AssertEqual(Scan, Snapshot["route"]["code"])
			AssertEqual(Edge[1], Snapshot["event"]["key_up"])
			AssertEqual(Edge[2], Snapshot["event"]["repeat"])
			AssertTrue(Snapshot["metadata_only"])
			AssertFalse(Snapshot["cohort_complete"])
			AssertFalse(Snapshot["transformed_output_enabled"])
			AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Snapshot, "none"),
				"a source-only direct digit cannot be stepped through the KLE Unicode model")
		}
	}
}

_DDBA_NoKLEReinterpretation() {
	global _LLM_NavEventOwnerTerminalRouteRecipes
	State := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
	Admission := _LLM_NavEventOwnerTerminalRouteRecipes[19]
	AssertEqual(2, Admission["route"]["kind"], "the original retained recipe is a real KLE Unicode digit")
	AssertEqual("1", KeylayoutEmulation_StepReplayRoute(Admission["recipe"], "none")["Output"])
	; Match every public fixture identity so only the source-family exclusion can
	; prevent a direct digit from being reinterpreted through that KLE model.
	Route := _DDBA_Route(2), Route["recipe_id"] := 19, Route["route_id"] := 19
	Admission["route"] := Route.Clone()
	Receipt := _LNTR_Receipt(19, 19)
	NumPut("UShort", 2, Receipt, 138)
	NumPut("UShort", 2, Receipt, 172)
	NumPut("UChar", 6, Receipt, 179)
	Snapshot := _LLM_NavEventOwnerTerminalRouteDecode(Receipt, 901)
	AssertThrows(() => LLM_NavEventOwner_StepTerminalRoute(Snapshot, "none"),
		"even a matching retained KLE digit cannot give source-only kind6 Unicode output")
}

Test("direct-digit-metadata-abi: ten source scans retain exact targetless x64 descriptors", _DDBA_Marshal)
Test("direct-digit-metadata-abi: targets chords transforms and invalid scans refuse", _DDBA_Refusals)
Test("direct-digit-metadata-abi: Down repeat Up remain diagnostic without Unicode stepping", _DDBA_Decode)
Test("direct-digit-metadata-abi: matching retained KLE digit cannot authorize Unicode reinterpretation",
	() => _LNTR_WithState(_DDBA_NoKLEReinterpretation))

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

_LNTR_LifecycleSource(State) {
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerTerminalRouteRefreshing
	global _LLM_NavEventOwnerStartCancelled
	State.SourceCalls += 1
	if State.StopPhase == "source"
		State.StopResult := LLM_NavEventOwner_Stop()
	else if State.StopPhase == "starting" {
		State.SawStarting := _LLM_NavEventOwnerStarting
		State.SawRefreshing := _LLM_NavEventOwnerTerminalRouteRefreshing
		State.StopResult := LLM_NavEventOwner_Stop()
		State.SawCancellation := _LLM_NavEventOwnerStartCancelled
		State.StopCallsDuringRefresh := State.Native.StopCalls
	}
	return _LNTR_Source(State)
}

_LNTR_LifecycleRegister(State, Owner, Generation, Layout, Bindings, Count) {
	if State.StopPhase == "register"
		State.StopResult := LLM_NavEventOwner_Stop()
	return _LNTR_Register(State, Owner, Generation, Layout, Bindings, Count)
}

_LNTR_LifecycleHeld(State, Owner, Ids, Capacity) {
	if State.StopPhase == "held"
		State.StopResult := LLM_NavEventOwner_Stop()
	return _LNTR_Held(State, Owner, Ids, Capacity)
}

_LNTR_LifecyclePort() {
	State := _LNTR_PortState()
	State.SourceCalls := 0
	State.StopPhase := "none"
	State.StopResult := "not_called"
	State.Port["terminal_route_source"] := _LNTR_LifecycleSource.Bind(State)
	State.Port["register_terminal_routes"] := _LNTR_LifecycleRegister.Bind(State)
	State.Port["list_terminal_held_recipes"] := _LNTR_LifecycleHeld.Bind(State)
	return State
}

_LNTR_LifecycleStopInsideRefresh(Phase) {
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerStarted
	Native := _LNEO_Setup()
	try {
		State := _LNTR_LifecyclePort()
		State.StopPhase := Phase
		Epoch := _LLM_NavEventOwnerRuntimeEpoch
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		AssertFalse(State.StopResult, Phase . ": Stop must refuse inside an active refresh")
		AssertEqual(0, Native.StopCalls, "the refusal must precede the physical Stop port")
		AssertTrue(Native.Started && _LLM_NavEventOwnerStarted)
		AssertEqual(Epoch, _LLM_NavEventOwnerRuntimeEpoch, "refresh keeps the admitted runtime epoch")
		AssertEqual(1, State.SourceCalls)
		AssertEqual(1, State.Calls.Length, "ordinary registration must still complete once")
		Coverage := LLM_NavEventOwner_TerminalRouteCoverage()
		AssertFalse(Coverage["cohort_complete"] || Coverage["transformed_output_enabled"])
	} finally _LNEO_Teardown()
}
Test("terminal-lifecycle-admission: source callback cannot Stop an active refresh",
	_LNTR_WithState.Bind(_LNTR_LifecycleStopInsideRefresh.Bind("source")))
Test("terminal-lifecycle-admission: registration callback cannot Stop an active refresh",
	_LNTR_WithState.Bind(_LNTR_LifecycleStopInsideRefresh.Bind("register")))
Test("terminal-lifecycle-admission: held query cannot Stop an active refresh",
	_LNTR_WithState.Bind(_LNTR_LifecycleStopInsideRefresh.Bind("held")))

_LNTR_LifecycleRefreshDuringStop(Native, State) {
	global _LLM_NavEventOwnerStopping
	AssertTrue(_LLM_NavEventOwnerStopping, "the injected physical Stop must observe admission")
	Native.NestedRefresh := LLM_NavEventOwner_RefreshTerminalRoutes(State.Port)
	return _LNEO_PortStop(Native)
}

_LNTR_LifecycleRefreshInsideStop() {
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteCoverage
	Native := _LNEO_Setup()
	try {
		State := _LNTR_LifecyclePort()
		Native.NestedRefresh := "not_called"
		Native.Port["stop"] := _LNTR_LifecycleRefreshDuringStop.Bind(Native, State)
		Epoch := _LLM_NavEventOwnerRuntimeEpoch
		Generation := _LLM_NavEventOwnerTerminalRouteGeneration
		Coverage := _LLM_NavEventOwnerTerminalRouteCoverage
		AssertTrue(LLM_NavEventOwner_Stop())
		AssertFalse(Native.NestedRefresh, "refresh must refuse during physical Stop")
		AssertEqual(0, State.SourceCalls, "no source callback may run after stop admission")
		AssertEqual(0, State.Calls.Length, "no registration may run after stop admission")
		AssertEqual(1, Native.StopCalls)
		AssertEqual(Epoch + 1, _LLM_NavEventOwnerRuntimeEpoch)
		AssertEqual(Generation, _LLM_NavEventOwnerTerminalRouteGeneration)
		AssertTrue(Coverage == _LLM_NavEventOwnerTerminalRouteCoverage)
	} finally {
		Native.Port["stop"] := _LNEO_PortStop.Bind(Native)
		_LNEO_Teardown()
	}
}
Test("terminal-lifecycle-admission: refresh is refused inside the actual Stop port",
	_LNTR_WithState.Bind(_LNTR_LifecycleRefreshInsideStop))

_LNTR_LifecycleRefreshWhilePending() {
	global _LLM_NavEventOwnerStopPending, _LLM_NavEventOwnerTerminalRouteGeneration
	Native := _LNEO_Setup()
	try {
		State := _LNTR_LifecyclePort()
		Generation := _LLM_NavEventOwnerTerminalRouteGeneration
		Native.StopMode := "pending"
		AssertFalse(LLM_NavEventOwner_Stop())
		AssertTrue(_LLM_NavEventOwnerStopPending)
		AssertFalse(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		AssertEqual(0, State.SourceCalls, "a draining runtime cannot inspect a successor source")
		AssertEqual(0, State.Calls.Length)
		AssertEqual(Generation, _LLM_NavEventOwnerTerminalRouteGeneration)
		Native.StopMode := "accept"
		AssertTrue(LLM_NavEventOwner_Stop())
		AssertFalse(_LLM_NavEventOwnerStopPending)
		AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
		AssertEqual(1, State.SourceCalls, "an acknowledged retirement releases only this admission fence")
		AssertEqual(1, State.Calls.Length)
	} finally {
		Native.StopMode := "accept"
		_LNEO_Teardown()
	}
}
Test("terminal-lifecycle-admission: pending Stop refuses refresh until acknowledgement",
	_LNTR_WithState.Bind(_LNTR_LifecycleRefreshWhilePending))

_LNTR_LifecycleStartWithRefresh(Native, State, Hwnd, WakeMessage) {
	Result := _LNEO_PortStart(Native, Hwnd, WakeMessage)
	Native.StartRefresh := LLM_NavEventOwner_RefreshTerminalRoutes(State.Port)
	return Result
}

_LNTR_LifecycleStartingRefreshCancellation() {
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerTerminalRouteRefreshing, _LLM_NavEventOwnerStartCancelled
	global _LLM_NavEventOwnerActiveStartTicket, _LLM_NavEventOwnerStartRollbackPending
	_LNEO_Teardown()
	Native := _LNEO_NewNativeState()
	try {
		State := _LNTR_LifecyclePort()
		State.StopPhase := "starting"
		State.Native := Native
		Native.StartRefresh := "not_called"
		Native.Port["start"] := _LNTR_LifecycleStartWithRefresh.Bind(Native, State)
		AssertFalse(LLM_NavEventOwner_EnsureStarted(Native.Port))
		AssertTrue(State.SawStarting && State.SawRefreshing)
		AssertFalse(State.StopResult)
		AssertTrue(State.SawCancellation, "Starting cancellation must precede the refresh refusal")
		AssertEqual(0, State.StopCallsDuringRefresh)
		AssertTrue(Native.StartRefresh, "the outer refresh must unwind normally before rollback")
		AssertEqual(1, Native.StartCalls.Length)
		AssertEqual(1, Native.StopCalls, "rollback must Stop once after both nested calls unwind")
		AssertFalse(Native.Started || _LLM_NavEventOwnerStarted || _LLM_NavEventOwnerStarting)
		AssertFalse(_LLM_NavEventOwnerTerminalRouteRefreshing || _LLM_NavEventOwnerStartCancelled
			|| _LLM_NavEventOwnerStartRollbackPending)
		AssertEqual(0, _LLM_NavEventOwnerActiveStartTicket)
	} finally _LNEO_Teardown()
}
Test("terminal-lifecycle-admission: Starting cancellation survives an active nested refresh",
	_LNTR_WithState.Bind(_LNTR_LifecycleStartingRefreshCancellation))

; Observer withdrawal must refuse dispatch before invoking a replaced callable.
; Controlled ports exercise admission and cleanup, without genuine DLL authority.
_LNTR_V3_RestoreCall(Target, Had, Saved) {
	if Had
		Object.Prototype.DefineProp.Call(Target, "Call", Saved)
	else if Object.Prototype.HasOwnProp.Call(Target, "Call")
		Object.Prototype.DeleteProp.Call(Target, "Call")
}

_LNTR_V3_AfterSourceCallableWithdrawal(Target) {
	_LNTR_WithState(Body)
	Body() {
		global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerTerminalRouteRefreshing
		global _LLM_NavEventOwnerRuntimeEpoch
		Native := _LNEO_Setup(), State := _LNTR_PortState(), ForeignCalls := 0
		Had := Object.Prototype.HasOwnProp.Call(Target, "Call")
		Saved := Had ? Object.Prototype.GetOwnPropDesc.Call(Target, "Call") : 0
		try {
			Epoch := _LLM_NavEventOwnerRuntimeEpoch
			State.Port["terminal_route_source"] := Source
			AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
			AssertEqual(0, ForeignCalls, "withdrawn helper facade cannot run after the source observer")
			AssertEqual(0, State.Calls.Length, "refusal precedes registration")
			AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map, "original retention bypasses the foreign facade")
			AssertFalse(_LLM_NavEventOwnerTerminalRouteRefreshing)
			AssertEqual(Epoch, _LLM_NavEventOwnerRuntimeEpoch)
		} finally {
			_LNTR_V3_RestoreCall(Target, Had, Saved)
			_LNEO_Teardown()
		}
		Source() {
			Value := _LNTR_Source(State)
			Object.Prototype.DefineProp.Call(Target, "Call", {Call: (*) => (ForeignCalls += 1, false)})
			return Value
		}
	}
}
for Target in [_LLM_NavEventOwnerPortFn, _LLM_NavEventOwnerTerminalRegistrationCurrent,
	_LLM_NavEventOwnerTerminalRegistrationRequire, _LLM_NavEventOwnerTerminalRegistrationRetain,
	_LLM_NavEventOwnerTerminalRegistrationUnknown]
	Test("native-retirement-owner: post-source facade refusal " . Target.Name,
		_LNTR_V3_AfterSourceCallableWithdrawal.Bind(Target))

_LNTR_V3_StopAckGetterThrows() {
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerStarted
	Native := _LNEO_Setup(), Calls := 0, SavedStopping := _LLM_NavEventOwnerStopping
	try {
		Epoch := _LLM_NavEventOwnerRuntimeEpoch
		Native.Port["stop"] := Stop
		AssertFalse(LLM_NavEventOwner_Stop(), "ACK observer failure is diagnostic refusal, not an escaping exception")
		AssertEqual(1, Calls)
		AssertFalse(_LLM_NavEventOwnerStopping, "only the current stop latch must be released")
		AssertTrue(_LLM_NavEventOwnerStarted && Native.Started)
		AssertEqual(Epoch, _LLM_NavEventOwnerRuntimeEpoch)
	} finally {
		; Owned fake fixture cleanup, including the deliberately broken original branch.
		_LLM_NavEventOwnerStopping := SavedStopping
		Native.Port["stop"] := _LNEO_PortStop.Bind(Native)
		_LNEO_Teardown()
	}
	Stop() {
		Calls += 1
		Value := Map()
		Value.DefineProp("Get", {Call: (*) => ThrowAck()})
		return Value
	}
	ThrowAck() {
		throw Error("owned ACK getter failure")
	}
}
Test("native-retirement-owner: throwing custom ACK observer releases only Stop latch", _LNTR_V3_StopAckGetterThrows)

_LNTR_V3_BeforeConstructorFacade(Target) {
	_LNTR_WithState(Body)
	Body() {
		global _LLM_NavEventOwnerTerminalRouteRefreshing
		Native := _LNEO_Setup(), State := _LNTR_PortState(), ForeignCalls := 0, PrivilegedCalls := 0
		Had := Object.Prototype.HasOwnProp.Call(Target, "Call")
		Saved := Had ? Object.Prototype.GetOwnPropDesc.Call(Target, "Call") : 0
		try {
			Object.Prototype.DefineProp.Call(Target, "Call", {Call: Facade})
			AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
			AssertEqual(0, ForeignCalls, "constructor/capture facade must be refused before invocation")
			AssertEqual(0, PrivilegedCalls, "an arbitrary Map cannot grant settle or native authority")
			AssertEqual(0, State.Calls.Length, "callable refusal precedes registration")
			AssertFalse(_LLM_NavEventOwnerTerminalRouteRefreshing)
		} finally {
			_LNTR_V3_RestoreCall(Target, Had, Saved)
			_LNEO_Teardown()
		}
		Facade(*) {
			ForeignCalls += 1
			return Map("frame", Map(), "guard", (*) => true,
				"native", Privileged, "settle", Privileged, "close", (*) => true)
		}
		Privileged(*) {
			PrivilegedCalls += 1
			return true
		}
	}
}
for Target in [_LLM_NavEventOwnerNativeEnsureLoaded, _LLM_NavEventOwnerTerminalRegistrationCapture]
	Test("native-retirement-owner: pre-constructor facade refusal " . Target.Name,
		_LNTR_V3_BeforeConstructorFacade.Bind(Target))

_LNTR_V3_SourceCannotReissue() {
	_LNTR_WithState(Body)
	Body() {
		global _LLM_NavEventOwnerTerminalRouteRefreshing
		Native := _LNEO_Setup(), State := _LNTR_PortState(), SourceCalls := 0, Refusals := 0
		try {
			State.Port["terminal_route_source"] := Source
			AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port))
			AssertEqual(1, SourceCalls)
			AssertEqual(3, Refusals, "no supplied or duplicate constructor may replace the first scope")
			AssertEqual(1, State.Calls.Length, "only the original custom registration is dispatched")
			AssertFalse(_LLM_NavEventOwnerTerminalRouteRefreshing)
		} finally _LNEO_Teardown()
		Source() {
			SourceCalls += 1
			for Action in [Supplied, Duplicate, StopDuringRefresh] {
				try Action.Call()
				catch {
					Refusals += 1
					continue
				}
				throw Error("A source callback reissued private authority.")
			}
			return _LNTR_Source(State)
		}
		Supplied() {
			return _LLM_NavEventOwnerNativeEnsureLoaded.Call("begin_frame", Map())
		}
		Duplicate() {
			return _LLM_NavEventOwnerNativeEnsureLoaded.Call("begin_frame")
		}
		StopDuringRefresh() {
			return _LLM_NavEventOwnerNativeEnsureLoaded.Call("begin_stop", 0)
		}
	}
}
Test("native-retirement-owner: source cannot replace its first issued scope", _LNTR_V3_SourceCannotReissue)

_LNTR_V3_AfterRegistrationFacade(Target, Boundary) {
	_LNTR_WithState(Body)
	Body() {
		global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerTerminalRouteRefreshing
		Native := _LNEO_Setup(), State := _LNTR_PortState(), ForeignCalls := 0, ObserverCalls := 0
		Had := Object.Prototype.HasOwnProp.Call(Target, "Call")
		Saved := Had ? Object.Prototype.GetOwnPropDesc.Call(Target, "Call") : 0
		try {
			if Boundary == "register"
				State.Port["register_terminal_routes"] := Register
			else
				State.Port["list_terminal_held_recipes"] := Held
			AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(State.Port))
			AssertEqual(1, ObserverCalls)
			AssertEqual(0, ForeignCalls, "post-observer foreign helper cannot execute even in catch")
			AssertEqual(1, State.Calls.Length)
			AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map)
			AssertFalse(_LLM_NavEventOwnerTerminalRouteRefreshing)
		} finally {
			_LNTR_V3_RestoreCall(Target, Had, Saved)
			_LNEO_Teardown()
		}
		Withdraw() {
			ObserverCalls += 1
			Object.Prototype.DefineProp.Call(Target, "Call", {Call: (*) => (ForeignCalls += 1, false)})
		}
		Register(Owner, Generation, Layout, Bindings, Count) {
			Result := _LNTR_Register(State, Owner, Generation, Layout, Bindings, Count)
			Withdraw()
			return Result
		}
		Held(Owner, Ids, Capacity) {
			Result := _LNTR_Held(State, Owner, Ids, Capacity)
			Withdraw()
			return Result
		}
	}
}
for Boundary in ["register", "held"]
	for Target in [_LLM_NavEventOwnerPortFn, _LLM_NavEventOwnerTerminalRegistrationCurrent,
		_LLM_NavEventOwnerTerminalRegistrationRequire, _LLM_NavEventOwnerTerminalRegistrationRetain,
		_LLM_NavEventOwnerTerminalRegistrationUnknown]
		Test("native-retirement-owner: post-" . Boundary . " facade refusal " . Target.Name,
			_LNTR_V3_AfterRegistrationFacade.Bind(Target, Boundary))

; Genuine registration custody is received in distinct no-hook processes.
; Private issuance stays outside the parent controlled-port fixtures.
_LNTR_GenuineChildCase() {
	global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerTerminalRouteRecipes
	global _LLM_NavEventOwnerTerminalRouteModels, _LLM_NavEventOwnerTerminalRouteCoverage
	global _LLM_NavEventOwnerTerminalRouteGeneration, _LLM_NavEventOwnerTerminalRouteNextRecipe
	global _LLM_NavEventOwnerTerminalRouteNextLayout, _LLM_NavEventOwnerRuntimeEpoch
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerTerminalRouteOwner
	State := {Caps: 0, HeldCalls: 0}, ForeignRecipes := 0
	; Prove the graph's actual initial state; never reset private or public owners.
	AssertFalse(_LLM_NavEventOwnerStarted || _LLM_NavEventOwnerStarting)
	AssertEqual(0, _LLM_NavEventOwnerModule)
	AssertEqual(0, _LLM_NavEventOwnerPort)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteGeneration)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteNextRecipe)
	AssertEqual(1, _LLM_NavEventOwnerTerminalRouteNextLayout)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteRecipes.Count)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteModels.Count)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown)
	_LNTR_LoadFixture("a")
	AssertTrue(_LLM_NavEventOwnerNativeEnsureLoaded())
	Module := _LLM_NavEventOwnerModule, Exports := _LLM_NavEventOwnerExports
	AssertTrue(Module is Integer && Module > 0)
	AssertTrue(Exports["ErgoptiNav_RegisterTerminalRoutes"] is Integer)
	AssertTrue(Exports["ErgoptiNav_Stop"] is Integer)
	Probe := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(
		_LLM_NavEventOwnerTerminalRouteOwner, Buffer(512, 0), 64)
	AssertEqual(8, Probe["status"], "fresh real C has no terminal route owner before Register")
	Port := Map("terminal_route_source", (*) => _LNTR_Source(State), "list_terminal_held_recipes", Held)
	AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(Port))
	AssertEqual(1, State.HeldCalls)
	Frame := _LLM_NavEventOwnerTerminalRouteUnknown
	AssertTrue(Frame is Map)
	OriginalRecipes := Frame["recipes"], OriginalModels := Frame["models"]
	OriginalRecipe := 0, OriginalModel := 0, GenuineAdmissions := 0
	for Id, Admission in Frame["recipe_refs"] {
		AssertTrue(Id is Integer && Id > 0, "retained admissions have actual positive recipe identities")
		if !(Admission is Map)
			continue
		Recipe := Admission.Get("recipe", 0)
		if !(Recipe is Map) || Recipe.Count == 0 || !IsObject(Recipe.Get("model", 0))
			continue
		GenuineAdmissions += 1
		if !IsObject(OriginalRecipe)
			OriginalRecipe := Admission, OriginalModel := Recipe["model"]
	}
	AssertTrue(GenuineAdmissions > 0 && OriginalRecipe is Map && IsObject(OriginalModel),
		"capture an actual nonempty KLE admission instead of assuming a recipe index")
	AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == ForeignRecipes)
	ForeignImage := ForeignRecipes.Clone(), OriginalImage := OriginalRecipes.Clone()
	ModelImage := OriginalModels.Clone()
	AdmissionFields := Map(), RouteFields := Map(), RecipeFields := Map(), RecipeModels := Map()
	for Id, Admission in OriginalImage {
		AssertTrue(Admission is Map)
		AdmissionFields[Id] := Admission.Clone()
		RouteFields[Id] := Admission["route"].Clone()
		Recipe := Admission["recipe"]
		RecipeFields[Id] := Recipe is Map ? Recipe.Clone() : 0
		RecipeModels[Id] := Recipe is Map ? Recipe.Get("model", 0) : 0
	}
	ModelFields := Map()
	for Id, Identity in ModelImage
		ModelFields[Id] := Identity.Clone()
	Generation := _LLM_NavEventOwnerTerminalRouteGeneration
	NextRecipe := _LLM_NavEventOwnerTerminalRouteNextRecipe
	NextLayout := _LLM_NavEventOwnerTerminalRouteNextLayout
	Epoch := _LLM_NavEventOwnerRuntimeEpoch
	AssertTrue(LLM_NavEventOwner_Stop(), "the real default same-module Stop must complete")
	; This is the intended baseline red, after real registration/query/Stop.
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown, "genuine retirement must release the exact Unknown")
	AssertTrue(_LLM_NavEventOwnerModule == Module && _LLM_NavEventOwnerExports == Exports)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == ForeignRecipes)
	AssertEqual(ForeignImage.Count, ForeignRecipes.Count)
	for Id, Value in ForeignImage
		AssertTrue(ForeignRecipes[Id] == Value, "foreign dictionary cells survive teardown")
	AssertEqual(OriginalImage.Count, OriginalRecipes.Count)
	for Id, Value in OriginalImage
		AssertTrue(OriginalRecipes[Id] == Value, "original holders are detached, never cleared")
	for Id, Admission in OriginalImage {
		_LNTR_GenuineAssertMapImage(Admission, AdmissionFields[Id], "all original admission fields survive")
		_LNTR_GenuineAssertMapImage(Admission["route"], RouteFields[Id], "all original route fields survive")
		if RecipeFields[Id] is Map {
			_LNTR_GenuineAssertMapImage(Admission["recipe"], RecipeFields[Id], "all original KLE recipe fields survive")
			AssertTrue(Admission["recipe"].Get("model", 0) == RecipeModels[Id], "every KLE model reference survives")
		}
	}
	AssertEqual(ModelImage.Count, OriginalModels.Count)
	for Id, Value in ModelImage
		AssertTrue(OriginalModels[Id] == Value, "original model identity cells survive teardown")
	for Id, Identity in ModelImage
		_LNTR_GenuineAssertMapImage(Identity, ModelFields[Id], "all original model identity fields survive")
	AssertTrue(OriginalRecipe["recipe"]["model"] == OriginalModel)
	AssertFalse(_LLM_NavEventOwnerTerminalRouteModels == OriginalModels)
	AssertEqual(Generation, _LLM_NavEventOwnerTerminalRouteGeneration)
	AssertEqual(NextRecipe, _LLM_NavEventOwnerTerminalRouteNextRecipe)
	AssertEqual(NextLayout, _LLM_NavEventOwnerTerminalRouteNextLayout)
	AssertEqual(Epoch + 1, _LLM_NavEventOwnerRuntimeEpoch)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteCoverage["registered"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["cohort_complete"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["transformed_output_enabled"])
	AssertFalse(_LLM_NavEventOwnerStarted || _LLM_NavEventOwnerStarting
		|| _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending)
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(Map("terminal_route_source", (*) => _LNTR_Source(State))))
	AssertTrue(_LLM_NavEventOwnerTerminalRouteGeneration > Generation)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteNextRecipe > NextRecipe)
	AssertTrue(LLM_NavEventOwner_Stop())
	AssertFalse(_LLM_NavEventOwnerStarted || _LLM_NavEventOwnerStarting)
	Held(Owner, BufferArg, Capacity) {
		State.HeldCalls += 1
		Reply := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, BufferArg, Capacity)
		AssertEqual(0, Reply["status"], "actual C accepted the current default registration owner")
		AssertEqual(0, Reply["count"], "no capture/hook/held debt was activated")
		ForeignRecipes := _LLM_NavEventOwnerTerminalRouteRecipes.Clone()
		_LLM_NavEventOwnerTerminalRouteRecipes := ForeignRecipes
		throw Error("owned holder withdrawal after actual C registration/query0")
	}
}
_LNTR_GenuineAssertMapImage(Actual, Image, Message) {
	AssertTrue(Actual is Map && Image is Map, Message)
	AssertEqual(Image.Count, Actual.Count, Message)
	for Name, Value in Image {
		AssertTrue(Actual.Has(Name), Message)
		AssertEqual(Type(Value), Type(Actual[Name]), Message)
		AssertTrue(Actual[Name] == Value, Message)
	}
}

_LNTR_GenuineNegativeSetup() {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteUnknown
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	global _LLM_NavEventOwnerTerminalRouteGeneration, _LLM_NavEventOwnerTerminalRouteNextRecipe
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerWakeFn, _LLM_NavEventOwnerServiceFn
	global _LLM_NavEventOwnerServiceArmed, _LLM_NavEventOwnerRecords, KLE_Model
	AssertEqual(0, _LLM_NavEventOwnerModule)
	AssertEqual(0, _LLM_NavEventOwnerPort)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteGeneration)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteNextRecipe)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown)
	AssertFalse(_LLM_NavEventOwnerStarted || _LLM_NavEventOwnerStarting)
	State := {Caps: 0, SourceCalls: 0, HeldCalls: 0}, ForeignRecipes := 0
	_LNTR_LoadFixture("a")
	AssertTrue(_LLM_NavEventOwnerNativeEnsureLoaded())
	AssertTrue(_LLM_NavEventOwnerModule is Integer && _LLM_NavEventOwnerModule > 0)
	AssertEqual(8, _LLM_NavEventOwnerNativeListTerminalHeldRecipes(
		_LLM_NavEventOwnerTerminalRouteOwner, Buffer(512, 0), 64)["status"])
	Port := Map("terminal_route_source", Source, "list_terminal_held_recipes", Held)
	AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(Port))
	AssertEqual(1, State.SourceCalls)
	AssertEqual(1, State.HeldCalls)
	Frame := _LLM_NavEventOwnerTerminalRouteUnknown
	AssertTrue(Frame is Map && Frame["candidate"] is Map && Frame["candidate"]["routes"].Length > 0)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == ForeignRecipes)
	ModelsFound := 0
	for Id, Admission in Frame["recipe_refs"] {
		AssertTrue(Id is Integer && Id > 0)
		if Admission["recipe"] is Map && IsObject(Admission["recipe"].Get("model", 0)) {
			AssertTrue(Admission["recipe"]["model"] == KLE_Model)
			ModelsFound += 1
		}
	}
	AssertTrue(ModelsFound > 0, "genuine source owns actual KLE model references")
	return {Frame: Frame, Module: _LLM_NavEventOwnerModule, Exports: _LLM_NavEventOwnerExports,
		Epoch: _LLM_NavEventOwnerRuntimeEpoch, NextRecipe: _LLM_NavEventOwnerTerminalRouteNextRecipe,
		Recipes: _LLM_NavEventOwnerTerminalRouteRecipes, Models: _LLM_NavEventOwnerTerminalRouteModels,
		Wake: _LLM_NavEventOwnerWakeFn, Service: _LLM_NavEventOwnerServiceFn,
		Armed: _LLM_NavEventOwnerServiceArmed, Records: _LLM_NavEventOwnerRecords}
	Source() {
		State.SourceCalls += 1
		Value := _LNTR_Source(State)
		AssertTrue(Value is Map && ObjGetBase(Value) == Map.Prototype && Value["model"] == KLE_Model)
		for Name in ObjOwnProps(Value)
			throw Error("A source facade cannot establish genuine provenance.")
		return Value
	}
	Held(Owner, BufferArg, Capacity) {
		State.HeldCalls += 1
		Reply := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, BufferArg, Capacity)
		AssertEqual(0, Reply["status"], "actual C query confirms the default registration owner")
		AssertEqual(0, Reply["count"])
		ForeignRecipes := _LLM_NavEventOwnerTerminalRouteRecipes.Clone()
		_LLM_NavEventOwnerTerminalRouteRecipes := ForeignRecipes
		throw Error("owned genuine retained Frame after holder withdrawal")
	}
}

_LNTR_GenuineNegativeNoTeardown(Context, AttemptPort, ExpectedEpoch, ExpectedNext, ExpectedUnknown) {
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerTerminalRouteNextRecipe
	global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerTerminalRouteRecipes
	global _LLM_NavEventOwnerTerminalRouteModels, _LLM_NavEventOwnerWakeFn, _LLM_NavEventOwnerServiceFn
	global _LLM_NavEventOwnerServiceArmed, _LLM_NavEventOwnerRecords, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	AssertEqual(ExpectedEpoch, _LLM_NavEventOwnerRuntimeEpoch, "refusal preserves its current runtime lifetime")
	AssertEqual(ExpectedNext, _LLM_NavEventOwnerTerminalRouteNextRecipe)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown == ExpectedUnknown)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == Context.Recipes)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteModels == Context.Models)
	AssertTrue(_LLM_NavEventOwnerWakeFn == Context.Wake && _LLM_NavEventOwnerServiceFn == Context.Service)
	AssertEqual(Context.Armed, _LLM_NavEventOwnerServiceArmed)
	AssertTrue(_LLM_NavEventOwnerRecords == Context.Records && _LLM_NavEventOwnerPort == AttemptPort)
	AssertFalse(_LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending)
}

; Private no-hook receiving: absence of the public frame is never a stop ACK.
_LNTR_GenuineMissingPublicationCase() {
	global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerTerminalRouteModels, _LLM_NavEventOwnerTerminalRouteRecipes
	global _LLM_NavEventOwnerTerminalRouteCoverage, _LLM_NavEventOwnerRuntimeEpoch
	Context := _LNTR_GenuineNegativeSetup()
	OriginalRecipes := Context.Frame["recipes"], OriginalModels := Context.Frame["models"]
	RecipeImage := OriginalRecipes.Clone(), ModelImage := OriginalModels.Clone()
	ForeignImage := Context.Recipes.Clone()
	FakeCalls := 0, Primary := 0, CleanupError := 0
	Port := Map("stop", FakeStop)
	try {
		_LLM_NavEventOwnerTerminalRouteUnknown := 0
		_LLM_NavEventOwnerPort := Port
		AssertFalse(LLM_NavEventOwner_Stop(), "missing publication still requires a genuine native stop")
		AssertEqual(1, FakeCalls, "the custom protocol runs but cannot discharge private native debt")
		_LNTR_GenuineNegativeNoTeardown(Context, Port, Context.Epoch, Context.NextRecipe, 0)
	} catch as Err {
		Primary := Err
	} finally {
		_LLM_NavEventOwnerPort := 0
		try {
			if !IsObject(Primary)
				AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown, "cleanup must not reconstruct public authority")
			AssertTrue(LLM_NavEventOwner_Stop(), "the actual default same-module stop retires private custody")
		} catch as Err {
			CleanupError := Err
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
	AssertEqual(Context.Epoch + 1, _LLM_NavEventOwnerRuntimeEpoch)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown)
	AssertFalse(_LLM_NavEventOwnerTerminalRouteModels == OriginalModels, "real stop detaches the original model holder")
	AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == Context.Recipes, "foreign recipe holder remains current")
	_LNTR_GenuineAssertMapImage(OriginalRecipes, RecipeImage, "original recipe cells remain untouched")
	_LNTR_GenuineAssertMapImage(OriginalModels, ModelImage, "original model cells remain untouched")
	_LNTR_GenuineAssertMapImage(Context.Recipes, ForeignImage, "foreign recipe cells remain untouched")
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteCoverage["registered"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["cohort_complete"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["transformed_output_enabled"])
	FakeStop() {
		FakeCalls += 1
		return Map("stopped", true)
	}
}

; Genuine module custody before default registration; no hook or output.
_LNTR_GenuinePreRegistrationWithdrawalCase(Phase) {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteUnknown
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	global _LLM_NavEventOwnerTerminalRouteCoverage, _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteNextRecipe, _LLM_NavEventOwnerTerminalRouteNextLayout
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerTerminalRouteRefreshing
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerStarting, KLE_Model
	AssertTrue(Phase == "source-get" || Phase == "source" || Phase == "builder"
		|| Phase == "builder-capture" || Phase == "builder-recipe")
	AssertEqual(0, _LLM_NavEventOwnerModule)
	AssertEqual(0, _LLM_NavEventOwnerPort)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteGeneration)
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown)
	AssertFalse(_LLM_NavEventOwnerStarted || _LLM_NavEventOwnerStarting)
	OriginalRecipes := _LLM_NavEventOwnerTerminalRouteRecipes
	OriginalModels := _LLM_NavEventOwnerTerminalRouteModels
	Epoch := _LLM_NavEventOwnerRuntimeEpoch
	_LNTR_LoadFixture("a")
	AssertTrue(_LLM_NavEventOwnerNativeEnsureLoaded())
	Module := _LLM_NavEventOwnerModule, Exports := _LLM_NavEventOwnerExports
	AssertEqual(8, _LLM_NavEventOwnerNativeListTerminalHeldRecipes(
		_LLM_NavEventOwnerTerminalRouteOwner, Buffer(512, 0), 64)["status"])
	State := {Caps: 0}, SourceCalls := 0, BuilderCalls := 0, LookupCalls := 0
	CaptureCalls := 0, RecipeCalls := 0, ForeignRecipes := 0
	ActualCapture := KeylayoutEmulation_CaptureReplayRoute
	Port := Map("terminal_route_source", Source)
	if Phase == "source-get"
		Port.DefineProp("Get", {Call: SourceGet})
	Primary := 0, CleanupError := 0, Stopped := false
	try {
		AssertThrows(LLM_NavEventOwner_RefreshTerminalRoutes.Bind(Port))
		AssertEqual(Phase == "source-get" ? 1 : 0, LookupCalls)
		AssertEqual(Phase == "source-get" ? 0 : 1, SourceCalls)
		AssertEqual(InStr(Phase, "builder") == 1 ? 1 : 0, BuilderCalls)
		AssertEqual(Phase == "builder-capture" || Phase == "builder-recipe" ? 1 : 0, CaptureCalls)
		AssertEqual(Phase == "builder-recipe" ? 1 : 0, RecipeCalls)
		Frame := _LLM_NavEventOwnerTerminalRouteUnknown
		AssertTrue(Frame is Map, "the original source/build frame remains retained")
		AssertFalse(Frame["native_attempted"], "no default registration boundary was entered")
		AssertTrue(Frame["recipes"] == OriginalRecipes && Frame["models"] == OriginalModels)
		AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == ForeignRecipes)
		AssertFalse(_LLM_NavEventOwnerTerminalRouteRefreshing)
		AssertEqual(Epoch, _LLM_NavEventOwnerRuntimeEpoch)
		AssertEqual(8, _LLM_NavEventOwnerNativeListTerminalHeldRecipes(
			_LLM_NavEventOwnerTerminalRouteOwner, Buffer(512, 0), 64)["status"],
			"real C still has no registration owner after the source/build refusal")
		RecipeImage := OriginalRecipes.Clone(), ModelImage := OriginalModels.Clone()
		ForeignImage := ForeignRecipes.Clone(), ModelFields := Map()
		for Id, Identity in OriginalModels
			ModelFields[Id] := Identity.Clone()
		Generation := _LLM_NavEventOwnerTerminalRouteGeneration
		NextRecipe := _LLM_NavEventOwnerTerminalRouteNextRecipe
		NextLayout := _LLM_NavEventOwnerTerminalRouteNextLayout
	} catch as Err {
		Primary := Err
	} finally {
		try Stopped := LLM_NavEventOwner_Stop()
		catch as Err {
			CleanupError := Err
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
	AssertTrue(Stopped, "actual default Stop acknowledges the child-owned cleanup")
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown,
		"pre-registration cleanup must release retained publication")
	AssertEqual(Epoch + 1, _LLM_NavEventOwnerRuntimeEpoch)
	AssertEqual(Generation, _LLM_NavEventOwnerTerminalRouteGeneration)
	AssertEqual(NextRecipe, _LLM_NavEventOwnerTerminalRouteNextRecipe)
	AssertEqual(NextLayout, _LLM_NavEventOwnerTerminalRouteNextLayout)
	AssertTrue(_LLM_NavEventOwnerModule == Module && _LLM_NavEventOwnerExports == Exports)
	AssertTrue(_LLM_NavEventOwnerTerminalRouteRecipes == ForeignRecipes)
	AssertFalse(_LLM_NavEventOwnerTerminalRouteModels == OriginalModels)
	_LNTR_GenuineAssertMapImage(OriginalRecipes, RecipeImage, "original recipe holder cells survive")
	_LNTR_GenuineAssertMapImage(OriginalModels, ModelImage, "original model holder cells survive")
	_LNTR_GenuineAssertMapImage(ForeignRecipes, ForeignImage, "foreign recipe holder cells survive")
	for Id, Identity in OriginalModels
		_LNTR_GenuineAssertMapImage(Identity, ModelFields[Id], "partial builder model fields survive")
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteCoverage["registered"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["cohort_complete"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["transformed_output_enabled"])
	AssertFalse(_LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending)
	Source() {
		SourceCalls += 1
		Value := _LNTR_Source(State)
		if Phase == "source"
			Withdraw()
		Value["eligible"] := Eligible
		if Phase == "builder-capture" || Phase == "builder-recipe"
			Value["capture"] := Capture
		return Value
	}
	SourceGet(*) {
		LookupCalls += 1
		Withdraw()
	}
	Eligible(*) {
		BuilderCalls += 1
		if Phase == "builder"
			Withdraw()
		return true
	}
	Capture(Args*) {
		CaptureCalls += 1
		Value := ActualCapture.Call(Args*)
		AssertTrue(Value is Map && Value.Get("model", 0) == KLE_Model,
			"the original production capture issues the actual KLE recipe")
		if Phase == "builder-capture"
			Withdraw()
		Value.DefineProp("__Item", {Get: RecipeGet})
		return Value
	}
	RecipeGet(*) {
		RecipeCalls += 1
		Withdraw()
	}
	Withdraw() {
		ForeignRecipes := _LLM_NavEventOwnerTerminalRouteRecipes.Clone()
		_LLM_NavEventOwnerTerminalRouteRecipes := ForeignRecipes
		throw Error("owned " . Phase . " withdrawal before any default C registration")
	}
}

_LNTR_GenuineNegativeCase(CaseName) {
	if SubStr(CaseName, 1, 7) == "prereg-"
		return _LNTR_GenuinePreRegistrationWithdrawalCase(SubStr(CaseName, 8))
	if CaseName == "missing-publication"
		return _LNTR_GenuineMissingPublicationCase()
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerTerminalRouteNextRecipe
	global _LLM_NavEventOwnerTerminalRouteUnknown, _LLM_NavEventOwnerTerminalRouteCoverage
	Context := _LNTR_GenuineNegativeSetup()
	SavedPointer := Context.Exports["ErgoptiNav_Stop"], CallbackPointer := 0
	Foreign := Map("marker", "foreign Unknown", "model", Context.Frame["models"]), ForeignImage := Foreign.Clone()
	FakeCalls := 0, GetterCalls := 0, ReportCalls := 0, Primary := 0, CleanupFailure := 0
	HadLoggerCall := Object.Prototype.HasOwnProp.Call(LoggerError, "Call")
	SavedLoggerCall := HadLoggerCall ? Object.Prototype.GetOwnPropDesc.Call(LoggerError, "Call") : 0
	AttemptPort := 0, ExpectedEpoch := Context.Epoch, ExpectedNext := Context.NextRecipe
	ExpectedUnknown := Context.Frame
	try {
		switch CaseName {
			case "custom-true":
				AttemptPort := Map("stop", FakeTrue), _LLM_NavEventOwnerPort := AttemptPort
			case "custom-map":
				AttemptPort := Map("stop", FakeMap), _LLM_NavEventOwnerPort := AttemptPort
			case "module-zero", "module-load":
				_LLM_NavEventOwnerModule := 0
			case "exports-clone":
				_LLM_NavEventOwnerExports := Context.Exports.Clone()
			case "exports-pointer":
				CallbackPointer := CallbackCreate(FakePointer, "F", 0)
				Context.Exports["ErgoptiNav_Stop"] := CallbackPointer
			case "exports-facade":
				Object.Prototype.DefineProp.Call(Context.Exports, "Has", {Call: HasFacade})
			case "epoch":
				ExpectedEpoch := Context.Epoch + 1, _LLM_NavEventOwnerRuntimeEpoch := ExpectedEpoch
			case "lower-counter":
				ExpectedNext := Context.NextRecipe - 1, _LLM_NavEventOwnerTerminalRouteNextRecipe := ExpectedNext
			case "unknown-before-get":
				ExpectedUnknown := Foreign, _LLM_NavEventOwnerTerminalRouteUnknown := Foreign
			case "unknown-report":
				Object.Prototype.DefineProp.Call(LoggerError, "Call", {Call: ReportObserver})
				AttemptPort := Map()
				Object.Prototype.DefineProp.Call(AttemptPort, "Get", {Call: ReportFromGet})
				_LLM_NavEventOwnerPort := AttemptPort, ExpectedUnknown := Foreign
			default:
				throw Error("Unknown genuine fault selector.")
		}
		if CaseName == "module-load" {
			AssertThrows(AttemptLoad,
				"resident loader withdrawal must refuse")
			AssertEqual(0, _LLM_NavEventOwnerModule, "ordinary load must not rearm a withdrawn real issuance")
		} else {
			AssertFalse(LLM_NavEventOwner_Stop(), CaseName . ": retained genuine debt must refuse this authority")
			if CaseName == "module-zero" {
				AssertThrows(AttemptLoad,
					"resident loader withdrawal must refuse")
				AssertEqual(0, _LLM_NavEventOwnerModule)
			}
		}
		if CaseName == "custom-true" || CaseName == "custom-map"
			AssertEqual(1, FakeCalls)
		else
			AssertEqual(0, FakeCalls, "foreign pointer/Has facade must never execute")
		if CaseName == "unknown-report"
			AssertEqual(1, GetterCalls), AssertEqual(1, ReportCalls)
		_LNTR_GenuineNegativeNoTeardown(Context, AttemptPort, ExpectedEpoch, ExpectedNext, ExpectedUnknown)
		if ExpectedUnknown == Foreign {
			AssertEqual(ForeignImage.Count, Foreign.Count)
			for Key, Value in ForeignImage
				AssertTrue(Foreign[Key] == Value, "foreign Unknown fields survive refusal")
		}
	} catch as Err {
		Primary := Err
	} finally {
		; Restore only the explicit child-owned fault; no private static reset/API.
		_LLM_NavEventOwnerModule := Context.Module
		_LLM_NavEventOwnerExports := Context.Exports
		Context.Exports["ErgoptiNav_Stop"] := SavedPointer
		if Object.Prototype.HasOwnProp.Call(Context.Exports, "Has")
			Object.Prototype.DeleteProp.Call(Context.Exports, "Has")
		if HadLoggerCall
			Object.Prototype.DefineProp.Call(LoggerError, "Call", SavedLoggerCall)
		else if Object.Prototype.HasOwnProp.Call(LoggerError, "Call")
			Object.Prototype.DeleteProp.Call(LoggerError, "Call")
		_LLM_NavEventOwnerPort := 0
		if CaseName == "epoch"
			_LLM_NavEventOwnerRuntimeEpoch := Context.Epoch
		if CaseName == "lower-counter"
			_LLM_NavEventOwnerTerminalRouteNextRecipe := Context.NextRecipe
		if CaseName == "unknown-before-get" || CaseName == "unknown-report"
			_LLM_NavEventOwnerTerminalRouteUnknown := Context.Frame
		try {
			if !IsObject(Primary)
				AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown == Context.Frame,
					"restoration alone is not a retirement receipt")
			AssertTrue(LLM_NavEventOwner_Stop(), "cleanup obtains its own actual same-module native Stop")
		} catch as Err {
			CleanupFailure := Err
		}
		if CallbackPointer
			CallbackFree(CallbackPointer)
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown, "only actual cleanup Stop retires the retained Frame")
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteCoverage["registered"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["cohort_complete"])
	AssertFalse(_LLM_NavEventOwnerTerminalRouteCoverage["transformed_output_enabled"])
	FakeTrue() {
		FakeCalls += 1
		return 1
	}
	FakeMap() {
		FakeCalls += 1
		return Map("stopped", true)
	}
	FakePointer() {
		FakeCalls += 1
		return 0
	}
	HasFacade(*) {
		FakeCalls += 1
		return true
	}
	ReportObserver(*) {
		ReportCalls += 1
		_LLM_NavEventOwnerTerminalRouteUnknown := Foreign
	}
	ReportFromGet(*) {
		GetterCalls += 1
		try Func.Prototype.Call.Call(_LLM_NavEventOwnerReportNow, "owned pre-Stop report observer")
		finally {
			; The owned observer is one-shot; refusal diagnostics use normal logging.
			if HadLoggerCall
				Object.Prototype.DefineProp.Call(LoggerError, "Call", SavedLoggerCall)
			else if Object.Prototype.HasOwnProp.Call(LoggerError, "Call")
				Object.Prototype.DeleteProp.Call(LoggerError, "Call")
		}
		return 0
	}
	AttemptLoad() {
		return _LLM_NavEventOwnerNativeEnsureLoaded.Call()
	}
}

_LNTR_ReceiveActualChild(CaseName := "positive") {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _LLM_NavEventOwnerRuntimeEpoch
	global _LLM_NavEventOwnerTerminalRouteUnknown
	ParentModule := _LLM_NavEventOwnerModule, ParentExports := _LLM_NavEventOwnerExports
	ParentEpoch := _LLM_NavEventOwnerRuntimeEpoch, ParentUnknown := _LLM_NavEventOwnerTerminalRouteUnknown
	Kind := CaseName == "positive" ? "positive" : CaseName == "exact-count" ? "exact-count" : "negative"
	SelectedName := Kind == "exact-count"
		? "native-route-exact-count-child: actual196 descriptors and native retirement"
		: Kind == "positive"
		? "native-retirement-genuine-child: actual registration and full-owner retirement"
		: "native-retirement-genuine-negative: " . CaseName
	TestsRoot := A_ScriptDir
	CanonicalPath := TestsRoot . "\run_all.ahk"
	Canonical := FileRead(CanonicalPath, "UTF-8")
	CanonicalInput := Canonical
	; Resolve the unique production owner afresh so a module move or duplicate
	; cannot turn the byte-preservation assertion into a cached source comparison.
	AdapterPath := _DriverProductionFileForSymbol("_LLM_NavEventOwnerNativeEnsureLoaded")
	AdapterInput := FileRead(AdapterPath, "UTF-8")
	; Preserve original framework and include graph, including A_ScriptDir data.
	if StrSplit(Canonical, "SetTimer(_WatchdogFire, -_SUITE_TIMEOUT_MS)").Length != 2
		throw Error("The canonical child watchdog preimage changed.")
	Canonical := StrReplace(Canonical, "SetTimer(_WatchdogFire, -_SUITE_TIMEOUT_MS)",
		"; Owned native child: no forced exit is a receiving receipt.")
	Id := DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount . "_" . Random(1, 0x7FFFFFFF)
	ChildName := ".ergopti_native_retirement_child_" . Id . ".ahk"
	ChildPath := TestsRoot . "\" . ChildName
	ReceiptRoot := A_Temp . "\ergopti_native_retirement_" . Id
	DirCreate(ReceiptRoot)
	TapPath := ReceiptRoot . "\child.tap", OutPath := ReceiptRoot . "\child.log", ErrPath := ReceiptRoot . "\child.err"
	SavedKind := EnvGet("ERGOPTI_NATIVE_RETIREMENT_CHILD_KIND")
	SavedCase := EnvGet("ERGOPTI_GENUINE_NEGATIVE_CASE")
	SavedReceipt := EnvGet("ERGOPTI_AHK_RESULTS_FILE")
	AssertFalse(FileExist(ChildPath), "never reuse or replace another task's runner")
	try {
		FileAppend(Canonical, ChildPath, "UTF-8")
		EnvSet("ERGOPTI_NATIVE_RETIREMENT_CHILD_KIND", Kind)
		EnvSet("ERGOPTI_GENUINE_NEGATIVE_CASE", CaseName)
		EnvSet("ERGOPTI_AHK_RESULTS_FILE", TapPath)
		; A hidden shell only redirects stdout/stderr and waits for the exact child.
		; It performs no filesystem deletion/move or sibling process control.
		Quote := Chr(34)
		ChildCommand := Quote . A_AhkPath . Quote . " /ErrorStdOut=UTF-8 " . Quote . ChildPath . Quote
			. " --only=" . Quote . SelectedName . Quote
			. " 1>" . Quote . OutPath . Quote . " 2>" . Quote . ErrPath . Quote
		Command := Quote . A_ComSpec . Quote . " /D /C " . Quote . ChildCommand . Quote
		Code := RunWait(Command, TestsRoot, "Hide")
		AssertEqual(0, Code, "the actual child must exit naturally without timeout or termination")
		AssertTrue(FileExist(TapPath) && FileExist(ErrPath))
		AssertEqual(0, FileGetSize(ErrPath), "startup/parse errors are refusals")
		Tap := FileRead(TapPath, "UTF-8")
		AssertTrue(RegExMatch(Tap, "m)^1\.\.1\r?$"))
		AssertEqual(1, _LNTR_ReceiptMatches(Tap, "m)^RUNNING 1/1 - "))
		AssertEqual(1, _LNTR_ReceiptMatches(Tap, "m)^ok 1 - "))
		AssertEqual(0, _LNTR_ReceiptMatches(Tap, "m)^not ok|# SKIP|FATAL STARTUP|WATCHDOG"))
		AssertTrue(InStr(Tap, "ok 1 - " . SelectedName . "`r`n")
			|| InStr(Tap, "ok 1 - " . SelectedName . "`n"))
		AssertTrue(RegExMatch(Tap, "m)^# 1 passed, 0 failed\.\r?$"))
	} finally {
		EnvSet("ERGOPTI_NATIVE_RETIREMENT_CHILD_KIND", SavedKind)
		EnvSet("ERGOPTI_GENUINE_NEGATIVE_CASE", SavedCase)
		EnvSet("ERGOPTI_AHK_RESULTS_FILE", SavedReceipt)
		; ChildPath is constructed from the actual testsRoot and one owned basename.
		SplitPath(ChildPath, &ActualName, &ActualDirectory)
		if ActualDirectory != TestsRoot || ActualName != ChildName
			throw Error("Refuse child cleanup outside the exact owned ephemeral runner.")
		if FileExist(ChildPath)
			FileDelete(ChildPath)
	}
	AssertEqual(ParentModule, _LLM_NavEventOwnerModule)
	AssertTrue(ParentExports == _LLM_NavEventOwnerExports)
	AssertEqual(ParentEpoch, _LLM_NavEventOwnerRuntimeEpoch)
	AssertTrue(ParentUnknown == _LLM_NavEventOwnerTerminalRouteUnknown)
	AssertEqual(CanonicalInput, FileRead(CanonicalPath, "UTF-8"), "canonical graph remains unchanged during receiving")
	AssertEqual(AdapterInput, FileRead(AdapterPath, "UTF-8"), "actual adapter remains unchanged during receiving")
}

_LNTR_ReceiptMatches(Text, Pattern) {
	Count := 0, Position := 1
	while Found := RegExMatch(Text, Pattern, &Match, Position) {
		Count += 1
		Position := Found + Max(1, Match.Len(0))
	}
	return Count
}

; This registration is owned by the existing included metadata file. Fresh child
; processes select only their child case; the parent never loads real native
; issuance into its fake-port fixtures and never resets resident private statics.
_LNTR_NativeRetirementChildKind := EnvGet("ERGOPTI_NATIVE_RETIREMENT_CHILD_KIND")
if _LNTR_NativeRetirementChildKind == "positive" {
	Test("native-retirement-genuine-child: actual registration and full-owner retirement", _LNTR_GenuineChildCase)
} else if _LNTR_NativeRetirementChildKind == "negative" {
	_LNTR_NativeRetirementChildCase := EnvGet("ERGOPTI_GENUINE_NEGATIVE_CASE")
	Test("native-retirement-genuine-negative: " . _LNTR_NativeRetirementChildCase,
		_LNTR_GenuineNegativeCase.Bind(_LNTR_NativeRetirementChildCase))
} else {
	Test("terminal-native-retirement: actual same-owner C Stop in a distinct child", _LNTR_ReceiveActualChild)
	for CaseName in ["custom-true", "custom-map", "module-zero", "module-load", "exports-clone",
		"exports-pointer", "exports-facade", "epoch", "lower-counter", "unknown-before-get", "unknown-report", "missing-publication",
		"prereg-source-get", "prereg-source", "prereg-builder", "prereg-builder-capture", "prereg-builder-recipe"]
		Test("terminal-native-retirement: authority refusal in distinct child " . CaseName,
			_LNTR_ReceiveActualChild.Bind(CaseName))
}

; Repeat the original failing adjacency in one process. Public globals alone
; cannot prove that the original issuer retired its private retained frame.
_LNTR_RefusalSuccessorCase() {
	_LNTR_WithState(_LNTR_RefusalCase)
	_LNTR_WithState(_LNTR_RetainedRecipeCase)
}

Test("terminal route metadata: acknowledged refusal cleanup admits the original successor (todo49-route-adapter)",
	_LNTR_RefusalSuccessorCase)

; The resident DLL lifetime survives the original no-hook ABI case. Its later
; controlled fixture must retire retained references through the real protocol.
_LNTR_ResidentAbiBeforeControlledRetirement() {
	_LNEO_RealNativeAbiRoundTripDoesNotStartHook()
	_LNEO_RealNativeAbiBareDigitValidation()
	Targets := [_LLM_NavEventOwnerPortFn, _LLM_NavEventOwnerTerminalRegistrationCurrent,
		_LLM_NavEventOwnerTerminalRegistrationRequire, _LLM_NavEventOwnerTerminalRegistrationRetain,
		_LLM_NavEventOwnerTerminalRegistrationUnknown]
	Received := 0
	for Target in Targets {
		_LNTR_V3_AfterSourceCallableWithdrawal(Target)
		Received += 1
	}
	for Boundary in ["register", "held"] {
		for Target in Targets {
			_LNTR_V3_AfterRegistrationFacade(Target, Boundary)
			Received += 1
		}
	}
	AssertEqual(15, Received, "every original source/register/held facade keeps its cleanup obligation")
}
Test("terminal route metadata: resident ABI precedes controlled retirement (terminal-resident-cleanup)",
	_LNTR_ResidentAbiBeforeControlledRetirement)

/** Creates literal independent forty-byte descriptor expectations above the old cap. */
_TRE_Routes() {
	Routes := []
	Loop 196 {
		Routes.Push(Map("recipe_id", A_Index, "route_id", A_Index,
			"required_prefixes", 0, "prefix_bit", 0,
			"required_dead_key_id", 0, "next_dead_key_id", 0,
			"code", A_Index, "target_vk", 0, "target_scan", 0,
			"axis", 2, "kind", 1, "required_modifiers", 0, "effective_modifiers_lr", 0))
	}
	return Routes
}

/** Checks all serialized bytes using the public literal wire layout, not its decoder. */
_TRE_Marshal() {
	Routes := _TRE_Routes()
	Bytes := _LLM_NavEventOwnerTerminalRouteMarshal(Routes)
	AssertEqual(7840, Bytes.Size, "all196 descriptors retain exactly forty bytes each")
	Loop 196 {
		Expected := Buffer(40, 0)
		NumPut("UInt64", A_Index, "UInt", A_Index, Expected, 0)
		NumPut("UShort", A_Index, Expected, 28)
		NumPut("UChar", 2, "UChar", 1, Expected, 34)
		Offset := (A_Index - 1) * 40
		Loop 40
			AssertEqual(NumGet(Expected, A_Index - 1, "UChar"),
				NumGet(Bytes, Offset + A_Index - 1, "UChar"),
				"the complete native wire image agrees with an independent literal descriptor")
	}
}

/** Receives the unchanged wrapper ABI through its existing controlled native boundary. */
_TRE_NativeBoundary() {
	Bytes := Buffer(7840, 0), Facts := {Calls: 0}
	AssertEqual(0, _LLM_NavEventOwnerNativeRegisterTerminalRoutes(17, 19, 23, Bytes, 196, Receive),
		"the actual wrapper forwards an exact-count registration above128")
	AssertEqual(1, Facts.Calls, "the controlled boundary is reached once")
	for Vector in [[Buffer(7839, 0), 196], [Buffer(7841, 0), 196],
		[Bytes, -1], [Bytes, "196"], [Bytes, 1.5], [Bytes, 0x100000000]] {
		Expected := Vector[2] is Integer && Vector[2] == 196
			? "The terminal route native registration ABI is invalid." : "The terminal route descriptor count is invalid."
		_TRE_ValueError(_LLM_NavEventOwnerNativeRegisterTerminalRoutes.Bind(17, 19, 23,
			Vector[1], Vector[2], Receive), Expected)
	}
	AssertEqual(1, Facts.Calls, "every invalid count/span is refused before the supplied boundary")

	Receive(Owner, Generation, LayoutId, Bindings, Count) {
		Facts.Calls += 1
		AssertTrue(Owner == 17 && Generation == 19 && LayoutId == 23,
			"the wrapper preserves exact owner and generation identities")
		AssertTrue(Bindings == Bytes && Count == 196,
			"the wrapper preserves the exact owned buffer and full count")
		return 0
	}
}

/** Controlled source data proves that the builder never silently truncates routes. */
_TRE_Build() {
	global KLE_KeyCodes
	KLE_KeyCodes := Map()
	Loop 100
		KLE_KeyCodes[Format("SC{:03X}", 0x60 + A_Index - 1)] := 0
	State := _LNTR_PortState()
	Source := _LNTR_Source(State)
	Candidate := _LLM_NavEventOwnerTerminalRouteBuild(Source, 1)
	AssertEqual(216, Candidate["routes"].Length,
		"one hundred controlled source keys retain both levels and all sixteen natural modifier identities")
	AssertEqual(216, Candidate["recipes"].Count, "the recipe inventory matches the complete descriptor count")
	AssertEqual(8640, _LLM_NavEventOwnerTerminalRouteMarshal(Candidate["routes"]).Size,
		"the complete builder result crosses the same exact-count marshaller")
	for Reason in Candidate["unconverted"]
		AssertFalse(InStr(Reason, "registration capacity"), "no old capacity refusal hides a dropped descriptor")
}

/** Zero remains valid; invalid count types and UInt32 overflow remain explicit refusals. */
_TRE_Counts() {
	AssertEqual(0, _LLM_NavEventOwnerNativeEnsureLoaded("route_storage_size", 0), "the existing empty-table ABI remains representable")
	AssertEqual(7840, _LLM_NavEventOwnerNativeEnsureLoaded("route_storage_size", 196), "count and stride share one checked arithmetic owner")
	AssertEqual(171798691800, _LLM_NavEventOwnerNativeEnsureLoaded("route_storage_size", 0xFFFFFFFF),
		"the exact UInt32 maximum is representable without allocating that buffer")
	for Count in [-1, "196", 1.5, 0x100000000]
		_TRE_ValueError(_LLM_NavEventOwnerNativeEnsureLoaded.Bind("route_storage_size", Count),
			"The terminal route descriptor count is invalid.")
}

Test("terminal-route-exact-count: all196 literal descriptors retain every wire byte", _TRE_Marshal)
Test("terminal-route-exact-count: the native wrapper forwards the full count and refuses mismatched spans", _TRE_NativeBoundary)
Test("terminal-route-exact-count: the source builder retains every controlled base and Shift route",
	() => _LNTR_WithState(_TRE_Build))
Test("terminal-route-exact-count: count arithmetic retains zero and refuses UInt32 overflow", _TRE_Counts)

/** A borrowed callback cannot select the canonical source after frame issuance. */
_TCF_SourceReplacement(Operation, InitiallyInactive := false) {
	State := _LNTR_PortState()
	if InitiallyInactive
		KeylayoutEmulation_Unload()
	Before := KeylayoutEmulation_CaptureCanonicalSource()
	State.Port["terminal_route_source"] := ReplaceSource
	Failure := 0
	try LLM_NavEventOwner_RefreshTerminalRoutes(State.Port)
	catch as Err
		Failure := Err
	AssertTrue(IsObject(Failure), "registration must refuse the callback's successor source")
	AssertContains(Failure.Message, "canonical source", "the original captured source fences registration")
	AssertEqual(0, State.Calls.Length, "source replacement is rejected before the registration boundary")
	AssertFalse(Before["current"].Call(), "the callback actually replaced the original source")
	After := KeylayoutEmulation_CaptureCanonicalSource()
	AssertTrue(After["current"].Call(), "the legitimate successor remains usable")
	AssertEqual(Operation == "load", After["active"], "the callback performed its exact source operation")

	ReplaceSource() {
		if Operation == "load" {
			_LNTR_LoadFixture("z")
			return _LNTR_Source(State)
		}
		KeylayoutEmulation_Unload()
		return Map("active", 0, "caps", 0)
	}
}

Test("terminal-canonical-frame: source callback cannot replace the captured active layout",
	() => _LNTR_WithState(() => _TCF_SourceReplacement("load")))
Test("terminal-canonical-frame: source callback cannot activate a captured inactive layout",
	() => _LNTR_WithState(() => _TCF_SourceReplacement("load", true)))
Test("terminal-canonical-frame: source callback cannot withdraw the captured layout",
	() => _LNTR_WithState(() => _TCF_SourceReplacement("unload")))

/** Source admission cannot take away the old frame's independent Stop authority. */
_TCF_RegisteredReplacement() {
	global _LLM_NavEventOwnerTerminalRouteUnknown
	State := _LNTR_PortState()
	State.Port["register_terminal_routes"] := ReplaceAfterRegistration
	Failure := 0
	try LLM_NavEventOwner_RefreshTerminalRoutes(State.Port)
	catch as Err
		Failure := Err
	AssertTrue(IsObject(Failure), "a late source replacement cannot certify publication")
	AssertContains(Failure.Message, "canonical source")
	AssertEqual(1, State.Calls.Length, "the exact original registration boundary ran once")
	AssertTrue(_LLM_NavEventOwnerTerminalRouteUnknown is Map,
		"an uncertain registration retains its original frame")
	AssertTrue(KeylayoutEmulation_CaptureCanonicalSource()["current"].Call(),
		"the successor is valid even though the old frame cannot admit it")
	AssertTrue(_LNTR_StopFixtureState(), "source withdrawal must not prevent original retirement")
	AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown)
	State.Port["register_terminal_routes"] := _LNTR_Register.Bind(State)
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port),
		"the legitimate successor can register after exact retirement")
	AssertEqual(2, State.Calls.Length)

	ReplaceAfterRegistration(Owner, Generation, Layout, Bindings, Count) {
		Status := _LNTR_Register(State, Owner, Generation, Layout, Bindings, Count)
		_LNTR_LoadFixture("z")
		return Status
	}
}

Test("terminal-canonical-frame: late source withdrawal retains independent Stop and successor admission",
	() => _LNTR_WithState(_TCF_RegisteredReplacement))

/** Borrowed recipe fields cannot replace an original canonical graph selector. */
_TCF_CanonicalRecipeForgery(Kind) {
	global KLE_Model
	State := _LNTR_PortState(), Source := _LNTR_Source(State)
	ForeignModel := KLE_Model.Clone(), Frozen := Map()
	for Scan, Code in Source["keys"] {
		for Shift in [0, 1]
			Frozen[Scan . "|" . Shift] := KeylayoutEmulation_CaptureReplayRoute(Scan, Shift, false, false)
	}
	if Kind == "inactive"
		KeylayoutEmulation_Unload()
	if Kind == "model"
		Source["model"] := ForeignModel
	Source["capture"] := ForgeRecipe
	State.Port["terminal_route_source"] := (*) => Source
	Before := KeylayoutEmulation_CaptureCanonicalSource()
	Failure := 0
	try LLM_NavEventOwner_RefreshTerminalRoutes(State.Port)
	catch as Err
		Failure := Err
	AssertTrue(IsObject(Failure), "a borrowed recipe must not mint canonical graph admission")
	AssertContains(Failure.Message, "canonical", "the exact original graph rejects the substituted selector")
	AssertEqual(0, State.Calls.Length, "no foreign recipe reaches the registration boundary")
	AssertTrue(Before["current"].Call(), "the original source stayed unchanged throughout the forgery")

	ForgeRecipe(Scan, Shift, Caps, Option) {
		Recipe := Frozen[Scan . "|" . Shift].Clone()
		if Kind == "index"
			Recipe["index"] := Shift ? 0 : 1
		else if Kind == "keycode" && Scan == "SC010"
			Recipe["keycode"] := 1
		else if Kind == "model"
			Recipe["model"] := ForeignModel
		return Recipe
	}
}

for _TCF_Forgery in ["index", "keycode", "model", "inactive"]
	Test("terminal-canonical-recipe: borrowed " . _TCF_Forgery . " cannot mint graph admission",
		_LNTR_WithState.Bind(_TCF_CanonicalRecipeForgery.Bind(_TCF_Forgery)))

/** A missing model recipe cannot silently become a natural modifier admission. */
_TCF_MissingCanonicalRecipe() {
	Route := _LLM_NavEventOwnerTerminalRouteDescriptor(1, 1, 2, 0x10, 1)
	Admission := Map("recipe", 0, "route", Route.Clone(), "generation", 1, "layout_id", 2)
	Candidate := Map("layout_id", 2, "routes", [Route], "recipes", Map(1, Admission), "unconverted", [])
	DigitCell := Map("mode", "disabled", "factory", 0, "rows", Map())
	AssertThrows(() => _LLM_NavEventOwnerCaptureTerminalCandidate(Candidate, DigitCell),
		"an absent canonical recipe cannot issue a model-row witness")
}

Test("terminal-canonical-recipe: a model descriptor requires its original row recipe",
	_TCF_MissingCanonicalRecipe)

/** Receives the actual x64 DLL without starting a keyboard hook or emitting input. */
_TRE_GenuineNativeCount() {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerPort, _LLM_NavEventOwnerTerminalRouteUnknown
	Owner := 17, Retired := false, Primary := 0, CleanupFailure := 0, RefusalCalls := 0
	AssertEqual(0, _LLM_NavEventOwnerModule, "the count receiver requires a fresh private native issuer")
	AssertFalse(_LLM_NavEventOwnerStarted, "this ABI receiver starts no keyboard hook")
	AssertEqual(0, _LLM_NavEventOwnerPort, "no supplied port can manufacture native registration")
	try {
		AssertTrue(_LLM_NavEventOwnerNativeEnsureLoaded(), "the original loader issues the actual vendor DLL")
		ImageName := Buffer(65536, 0)
		Characters := DllCall("Kernel32\GetModuleFileNameW", "Ptr", _LLM_NavEventOwnerModule,
			"Ptr", ImageName, "UInt", 32768, "UInt")
		AssertTrue(Characters > 0 && Characters < 32768, "the actual module supplies its complete native image path")
		_TestPrint("# native-exact-count image=" . StrGet(ImageName.Ptr, Characters, "UTF-16"))
		Probe := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, Buffer(512, 0), 64)
		AssertEqual(8, Probe["status"], "fresh C has no existing terminal owner")
		_TestPrint("# native-exact-count phase=fresh owner_status=" . Probe["status"])
		Bindings := _LLM_NavEventOwnerTerminalRouteMarshal(_TRE_Routes())
		AssertEqual(7840, Bindings.Size, "the actual native submission owns all196 forty-byte descriptors")
		AssertEqual(0, _LLM_NavEventOwnerNativeRegisterTerminalRoutes(Owner, 19, 23, Bindings, 196),
			"the actual DLL accepts the exact complete registration without an injected native operation")
		Probe := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, Buffer(512, 0), 64)
		AssertTrue(Probe["status"] == 0 && Probe["count"] == 0,
			"the same genuine C owner is admitted without inventing held input")
		_TestPrint("# native-exact-count phase=registered count=196 held=" . Probe["count"])
		for Size in [7839, 7841] {
			Bytes := Buffer(Size, 0)
			_TRE_ValueError(_LLM_NavEventOwnerNativeRegisterTerminalRoutes.Bind(Owner, 20, 23,
				Bytes, 196, UnexpectedOperation), "The terminal route native registration ABI is invalid.")
		}
		AssertEqual(0, RefusalCalls, "no malformed span reaches a native operation")
		AssertFalse(_LLM_NavEventOwnerStarted, "registration alone never installs a keyboard hook")
		AssertEqual(0, _LLM_NavEventOwnerTerminalRouteUnknown, "direct ABI receiving creates no claimed AHK frame")
		AssertTrue(LLM_NavEventOwner_Stop(), "the actual default native Stop retires the route storage")
		Probe := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, Buffer(512, 0), 64)
		AssertEqual(8, Probe["status"], "actual C owner retirement is independently queried")
		Retired := true
		_TestPrint("# native-exact-count phase=retired owner_status=" . Probe["status"])
	} catch as Err {
		Primary := Err
	} finally {
		if _LLM_NavEventOwnerModule && !Retired {
			try {
				AssertTrue(LLM_NavEventOwner_Stop(), "failed ABI receiving retains actual native cleanup ownership")
				Probe := _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, Buffer(512, 0), 64)
				AssertEqual(8, Probe["status"], "failed receiving still proves actual C owner retirement")
				Retired := true
				_TestPrint("# native-exact-count phase=cleanup owner_status=" . Probe["status"])
			} catch as Err {
				CleanupFailure := Err
			}
		}
	}
	if Primary is Error {
		if CleanupFailure is Error
			_TestPrint("# native-exact-count secondary_cleanup=" . CleanupFailure.Message)
		throw Primary
	}
	if CleanupFailure is Error
		throw CleanupFailure

	UnexpectedOperation(Args*) {
		RefusalCalls += 1
		return 0
	}
}

if _LNTR_NativeRetirementChildKind == "exact-count"
	Test("native-route-exact-count-child: actual196 descriptors and native retirement", _TRE_GenuineNativeCount)
else if _LNTR_NativeRetirementChildKind == ""
	Test("terminal-route-native-exact-count: actual DLL registration and retirement in a fresh child",
		_LNTR_ReceiveActualChild.Bind("exact-count"))

/** Requires the actual value-error contract, not an unrelated failing callback. */
_TRE_ValueError(Operation, ExpectedMessage) {
	Failure := 0
	try Operation.Call()
	catch as Err
		Failure := Err
	AssertTrue(Failure is ValueError, "the actual invalid count/span produces ValueError; actual=" . Type(Failure)
		. "; detail=" . (IsObject(Failure) ? Failure.Message . "; extra=" . Failure.Extra . "; stack=" . Failure.Stack : "no exception"))
	AssertEqual(ExpectedMessage, Failure.Message, "the actual refusal belongs to the count/span owner")
}
