; tests/unit/llm_profiles/test_registry_admission.ahk

; ==============================================================================
; MODULE: LLM Profile Registry Admission
; DESCRIPTION:
; Exercises the real file loader rather than the obsolete regular-expression
; parser. Malformed records must not reach prompt resolution or poison the cache
; ==============================================================================





/** Loads one process-owned registry fixture and always removes its output. */
_LPRA_Load(Text) {
	static Sequence := 0
	Sequence += 1
	Path := A_Temp . "\ergopti-profile-admission-" . DllCall("GetCurrentProcessId")
		. "-" . Sequence . ".json"
	Assert(!FileExist(Path), "the registry fixture must not overwrite another owner")
	try {
		AssertTrue(FSWrite(Path, Text), "the real fixture write must commit")
		return LLM_LoadProfilesJSON(Path)
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

_LPRA_Reject(Text) {
	Profiles := _LPRA_Load(Text)
	Assert(Profiles is Array, "registry rejection must preserve the empty-array contract")
	AssertEqual(0, Profiles.Length, "a malformed registry must not publish any record")
}

for Vector in [
	["single prompt", '[{"id":"basic","system_single":[]}]'],
	["raw prompt", '[{"id":"basic","raw_prompt":{}}]'],
	["multi template", '[{"id":"basic","system_multi_template":[]}]'],
	["legacy multi prompt", '[{"id":"basic","system_multi":false}]'],
	["label", '[{"id":"basic","label":[]}]'],
	["missing id", '[{"system_single":"hello"}]'],
	["numeric id", '[{"id":3,"system_single":"hello"}]'],
	["empty id", '[{"id":"","system_single":"hello"}]'],
	["batch string", '[{"id":"basic","batch":"true"}]'],
	["batch range", '[{"id":"basic","batch":2}]'],
	["stop array", '[{"id":"basic","stop_sequences":"stop"}]'],
	["stop item", '[{"id":"basic","stop_sequences":[{}]}]'],
	["non-record", '[42]'],
	["duplicate id", '[{"id":"basic"},{"id":"basic"}]'],
	["partial admission", '[{"id":"basic","system_single":"hello"},{"id":"bad","raw_prompt":[]}]']
] {
	Test("LLM profile registry-admission: rejects " . Vector[1], _LPRA_Reject.Bind(Vector[2]))
}

_LPRA_ValidRoundtrip() {
	Profiles := _LPRA_Load('[{"id":"basic","label":"Basic","system_single":"hello {language}",'
		. '"system_multi_template":"return {n}","batch":true,"stop_sequences":["]","}","stop"]},'
		. '{"id":"BASIC","raw_prompt":"raw {min_words}"}]')
	AssertEqual(2, Profiles.Length, "distinct case-sensitive IDs must remain distinct")
	AssertEqual("Basic", Profiles[1]["label"])
	AssertTrue(Profiles[1]["batch"])
	AssertEqual(3, Profiles[1]["stop_sequences"].Length)
	AssertEqual("]", Profiles[1]["stop_sequences"][1])
	AssertEqual("}", Profiles[1]["stop_sequences"][2])
	AssertEqual("hello fr", LLM_ResolveSystemPrompt(Profiles[1], 1, 2, 5, "fr"))
	AssertEqual("hello fr`n`nreturn 3", LLM_ResolveSystemPrompt(Profiles[1], 3, 2, 5, "fr"))
	AssertEqual("raw 2", LLM_ResolveSystemPrompt(Profiles[2], 1, 2, 5, "fr"))
}
Test("LLM profile registry-admission: valid fields reach real prompt resolution", _LPRA_ValidRoundtrip)

_LPRA_NullFieldIsAbsent() {
	Profiles := _LPRA_Load('[{"id":"basic","system_single":"hello","system_multi":null}]')
	AssertEqual(1, Profiles.Length, "the shipped registry spells unused prompts as null")
	AssertFalse(Profiles[1].Has("system_multi"), "a null field must not reach consumers as the sentinel")
}
Test("LLM profile registry-admission: a null field is admitted as absent", _LPRA_NullFieldIsAbsent)

_LPRA_ShippedRegistryAdmitted() {
	Profiles := LLM_LoadProfilesJSON()
	AssertTrue(Profiles.Length > 0, "the shipped profiles.json must pass its own admission")
}
Test("LLM profile registry-admission: the shipped registry is admitted", _LPRA_ShippedRegistryAdmitted)
