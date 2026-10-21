; tests/unit/modules/llm/profiles/test_llm_profile_opening_image.ahk

; ==============================================================================
; MODULE: LLM profile opening-image regression tests
; DESCRIPTION:
; Retains real READY configuration images across native modal ports and the actual
; WebView save context. The production profile collector, codec and borrowed
; native writer preserve another profile edited before the old action returns.
; ==============================================================================

#Requires AutoHotkey v2.0

_PFI_Profile(Id, Prompt) {
	return Map("id", Id, "label", Id, "system_single", Prompt,
		"system_multi", "", "batch", false)
}

_PFI_External(State) {
	External := LLM_Menu_DeepClone(State.InitialProfiles)
	External[2]["system_single"] := "external-b-must-survive"
	Built := TOML_BuildConfigUpdatedContent(State.World.ConfigPath,
		[{ Section: "llm", Key: "user_profiles", Value: _LLM_Menu_SerializeUserProfiles(External) }])
	AssertTrue(Built is Map && Built.Get("status", "") == "ok")
	State.ExternalImage := Built["content"]
	AssertTrue(StrCompare(State.ExternalImage, State.InitialImage, true) != 0,
		"The real external write must change the profile payload.")
	AssertTrue(FSWriteDurable(State.World.ConfigPath, State.ExternalImage))
	AssertTrue(ConfigFullStateCanPersist(), "The actual READY schema admits this external current document.")
}

_PFI_Input(State, Prompt, Title, Options, Default := "") {
	State.Inputs += 1
	AssertTrue(Prompt != "" && Title != "", "The native fallback must reach actual localized input boundaries.")
	if InStr(State.Mode, "external") && State.Inputs == 1 && State.ExternalImage == ""
		_PFI_External(State)
	if InStr(State.Mode, "cancel")
		return { Result: "Cancel", Value: "never saved" }
	return { Result: "OK", Value: State.Inputs == 1 ? "Edited A" : "edited-a" }
}

_PFI_Confirm(State, Body, Title, Options) {
	State.Confirms += 1
	AssertTrue(Body != "" && Title != "", "The actual management dialog must identify its profile action.")
	if InStr(State.Mode, "external") && State.Confirms == 1
		_PFI_External(State)
	if State.Confirms == 1 {
		AssertEqual("3 32", Options)
		if InStr(State.Mode, "chooser-edit")
			return "No"
		return InStr(State.Mode, "use") ? "Yes" : "Cancel"
	}
	AssertEqual("4 48", Options, "Removal requires the real second Yes/No confirmation.")
	return InStr(State.Mode, "cancel") ? "No" : "Yes"
}

_PFI_Collect(State, CandidateFeatures, CandidateMenu) {
	State.Collects += 1
	Updates := []
	AssertTrue(_LLM_Menu_AppendPersistedUpdates(Updates, CandidateMenu),
		"The real collector must serialize profile and sibling LLM preferences.")
	ProfileRows := 0
	for Row in Updates {
		if Row.Section == "llm" && Row.Key == "user_profiles" {
			ProfileRows += 1
			Decoded := _LLM_Menu_DeserializeUserProfiles(Row.Value)
			AssertTrue(Decoded is Array, "The production v1/Base64 codec must own the profile projection.")
		}
	}
	AssertEqual(1, ProfileRows, "Exactly one genuine whole-profile-array effect must reach the native writer.")
	if InStr(State.Mode, "late-write")
		_PFI_External(State)
	return Updates
}

_PFI_Notify(State, Message, Options) {
	State.Notices.Push(Message)
	return true
}

_PFI_Run(Mode) {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner, _VendorDir
	global _PromptEdWeb_OpeningSource, _PromptEdWeb_PersistHook, _PromptEdWeb_ResetDone
	PreviousContext := _PEC_InstallFixture()
	World := 0
	PreviousCritical := Critical("On")
	WasSuspended := A_IsSuspended
	SavedHotkeys := _LLM_Menu_ProfileHotkeyOwner
	SavedVendor := _VendorDir
	SavedReset := _PromptEdWeb_ResetDone
	State := { Mode: Mode, World: 0, Inputs: 0, Confirms: 0, Collects: 0,
		Notices: [], InitialProfiles: 0, InitialImage: "", ExternalImage: "" }
	try {
		Suspend(false)
		World := _LSP_World()
		State.World := World
		_LLM_Menu_ProfileHotkeyOwner := 0
		; Genuine missing loader forces the actual native fallback without replacing TryOpen.
		_VendorDir := World.ConfigPath . "-no-webview-loader"
		Profiles := [_PFI_Profile("user_profile_a", "original-a"), _PFI_Profile("user_profile_b", "original-b")]
		AssertTrue(TOML_ConfigBatchWrite(World.ConfigPath,
			[{ Section: "llm", Key: "user_profiles", Value: _LLM_Menu_SerializeUserProfiles(Profiles) }]))
		_LLM_Menu["user_profiles"] := Profiles
		_LLM_Menu["profile_id"] := "user_profile_a"
		_LLM_Menu["enabled"] := false
		State.InitialProfiles := LLM_Menu_DeepClone(Profiles)
		State.InitialImage := FSReadUtf8Exact(World.ConfigPath)
		MenuBefore := _LLM_Menu
		Port := Map("input", _PFI_Input.Bind(State), "confirm", _PFI_Confirm.Bind(State),
			"notify", _PFI_Notify.Bind(State), "collect", _PFI_Collect.Bind(State),
			"apply", ObjBindMethod(World, "ApplyCommitted"), "acquire", _LMT_Acquire, "settle", _LMT_Settle)
		Result := false
		if SubStr(Mode, 1, 4) == "web-" {
			_PromptEdWeb_PersistHook := 0
			Source := _LLM_Menu_CaptureProfileSource()
			AssertTrue(Source is Map)
			Context := _PromptEdWeb_BeginContext(Profiles[1], Source)
			AssertTrue(IsObject(Context), "The real WebView context must own the exact opening file.")
			AssertTrue(_PromptEdWeb_OpeningSource == Source)
			if Mode == "web-external"
				_PFI_External(State)
			if Mode == "web-successor" {
				Expected := { Serial: Context.Epoch, Epoch: Context.Epoch }
				NewSource := _LLM_Menu_CaptureProfileSource()
				AssertTrue(NewSource is Map && NewSource != Source)
				NewContext := _PromptEdWeb_BeginContext(Profiles[2], NewSource)
				AssertFalse(_PromptEdWeb_BeginContext(Profiles[1], Source, Expected),
					"An old opening continuation cannot replace a source attached to a newer editor epoch.")
				AssertTrue(_PromptEdWeb_IsCurrentContext(NewContext.EditId, NewContext.Epoch))
				AssertTrue(_PromptEdWeb_OpeningSource == NewSource)
				Result := _PromptEdWeb_PersistProfile(Context.EditId, Context.Epoch, "Edited A", false, "edited-a", Port)
			} else if Mode == "web-no-source" {
				Context := _PromptEdWeb_BeginContext(Profiles[1])
				Result := _PromptEdWeb_PersistProfile(Context.EditId, Context.Epoch, "Edited A", false, "edited-a", Port)
			} else
				Result := _PromptEdWeb_PersistProfile(Context.EditId, Context.Epoch, "Edited A", false, "edited-a", Port)
		} else if SubStr(Mode, 1, 7) == "create-"
			Result := LLM_Menu_PromptCreateProfile(Port)
		else if SubStr(Mode, 1, 5) == "edit-"
			Result := LLM_Menu_PromptEditProfile(Profiles[1], Port)
		else
			Result := LLM_Menu_OnUserProfileClick(Profiles[1], Port)
		Accepted := Mode == "edit-current" || Mode == "create-current" || Mode == "delete-current"
			|| Mode == "web-current" || Mode == "use-current"
		Cancelled := InStr(Mode, "cancel") > 0
		AssertEqual(Accepted, World.ApplyCalls, "Only an owned accepted image may publish the real profile action.")
		HandledChooser := InStr(Mode, "chooser-edit") || InStr(Mode, "use")
		if HandledChooser
			AssertTrue(Result, "Use and Edit keep the management dialog's existing handled-result contract.")
		else if !Cancelled
			AssertEqual(Accepted, !!Result, "A stale opening source cannot be reported as a saved profile.")
		Actual := FSReadUtf8Exact(World.ConfigPath)
		if !Accepted {
			AssertEqual(State.ExternalImage != "" ? State.ExternalImage : State.InitialImage, Actual,
				"Refusal or cancellation must preserve the actual externally edited image byte for byte.")
			AssertTrue(_LLM_Menu == MenuBefore)
			AssertTrue(ManifestValuesEqual(State.InitialProfiles, _LLM_Menu["user_profiles"]),
				"A refused detached profile edit cannot mutate the original live models.")
		} else {
			Snapshot := TOML_ParseFreshFileTyped(World.ConfigPath)
			Saved := _LLM_Menu_DeserializeUserProfiles(Snapshot["llm"]["user_profiles"])
			AssertTrue(Saved is Array, "The real stored v1/Base64 payload must decode through its production owner.")
			ExpectedCount := Mode == "create-current" ? 3 : (Mode == "delete-current" ? 1 : 2)
			AssertEqual(ExpectedCount, Saved.Length)
			Sibling := Mode == "delete-current" ? Saved[1] : Saved[2]
			AssertEqual("user_profile_b", Sibling["id"])
			AssertEqual("original-b", Sibling["system_single"], "Successful edits preserve the independent sibling profile.")
			if Mode == "edit-current" || Mode == "web-current" {
				AssertEqual("edited-a", Saved[1]["system_single"])
				AssertEqual("Edited A", Saved[1]["label"])
			}
		}
		if SubStr(Mode, 1, 5) == "edit-" || SubStr(Mode, 1, 7) == "create-"
			AssertEqual(Cancelled ? 1 : 2, State.Inputs, "Both actual fallback inputs must be exercised except ordinary cancellation.")
		if InStr(Mode, "delete")
			AssertEqual(2, State.Confirms, "Removal must exercise both real confirmation callbacks.")
		if InStr(Mode, "chooser-edit") {
			AssertEqual(1, State.Confirms)
			AssertEqual(2, State.Inputs, "The chooser must carry its original image into the subsequent editor.")
		}
		if !Cancelled && Mode != "web-successor"
			AssertEqual(1, State.Collects, "The actual profile collector must run before native image refusal.")
		AssertFalse(_ConfigWriteTerminalIsActive(), "Every path must release its exact borrowed configuration lease.")
	} finally {
		try {
			if World is _LSP_World
				World.Restore()
		} finally {
			_PEC_RestoreFixture(PreviousContext)
			_PromptEdWeb_ResetDone := SavedReset
			_LLM_Menu_ProfileHotkeyOwner := SavedHotkeys
			_VendorDir := SavedVendor
			State.World := 0
			Suspend(WasSuspended)
			Critical(PreviousCritical)
		}
	}
}
for _PFI_Mode in ["edit-current", "edit-external", "edit-cancel", "edit-late-write",
		"create-current", "create-external", "create-cancel", "delete-current", "delete-external", "delete-cancel",
		"chooser-edit-external", "use-current", "use-external", "web-current", "web-external", "web-late-write", "web-successor", "web-no-source"]
	Test("LLM profile opening image: " . _PFI_Mode . " (llm-profile-opening-image)", _PFI_Run.Bind(_PFI_Mode))

_PFI_ColdProfilePolicy() {
	global LLM_PROFILE_ADVANCED_PARAMS_B, LLM_PROFILE_BATCH_PARAMS_B
	global _LLM_PresetsCache, _LLM_IndexCache
	AssertTrue(IsSet(LLM_PROFILE_ADVANCED_PARAMS_B) && IsSet(LLM_PROFILE_BATCH_PARAMS_B),
		"The definitions-only profile policy must initialize both thresholds without menu startup.")
	AssertTrue(LLM_PROFILE_ADVANCED_PARAMS_B is Float && LLM_PROFILE_BATCH_PARAMS_B is Float)
	AssertEqual(2.0, LLM_PROFILE_ADVANCED_PARAMS_B)
	AssertEqual(4.0, LLM_PROFILE_BATCH_PARAMS_B)
	HadPresets := IsSet(_LLM_PresetsCache)
	Presets := HadPresets ? _LLM_PresetsCache : 0
	HadIndex := IsSet(_LLM_IndexCache)
	Index := HadIndex ? _LLM_IndexCache : 0
	try {
		Model := "__ergopti_profile_policy_composition_unknown__"
		Models := LLM_GetModelIndex()
		AssertTrue(Models is Map && !Models.Has(Model), "The real catalogue must admit the unknown-model policy branch.")
		Info := LLM_GetModelInfo(Model)
		AssertEqual("chat", Info["type"])
		AssertEqual(0.0, Info["params_b"])
		AssertEqual("basic", LLM_RecommendProfileForModel(Model),
			"A real nonempty model recommendation must consume the policy before menu startup.")
	} finally {
		_LLM_PresetsCache := HadPresets ? Presets : unset
		_LLM_IndexCache := HadIndex ? Index : unset
	}
}
Test("LLM profile policy: cold recommendation is composed before menu startup (llm-profile-policy-composition)",
	_PFI_ColdProfilePolicy)
