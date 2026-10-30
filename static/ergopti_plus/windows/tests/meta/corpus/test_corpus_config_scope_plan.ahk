; tests/meta/corpus/test_corpus_config_scope_plan.ahk

; ==============================================================================
; MODULE: Config Scope Plan Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/config_scope/plan_vectors.json through the Windows
; manifest reader (ManifestScopeInventory, ManifestScopePlan), with the production
; parameter owner, ConfigScopeActionParameterDomain.
;
; FEATURES & RATIONALE:
; 1. declaration_plans, declaration_refusals and declaration_cycles build a private
;    declaration with the Lua config defaults contract. The Windows reader only
;    plans the generated manifest and takes no declaration, so those six vectors
;    have no Windows entry; they are counted, not replayed.
; 2. Every replayed case agrees or is pinned in _CTCS_PENDING with its reason.
; ==============================================================================

#Requires AutoHotkey v2.0



global _CTCS_PENDING := Map()

_CTCS_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\config_scope\plan_vectors.json", "UTF-8"))
	return Corpus
}

_CTCS_Owners() {
	return Map("action_parameter_domain", ConfigScopeActionParameterDomain)
}

_CTCS_Join(Paths) {
	Text := ""
	for Path in Paths
		Text .= (Text == "" ? "" : "|") . Path
	return Text
}

_CTCS_InventoryDifference(Vector) {
	Paths := _CTCS_Corpus()["stored_paths"]
	Owners := _CTCS_Owners()
	Inventory := ManifestScopeInventory(Vector["scope"], Map("actions", (*) => Paths), Owners)
	if Inventory.Length != Vector["inventory_count"]
		return "the inventory holds " . Inventory.Length
	for Mode in ["clear", "recommended"] {
		Actual := []
		for Row in ManifestScopePlan(Vector["scope"], Mode, Paths, Owners).operations {
			if Row.Section != "action_parameters"
				continue
			if !Row.HasOwnProp("Delete") || Row.Delete != 1 || Row.HasOwnProp("Value")
				return Mode . " must delete " . Row.Key
			Actual.Push(Row.Section . "." . Row.Key)
		}
		if _CTCS_Join(SortArray(Actual)) != _CTCS_Join(SortArray(Inventory.Clone()))
			return Mode . " deletes " . _CTCS_Join(Actual)
	}
	return ""
}

_CTCS_RefusalDifference(Vector) {
	Path := Vector["path"]
	Owners := _CTCS_Owners()
	try {
		ManifestScopePlan("gestures", "clear", [Path], Owners)
		return "the plan must refuse " . Path
	} catch Error {
	}
	try {
		ManifestScopeInventory("gestures", Map("actions", (*) => [Path]), Owners)
		return "the inventory must refuse " . Path
	} catch Error {
	}
	return ""
}

_CTCS_Throwing(*) {
	throw Error("runtime inventory unavailable")
}

_CTCS_Answer(Calls, Paths, *) {
	Calls.Count += 1
	return Paths
}

_CTCS_Providers(Vector, Calls) {
	Providers := Map()
	for Provider in Vector["providers"] {
		if Provider.Has("raises")
			Providers[Provider["name"]] := _CTCS_Throwing
		else if Provider.Has("not_a_function")
			Providers[Provider["name"]] := false
		else
			Providers[Provider["name"]] := _CTCS_Answer.Bind(Calls, Provider["paths"])
	}
	return Providers
}

_CTCS_CollectionDifference(Vector) {
	Expect := Vector["expect"]
	Calls := { Count: 0 }
	Owned := ManifestScopeInventory(Vector["scope"], _CTCS_Providers(Vector, Calls))
	if Calls.Count != Expect["calls"]
		return "the providers ran " . Calls.Count . " times"
	if _CTCS_Join(Owned) != _CTCS_Join(Expect["owned"])
		return "owned " . _CTCS_Join(Owned)
	Indexed := Map()
	for Row in ManifestScopePlan(Vector["scope"], "clear", Owned).operations {
		Name := ""
		for Part in TOML_ParseKeyPath(Row.Section, true)
			Name .= Part . "."
		Indexed[Name . Row.Key] := Row
	}
	for Path in Owned
		if !Indexed.Has(Path) || !Indexed[Path].HasOwnProp("Delete") || Indexed[Path].Delete != 1
			return "the clear must delete " . Path
	for Path, Section in Expect["section_of"]
		if !(Indexed[Path].Section == Section)
			return Path . " is written under " . Indexed[Path].Section
	for Path in Expect["no_row_for"]
		if Indexed.Has(Path)
			return "no row may address " . Path
	return ""
}

_CTCS_InventoryRefusalDifference(Vector) {
	try {
		ManifestScopeInventory(Vector["scope"], _CTCS_Providers(Vector, { Count: 0 }))
		return "the inventory must be refused"
	} catch Error {
	}
	return ""
}

_CTCS_Replay(Kind, Vector) {
	global _CTCS_PENDING
	Difference := %"_CTCS_" . Kind . "Difference"%(Vector)
	if _CTCS_PENDING.Has(Vector["id"])
		AssertTrue(Difference != "", Vector["id"] . " now agrees: remove it from _CTCS_PENDING")
	else
		AssertEqual("", Difference, Vector["id"])
}

_CTCS_CountsAreCurrent() {
	global _CTCS_PENDING
	Corpus := _CTCS_Corpus()
	AssertEqual(5, Corpus["stored_paths"].Length, "the stored paths changed")
	AssertEqual(4, Corpus["inventories"].Length, "the inventories changed")
	AssertEqual(6, Corpus["refusals"].Length, "the refusals changed")
	AssertEqual(1, Corpus["inventory_collections"].Length, "the collections changed")
	AssertEqual(5, Corpus["inventory_refusals"].Length, "the inventory refusals changed")
	AssertEqual(2 + 3 + 1, Corpus["declaration_plans"].Length + Corpus["declaration_refusals"].Length
		+ Corpus["declaration_cycles"].Length, "the vectors without a Windows entry changed")
	for Id, Reason in _CTCS_PENDING
		AssertTrue(Reason != "", "a pending entry states its reason: " . Id)
}
Test("config scope plan corpus: the counts and the pending inventory are current", _CTCS_CountsAreCurrent)

_CTCS_Register() {
	Corpus := _CTCS_Corpus()
	for Kind, Field in Map("Inventory", "inventories", "Refusal", "refusals",
			"Collection", "inventory_collections", "InventoryRefusal", "inventory_refusals")
		for Vector in Corpus[Field]
			Test("config scope plan corpus: " . Vector["id"], _CTCS_Replay.Bind(Kind, Vector))
}
_CTCS_Register()
