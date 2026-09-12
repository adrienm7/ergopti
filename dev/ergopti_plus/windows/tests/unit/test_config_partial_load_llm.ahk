; tests/unit/test_config_partial_load_llm.ahk

; ==============================================================================
; MODULE: Partial Configuration Load LLM Tests
; DESCRIPTION:
; Detached LLM transactions must refuse incomplete boot state before invoking
; any admission, quiescence, collection or persistence callback.
; ==============================================================================

#Requires AutoHotkey v2.0

_CPL_LlmRefusesBeforeAdmission(Api, Unreadable) {
	global _ConfigBootRejectedOverrides, _ConfigBootReadFailed
	OldRejected := _ConfigBootRejectedOverrides
	OldReadFailed := _ConfigBootReadFailed
	Previous := _LMT_InstallApiFixture()
	Calls := []
	Probe := (Args*) => (Calls.Push(Args), false)
	try {
		_ConfigBootRejectedOverrides := Unreadable ? 0 : 1
		_ConfigBootReadFailed := Unreadable
		if Api {
			Result := LLM_Menu_CommitApiEntriesMutation("partial boot test",
				Probe, Probe, ConfigTransitionProductionPort(), _LMT_Notify,
				Probe, Probe, Probe, Probe, Probe, Probe)
		} else {
			Result := LLM_Menu_CommitMutation("partial boot test",
				Probe, Probe, Probe, _LMT_Notify, Probe, Probe, Probe, Probe)
		}
		AssertFalse(Result)
		AssertEqual(0, Calls.Length,
			"refusal must precede admission and every user-state operation")
	} finally {
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootReadFailed := OldReadFailed
		_LMT_RestoreApiFixture(Previous)
	}
}
Test("config: LLM full candidate refuses rejected boot state (config-partial-load-llm)",
	_CPL_LlmRefusesBeforeAdmission.Bind(false, false))
Test("config: LLM API candidate refuses rejected boot state (config-partial-load-api)",
	_CPL_LlmRefusesBeforeAdmission.Bind(true, false))
Test("config: LLM full candidate refuses unreadable boot state (config-partial-load-llm-read)",
	_CPL_LlmRefusesBeforeAdmission.Bind(false, true))
Test("config: LLM API candidate refuses unreadable boot state (config-partial-load-api-read)",
	_CPL_LlmRefusesBeforeAdmission.Bind(true, true))
