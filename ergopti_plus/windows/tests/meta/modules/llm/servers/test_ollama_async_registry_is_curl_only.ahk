; tests/meta/modules/llm/servers/test_ollama_async_registry_is_curl_only.ahk

; ==============================================================================
; MODULE: Regression - the Ollama async registry is a curl registry
;         (ollama-dead-winhttp-branch)
; DESCRIPTION:
; ROOT CAUSE ENCODED:
; The Ollama backend carried a whole WinHTTP generation path that could never
; run. LLM_OllamaCancelAsync had no production caller, _LLM_Ollama_PollRequest
; was never armed by anything except itself, and both branched on
; entry.Has("http") - a key the live curl creation site never wrote, because
; the supported transport is a
; curl child identified by its pid. The branch read as a supported path, the
; poll re-armed itself so a "who calls this?" search found a caller, and the only
; test that touched the shape fabricated an "http" key of its own. Three
; independent reasons for dead code to look alive.
;
; The guards below encode the two properties that make that impossible to
; recreate, and both DERIVE their subject from the driver source:
;   1. The entry shape is CLOSED - every key any code reads off a registry entry
;      must be a key the single creation site writes. A branch on a key nobody
;      writes is dead by construction, whatever it claims to do.
;   2. No private helper of the backend is defined without being referenced from
;      outside its own body. A poll tick that only ever re-arms itself is not
;      armed at all, and reference-counting that ignores self-reference is the
;      only way to see it.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 0/ Source helpers =======
; =================================
; =================================

; Strips full-line ";" comments AND the "/** ... */" docstring lines that
; _StripFullLineComments deliberately leaves whole. A prose mention of a function
; name is not a call site, and telling those two apart is this file's whole job.
_OACR_StripProse(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r")
		if !RegExMatch(Line, "^\s*(;|\*|/\*)")
			Out .= Line . "`n"
	return Out
}

_OACR_OllamaSrc() {
	return _OACR_StripProse(_DriverDirConcat("modules/llm/api_ollama"))
}

_OACR_CountWord(Src, Word) {
	N := 0
	Pos := 1
	while (F := RegExMatch(Src, "\b" . Word . "\b", &M, Pos)) {
		Pos := F + M.Len
		N += 1
	}
	return N
}





; =====================================================
; =====================================================
; ======= 1/ The registry entry shape is closed =======
; =====================================================
; =====================================================

; Collects the keys written by the single creation site, then requires every key
; read off an entry anywhere in the backend to be one of them.
_OACR_RegistryCallback(*) => 0
_OACR_RegistryCurrent(*) => true

; Admission only publishes RAM metadata; restore the live registry before I/O.
_OACR_ActualEntry() {
	global _LLM_Ollama_Async
	Creator := _LLM_Ollama_ReserveAsync
	AssertFalse(Creator.HasOwnProp("Call"), "the entry shape must come from the genuine constructor")
	Temporary := Map()
	Job := Map("req_id", 1, "on_success", _OACR_RegistryCallback, "on_fail", _OACR_RegistryCallback,
		"requester_current", _OACR_RegistryCurrent)
	PreviousCritical := Critical("On")
	try {
		Saved := _LLM_Ollama_Async
		_LLM_Ollama_Async := Temporary
		try Entry := Creator.Call(Job)
		finally _LLM_Ollama_Async := Saved
	} finally Critical(PreviousCritical)
	AssertTrue(_LLM_Ollama_Async == Saved, "metadata inspection restores the exact prior registry")
	AssertTrue(Entry is Map, "the real admission owner creates the registry's map")
	AssertEqual(1, Temporary.Count, "one real admission publishes one entry")
	AssertTrue(Temporary.Has(1) && Temporary[1] == Entry, "the returned shape is the actual published entry")
	AssertTrue(Entry.Count >= 5, "the constructor must publish a recognisable field set")
	return Entry
}

_OACR_RequireClosedShape(Src, Written) {
	AssertTrue(Src != "", "the actual backend source must be readable")
	Code := _DriverMaskNonCode(&Src)
	Publication := "(?i)\b_LLM_Ollama_Async\s*\[[^\]\r\n]+\]\s*:=\s*(\w+)"
	Creations := 0, Position := 1, Published := ""
	while RegExMatch(Code, Publication, &Store, Position) {
		Creations += 1
		Published := Store[1]
		Position := Store.Pos + Store.Len
	}
	AssertEqual(1, Creations, "the registry must have exactly one admission publication")
	Creator := _LLM_Ollama_ReserveAsync
	Body := _DriverExtractFunctionBody(&Code, Creator.Name, 1, true)
	AssertTrue(Body != "", "the genuine admission constructor must be readable")
	RegExReplace(Body, Publication, "", &OwnerStores)
	AssertEqual(1, OwnerStores, "the sole publication belongs to the real constructor")
	RegExReplace(Body, "(?i)\b" . Published . "\s*:=\s*Map\s*\(", "", &Constructors)
	AssertEqual(1, Constructors, "the published value must come from one local map constructor")

	; The canonical mask aligns code positions while field literals stay readable.
	; A comment or quoted example cannot add a registry read or publication.
	Quote := "[\x22\x27]"
	Alias := "\b(?:entry|oldest_entry|" . Published . "|_LLM_Ollama_Async\s*\[[^\]\r\n]+\])"
	Reads := 0
	for Pattern in [
		"(?i)" . Alias . "\s*\.\s*(?:Has|Get)\s*\(\s*" . Quote . "(\w+)" . Quote,
		"(?i)" . Alias . "\s*\[\s*" . Quote . "(\w+)" . Quote . "\s*\]"
	] {
		Position := 1
		while RegExMatch(Src, Pattern, &Read, Position) {
			Position := Read.Pos + Read.Len
			if !RegExMatch(SubStr(Code, Read.Pos, 1), "[A-Za-z_]")
				continue
			Reads += 1
			AssertTrue(Written.Has(Read[1]), "undeclared async registry key: " . Read[1])
		}
	}
	AssertTrue(Reads >= 10, "the key scan must reach the actual entry reads")
}

_OACR_EntryShapeIsClosed() {
	_OACR_RequireClosedShape(_OACR_OllamaSrc(), _OACR_ActualEntry())
}

_OACR_RejectShapeMutation(Expression, Expected) {
	Src := _OACR_OllamaSrc(), Written := _OACR_ActualEntry()
	AssertFalse(Written.Has("__oacr_absent"), "the negative field is genuinely absent")
	if Expression == "duplicate"
		Src .= "`n_LLM_Ollama_Async[other_id] := Other`n"
	else if Expression == "foreign" {
		Src := RegExReplace(Src, "(?i)(_LLM_Ollama_Async\[[^\]\r\n]+\]\s*:=\s*)Entry\b", "$1job", &Changed)
		AssertEqual(1, Changed, "the foreign same-count publication mutation is nonvacuous")
	} else
		Src .= "`n_OACR_SourceFixture(Entry, oldest_entry, id) {`n" . Expression . "`n}`n"
	Rejected := false
	try _OACR_RequireClosedShape(Src, Written)
	catch Error as Failure {
		AssertContains(Failure.Message, Expected, "the exact invariant rejects the source mutation")
		Rejected := true
	}
	AssertTrue(Rejected, "an invalid registry variant cannot pass the shape guard")
}

for _OACR_ReadFixture in [
	["Has", 'entry.Has("__oacr_absent")'],
	["case-insensitive Get", 'ENTRY.Get("__oacr_absent", 0)'],
	["indexed field", 'entry["__oacr_absent"]'],
	["oldest Get", 'oldest_entry.Get("__oacr_absent", 0)'],
	["direct registry Get", '_LLM_Ollama_Async[id].Get("__oacr_absent", 0)']
]
	Test("meta ollama-registry: " . _OACR_ReadFixture[1] . " rejects an undeclared field (ollama-registry-live-shape)",
		_OACR_RejectShapeMutation.Bind(_OACR_ReadFixture[2], "__oacr_absent"))
Test("meta ollama-registry: duplicate publication is rejected (ollama-registry-live-shape)",
	_OACR_RejectShapeMutation.Bind("duplicate", "exactly one admission publication"))
Test("meta ollama-registry: same-count foreign map is rejected (ollama-registry-live-shape)",
	_OACR_RejectShapeMutation.Bind("foreign", "one local map constructor"))

_OACR_QuotedDecoys() {
	Src := _OACR_OllamaSrc()
	Src .= "`n; entry.Get(" . Chr(34) . "__oacr_absent" . Chr(34) . ", 0)`n"
	Src .= Chr(39) . 'ENTRY.Get("__oacr_absent", 0)' . Chr(39) . "`n"
	Src .= Chr(39) . '_LLM_Ollama_Async[other_id] := Other' . Chr(39) . "`n"
	_OACR_RequireClosedShape(Src, _OACR_ActualEntry())
}
Test("meta ollama-registry: comments and quoted decoys confer no authority (ollama-registry-live-shape)", _OACR_QuotedDecoys)





; ====================================================
; ====================================================
; ======= 2/ No helper is only self-referenced =======
; ====================================================
; ====================================================

; Every private helper of the backend must be referenced from OUTSIDE its own
; body. Self-reference does not count: the dead poll re-armed itself through a
; SetTimer closure, which is exactly why a naive reference count said it was live.
_OACR_NoPrivateIsOnlySelfReferenced() {
	Src := _OACR_OllamaSrc()
	Driver := _OACR_StripProse(_DriverSourceConcat())

	Names := []
	Pos := 1
	while (F := RegExMatch(Src, "m)^(_LLM_Ollama_\w+)\([^\r\n]*\)\s*\{", &M, Pos)) {
		Pos := F + M.Len
		Names.Push(M[1])
	}
	Assert(Names.Length >= 20,
		"the scan must find the backend's private helpers (found " . Names.Length . ") - a regex that matches nothing would pass this test without checking anything")

	for _, Name in Names {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must be resolvable in the driver source")
		External := _OACR_CountWord(Driver, Name) - _OACR_CountWord(Body, Name)
		Assert(External >= 1,
			Name . " is defined but never referenced outside its own body - a poll tick whose only caller is its own SetTimer re-arm is never armed at all, and dead code that answers a 'who calls this?' search is the hardest kind to notice")
	}
}


Test("meta ollama-registry: every key read off an async entry is one the creation site writes",
	_OACR_EntryShapeIsClosed)
Test("meta ollama-registry: no private backend helper is only ever self-referenced",
	_OACR_NoPrivateIsOnlySelfReferenced)
