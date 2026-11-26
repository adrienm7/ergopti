; tests/unit/ai/profiles/test_prompt_editor_save_vectors.ahk

; ==============================================================================
; MODULE: Prompt Editor Save Vectors (PCK-20)
; DESCRIPTION:
; Windows trimmed the prompt it saved where macOS and Linux keep it byte for
; byte, trimmed only spaces and tabs from the name where Lua trims every %s
; character, and dropped an unknown page action without a log line where Linux
; logged it. The shared corpus prompt_editor_save_vectors.json is replayed here
; through the real save reader and the real page message entry.
; ==============================================================================

#Requires AutoHotkey v2.0

class _PESV_Args {
	__New(Json) {
		this.Json := Json
	}
	TryGetWebMessageAsString() => this.Json
}

_PESV_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\prompt_editor_save_vectors.json", "UTF-8"))
}

_PESV_SaveVectors() {
	Vectors := _PESV_Corpus()["save"]
	AssertTrue(Vectors.Length >= 10, "the corpus carries its save vectors")
	for Vector in Vectors {
		Id := Vector["id"]
		Accepted := _PromptEdWeb_ReadSavePayload(Vector["payload"], &Name, &Batch, &Prompt)
		AssertEqual(Vector["accepted"] ? 1 : 0, Accepted ? 1 : 0, "pck-20 " . Id . ": admission")
		if !Vector["accepted"]
			continue
		AssertEqual(Vector["name"], Name, "pck-20 " . Id . ": the name")
		AssertEqual(Vector["prompt"], Prompt, "pck-20 " . Id . ": the prompt is kept byte for byte")
		AssertEqual(Vector["batch"] ? 1 : 0, Batch ? 1 : 0, "pck-20 " . Id . ": batch")
	}
}
Test("prompt editor: the shared save vectors, as macOS and Linux read them (pck-20)", _PESV_SaveVectors)

_PESV_WarningCount(Action) {
	Count := 0
	for Line in LoggerRingBufferSnapshot()
		if InStr(Line, "[WARNING]") && InStr(Line, "unknown prompt editor action '" . Action . "'")
			Count += 1
	return Count
}

_PESV_UnknownActionsAreLogged() {
	global _PromptEdWeb_DeferHook
	Saved := _PromptEdWeb_DeferHook
	Deferred := []
	_PromptEdWeb_DeferHook := (Callback) => Deferred.Push(Callback)
	try {
		for Action in _PESV_Corpus()["unknown_actions"]["actions"] {
			Before := _PESV_WarningCount(Action)
			_PromptEdWeb_OnWebMessage(0, _PESV_Args('{"action":' . JsonStringLiteral(Action)
				. ',"edit_id":"pck20","epoch":1,"name":"A","prompt":"x","batch":false}'))
			AssertEqual(Before + 1, _PESV_WarningCount(Action), "pck-20: an unknown action is logged once: " . Action)
		}
		AssertEqual(0, Deferred.Length, "an unknown action schedules nothing")
	} finally _PromptEdWeb_DeferHook := Saved
}
Test("prompt editor: an unknown page action is logged, as on macOS and Linux (pck-20)", _PESV_UnknownActionsAreLogged)
