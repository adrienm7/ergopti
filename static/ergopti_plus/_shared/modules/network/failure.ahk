; _shared/modules/network/failure.ahk

; ==============================================================================
; MODULE: Managed Network Failure Contract
; DESCRIPTION:
; Pure AHK interpreter of managed_network.json. Native drivers own typed
; receipts and live action capabilities; neither stderr nor URLs become causes.
; Both interpreters replay the independent network/failure_vectors.json corpus.
; ==============================================================================

#Requires AutoHotkey v2.0

; Exact comparisons keep receipt strings consistent with the Lua interpreter.
_ManagedNetwork_Equal(Left, Right) {
	if Left is String
		return Right is String && StrCompare(Left, Right, true) == 0
	return Left is Number && Right is Number && Left == Right
}

_ManagedNetwork_Contains(Values, Expected) {
	for Value in Values
		if _ManagedNetwork_Equal(Value, Expected)
			return true
	return false
}

; Map defaults can ignore key case, while JSON and Lua keys are exact.
_ManagedNetwork_Get(Record, Name, Default := 0) {
	if !(Name is String)
		return Default
	for Key, Value in Record
		if Key is String && StrCompare(Key, Name, true) == 0
			return Value
	return Default
}

_ManagedNetwork_Scalar(Value, Definition) {
	Kind := Definition["type"]
	if Kind == "integer" {
		if !(Value is Number) || Value != Floor(Value)
			return false
	} else if Kind == "string" {
		if !(Value is String)
			return false
	} else {
		return false
	}
	return !Definition.Has("values") || _ManagedNetwork_Contains(Definition["values"], Value)
}

_ManagedNetwork_Array(Value) {
	return Value is Array && Value.Length > 0
}

_ManagedNetwork_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_ManagedNetwork_Validate(Policy) {
	_ManagedNetwork_Require(Policy is Map && Policy.Get("schema_version", 0) == 1,
		"Unsupported managed network policy")
	_ManagedNetwork_Require(Policy.Get("fields", 0) is Map && Policy.Get("causes", 0) is Map
		&& Policy.Get("actions", 0) is Map && _ManagedNetwork_Array(Policy.Get("rules", 0))
		&& _ManagedNetwork_Array(Policy.Get("capabilities", 0)), "Incomplete managed network policy")
	_ManagedNetwork_Require(Policy.Get("default_cause", 0) is String
		&& Policy["causes"].Has(Policy["default_cause"]), "Invalid default cause")
	Capabilities := Map()
	RuleIds := Map()
	for Name in Policy["capabilities"] {
		_ManagedNetwork_Require(Name is String && Name != "" && !Capabilities.Has(Name), "Invalid capability")
		Capabilities[Name] := true
	}
	for Name, Field in Policy["fields"] {
		_ManagedNetwork_Require(Name is String && Field is Map
			&& (Field.Get("type", "") == "string" || Field.Get("type", "") == "integer"), "Invalid receipt field")
		if Field.Has("values") {
			_ManagedNetwork_Require(_ManagedNetwork_Array(Field["values"]), "Receipt enum must not be empty")
			for Value in Field["values"]
				_ManagedNetwork_Require(_ManagedNetwork_Scalar(Value, Map("type", Field["type"])), "Invalid receipt enum value")
		}
	}
	for Id, Action in Policy["actions"] {
		_ManagedNetwork_Require(Id is String && Action is Map && Action.Get("label_key", 0) is String
			&& Action["label_key"] != "" && _ManagedNetwork_Array(Action.Get("requires", 0)), "Invalid managed network action")
		for Capability in Action["requires"]
			_ManagedNetwork_Require(Capabilities.Has(Capability), "Action needs an undeclared capability")
	}
	for Id, Cause in Policy["causes"] {
		_ManagedNetwork_Require(Id is String && Cause is Map && Cause.Get("message_key", 0) is String
			&& Cause["message_key"] != "" && _ManagedNetwork_Array(Cause.Get("actions", 0)), "Invalid managed network cause")
		for Action in Cause["actions"]
			_ManagedNetwork_Require(Policy["actions"].Has(Action), "Cause has an undeclared action")
	}
	for Rule in Policy["rules"] {
		_ManagedNetwork_Require(Rule is Map && Rule.Get("id", 0) is String && Rule["id"] != ""
			&& !RuleIds.Has(Rule["id"]) && Policy["causes"].Has(Rule.Get("cause", 0))
			&& Rule.Get("when", 0) is Map && Rule["when"].Count > 0, "Invalid failure rule")
		RuleIds[Rule["id"]] := true
		for Field, Values in Rule["when"] {
			_ManagedNetwork_Require(Policy["fields"].Has(Field) && _ManagedNetwork_Array(Values),
				"Rule has an undeclared receipt field")
			for Value in Values
				_ManagedNetwork_Require(_ManagedNetwork_Scalar(Value, Policy["fields"][Field]), "Invalid rule receipt value")
		}
	}
}

/** Builds a pure contract from the decoded canonical managed_network.json. */
class ManagedNetworkFailureContract {
	__New(Policy) {
		_ManagedNetwork_Validate(Policy)
		this.Policy := Policy
	}

	/** Recomputes available actions from fresh native capabilities before dispatch. */
	Actions(Cause, Capabilities) {
		Policy := this.Policy
		Definition := _ManagedNetwork_Get(Policy["causes"], Cause)
		_ManagedNetwork_Require(Capabilities is Map && Definition is Map, "Invalid failure action context")
		Actions := []
		for Id in Definition["actions"] {
			Definition := Policy["actions"][Id]
			Available := true
			for Capability in Definition["requires"] {
				Value := _ManagedNetwork_Get(Capabilities, Capability)
				if !(Value is Integer) || Value != true
					Available := false
			}
			if Available
				Actions.Push(Map("id", Id, "label_key", Definition["label_key"]))
		}
		return Actions
	}

	/** Returns cause, locale key, rule id and action ids; never raw metadata. */
	Classify(Receipt, Capabilities) {
		_ManagedNetwork_Require(Receipt is Map, "Managed network receipt must be a map")
		Policy := this.Policy
		Cause := Policy["default_cause"]
		Evidence := "insufficient_evidence"
		Valid := true
		for Field, Value in Receipt {
			Definition := _ManagedNetwork_Get(Policy["fields"], Field)
			if Definition is Map && !_ManagedNetwork_Scalar(Value, Definition)
				Valid := false
		}
		if Valid {
			for Rule in Policy["rules"] {
				Matches := true
				for Field, Values in Rule["when"] {
					if !_ManagedNetwork_Contains(Values, _ManagedNetwork_Get(Receipt, Field, Map()))
						Matches := false
				}
				if Matches {
					Cause := Rule["cause"]
					Evidence := Rule["id"]
					break
				}
			}
		} else {
			Evidence := "invalid_receipt"
		}
		return Map("cause", Cause, "message_key", Policy["causes"][Cause]["message_key"],
			"evidence", Evidence, "actions", this.Actions(Cause, Capabilities))
	}
}
