; tests/fixtures/terminal_digit_producer_body.ahk

; ==============================================================================
; MODULE: Direct-Digit Producer Child Receiving
; DESCRIPTION:
; Exercises the actual private source/candidate scopes after genuine original
; digit binding registration in a suspended child. Registration bytes are
; observed through a controlled port; no native emission or physical claim.
; ==============================================================================

; Private receiving fixture. No native issuance, input injection or output qualification.
_DDPR_State := {Calls: [], Held: [], HeldQueries: 0, Cell: 0, Frame: 0, Observations: 0}

_DDPR_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_DDPR_RequireThrows(Fn, ExpectedType, ExpectedMessage) {
	Failure := 0
	try Fn.Call()
	catch as Err
		Failure := Err
	_DDPR_Require(IsObject(Failure) && Type(Failure) == ExpectedType
		&& Failure.Message == ExpectedMessage, "the intended refusal was not observed; expected_type=" . ExpectedType . "; actual_type=" . Type(Failure)
		. "; expected_message=" . ExpectedMessage . "; actual_message=" . (IsObject(Failure) ? Failure.Message . "; actual_extra=" . Failure.Extra . "; actual_stack=" . Failure.Stack : "no exception"))
}

_DDPR_Noop(*) {
	return
}

_DDPR_Register(Owner, Generation, Layout, Bytes, Count) {
	global _DDPR_State
	Routes := []
	Loop Count
		Routes.Push(_LLM_NavEventOwnerTerminalRouteRead(Bytes, (A_Index - 1) * 40))
	_DDPR_State.Calls.Push(Routes)
	return 0
}

_DDPR_Held(Owner, Ids, Capacity) {
	global _DDPR_State
	_DDPR_Require(Capacity == 64 && Ids.Size == 512, "held query ABI changed")
	_DDPR_State.HeldQueries += 1
	for Index, Id in _DDPR_State.Held
		NumPut("UInt64", Id, Ids, (Index - 1) * 8)
	return Map("status", 0, "count", _DDPR_State.Held.Length)
}

_DDPR_ModeObserver(Receiver, Name, Default := 0) {
	global _DDPR_State
	_DDPR_State.Observations += 1
	_DDPR_State.Cell["rows"][2] := _DDPR_State.Cell["rows"][2].Clone()
	return Map.Prototype.Get.Call(Receiver, Name, Default)
}

_DDPR_LegacyObserver(Receiver, Name, Default := 0) {
	global _DDPR_State
	_DDPR_State.Observations += 1
	_DDPR_State.Frame["generation"] += 1
	return Map.Prototype.Get.Call(Receiver, Name, Default)
}

_DDPR_ProbeNewScope(ExpectRefusal) {
	global _LLM_NavEventOwnerTerminalRouteRefreshing
	PreviousCritical := Critical("On")
	_LLM_NavEventOwnerTerminalRouteRefreshing := true
	Scope := 0, Failure := 0
	try {
		try Scope := _LLM_NavEventOwnerNativeEnsureLoaded("begin_frame")
		catch as Err
			Failure := Err
		if ExpectRefusal
			_DDPR_Require(IsObject(Failure) && Type(Failure) == "Error"
				&& Failure.Message == "The native registration scope cannot be issued.", "uncertain private custody admitted a successor before Stop")
		else
			_DDPR_Require(!IsObject(Failure) && Scope is Map, "acknowledged Stop did not release original private custody")
	} finally {
		try {
			if Scope is Map
				_LLM_NavEventOwnerNativeEnsureLoaded("close_scope", Scope)
		} finally {
			_LLM_NavEventOwnerTerminalRouteRefreshing := false
			Critical(PreviousCritical)
		}
	}
}

_DDPR_ScopeGuard(Scenario) {
	global Features, _DDPR_State, _LLM_NavEventOwnerTerminalRouteRefreshing
	global _LLM_NavEventOwnerTerminalRouteGeneration
	PreviousCritical := Critical("On")
	_LLM_NavEventOwnerTerminalRouteRefreshing := true
	Scope := 0
	try {
		; The original constructor issues the Frame and its operations. Nothing
		; supplied by the fixture can become the loader's source or witness.
		Scope := _LLM_NavEventOwnerNativeEnsureLoaded("begin_frame")
		Frame := Scope["frame"]
		Scope["capture_digit_source"].Call()
		_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
		_LLM_NavEventOwnerTerminalRouteGeneration += 1
		Frame["generation"] := _LLM_NavEventOwnerTerminalRouteGeneration
		Source := Map("active", 0, "caps", 0)
		Candidate := _LLM_NavEventOwnerTerminalRouteBuild(Source, Frame["generation"], Frame, Scope["guard"])
		Frame["candidate"] := Candidate
		Scope["seal_candidate"].Call()
		_LLM_NavEventOwnerTerminalRegistrationAdvance(Frame, Candidate, Source)
		_LLM_NavEventOwnerTerminalRegistrationRetain(Frame)
		_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
		_DDPR_State.Frame := Frame
		if Scenario == "scope-policy-legacy" {
			Features["layout"].DefineProp("Get", {Call: _DDPR_LegacyObserver})
			try _DDPR_Require(!_LLM_NavEventOwnerTerminalRegistrationCurrent(Frame), "late policy observer exchanged the checked legacy Frame")
			finally Features["layout"].DeleteProp("Get")
			_DDPR_Require(_DDPR_State.Observations == 1, "legacy policy observer was not reached exactly once")
		} else {
			Scope["custom"].Call()
			Route := Candidate["routes"][17]
			Admission := Candidate["recipes"][Route["recipe_id"]]
			if Scenario == "scope-pending-binding"
				Admission["binding"]["digit"] := "9"
			else if Scenario == "scope-pending-route"
				Route["code"] := 0x30
			else if Scenario == "scope-pending-admission"
				Admission["generation"] += 1
			else if Scenario == "scope-pending-recipe"
				Admission["recipe"] := Map("invented", true)
			else
				throw Error("unknown scope scenario")
			_DDPR_RequireThrows(Scope["guard"], "Error", "The original direct-digit source changed during registration.")
			_DDPR_RequireThrows(Scope["complete"], "Error", "The original direct-digit source changed during registration.")
		}
	} finally {
		try {
			if Scope is Map
				_LLM_NavEventOwnerNativeEnsureLoaded("close_scope", Scope)
		} finally {
			_LLM_NavEventOwnerTerminalRouteRefreshing := false
			Critical(PreviousCritical)
		}
	}
	if Scenario != "scope-policy-legacy"
		_DDPR_ProbeNewScope(true)
	_DDPR_Require(LLM_NavEventOwner_Stop(), "altered source scope blocked controlled retirement")
	_DDPR_ProbeNewScope(false)
}

_DDPR_SourceGuard(Scenario) {
	global Features, _DDPR_State
	Issued := _LLM_NavEventOwnerCaptureDigitSource()
	_DDPR_Require(Issued is Map && Issued.Count == 3, "source packet was not issued")
	Cell := Issued["source"], Pure := Issued["current"], Policy := Issued["mode_current"]
	_DDPR_Require(Pure.Call() && Policy.Call(), "fresh source is not current")
	_DDPR_State.Cell := Cell
	if Scenario == "source-clean" {
		_DDPR_Require(Cell["rows"].Count == 10, "incomplete source family")
		return
	}
	if Scenario == "source-row-replacement"
		Cell["rows"][2] := Cell["rows"][2].Clone()
	else if Scenario == "source-mode-case"
		Cell["mode"] := "DIGITS"
	else if Scenario == "source-callback-call"
		Cell["rows"][2]["down"].DefineProp("Call", {Value: _DDPR_Noop})
	else if Scenario == "source-factory-call"
		Cell["factory"].DefineProp("Call", {Value: _DDPR_Noop})
	else if Scenario == "source-policy-observer" {
		Features["layout"].DefineProp("Get", {Call: _DDPR_ModeObserver})
		try {
			_DDPR_Require(!Policy.Call(), "policy observation blessed an equivalent foreign row")
			_DDPR_Require(_DDPR_State.Observations == 1, "policy observation was not reached exactly once")
		} finally Features["layout"].DeleteProp("Get")
	} else
		throw Error("unknown source scenario")
	_DDPR_Require(!Pure.Call(), "source witness accepted an altered source")
}

_DDPR_CandidateGuard(Scenario) {
	Issued := _LLM_NavEventOwnerCaptureDigitSource()
	Frame := Map("digit_source", Issued["source"])
	Candidate := _LLM_NavEventOwnerTerminalRouteBuild(Map("active", 0, "caps", 0), 1, Frame, _DDPR_Noop)
	_DDPR_Require(Candidate["routes"].Length == 26, "candidate did not retain sixteen natural and ten digit sources")
	Guard := _LLM_NavEventOwnerCaptureTerminalCandidate(Candidate, Issued["source"])
	_DDPR_Require(Guard.Call(), "fresh candidate witness is not current")
	if Scenario == "candidate-clean"
		return
	Route := Candidate["routes"][17], Admission := Candidate["recipes"][Route["recipe_id"]]
	if Scenario == "candidate-route"
		Route["code"] := 0x30
	else if Scenario == "candidate-route-clone"
		Candidate["routes"][17] := Route.Clone()
	else if Scenario == "candidate-admission"
		Admission["generation"] := 99
	else if Scenario == "candidate-binding"
		Admission["binding"]["digit"] := "9"
	else if Scenario == "candidate-recipe"
		Admission["recipe"] := Map("invented", true)
	else if Scenario == "candidate-reason-case"
		Candidate["unconverted"][1] := StrUpper(Candidate["unconverted"][1])
	else
		throw Error("unknown candidate scenario")
	_DDPR_Require(!Guard.Call(), "candidate witness accepted altered pending admission")
}

_DDPR_Production(Scenario) {
	global Features, KLE_Model, KLE_State, KLE_KeyCodes, _DDPR_State, _LLM_NavEventOwnerTerminalRouteRecipes
	_LNTR_LoadFixture("a")
	State := _LNTR_PortState()
	State.Port["register_terminal_routes"] := _DDPR_Register
	State.Port["list_terminal_held_recipes"] := _DDPR_Held
	if Scenario == "production-inactive" {
		State.Port.Delete("terminal_route_source")
		KeylayoutEmulation_Unload()
	}
	else if Scenario == "production-caps"
		State.Caps := 1
	else if Scenario == "production-composition"
		KLE_State := "acute"
	else if Scenario == "production-capacity" {
		CapacityKeycodeTable := Map("conventions", ["iso"], "keys", [])
		Loop 60
			CapacityKeycodeTable["keys"].Push(Map("ahk", Format("SC{:03X}", A_Index + 0x3F), "mac", 0))
		_DDPR_Require(_LNTR_LoadFixture("a", CapacityKeycodeTable) == 60,
			"PRECONDITION: the original loader must admit all sixty capacity keys")
	}
	else if Scenario != "production-kle" && Scenario != "production-held-withdrawal"
		throw Error("unknown production scenario")
	_DDPR_Require(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "actual producer refused controlled registration")
	_DDPR_Require(_DDPR_State.Calls.Length == 1, "registration boundary count changed")
	Digits := [], Kle := []
	for Route in _DDPR_State.Calls[1] {
		if Route["kind"] == 6
			Digits.Push(Route)
		else if Route["kind"] == 1 || Route["kind"] == 2
			Kle.Push(Route)
	}
	_DDPR_Require(Digits.Length == 10, "expected ten source declarations")
	_DDPR_Require(_DDPR_State.Calls[1].Length == 16 + Digits.Length + Kle.Length, "natural source family was discarded or duplicated")
	Loop 10 {
		Route := Digits[A_Index]
		_DDPR_Require(Route["axis"] == 2 && Route["code"] == A_Index + 1
			&& Route["target_vk"] == 0 && Route["target_scan"] == 0
			&& Route["required_modifiers"] == 0, "source declaration guessed output or changed selector")
	}
	Coverage := LLM_NavEventOwner_TerminalRouteCoverage()
	_DDPR_Require(!Coverage["cohort_complete"] && !Coverage["transformed_output_enabled"], "diagnostic source acquired output qualification")
	if Scenario == "production-capacity" {
		_DDPR_Require(Kle.Length == 120 && _DDPR_State.Calls[1].Length == 146,
			"the original producer truncated the sixty controlled base and Shift pairs")
		for Size in [5839, 5841] {
			Bytes := Buffer(Size, 0)
			_DDPR_RequireThrows(_LLM_NavEventOwnerNativeRegisterTerminalRoutes.Bind(1, 1, 1,
				Bytes, 146, _DDPR_Register), "ValueError",
				"The terminal route native registration ABI is invalid.")
		}
		_DDPR_Require(_DDPR_State.Calls.Length == 1, "a mismatched exact-count span reached registration")
	} else if Scenario == "production-kle" || Scenario == "production-held-withdrawal" {
		_DDPR_Require(Kle.Length == 4, "independent base and Shift KLE routes were discarded")
		if Scenario == "production-held-withdrawal" {
			DigitId := Digits[1]["recipe_id"], KleId := Kle[1]["recipe_id"]
			UnheldDigitId := Digits[2]["recipe_id"]
			OldDigit := _LLM_NavEventOwnerTerminalRouteRecipes[DigitId]
			OldKle := _LLM_NavEventOwnerTerminalRouteRecipes[KleId]
			Queries := _DDPR_State.HeldQueries
			_DDPR_State.Held := [DigitId, KleId]
			_DigitRowDown.DefineProp("Call", {Value: _DDPR_Noop})
			try _DDPR_Require(DigitRow_BindingSource() == 0, "withdrawn source still issued")
			finally _DigitRowDown.DeleteProp("Call")
			_DDPR_Require(DigitRow_BindingSource() == 0, "restoration recreated a withdrawn lease")
			_DDPR_Require(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "historical factory prevented a successor registration")
			_DDPR_Require(_DDPR_State.HeldQueries == Queries + 1, "successor did not perform the exact held query")
			_DDPR_Require(_DDPR_State.Calls.Length == 2 && _DDPR_State.Calls[2].Length == 20, "withdrawn source changed the successor family")
			for Route in _DDPR_State.Calls[2]
				_DDPR_Require(Route["kind"] != 6, "withdrawn source published fresh direct-digit declarations")
			_DDPR_Require(_LLM_NavEventOwnerTerminalRouteRecipes[DigitId] == OldDigit
				&& _LLM_NavEventOwnerTerminalRouteRecipes[KleId] == OldKle, "held historical admissions were exchanged")
			_DDPR_Require(!_LLM_NavEventOwnerTerminalRouteRecipes.Has(UnheldDigitId), "unheld old digit admission did not retire")
			_DDPR_State.Held := []
			_DDPR_Require(LLM_NavEventOwner_RefreshTerminalRoutes(State.Port), "debt-free successor registration refused")
			_DDPR_Require(_DDPR_State.HeldQueries == Queries + 2, "debt-free successor did not query held identities")
			_DDPR_Require(!_LLM_NavEventOwnerTerminalRouteRecipes.Has(DigitId)
				&& !_LLM_NavEventOwnerTerminalRouteRecipes.Has(KleId), "released digit or KLE admission did not retire")
			_DDPR_Require(LLM_NavEventOwner_Stop(), "withdrawn producer blocked acknowledged cleanup")
		}
	} else
		_DDPR_Require(Kle.Length == 0, "inactive or unsupported KLE acquired recipes")
}

try {
	Features := Map("layout", Map("direct_access_digits", "digits"))
	CategoryEnabled := Map("Layout", true)
	_DDPR_Require(NumberRowEffectiveMode() == "digits", "PRECONDITION: policy did not admit digits")
	_DDPR_Require(DigitRow_RegisterBindings() == 20, "PRECONDITION: genuine twenty-slot registration did not complete")
	_DDPR_Require(DigitRow_BindingSource() is BoundFunc, "PRECONDITION: original factory not issued")
	Scenario := EnvGet("ERGOPTI_DIGIT_RECEIVING_SCENARIO")
	if SubStr(Scenario, 1, 7) == "source-"
		_DDPR_SourceGuard(Scenario)
	else if SubStr(Scenario, 1, 10) == "candidate-"
		_DDPR_CandidateGuard(Scenario)
	else if SubStr(Scenario, 1, 11) == "production-"
		_DDPR_Production(Scenario)
	else if SubStr(Scenario, 1, 6) == "scope-"
		_DDPR_ScopeGuard(Scenario)
	else if Scenario == "bind-own-call" {
		Func.Prototype.Bind.DefineProp("Call", {Value: _DDPR_Noop})
		try _DDPR_RequireThrows(_LLM_NavEventOwnerCaptureDigitSource, "Error", "The original direct-digit source accessor was withdrawn.")
		finally Func.Prototype.Bind.DeleteProp("Call")
	} else
		throw Error("unknown receiving scenario")
	FileAppend("PASS scenario=" Scenario " source_only=true physical_qualified=false`n", "*")
	ExitApp(0)
} catch as Failure {
	FileAppend(Failure.Message "`n" Failure.Stack "`n", "**")
	ExitApp(InStr(Failure.Message, "PRECONDITION:") == 1 ? 42 : 1)
}
