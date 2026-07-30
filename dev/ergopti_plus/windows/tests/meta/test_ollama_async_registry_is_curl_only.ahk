; tests/meta/test_ollama_async_registry_is_curl_only.ahk

; ==============================================================================
; MODULE: Regression - the Ollama async registry is a curl registry
;         (ollama-dead-winhttp-branch)
; DESCRIPTION:
; ROOT CAUSE ENCODED:
; The Ollama backend carried a whole WinHTTP generation path that could never
; run. LLM_OllamaCancelAsync had no production caller, _LLM_Ollama_PollRequest
; was never armed by anything except itself, and both branched on
; entry.Has("http") - a key the ONE site that creates a registry entry
; (_LLM_Ollama_DispatchAsync) has never written, because the live transport is a
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
_OACR_EntryShapeIsClosed() {
	Src := _OACR_OllamaSrc()

	; One creation site is the premise of the whole invariant: it is what lets a
	; written-key set be enumerated at all.
	Creations := 0
	CreationAt := 0
	Pos := 1
	while (F := RegExMatch(Src, "_LLM_Ollama_Async\[\w+\]\s*:=\s*Map\(", &M, Pos)) {
		Pos := F + M.Len
		CreationAt := F + M.Len - 1
		Creations += 1
	}
	Assert(Creations == 1,
		"the async registry must be created at exactly ONE site (found " . Creations . ") - with two shapes in circulation, a branch keyed on the field only one of them writes is dead half the time and nobody can tell which half")

	; Walk to the closing parenthesis of that Map(...) literal so the key scan
	; cannot spill into the next statement.
	Depth := 0
	i := CreationAt
	Len := StrLen(Src)
	End := Len
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "(")
			Depth++
		else if (ch == ")") {
			Depth--
			if (Depth <= 0) {
				End := i
				break
			}
		}
		i++
	}
	Literal := SubStr(Src, CreationAt, End - CreationAt + 1)

	Written := Map()
	Pos := 1
	while (F := RegExMatch(Literal, '"(\w+)"', &M2, Pos)) {
		Pos := F + M2.Len
		Written[M2[1]] := true
	}
	Assert(Written.Count >= 5,
		"the creation site must write a recognisable set of keys (found " . Written.Count . ") - fewer means the literal was not parsed and every check below would pass vacuously")

	Reads := 0
	for _, Pattern in ['(?:entry|oldest_entry)\.Has\("(\w+)"\)',
	                   '(?:entry|oldest_entry)\["(\w+)"\]',
	                   '_LLM_Ollama_Async\[\w+\]\["(\w+)"\]'] {
		Pos := 1
		while (F := RegExMatch(Src, Pattern, &M3, Pos)) {
			Pos := F + M3.Len
			Reads += 1
			Assert(Written.Has(M3[1]),
				"the Ollama backend reads the registry key '" . M3[1] . "', which _LLM_Ollama_DispatchAsync never writes - the branch behind it can never be taken, so it is dead code wearing the costume of a supported transport")
		}
	}
	Assert(Reads >= 10,
		"the key scan must actually reach the entry reads (found " . Reads . ") - a regex that stopped matching would make this guard vacuous")
}





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
