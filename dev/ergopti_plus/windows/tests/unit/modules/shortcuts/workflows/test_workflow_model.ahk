; tests/unit/modules/shortcuts/workflows/test_workflow_model.ahk

; ==============================================================================
; MODULE: User Workflow Model and Interpreter (Windows port)
; DESCRIPTION:
; Replays _shared/tests/corpus/workflows/validation_vectors.json and
; interpreter_vectors.json, which the canonical JS check and the macOS and
; Linux suites replay (_shared/tests/lua/workflows/), through the AutoHotkey
; port modules/shortcuts/workflows/model.ahk: the first refusal of a file with
; its reason and JSON Pointer. Also pins the placeholder expansion, the shell
; digest and the lossless decode the model reads files with. The interpreter
; vectors are test_workflow_interpreter.ahk.
;
; ROOT CAUSE ENCODED:
; Windows could not read a user workflow: a hand-written check would accept a
; file the editor refuses (a boolean read as the integer 1) or refuse one it
; accepts, at another JSON Pointer.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus helpers ==================
; ============================================
; ============================================

; @returns {Map} One shared JSON file, decoded lossless or plain.
_TWFM_Shared(Relative, Lossless) {
	global _SharedDir
	AssertTrue(IsSet(_SharedDir), "the harness must expose _SharedDir")
	Path := _SharedDir . "\" . Relative
	AssertTrue(FileExist(Path) != "", "the shared file must exist at " . Path)
	Text := FileRead(Path, "UTF-8")
	return Lossless ? JsonParseLossless(Text) : JsonParse(Text)
}

_TWFM_Catalogue() {
	static Catalogue := 0
	if !IsObject(Catalogue)
		Catalogue := _TWFM_Shared(WorkflowCataloguePath(), false)
	return Catalogue
}

; A copy of the catalogue with a vector's limits merged over its own.
_TWFM_WithLimits(Catalogue, Limits) {
	if !(Limits is Map)
		return Catalogue
	Copy := Catalogue.Clone()
	Copy["limits"] := Catalogue["limits"].Clone()
	for Key, Value in Limits
		Copy["limits"][Key] := Value
	return Copy
}

; Deep equality across the lossless and plain decodes: same type, same value.
_TWFM_Equal(Expected, Actual) {
	if Expected is Map {
		if !(Actual is Map) || Actual.Count != Expected.Count
			return false
		for Key, Value in Expected
			if !Actual.Has(Key) || !_TWFM_Equal(Value, Actual[Key])
				return false
		return true
	}
	if Expected is Array {
		if !(Actual is Array) || Actual.Length != Expected.Length
			return false
		for Index, Value in Expected
			if !_TWFM_Equal(Value, Actual[Index])
				return false
		return true
	}
	if Expected is String
		return (Actual is String) && Actual == Expected
	if Expected is Number
		return (Actual is Number) && Actual == Expected
	return IsObject(Actual) && ObjPtr(Actual) == ObjPtr(Expected)
}

; The JSON of a value, for a failure message.
_TWFM_Show(Value) {
	try return WorkflowJsonEncode(Value)
	catch
		return Type(Value)
}

; A lossless answer as the drivers' ports give it: true and false are booleans.
_TWFM_Plain(Value) {
	global JSON_TRUE, JSON_FALSE
	if IsObject(Value) && Value == JSON_TRUE
		return true
	if IsObject(Value) && Value == JSON_FALSE
		return false
	return Value
}

; Replaces the "@digest" token by the workflow's own digest, deeply.
_TWFM_Resolve(Value, Digest) {
	if (Value is String) && Value == "@digest"
		return Digest
	if Value is Map {
		Out := Map()
		for Key, Item in Value
			Out[Key] := _TWFM_Resolve(Item, Digest)
		return Out
	}
	return Value
}




; ============================================
; ============================================
; ======= 2/ Validation vectors ==============
; ============================================
; ============================================

_TWFM_ValidationVectors() {
	Catalogue := _TWFM_Catalogue()
	Corpus := _TWFM_Shared("tests\corpus\workflows\validation_vectors.json", true)
	Timings := Map("wait_max_ms", Corpus["timings"]["wait_max_ms"])
	Count := 0
	for Vector in Corpus["vectors"] {
		Count += 1
		Result := WorkflowValidateFile(Vector["doc"], _TWFM_WithLimits(Catalogue, Vector.Get("limits", 0)), Timings)
		Expected := Vector["expected"]
		Label := Vector["id"] . ": expected " . _TWFM_Show(Expected) . ", got " . _TWFM_Show(Result)
		AssertEqual(_TWFM_Plain(Expected["ok"]) ? 1 : 0, Result["ok"] ? 1 : 0, Label)
		if !Result["ok"] {
			AssertEqual(Expected["reason"], Result["reason"], Label)
			AssertEqual(Expected["path"], Result["path"], Label)
		}
	}
	AssertTrue(Count >= 90, "the validation corpus lost its vectors: " . Count)
}
Test("workflows: the validation vectors replay through the Windows model (workflow-model)", _TWFM_ValidationVectors)

_TWFM_CatalogueGuard() {
	Altered := _TWFM_Catalogue().Clone()
	Altered["identifier_pattern"] := "^[a-z]+$"
	AssertThrows(() => WorkflowValidateFile(Map(), Altered, Map("wait_max_ms", 1)),
		"a changed catalogue pattern must refuse the port, not run a stale one")
}
Test("workflows: a catalogue whose patterns changed refuses the Windows port (workflow-model)", _TWFM_CatalogueGuard)




; ============================================
; ============================================
; ======= 3/ Placeholders and digest =========
; ============================================
; ============================================

_TWFM_Placeholders() {
	AssertEqual("Hi Ada!", WorkflowExpand("Hi {{who}}!", Map("who", "Ada")), "a known variable expands")
	Missing := ""
	AssertEqual(0, WorkflowExpand("{{who}} {{what}}", Map("who", "Ada"), &Missing), "an unknown variable stops")
	AssertEqual("what", Missing, "the unknown variable is named")
	AssertEqual("{{ x }} {{}} {{1a}} {{a", WorkflowExpand("{{ x }} {{}} {{1a}} {{a", Map()),
		"braces that name no identifier stay text")
	AssertEqual("{{b}}", WorkflowExpand("{{a}}", Map("a", "{{b}}")), "a placeholder value is not expanded again")
}
Test("workflows: placeholders expand once and name an unknown variable (workflow-model)", _TWFM_Placeholders)

_TWFM_Digest() {
	Workflow := Map("id", "wf_1", "steps", [
		Map("kind", "shell", "command", "echo a"),
		Map("kind", "if", "condition", Map(), "then", [Map("kind", "shell", "command", "echo b")],
			"else", [Map("kind", "repeat", "count", 1, "steps", [Map("kind", "shell", "command", "echo c")])])])
	; SHA-256 of "wf_1\0echo a\0echo b\0echo c", computed outside AutoHotkey.
	Digest := WorkflowShellDigest(Workflow)
	AssertEqual("bea4b172dfa73a360d70b89882babf4ed45a0bde2773489e4dfc8366658a71c7", Digest,
		"the shell digest covers the id and every command in order, NUL-separated")
	Workflow["steps"][1]["command"] := "echo A"
	AssertTrue(WorkflowShellDigest(Workflow) != Digest, "an edited command needs a new approval")
	AssertEqual("", WorkflowShellDigest(Map("id", "wf_1", "steps", [Map("kind", "wait", "duration_ms", 1)])),
		"a workflow without a shell step has no digest")
}
Test("workflows: the shell digest covers the id and every command (workflow-model)", _TWFM_Digest)

_TWFM_LosslessDecode() {
	global JSON_TRUE, JSON_FALSE, JSON_NULL
	Doc := JsonParseLossless('{"a":true,"b":false,"c":null,"d":1,"e":{},"f":[]}')
	AssertTrue(Doc["a"] == JSON_TRUE && Doc["b"] == JSON_FALSE && Doc["c"] == JSON_NULL,
		"true, false and null decode to their sentinels")
	AssertTrue((Doc["d"] is Integer) && (Doc["e"] is Map) && (Doc["f"] is Array), "numbers and containers stay apart")
	AssertEqual('{"a":true,"b":false,"c":null,"d":1,"e":{},"f":[]}', WorkflowJsonEncode(Doc),
		"the workflow writer round-trips a lossless document")
}
Test("workflows: a lossless decode keeps a boolean apart from a number (workflow-model)", _TWFM_LosslessDecode)
