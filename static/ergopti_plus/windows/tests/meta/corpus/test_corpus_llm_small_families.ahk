; tests/meta/corpus/test_corpus_llm_small_families.ahk

; ==============================================================================
; MODULE: Small Shared Corpus Consumers (Windows)
; DESCRIPTION:
; Replays the shared corpora the Lua suites already replay on macOS and Linux
; through the real Windows owners: the per-application profile rule
; (llm/app_profile_overrides_vectors.json), the output token budget of one call
; (llm/request_plan_token_budget_vectors.json) and the separator normalisation of a
; native menu (menus/separator_normalization_vectors.json).
;
; FEATURES & RATIONALE:
; 1. The first replay of each corpus found real bugs, fixed with it: one prediction
;    was budgeted five tokens more than on macOS and Linux, an invalid count was
;    silently read as one, the empty map wrote "v1:W10=" and not the neutral value,
;    unnormalised application keys were admitted and legacy pairs were read.
; 2. A native separator owns no submenu, so the corpus row where one does is not
;    representable here; it is named and skipped, never replayed as something else.
; ==============================================================================

#Requires AutoHotkey v2.0



_CTSF_Read(Relative) {
	return JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\" . Relative, "UTF-8"))
}

_CTSF_Map(Value) {
	return Value is Map ? Value : Map()
}

_CTSF_AppOverridesCounts() {
	Corpus := _CTSF_Read("llm\app_profile_overrides_vectors.json")
	AssertEqual(9, Corpus["normalize"].Length, "the normalize vectors changed")
	AssertEqual(6, Corpus["resolve"].Length, "the resolve vectors changed")
	AssertEqual(13, Corpus["decode"].Length, "the decode vectors changed")
	AssertEqual(3, Corpus["encode"].Length, "the encode vectors changed")
}

_CTSF_AppOverridesNormalize() {
	for Vector in _CTSF_Read("llm\app_profile_overrides_vectors.json")["normalize"] {
		Expected := Vector["expected"]
		AssertEqual(Expected is String ? Expected : "", LLM_AppIdentity_Normalize(Vector["input"]), Vector["input"])
	}
}

; The lookup the engine runs on the focused application.
_CTSF_AppOverridesResolve(Vector) {
	AssertEqual(Vector["expected"], LLM_AppProfile_Resolve(_CTSF_Map(Vector["overrides"]), Vector["app"], Vector["default"]), Vector["id"])
}

_CTSF_AppOverridesDecode(Vector) {
	Decoded := _LLM_Menu_DeserializeAppProfileOverrides(Vector["payload"])
	if Vector.Has("refused") {
		AssertEqual(false, Decoded, Vector["id"])
		return
	}
	Assert(Decoded is Map, Vector["id"] . " decodes")
	Expected := _CTSF_Map(Vector["expected"])
	AssertEqual(Expected.Count, Decoded.Count, Vector["id"])
	for App, Profile in Expected
		AssertEqual(Profile, Decoded[App], Vector["id"])
}

_CTSF_AppOverridesEncode(Vector) {
	AssertEqual(Vector["expected"], _LLM_Menu_SerializeAppProfileOverrides(_CTSF_Map(Vector["overrides"])), Vector["id"])
}

_CTSF_TokenBudget() {
	Vectors := _CTSF_Read("llm\request_plan_token_budget_vectors.json")["vectors"]
	AssertEqual(8, Vectors.Length, "the token budget vectors changed")
	Replayed := 0
	for Vector in Vectors {
		Replayed += 1
		Budget := _CTSF_TokenBudgetOf.Bind(Vector)
		if Vector.Has("expect_error") {
			Message := ""
			try Budget.Call()
			catch as Err
				Message := Err.Message
			AssertContains(Message, Vector["expect_error"], Vector["id"])
		} else {
			AssertEqual(Vector["expect"], Budget.Call(), Vector["id"])
		}
	}
	AssertEqual(8, Replayed, "every corpus row has a Windows owner")
}

_CTSF_TokenBudgetOf(Vector) {
	if !Vector.Has("retry")
		return _LLM_Engine_CallTokenBudget(Vector["base_tokens"], Vector["per_call"])
	Retry := Vector["retry"]
	return _LLM_Engine_RetryTokenBudget(Retry["call_tokens"], Retry["extra_tokens"])
}

; Builds one real popup from corpus rows. A plain string is a row named after itself.
_CTSF_BuildMenu(Rows) {
	Built := Menu()
	Subs := Map()
	for Row in Rows {
		Title := Row is Map ? Row["title"] : Row
		if Title == "-" {
			Built.Add()
			continue
		}
		if Row is Map && Row.Has("menu") {
			Child := _CTSF_BuildMenu(Row["menu"])
			Built.Add(Title, Child.Menu)
			Subs[Title] := Child
			continue
		}
		Built.Add(Title, (*) => 0)
	}
	_MR_NormalizeSeparators(Built)
	return { Menu: Built, Subs: Subs }
}

; What a native popup holds now, in the corpus's own shape.
_CTSF_ReadMenu(Built) {
	Rows := []
	Count := TrayMenuItemCount(Built.Menu)
	Buffer_ := Buffer(1024)
	loop Count {
		Position := A_Index - 1
		if TrayMenuIsSeparatorAt(Built.Menu, Position) {
			Rows.Push("-")
			continue
		}
		DllCall("GetMenuStringW", "Ptr", Built.Menu.Handle, "UInt", Position, "Ptr", Buffer_, "Int", 512, "UInt", 0x400)
		Title := StrGet(Buffer_, "UTF-16")
		if Built.Subs.Has(Title)
			Rows.Push(Map("title", Title, "menu", _CTSF_ReadMenu(Built.Subs[Title])))
		else
			Rows.Push(Title)
	}
	return Rows
}

_CTSF_Shape(Rows) {
	Text := "["
	for Row in Rows {
		if Row is Map
			Text .= Row.Has("menu") ? Row["title"] . _CTSF_Shape(Row["menu"]) . "," : Row["title"] . ","
		else
			Text .= Row . ","
	}
	return Text . "]"
}

_CTSF_Separators(Vector) {
	AssertEqual(_CTSF_Shape(Vector["expected"]), _CTSF_Shape(_CTSF_ReadMenu(_CTSF_BuildMenu(Vector["input"]))), Vector["name"])
}

_CTSF_Register() {
	Overrides := _CTSF_Read("llm\app_profile_overrides_vectors.json")
	Test("corpus app profile overrides: the counts are current", _CTSF_AppOverridesCounts)
	Test("corpus app profile overrides: normalize", _CTSF_AppOverridesNormalize)
	for Vector in Overrides["resolve"]
		Test("corpus app profile overrides: resolve " . Vector["id"], _CTSF_AppOverridesResolve.Bind(Vector))
	for Vector in Overrides["decode"]
		Test("corpus app profile overrides: decode " . Vector["id"], _CTSF_AppOverridesDecode.Bind(Vector))
	for Vector in Overrides["encode"]
		Test("corpus app profile overrides: encode " . Vector["id"], _CTSF_AppOverridesEncode.Bind(Vector))
	Test("corpus token budget: every row with a Windows owner", _CTSF_TokenBudget)
	Replayed := 0
	for Vector in _CTSF_Read("menus\separator_normalization_vectors.json")["vectors"] {
		if Vector["name"] == "a separator row owning a menu is still a separator"
			continue
		Replayed += 1
		Test("corpus separators: " . Vector["name"], _CTSF_Separators.Bind(Vector))
	}
	if Replayed != 11
		throw Error("The separator corpus changed: " . Replayed . " rows replayed.")
}
_CTSF_Register()
