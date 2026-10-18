; tests/unit/modules/keymap/test_keylayout_altgr_characterization.ahk

; ==============================================================================
; MODULE: Ergopti+ AltGr Characterization
; DESCRIPTION:
; The Ergopti+ AltGr outputs keep their recorded legacy differences, the
; KLE captured-reset observer keeps the original registration contract,
; and AltGr bindings are only issued through the canonical source.
; ==============================================================================

#Requires AutoHotkey v2.0





_KLT_PlusOutputMatrixCase() {
	Matrix := JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_plus_altgr_output_matrix.json", "UTF-8"))
	Golden := JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_emulation_golden.json", "UTF-8"))["levels"]
	AssertEqual(6, Matrix["rows"].Length, "all three legacy plus keys need both Shift states")
	_KLT_Load("ergopti_plus")
	Seen := Map()
	Observed := 0
	TextDifferences := 0
	for Row in Matrix["rows"] {
		Identity := Row["legacy_level"] . ":" . Row["scan"]
		AssertFalse(Seen.Has(Identity), "the independent matrix must not repeat a legacy entry")
		Seen[Identity] := true
		ExpectedLegacy := Golden[Row["legacy_level"]][Row["scan"]]
		AssertEqual(_EKT_Describe(ExpectedLegacy), _EKT_Describe(Row["descriptor"]),
			"the independent historical golden remains authoritative")
		for Caps in [false, true] {
			KeylayoutEmulation_ResetDeadKey()
			Actual := KeylayoutEmulation_Press(Row["scan"], Row["shift"], Caps, true)
			AssertEqual(Row["selected"], Actual,
				Identity . ": selected Ergopti+ types the independent neutral output with Caps " . Caps)
			Observed += 1
			if ExpectedLegacy.Has("text") {
				AssertFalse(Actual == ExpectedLegacy["text"],
					"the current selected text is not the legacy Shift deviation")
				TextDifferences += 1
			}
		}
	}
	for Level in ["altgr_plus", "altgr_plus_shift"] {
		AssertEqual(3, Golden[Level].Count, "the historical plus level has three keys")
		for Scan in Golden[Level]
			AssertTrue(Seen.Has(Level . ":" . Scan), "no legacy plus entry may be omitted")
	}
	AssertEqual(12, Observed, "each independent output runs with both Caps states")
	AssertEqual(4, TextDifferences, "both Shift deviations remain distinct with Caps off and on")
}
Test("Ergopti+ matrix: selected raw AltGr outputs retain the independently recorded legacy differences (todo96-output-matrix)",
	_KLT_WithEmulation.Bind(_KLT_PlusOutputMatrixCase))

; Captured KLE reset metadata: authored AHK behavior, UNRUN outside Windows.
; These callables cannot authenticate a captured physical event or consume FIFO.
_KLTR_WithObserver(Fn) {
	global KLE_Registered, _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering
	global _KLE_ResetObserverGeneration, _KLE_ResetObserverCapture, CategoryEnabled, LayerEnabled
	Saved := [KLE_Registered, _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering,
		_KLE_ResetObserverGeneration, CategoryEnabled, LayerEnabled, _KLE_ResetObserverCapture]
	try {
		KLE_Registered := false
		_KLE_ResetObserverCohort := 0, _KLE_ResetObserverRegistering := 0, _KLE_ResetObserverCapture := 0
		CategoryEnabled := Map("Layout", true), LayerEnabled := false
		_KLT_WithEmulation(_KLTR_RunObserver.Bind(Fn))
	} finally {
		KLE_Registered := Saved[1], _KLE_ResetObserverCohort := Saved[2]
		_KLE_ResetObserverRegistering := Saved[3], _KLE_ResetObserverGeneration := Saved[4]
		CategoryEnabled := Saved[5], LayerEnabled := Saved[6], _KLE_ResetObserverCapture := Saved[7]
	}
}

_KLTR_RunObserver(Fn) {
	global KLE_State
	_KLT_Load("ergol")
	KLE_State := "acute"
	Fn()
}

_KLTR_Port(Mode := "") {
	return {Mode: Mode, Rows: Map(), Criterion: 0, Injected: false,
		During: 0, Returns: 0, Cleanup: 0}
}

_KLTR_HotIf(Port, Args*) {
	if Args.Length
		Port.Criterion := Args[1]
	else {
		Port.Cleanup += 1
		if Port.Mode == "cleanup_throw"
			throw Error("Original reset registration cleanup failed.")
	}
}

_KLTR_Hotkey(Port, Name, Callback, Options) {
	global _KLE_ResetObserverRegistering
	Port.Rows[Name] := Map("callback", Callback, "criterion", Port.Criterion, "options", Options)
	if SubStr(Name, 1, 1) == "~" && !Port.Injected {
		Port.Injected := true
		Port.During := KeylayoutEmulation_CaptureResetObserver(SubStr(Name, 2))
		switch Port.Mode {
			case "hotkey_throw": throw Error("A physical reset binding may already be installed.")
			case "reentry":
				AssertThrows(KeylayoutEmulation_Register.Bind(LayoutRegistry_Keycodes(),
					(*) => 0, (*) => 0, 0, (*) => 0))
			case "lost_registering": _KLE_ResetObserverRegistering := Map("invalid", false)
		}
	}
	; Original registration accepts nonthrowing ports, not an invented ACK type.
	Port.Returns += 1
	return Port.Mode == "untyped_return" ? "no native ACK promised" : 0
}

_KLTR_Register(Port) {
	return KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
		_KLTR_Hotkey.Bind(Port), _KLTR_HotIf.Bind(Port), 0, (*) => 0)
}

_KLTR_Event(Sc, Origin := 1, Repeat := 0) {
	return Map("scan", Integer("0x" . SubStr(Sc, 3)), "origin", Origin,
		"key_up", 0, "repeat", Repeat)
}

_KLTR_Positive(Sc, Origin, Repeat) {
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE, _KLE_ResetObserverCohort
	Port := _KLTR_Port()
	_KLTR_Register(Port)
	AssertEqual(0, Port.During, "Partial physical registration grants no captured recipe.")
	AssertEqual(13, _KLE_ResetObserverCohort["bindings"].Count)
	Actual := Port.Rows["~" . Sc]
	AssertTrue(Actual["callback"] == KeylayoutEmulation_ResetDeadKey)
	AssertTrue(Actual["criterion"] == _KLE_PendingDeadKeyCriterion)
	AssertEqual("I2", Actual["options"])
	Recipe := KeylayoutEmulation_CaptureResetObserver(Sc)
	AssertTrue(HasMethod(Recipe, "Call"), "The real successful registration supplies a retained callable.")
	for Pass in [1, 2] {
		Result := Recipe.Call(_KLTR_Event(Sc, Origin, Repeat), "acute")
		AssertEqual(KEYLAYOUT_NEUTRAL_STATE, Result["Next"])
		AssertEqual("", Result["Output"])
		AssertTrue(Result["metadata_only"])
		AssertFalse(Result["cohort_complete"])
		AssertFalse(Result["transformed_output_enabled"])
		AssertFalse(Result["native_consumed"])
		AssertEqual("acute", KLE_State, "Pure interpretation does not reset live composition or consume an edge.")
	}
	Actual["callback"].Call()
	AssertEqual(KEYLAYOUT_NEUTRAL_STATE, KLE_State, "The unchanged physical callback shares the neutral transition.")
}

_KLTR_Mutate(Source) {
	global _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering, KLE_Model, KLE_Id, KLE_State
	global KLE_Registered, _KLE_ResetObserverCapture
	Row := _KLE_ResetObserverCohort["bindings"].Get("SC00E", 0)
	switch Source {
		case "cohort_removed": _KLE_ResetObserverCohort := 0
		case "cohort_replaced": _KLE_ResetObserverCohort := _KLE_ResetObserverCohort.Clone()
		case "generation": _KLE_ResetObserverCohort["generation"] += 1
		case "bindings_replaced": _KLE_ResetObserverCohort["bindings"] := _KLE_ResetObserverCohort["bindings"].Clone()
		case "factory_removed": _KLE_ResetObserverCapture := 0
		case "factory_call_override": _KLE_ResetObserverCapture.DefineProp("Call", {Call: (*) => 0})
		case "cohort_get_override": _KLE_ResetObserverCohort.DefineProp("Get", {Call: (*) => 0})
		case "bindings_get_override": _KLE_ResetObserverCohort["bindings"].DefineProp("Get", {Call: (*) => 0})
		case "binding_get_override": Row.DefineProp("Get", {Call: (*) => 0})
		case "binding_removed": _KLE_ResetObserverCohort["bindings"].Delete("SC00E")
		case "binding_replaced": _KLE_ResetObserverCohort["bindings"]["SC00E"] := Row.Clone()
		case "callback": Row["callback"] := (*) => 0
		case "criterion": Row["criterion"] := (*) => true
		case "options": Row["options"] := "I3"
		case "scan": Row["scan"] := "SC001"
		case "name": Row["name"] := "~SC001"
		case "model": KLE_Model := KLE_Model.Clone()
		case "layout": KLE_Id := "foreign-layout"
		case "state": KLE_State := "other-dead"
		case "unregistered": KLE_Registered := false
		case "registering": _KLE_ResetObserverRegistering := Map("invalid", false)
		default: throw ValueError("Unknown captured reset mutation.")
	}
}

_KLTR_Invoke(Recipe, Event, State) => Recipe.Call(Event, State)

_KLTR_SourceRefusal(Source) {
	Port := _KLTR_Port()
	_KLTR_Register(Port)
	Recipe := KeylayoutEmulation_CaptureResetObserver("SC00E")
	AssertTrue(HasMethod(Recipe, "Call"))
	_KLTR_Mutate(Source)
	AssertThrows(_KLTR_Invoke.Bind(Recipe, _KLTR_Event("SC00E"), "acute"),
		"A retained callable must reject changed registration or source identity.")
	Fresh := KeylayoutEmulation_CaptureResetObserver("SC00E")
	if Source == "model" || Source == "layout" || Source == "state"
		AssertTrue(HasMethod(Fresh, "Call"), "A fresh valid source can capture its own pure reset recipe.")
	else
		AssertEqual(0, Fresh)
}

_KLTR_BadEvent(Field, Value, Delete := false) {
	_KLTR_Register(_KLTR_Port())
	Recipe := KeylayoutEmulation_CaptureResetObserver("SC00E")
	Event := _KLTR_Event("SC00E")
	if Delete
		Event.Delete(Field)
	else
		Event[Field] := Value
	AssertThrows(_KLTR_Invoke.Bind(Recipe, Event, "acute"))
}

_KLTR_RegistrationRefusal(Mode) {
	global _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering, KLE_Registered
	Port := _KLTR_Port(Mode)
	if Mode == "hotkey_throw" || Mode == "cleanup_throw" {
		AssertThrows(_KLTR_Register.Bind(Port))
		AssertFalse(KLE_Registered)
		AssertTrue(Port.Rows.Count > 0, "Already installed bindings are not falsely rolled back.")
	} else {
		Count := _KLTR_Register(Port)
		AssertEqual(Port.Rows.Count + LayoutRegistry_Keycodes()["keys"].Length - 1, Count,
			"Existing Win broker calls retain the original registration count.")
		AssertTrue(KLE_Registered)
	}
	AssertEqual(0, _KLE_ResetObserverRegistering)
	AssertEqual(0, _KLE_ResetObserverCohort)
	AssertEqual(0, KeylayoutEmulation_CaptureResetObserver("SC00E"))
}

class _KLTR_ObservedCategory extends Map {
	Has(Name) {
		if this.Armed {
			this.Armed := false
			_KLTR_Mutate(this.Mutation)
		}
		return super.Has(Name)
	}
}

_KLTR_CriterionWithdrawal(Source) {
	global CategoryEnabled
	_KLTR_Register(_KLTR_Port())
	Gate := _KLTR_ObservedCategory("Layout", true)
	Gate.Armed := true, Gate.Mutation := Source
	CategoryEnabled := Gate
	AssertEqual(0, KeylayoutEmulation_CaptureResetObserver("SC00E"),
		"The actual criterion's category read cannot publish a changed source.")
	AssertFalse(Gate.Armed, "The actual existing criterion must cross the observed category read.")
}

_KLTR_ReturnConvention() {
	_KLTR_Register(_KLTR_Port("untyped_return"))
	AssertTrue(HasMethod(KeylayoutEmulation_CaptureResetObserver("SC00E"), "Call"),
		"No synthetic native registration ACK is required.")
}

; Every original KLE test and assertion remains an exact byte prefix above.
for Scan in ["SC00E", "SC001", "SC01C", "SC00F", "SC153", "SC14B", "SC14D",
		"SC148", "SC150", "SC147", "SC14F", "SC149", "SC151"] {
	for Origin in [1, 2] {
		for Repeated in [0, 1] {
			Test("KLE captured reset: " . Scan . "/" . Origin . "/" . Repeated . " (kle-reset-observer)",
				_KLTR_WithObserver.Bind(_KLTR_Positive.Bind(Scan, Origin, Repeated)))
		}
	}
}
for Mutation in ["cohort_removed", "cohort_replaced", "generation", "binding_removed",
		"binding_replaced", "bindings_replaced", "factory_removed", "factory_call_override",
		"cohort_get_override", "bindings_get_override", "binding_get_override", "callback", "criterion", "options", "scan", "name", "model",
		"layout", "state", "unregistered", "registering"] {
	Test("KLE captured reset: refuses " . Mutation . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_SourceRefusal.Bind(Mutation)))
}
for Vector in [["scan", 1], ["origin", 0], ["origin", 3], ["key_up", 1],
		["repeat", 2], ["repeat", -1], ["origin", "1"], ["scan", 0, true]] {
	Test("KLE captured reset: malformed " . Vector[1] . "/" . Vector[2] . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_BadEvent.Bind(Vector[1], Vector[2], Vector.Length == 3)))
}
for Mode in ["hotkey_throw", "cleanup_throw", "reentry", "lost_registering"] {
	Test("KLE captured reset: unavailable after " . Mode . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_RegistrationRefusal.Bind(Mode)))
}
for Mutation in ["cohort_replaced", "binding_replaced", "model", "layout", "state"] {
	Test("KLE captured reset: actual criterion withdraws " . Mutation . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_CriterionWithdrawal.Bind(Mutation)))
}
Test("KLE captured reset: original registration return convention (kle-reset-observer)",
	_KLTR_WithObserver.Bind(_KLTR_ReturnConvention))


; Genuine binding issuance is received separately on an idle Windows desktop.
; These controlled registrations must never manufacture that native authority.
_KAB_UnissuedSource() {
	global KLE_Registered
	AssertEqual(0, KeylayoutEmulation_AltGrBindingSource())
	for ProbeSource in [0, Map("complete", true), {}, ((*) => 0).Bind()]
		for ProbeScan in ["SC010", "SC002", "", 0, {}]
			AssertEqual(0, KeylayoutEmulation_CaptureAltGrBinding(ProbeSource, ProbeScan),
				"caller descriptions cannot issue original native binding custody")
	ProbeSaved := KLE_Registered
	try {
		KLE_Registered := true
		AssertEqual(0, KeylayoutEmulation_AltGrBindingSource(), "a public completion flag grants no source")
	} finally KLE_Registered := ProbeSaved
}

_KAB_NoPublicIssuer() {
	AssertFalse(IsSet(_KLE_RegisterBindings), "the effectful original body has no alternate public entry")
	for ProbeRequest in ["issue", "ready", "reset", "complete", {}, 0]
		AssertThrows(_KLE_AltGrBindingOwner.Bind(ProbeRequest))
	AssertThrows(_KLE_AltGrBindingOwner.Bind("initialize"), "initialization has exactly one owner")
	AssertEqual(0, KeylayoutEmulation_AltGrBindingSource())
}

_KAB_FreshRegistryRead() {
	global _LayoutRegistryKeycodes
	ProbeSaved := _LayoutRegistryKeycodes
	try {
		ProbeOriginal := _LayoutRegistryReadKeycodes()
		AssertTrue(ProbeOriginal["keys"].Length > 1, "the real physical-key inventory must be nonempty")
		_LayoutRegistryKeycodes := ProbeOriginal.Clone()
		_LayoutRegistryKeycodes["keys"] := [ProbeOriginal["keys"][1]]
		AssertEqual(1, LayoutRegistry_Keycodes()["keys"].Length,
			"the legacy public cache still retains its original ordinary behavior")
		ProbeFresh := _LayoutRegistryReadKeycodes()
		AssertEqual(ProbeOriginal["keys"].Length, ProbeFresh["keys"].Length,
			"native preflight reads the real file rather than trusting a replaced cache")
		for ProbeIndex, ProbeKey in ProbeOriginal["keys"]
			AssertEqual(ProbeKey["ahk"], ProbeFresh["keys"][ProbeIndex]["ahk"])
	} finally _LayoutRegistryKeycodes := ProbeSaved
}

_KAB_InjectedRegistration() {
	global KLE_Registered, KLE_DEAD_RESET_KEYS, _KLE_ResetObserverRegistering
	global _KLE_ResetObserverCohort, _KLE_ResetObserverCapture, _KLE_ResetObserverGeneration
	ProbeSaved := [KLE_Registered, _KLE_ResetObserverRegistering, _KLE_ResetObserverCohort,
		_KLE_ResetObserverCapture, _KLE_ResetObserverGeneration]
	try {
		KLE_Registered := false
		_KLE_ResetObserverRegistering := 0
		ProbeRows := [], ProbeContexts := []
		ProbeTable := LayoutRegistry_Keycodes()
		ProbeCount := KeylayoutEmulation_Register(ProbeTable,
			(ProbeName, *) => (ProbeRows.Push(ProbeName), AssertEqual(0, KeylayoutEmulation_AltGrBindingSource())),
			(ProbeArgs*) => ProbeContexts.Push(ProbeArgs.Length), 0,
			(ProbeScan, *) => ProbeRows.Push("#" . ProbeScan))
		ProbeExpected := ProbeTable["keys"].Length * 3 + (ProbeTable["keys"].Length - 1) * 6 + KLE_DEAD_RESET_KEYS.Length
		AssertEqual(ProbeExpected, ProbeCount)
		AssertEqual(ProbeExpected, ProbeRows.Length)
		AssertEqual(0, ProbeContexts[ProbeContexts.Length], "the original process-wide criterion is released")
		AssertEqual(0, KeylayoutEmulation_AltGrBindingSource(), "injected ports grant no native source")
		AssertThrows(KeylayoutEmulation_Register.Bind(ProbeTable, (*) => 0, (*) => 0),
			"the original duplicate-registration refusal remains effective")
		KLE_Registered := false
		KeylayoutEmulation_Register(ProbeTable, (*) => 0, (*) => 0, 0, (*) => 0)
		AssertEqual(0, KeylayoutEmulation_AltGrBindingSource(), "restoring public state cannot revive issuance")
	} finally {
		KLE_Registered := ProbeSaved[1], _KLE_ResetObserverRegistering := ProbeSaved[2]
		_KLE_ResetObserverCohort := ProbeSaved[3], _KLE_ResetObserverCapture := ProbeSaved[4]
		_KLE_ResetObserverGeneration := ProbeSaved[5]
	}
}

Test("kle-altgr-binding-source: unissued factories grant no binding custody", _KAB_UnissuedSource)
Test("kle-altgr-binding-source: no public initialization or issuance bypass", _KAB_NoPublicIssuer)
Test("kle-altgr-binding-source: canonical inventory ignores the public registry cache", _KAB_FreshRegistryRead)
Test("kle-altgr-binding-source: controlled registration preserves legacy behavior without native issuance", _KAB_InjectedRegistration)
