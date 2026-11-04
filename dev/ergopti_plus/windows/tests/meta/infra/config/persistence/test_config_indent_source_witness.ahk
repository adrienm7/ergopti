; tests/meta/infra/config/persistence/test_config_indent_source_witness.ahk

; ==============================================================================
; MODULE: Indentation Native Source Witness Guard
; DESCRIPTION:
; The real writer's exact source and presence must reach both native branches.
; Mutations alter actual production facts, without weakening its ACK census.
; ==============================================================================

#Requires AutoHotkey v2.0

_CPC_IndentSourceBound(Body) {
	Read := InStr(Body, 'Content := FSReadUtf8Exact(Path)')
	if !Read
		return false
	Guard := InStr(Body, 'if !(Content is String) || !_LLM_Menu_EnableSourceMatches(Expected["source"], _LLM_Menu_EnableReadSource())', true, Read)
	if !Guard
		return false
	Refusal := InStr(Body, "return false", true, Guard)
	Call := InStr(Body, 'return HasMethod(WriterFn, "Call") ? WriterFn.Call(Path, Owned, Content, 1) : TOML_ConfigBatchWrite(Path, Owned, [], 0, Content, 1)')
	return Read > 0 && Guard > Read && Refusal > Guard && Call > Refusal
}

_CPC_IndentSourceWitness() {
	Body := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_IndentWrite"))
	AssertTrue(Body != "", "the actual native indentation writer must exist")
	AssertTrue(_CPC_IndentSourceBound(Body), "both actual terminal branches retain the admitted exact source")
	AssertFalse(_CPC_IndentSourceBound(""), "a missing first link is a refusal, not an invalid search offset")
	AssertFalse(_CPC_IndentSourceBound('Content := FSReadUtf8Exact(Path)'), "a truncated chain is refused before its dependent search")
	Mutations := [
		['Content := FSReadUtf8Exact(Path)', 'Content := ""'],
		['!(Content is String)', 'false'],
		['if !(Content is String) || !_LLM_Menu_EnableSourceMatches(Expected["source"], _LLM_Menu_EnableReadSource())', 'if !(Content is String)'],
		['WriterFn.Call(Path, Owned, Content, 1)', 'WriterFn.Call(Path, Owned)'],
		['TOML_ConfigBatchWrite(Path, Owned, [], 0, Content, 1)', 'TOML_ConfigBatchWrite(Path, Owned)'],
		['TOML_ConfigBatchWrite(Path, Owned, [], 0, Content, 1)', 'TOML_ConfigBatchWrite(Path, Owned, [], 0, Content, 0)']]
	for Mutation in Mutations {
		Changed := StrReplace(Body, Mutation[1], Mutation[2], true, &Count)
		AssertEqual(1, Count, "each negative control changes one real production fact")
		AssertTrue(Changed != Body, "a stale mutation cannot receive test credit")
		AssertFalse(_CPC_IndentSourceBound(Changed), "withdrawing any link cannot authorize the native source witness")
	}
}
Test("AHK-15-persistence: indentation retains its exact source at both terminal branches (llm-indent-source-witness)",
	_CPC_IndentSourceWitness)
