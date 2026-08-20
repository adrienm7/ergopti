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
	Assert(InStr(Candidate, 'Candidate["user_profiles"].RemoveAt(Index)') > 0,
		"the detached candidate must remove the selected user profile")
	Assert(InStr(Candidate, 'Candidate["profile_id"] := "basic"') > 0,
		"deleting the active profile must select a valid built-in fallback")
	Assert(InStr(Publisher, "LLM_Menu_BindProfileHotkeys") > 0,
		"only the committed publisher may re-bind profile hotkeys")
}

Test("LLMTray: profiles can be deleted", _TPD_Check)
