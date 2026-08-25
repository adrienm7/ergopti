; tests/meta/test_profile_delete_path.ahk

; ==============================================================================
; MODULE: Profile Delete Path Meta Test
; DESCRIPTION:
; Static source guard for the "no-profile-delete-path" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPD_Check() {
	Entry := _DriverFuncBody("LLM_Menu_OnUserProfileClick")
	Candidate := _DriverFuncBody("_LLM_Menu_DeleteProfileCandidate")
	Publisher := _DriverFuncBody("_LLM_Menu_ApplyProfileCommitted")
	Assert(Entry != "" && Candidate != "" && Publisher != "",
		"the profile delete entry, detached mutation, and committed publisher must exist")
	Assert(InStr(Entry, 'choice == "Cancel"') > 0
		&& InStr(Entry, "LLM_Menu_CommitMutation(") > 0
		&& InStr(Entry, "_LLM_Menu_DeleteProfileCandidate") > 0
		&& InStr(Entry, "_LLM_Menu_ApplyProfileCommitted") > 0,
		"confirmed deletion must flow through the shared persist-before-publish transaction")
	CardinalityPos := InStr(Candidate, "if MatchIndex == 0")
	RemovePos := InStr(Candidate, "Profiles.RemoveAt(MatchIndex)")
	CollectPos := InStr(Candidate, "OverrideKeys.Push(AppName)")
	DeletePos := InStr(Candidate, "Overrides.Delete(AppName)")
	Assert(CardinalityPos > 0 && RemovePos > CardinalityPos,
		"the detached candidate must prove one exact profile before removing it")
	Assert(CollectPos > 0 && DeletePos > CollectPos,
		"override keys must be collected before the detached Map is mutated")
	Assert(InStr(Candidate, 'Candidate["profile_id"] := "basic"') > 0,
		"deleting the active profile must select a valid built-in fallback")
	Assert(InStr(Publisher, "LLM_Menu_BindProfileHotkeys") == 0,
		"fixed profile variants must not rebind post-commit")
	Transaction := _DriverFuncBody("_LLM_Menu_CommitMutationNonCritical")
	Callback := _DriverFuncBody("_LLM_Menu_OnProfileHotkey")
	Assert(Transaction != "" && Callback != "",
		"the menu transaction and legacy callback must remain reachable")
	Assert(InStr(Transaction,
		"_LLM_Menu_PrepareProfileOwnerCandidate(CandidateMenu)") > 0
		&& InStr(Transaction,
		"_LLM_Menu_CommitProfileOwnerCandidate(") > 0,
		"profile CRUD must fence native admission before writing and publish it with RAM")
	Assert(InStr(Callback, 'Get("native", false)') > 0
		&& InStr(Callback, "return false") > 0,
		"the legacy callback must remain inert after native profile ownership")
}

Test("LLMTray: profiles can be deleted", _TPD_Check)
