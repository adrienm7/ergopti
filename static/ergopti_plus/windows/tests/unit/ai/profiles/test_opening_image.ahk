; tests/unit/ai/profiles/test_opening_image.ahk

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


_PFI_NativeInputTick(Step) {
	if Step.Submitted || Step.Busy
		return
	Step.Busy := true
	try {
		for Hwnd in WinGetList("ahk_pid " . ProcessExist()) {
			if WinGetTitle("ahk_id " . Hwnd) != Step.Title
				continue
			Step.Hwnd := Hwnd
			EditHwnd := ControlGetHwnd("Edit1", "ahk_id " . Hwnd)
			Step.Multiline := !!(DllCall("User32\GetWindowLongW", "Ptr", EditHwnd, "Int", -16, "UInt") & 4)
			NativeBox := WinGetClass("ahk_id " . Hwnd) == "#32770"
			if Step.Cancel {
				if NativeBox
					PostMessage(0x111, 2, 0, , "ahk_id " . Hwnd)
				else
					PostMessage(0xF5, 0, 0, "Button2", "ahk_id " . Hwnd)
			} else {
				if Step.Label
					ControlSetText("Edited A", "Edit1", "ahk_id " . Hwnd)
				else {
					; Select all, then exercise the actual native paste behavior of
					; the production dialog's Edit control, not SetWindowText.
					SendMessage(0xB1, 0, -1, "Edit1", "ahk_id " . Hwnd)
					SendMessage(0x302, 0, 0, "Edit1", "ahk_id " . Hwnd)
				}
				Step.Observed := ControlGetText("Edit1", "ahk_id " . Hwnd)
				if NativeBox
					PostMessage(0x111, 1, 0, , "ahk_id " . Hwnd)
				else
					PostMessage(0xF5, 0, 0, "Button1", "ahk_id " . Hwnd)
			}
			Step.Submitted := true
			return
		}
	} catch as Failure {
		Step.Failure := Failure
		if Step.Hwnd
			DllCall("User32\PostMessageW", "Ptr", Step.Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int")
		Step.Submitted := true
	} finally Step.Busy := false
}

_PFI_NativeInput(State, Prompt, Title, Options, Default) {
	AssertFalse(A_IsCritical, "The public profile wizard must admit native modal automation outside Critical")
	Step := {Title: WindowTitle(Title), Hwnd: 0, Label: State.Inputs == 1,
		Cancel: State.Mode == "edit-native-cancel" && State.Inputs == 2,
		Submitted: false, Busy: false, Failure: 0, Multiline: false, Observed: "", Returned: ""}
	SavedClipboard := ClipboardAll()
	Tick := _PFI_NativeInputTick.Bind(Step)
	try {
		if !Step.Label && !Step.Cancel {
			A_Clipboard := State.Mode == "edit-native-single" ? "native single-line prompt"
				: "first prompt line`r`nsecond prompt line"
			AssertTrue(ClipWait(1), "The native paste must own actual Unicode clipboard text")
		}
		SetTimer(Tick, 10)
		; T5 bounds automation failure without changing the dialog's text or
		; control styles. Both dimensions come unchanged from production.
		NativeInput := Step.Label ? Ui_InputBox : _LLM_Menu_ProfilePromptInput
		Box := NativeInput.Call(Prompt, Title, Options . " T5", Default)
		if Step.Failure is Error
			throw Step.Failure
		AssertTrue(Step.Submitted && Step.Hwnd != 0, "The real production InputBox must receive native automation")
		AssertEqual(Step.Cancel ? "Cancel" : "OK", Box.Result)
		Step.Returned := Box.Value
		State.NativeCaptures.Push(Step)
		return Box
	} finally {
		SetTimer(Tick, 0)
		A_Clipboard := SavedClipboard
	}
}

_PFI_Input(State, Prompt, Title, Options, Default := "") {
	State.Inputs += 1
	AssertTrue(Prompt != "" && Title != "", "The native fallback must reach actual localized input boundaries.")
	if InStr(State.Mode, "edit-native-") == 1
		return _PFI_NativeInput(State, Prompt, Title, Options, Default)
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
	State.NoticeLevels.Push(Options["level"])
	return true
}

_PFI_Run(Mode) {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner, _VendorDir, Features, LLM_Defaults, _LLM_Menu_ApiPrivateAuthorityGeneration
	global _PromptEdWeb_OpeningSource, _PromptEdWeb_PersistHook, _PromptEdWeb_ResetDone
	SavedApiAuthority := _LLM_Menu_ApiPrivateAuthorityGeneration
	HadDefaults := IsSet(LLM_Defaults)
	SavedDefaults := HadDefaults ? LLM_Defaults : 0
	PreviousContext := _PEC_InstallFixture()
	World := 0
	PreviousCritical := Critical("Off")
	WasSuspended := A_IsSuspended
	SavedHotkeys := _LLM_Menu_ProfileHotkeyOwner
	SavedVendor := _VendorDir
	SavedReset := _PromptEdWeb_ResetDone
	State := { Mode: Mode, World: 0, Inputs: 0, Confirms: 0, Collects: 0,
		Notices: [], NoticeLevels: [], InitialProfiles: 0, InitialImage: "", ExternalImage: "", NativeCaptures: [] }
	try {
		Suspend(false)
		World := _LSP_World()
		State.World := World
		_LLM_Menu_ProfileHotkeyOwner := 0
		; Genuine missing loader forces the actual native fallback without replacing TryOpen.
		_VendorDir := World.ConfigPath . "-no-webview-loader"
		_PFI_InstallMemoryRetirement(State)
		Profiles := [_PFI_Profile("user_profile_a", "original-a"), _PFI_Profile("user_profile_b", "original-b")]
		AssertTrue(TOML_ConfigBatchWrite(World.ConfigPath,
			[{ Section: "llm", Key: "user_profiles", Value: _LLM_Menu_SerializeUserProfiles(Profiles) }]))
		_LLM_Menu["user_profiles"] := Profiles
		_LLM_Menu["profile_id"] := "user_profile_a"
		_LLM_Menu["enabled"] := InStr(Mode, "edit-memory-retire-") == 1
		if Mode == "edit-current-absent-foreign" || Mode == "edit-current-stock-port" {
			LLM_Defaults_Load()
			AssertTrue(LLM_Defaults is Map && LLM_Defaults.Has("llm_ollama_owned_port"))
			_LLM_Menu["ollama_port"] := LLM_Defaults["llm_ollama_owned_port"]
		}
		if Mode == "edit-current-absent-foreign" || Mode == "edit-current-api-neutral" {
			_LLM_Menu["api_entry_id"] := _LLM_Menu_DefaultApiEntryId()
			AssertTrue(_LLM_Menu_LoadApiEntries(), "The real private file loader must supply the automatic active entry")
			AssertTrue(_LLM_Menu["api_entries"].Length > 0 && _LLM_Menu["api_entry_id"] == _LLM_Menu["api_entries"][1]["Id"])
		}
		if InStr(Mode, "edit-current-legacy-bool") == 1
			_LLM_Menu[ConfigLeaf.SHOW_INFO_BAR] := InStr(Mode, "bool1") > 0
		if Mode == "edit-current-disabled-alias"
			_LLM_Menu["disabled_apps"] := ["visual studio code"]
		AssertTrue(TOML_ConfigBatchWrite(World.ConfigPath,
			_ConfigPrepareTypedUpdates(_LLM_Menu_ProfileProjectionUpdates(Features, _LLM_Menu))),
			"The private current source must genuinely match every persisted LLM leaf before external replacement")
		if InStr(Mode, "edit-current-") == 1
			_PFI_CurrentCanonicalSource(State)
		State.InitialProfiles := LLM_Menu_DeepClone(Profiles)
		State.InitialImage := FSReadUtf8Exact(World.ConfigPath)
		; A source captured only after this valid external replacement must not
		; bless the old live profile array as the source of those newer bytes.
		if Mode == "edit-preopen-external"
			_PFI_External(State)
		if Mode == "edit-preopen-nav"
			_PFI_ExternalNavigation(State)
		if Mode == "edit-preopen-unrepresentable"
			_PFI_ExternalUnknownProfileField(State)
		if Mode == "edit-preopen-api-unknown"
			_PFI_UnknownApiSelection(State)
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
		if InStr(Mode, "edit-current-") == 1
			_TestPrint("# profile-canonical mode=" . Mode . " apply_calls=" . World.ApplyCalls . " inputs=" . State.Inputs . " collects=" . State.Collects)
		Accepted := Mode == "edit-current" || InStr(Mode, "edit-current-") == 1 || Mode == "create-current" || Mode == "delete-current"
			|| Mode == "web-current" || Mode == "use-current"
			|| ((Mode == "edit-preopen-external" || Mode == "edit-preopen-nav") && World.ApplyCalls == 1)
			|| Mode == "edit-native-paste" || Mode == "edit-native-single"
		Cancelled := InStr(Mode, "cancel") > 0
		if Mode == "edit-preopen-external" {
			Observed := TOML_ParseFreshFileTyped(World.ConfigPath)
			ObservedProfiles := _LLM_Menu_DeserializeUserProfiles(Observed["llm"]["user_profiles"])
			AssertTrue(ObservedProfiles is Array && ObservedProfiles.Length == 2)
			Preserved := ObservedProfiles[2]["system_single"] == "external-b-must-survive"
			_TestPrint("# profile-preopen-source apply_calls=" . World.ApplyCalls . " input_calls=" . State.Inputs
				. " physical_sibling_preserved=" . Preserved
				. " external_exact_bytes=" . FSUtf8ExactMatches(World.ConfigPath, State.ExternalImage))
			AssertTrue(Preserved, "Opening the editor after replacement cannot bless stale RAM and erase the newer independent profile")
		}
		if Mode == "edit-preopen-nav" {
			Observed := TOML_ParseDocument(FSReadUtf8Exact(World.ConfigPath))
			NavPreserved := _LLM_Menu_ModifiersArrayToString(State.ExternalNav)
				== _LLM_Menu_ModifiersArrayToString(Observed["llm"]["navigation"]["nav_modifiers"])
			_TestPrint("# profile-preopen-navigation apply_calls=" . World.ApplyCalls . " input_calls=" . State.Inputs
				. " physical_nav_preserved=" . NavPreserved . " external_exact_bytes=" . FSUtf8ExactMatches(World.ConfigPath, State.ExternalImage))
			AssertTrue(NavPreserved, "Editing a profile cannot erase an independent navigation preference written before opening")
		}
		if InStr(Mode, "edit-memory-retire-") == 1 {
			_TestPrint("# profile-memory-source mode=" . Mode . " retired=" . State.Retired . " enabled=" . _LLM_Menu["enabled"] . " apply_calls=" . World.ApplyCalls . " disk_changed=" . !FSUtf8ExactMatches(World.ConfigPath, State.InitialImage))
			AssertTrue(State.Retired && State.Rebuilds == 1, "The genuine dependency failure must execute once inside the actual profile save")
			AssertFalse(_LLM_Menu["enabled"], "The old profile candidate cannot re-enable the actual retired dependency state")
		}
		AssertEqual(Accepted, World.ApplyCalls, "Only an owned accepted image may publish the real profile action.")
		HandledChooser := InStr(Mode, "chooser-edit") || InStr(Mode, "use")
		if HandledChooser
			AssertTrue(Result, "Use and Edit keep the management dialog's existing handled-result contract.")
		else if !Cancelled
			AssertEqual(Accepted, !!Result, "A stale opening source cannot be reported as a saved profile.")
		Actual := FSReadUtf8Exact(World.ConfigPath)
		if !Accepted {
			if Mode == "edit-memory-retire-after-ack" {
				DurableRows := _LLM_Menu_DeserializeUserProfiles(TOML_ParseFreshFileTyped(World.ConfigPath)["llm"]["user_profiles"])
				AssertEqual("edited-a", DurableRows[1]["system_single"], "A retired presentation cannot undo an already acknowledged profile write")
				AssertEqual("original-b", DurableRows[2]["system_single"])
				_PFI_AssertRetiredPublicationFence(State)
			} else
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
			AssertEqual(Mode == "edit-preopen-external" ? "external-b-must-survive" : "original-b",
				Sibling["system_single"], "Successful edits preserve the independent sibling profile.")
			if Mode == "edit-current" || InStr(Mode, "edit-current-") == 1 || Mode == "web-current" || Mode == "edit-preopen-external" || Mode == "edit-preopen-nav" {
				AssertEqual("edited-a", Saved[1]["system_single"])
				AssertEqual("Edited A", Saved[1]["label"])
			}
			if Mode == "edit-native-paste" || Mode == "edit-native-single" {
				ExpectedPrompt := Mode == "edit-native-single" ? "native single-line prompt"
					: "first prompt line`nsecond prompt line"
				AssertEqual(2, State.NativeCaptures.Length)
				Input := State.NativeCaptures[2]
				AssertTrue(Input.Multiline, "The actual native prompt Edit must retain multiline paste")
				SavedPrompt := StrReplace(Saved[1]["system_single"], "`r`n", "`n")
				_TestPrint("# native-profile-paste mode=" . Mode . " multiline_style=" . Input.Multiline
					. " paste_control_lines=" . StrSplit(StrReplace(Input.Observed, "`r`n", "`n"), "`n").Length
					. " returned_lines=" . StrSplit(StrReplace(Input.Returned, "`r`n", "`n"), "`n").Length
					. " durable_lines=" . StrSplit(SavedPrompt, "`n").Length)
				AssertEqual(ExpectedPrompt, SavedPrompt, "A real native paste must retain every prompt line through actual durable serialization")
				AssertEqual(ExpectedPrompt, StrReplace(_LLM_Menu["user_profiles"][1]["system_single"], "`r`n", "`n"))
				AssertEqual("Edited A", Saved[1]["label"])
			}
		}
		if Mode == "edit-preopen-unrepresentable" || Mode == "edit-preopen-api-unknown" {
			AssertEqual(0, State.Inputs, "The public editor must refuse before authorizing native inputs from a lossy profile projection")
			AssertEqual(0, State.Collects, "No complete profile-array effect may be built from an unrepresentable source")
			AssertTrue(State.Notices.Length > 0, "The actual public failure must visibly explain the refused source")
		} else if Mode == "edit-preopen-external" || Mode == "edit-preopen-nav" {
			AssertTrue(State.Inputs <= 2, "A refused stale opening may stop before the native inputs")
			if Accepted
				AssertEqual(2, State.Inputs, "A source-reconciled successful edit must still consume both actual inputs")
		} else if SubStr(Mode, 1, 5) == "edit-" || SubStr(Mode, 1, 7) == "create-"
			AssertEqual(Cancelled && Mode != "edit-native-cancel" ? 1 : 2, State.Inputs, "Both actual fallback inputs must be exercised except ordinary label cancellation.")
		if InStr(Mode, "delete")
			AssertEqual(2, State.Confirms, "Removal must exercise both real confirmation callbacks.")
		if InStr(Mode, "chooser-edit") {
			AssertEqual(1, State.Confirms)
			AssertEqual(2, State.Inputs, "The chooser must carry its original image into the subsequent editor.")
		}
		if Mode == "edit-preopen-external" || Mode == "edit-preopen-nav" {
			AssertTrue(State.Collects <= 1, "A refused stale image must never retry its full projection automatically")
			if Accepted
				AssertEqual(1, State.Collects, "A successful reconciled edit must serialize its actual candidate")
		} else if !Cancelled && Mode != "web-successor" && Mode != "edit-preopen-unrepresentable" && Mode != "edit-preopen-api-unknown"
			AssertEqual(1, State.Collects, "The actual profile collector must run before native image refusal.")
		AssertFalse(_ConfigWriteTerminalIsActive(), "Every path must release its exact borrowed configuration lease.")
	} finally {
		try {
			try _PFI_ReleaseMemoryRetirement(State)
			finally {
				if World is _LSP_World
					World.Restore()
			}
		} finally {
			_PEC_RestoreFixture(PreviousContext)
			_PromptEdWeb_ResetDone := SavedReset
			_LLM_Menu_ProfileHotkeyOwner := SavedHotkeys
			_VendorDir := SavedVendor
			State.World := 0
			_LLM_Menu_ApiPrivateAuthorityGeneration := SavedApiAuthority
			if HadDefaults
				LLM_Defaults := SavedDefaults
			else
				LLM_Defaults := unset
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

for _PFI_NativeMode in ["edit-native-paste", "edit-native-single", "edit-native-cancel"]
	Test("LLM native profile prompt: " . _PFI_NativeMode . " retains pasted lines (native-profile-paste-owner)",
		_PFI_Run.Bind(_PFI_NativeMode))

Test("LLM profile opening source: prior external sibling edit survives (llm-profile-preopen-source)",
	_PFI_Run.Bind("edit-preopen-external"))
Test("LLM profile opening source: matching live and physical images still edit (llm-profile-preopen-source)",
	_PFI_Run.Bind("edit-current"))

; Author a valid forward-compatible JSON object through the real scalar TOML
; writer. The public opening owner must preserve bytes the strict codec cannot
; represent, rather than treating the payload as an empty or filtered array.
_PFI_ExternalUnknownProfileField(State) {
	Encoded := _LLM_Menu_SerializeUserProfiles(State.InitialProfiles)
	Bytes := CryptoBase64Decode(SubStr(Encoded, 4))
	Json := StrGet(Bytes, Bytes.Size, "UTF-8")
	AssertEqual("[{", SubStr(Json, 1, 2))
	Json := '[{"future_profile_field":{"owned":true},' . SubStr(Json, 3)
	Parsed := JsonParse(Json)
	AssertTrue(Parsed is Array && Parsed.Length == 2 && Parsed[1].Has("future_profile_field"),
		"The external profile source is genuine valid JSON with a user-owned future member")
	Payload := "v1:" . CryptoBase64EncodeUtf8(Json)
	AssertTrue(TOML_ConfigBatchWrite(State.World.ConfigPath,
		[{Section: "llm", Key: "user_profiles", Value: Payload}]))
	State.ExternalImage := FSReadUtf8Exact(State.World.ConfigPath)
	AssertTrue(ConfigFullStateCanPersist(), "The scalar schema remains READY for the actual external envelope")
	Document := TOML_ParseFreshFileTyped(State.World.ConfigPath)
	AssertEqual(Payload, Document["llm"]["user_profiles"], "The physical typed TOML retained the exact authored envelope")
}

Test("LLM profile opening source: unknown JSON profile members refuse without projection loss (llm-profile-source-representation)",
	_PFI_Run.Bind("edit-preopen-unrepresentable"))

; Preserve a different scalar projection written before the profile source is
; captured. The actual profile collector also serializes this navigation row.
_PFI_ExternalNavigation(State) {
	global _LLM_Menu
	State.ExternalNav := _LLM_Menu_ModifiersStringToArray(StrLower(_LLM_Menu[ConfigLeaf.NAV_MODIFIERS]) == "alt" ? "ctrl" : "alt")
	Built := TOML_BuildConfigUpdatedContent(State.World.ConfigPath,
		[{Section: "llm.navigation", Key: "nav_modifiers", Value: State.ExternalNav}])
	AssertTrue(Built is Map && Built.Get("status", "") == "ok")
	State.ExternalImage := Built["content"]
	AssertTrue(StrCompare(State.ExternalImage, State.InitialImage, true) != 0,
		"The external native write must change the actual navigation leaf")
	AssertTrue(FSWriteDurable(State.World.ConfigPath, State.ExternalImage))
	AssertTrue(ConfigFullStateCanPersist(), "The real READY schema admits the independent external navigation choice")
	Observed := TOML_ParseDocument(FSReadUtf8Exact(State.World.ConfigPath))
	AssertTrue(ManifestValuesEqual(State.ExternalNav, Observed["llm"]["navigation"]["nav_modifiers"]))
}

Test("LLM profile opening source: prior external navigation edit survives (llm-profile-preopen-navigation)",
	_PFI_Run.Bind("edit-preopen-nav"))

; Retire actual dependencies after real stage verification or durable observation.
; The only suppressed external effect is the unrelated tray rebuild request.
_PFI_InstallMemoryRetirement(State) {
	if !InStr(State.Mode, "edit-memory-retire-")
		return
	State.RetirementScope := []
	State.Retired := false
	State.Rebuilds := 0
	for Spec in [[FSWriteReplaceOwned, _PFI_RetirementHeldPublish.Bind(State)],
		[_LLM_Menu_ObservationEnd, _PFI_RetirementObservation.Bind(State)],
		[LLM_Menu_RequestBuild, _PFI_RetirementRebuild.Bind(State)]] {
		AssertFalse(Spec[1].HasOwnProp("Call"), "The retirement probe delegates genuine unmodified function bodies")
		Spec[1].DefineProp("Call", {Call: Spec[2]})
		State.RetirementScope.Push({Function: Spec[1], Callback: Spec[2]})
	}
}

_PFI_ReleaseMemoryRetirement(State) {
	if !State.HasOwnProp("RetirementScope")
		return
	for Scope in State.RetirementScope {
		AssertTrue(Scope.Function.HasOwnProp("Call") && Scope.Function.GetOwnPropDesc("Call").Call == Scope.Callback,
			"Only this probe's exact function observer may be removed")
		Scope.Function.DeleteProp("Call")
	}
}

_PFI_RetirementHandlePath(Handle) {
	Wide := Buffer(65536, 0)
	Length := DllCall("kernel32\GetFinalPathNameByHandleW", "Ptr", Handle,
		"Ptr", Wide, "UInt", 32768, "UInt", 0, "UInt")
	AssertTrue(Length > 0 && Length < 32768, "the native owned file must expose its exact complete path")
	return StrGet(Wide, Length, "UTF-16")
}

_PFI_RetirementCaptureStage(Receipt, Create, Folder, Name, Attributes) {
	Handle := Create.Call(Folder, Name, Attributes)
	Receipt.handle := Handle
	return Handle
}

_PFI_RetirementHeldPreflight(State, Receipt, Before) {
	Result := Before.Call()
	AssertTrue(Result is Integer && Result == 1, "the native writer must genuinely flush and verify its complete staged image")
	AssertTrue(Receipt.handle != -1, "the actual exclusive stage factory must have returned its retained handle")
	; Compare native handle names rather than a pathname passed to readback:
	; the held reader intentionally no longer reopens its stage by that name.
	Target := DllCall("kernel32\CreateFileW", "Str", State.World.ConfigPath,
		"UInt", 0, "UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
	AssertTrue(Target != -1, "the existing real configured target must remain queryable")
	try {
		StagePath := _PFI_RetirementHandlePath(Receipt.handle)
		TargetPath := _PFI_RetirementHandlePath(Target)
		AssertTrue(InStr(StagePath, TargetPath . ".", false) == 1,
			"the actual retained native stage must belong to this exact configured target")
	} finally {
		AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Target, "Int") != 0,
			"the fixture must acknowledge retirement of its own target query handle")
	}
	_PFI_RetireActualDependencies(State)
	return Result
}

_PFI_RetirementHeldPublish(State, Self, Path, Content, Suffix, &Detail := "", StageFn := 0,
		BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true, &Publication := 0, FlushFn := 0) {
	if State.Mode == "edit-memory-retire-before-ack" && State.Collects > 0 && !State.Retired
			&& Path == State.World.ConfigPath {
		AssertTrue(HasMethod(StageFn, "Call") && HasMethod(BeforePublishFn, "Call"),
			"the genuine config writer must retain its actual stage and exact-source preflight callbacks")
		Receipt := {handle: -1}
		return Func.Prototype.Call.Call(Self, Path, Content, Suffix, &Detail,
			_PFI_RetirementCaptureStage.Bind(Receipt, StageFn),
			_PFI_RetirementHeldPreflight.Bind(State, Receipt, BeforePublishFn),
			AdmissionFn, ReplaceExisting, &Publication, FlushFn)
	}
	return Func.Prototype.Call.Call(Self, Path, Content, Suffix, &Detail, StageFn,
		BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn)
}

_PFI_RetirementObservation(State, Self, Stage, Started, Result) {
	Returned := Func.Prototype.Call.Call(Self, Stage, Started, Result)
	if State.Mode == "edit-memory-retire-after-ack" && Stage == "durable-writer" && Result == 1 && !State.Retired
		_PFI_RetireActualDependencies(State)
	return Returned
}

_PFI_RetirementRebuild(State, Self, Reason, Args*) {
	AssertTrue(Self == LLM_Menu_RequestBuild && Reason == "deps_failure", "Only the actual dependency failure may request this isolated tray effect")
	State.Rebuilds += 1
	return true
}

_PFI_RetireActualDependencies(State) {
	global _LLM_Menu
	State.Retired := true
	Before := _LLM_Menu
	AssertTrue(_LLM_Menu["enabled"], "The actual failure must retire a previously enabled menu state")
	AssertTrue(_LLM_Menu_ApplyCurrentDepsFailure())
	AssertTrue(_LLM_Menu == Before && !_LLM_Menu["enabled"], "The genuine producer changes enabled in place without replacing its Map")
}

; The existing permanent session refusal is the recovery protocol: reopening
; the real driver reads B, and until then neither full-state admission nor the
; actual native writer can serialize old RAM over that acknowledged image.
_PFI_AssertRetiredPublicationFence(State) {
	global _LLM_Menu, Features
	Path := State.World.ConfigPath
	Durable := FSConfigReadUtf8Exact(Path)
	AssertEqual("durable LLM profile publication was retired; restart required", TOML_WriteRefusal(Path))
	AssertFalse(ConfigFullStateCanPersist(), "The actual full-save admission must reject the stale loaded tree")
	OldProjection := _LLM_Menu_ProfileProjectionUpdates(Features, _LLM_Menu)
	OldProfiles := ""
	for Row in OldProjection
		if Row.Section == "llm" && Row.Key == "user_profiles" && Row.HasOwnProp("Value")
			OldProfiles := Row.Value
	AssertTrue(OldProfiles is String && _LLM_Menu_DeserializeUserProfiles(OldProfiles)[1]["system_single"] == "original-a",
		"The real full-save LLM collector must still expose the stale value this fence protects against")
	AssertFalse(TOML_ConfigBatchWrite(Path, _ConfigPrepareTypedUpdates(OldProjection)),
		"Even an actual native attempt to write the old full-save projection must be refused")
	AssertEqual(Durable, FSConfigReadUtf8Exact(Path), "The acknowledged profile B remains byte exact after the later old-RAM write attempt")
	PartialNotice := false
	for Index, Message in State.Notices
		if Message == t("onboarding.done.restart_required") && State.NoticeLevels[Index] == "warning"
			PartialNotice := true
	AssertTrue(PartialNotice, "The real notification must say the configuration was saved and requires restart, not that nothing changed")
}

for _PFI_RetirementMode in ["edit-memory-retire-before-ack", "edit-memory-retire-after-ack"]
	Test("LLM profile frozen RAM source: " . _PFI_RetirementMode . " preserves actual dependency retirement (llm-profile-memory-source)",
		_PFI_Run.Bind(_PFI_RetirementMode))

; These are current, representable images under the existing consumer policy,
; not stale choices: prove the broader source guard still admits their edit.
_PFI_CurrentCanonicalSource(State) {
	global _LLM_Menu, LLM_Defaults
	Updates := []
	if InStr(State.Mode, "edit-current-legacy-bool") == 1 {
		Digit := InStr(State.Mode, "bool1") > 0 ? 1 : 0
		Built := TOML_BuildUpdatedContent(State.World.ConfigPath,
			[{Section: "llm.display", Key: "show_info_bar", Value: Digit}])
		AssertTrue(Built is Map && Built.Get("status", "") == "ok")
		AssertTrue(FSWriteDurable(State.World.ConfigPath, Built["content"]))
		RawFound := false
		for Row in ConfigTomlDecodeSnapshot(FSConfigReadUtf8Exact(State.World.ConfigPath)).Rows {
			if Row.Section == "llm.display" && Row.Key == "show_info_bar" {
				AssertEqual(String(Digit), Trim(TOML_StripInlineComment(Row.Raw)))
				RawFound := true
			}
		}
		AssertTrue(RawFound, "The actual typed snapshot must retain the exact legacy bare Boolean token")
		AssertTrue(ConfigFullStateCanPersist(), "The genuine source owner must admit the historical bare Boolean")
		return
	}
	switch State.Mode {
		case "edit-current-absent-foreign":
			Updates := [{Section: "llm", Key: "ollama_port", Delete: 1},
				{Section: "llm", Key: "api_entry_id", Delete: 1}]
		case "edit-current-api-neutral":
			Updates := [{Section: "llm", Key: "api_entry_id", Value: _LLM_Menu_DefaultApiEntryId()}]
		case "edit-current-streaming-canonical":
			Updates := [{Section: "llm.display", Key: "streaming", Value: TOML_Bool(true)}]
		case "edit-current-disabled-alias":
			Updates := [{Section: "llm.trigger", Key: "disabled_apps", Value: ["VISUAL STUDIO CODE", "visual studio code"]}]
		case "edit-current-stock-port":
			AssertTrue(LLM_Defaults is Map && LLM_Defaults.Has("llm_ollama_port"))
			Updates := [{Section: "llm", Key: "ollama_port", Value: LLM_Defaults["llm_ollama_port"]}]
	}
	AssertTrue(Updates.Length > 0)
	AssertTrue(TOML_ConfigBatchWrite(State.World.ConfigPath, Updates), "The current canonicalization control must be a genuine native source")
	AssertTrue(ConfigFullStateCanPersist(), "The actual schema owner must admit the current canonical source")
}

for _PFI_CanonicalMode in ["edit-current-absent-foreign", "edit-current-streaming-canonical", "edit-current-disabled-alias", "edit-current-stock-port", "edit-current-api-neutral", "edit-current-legacy-bool0", "edit-current-legacy-bool1"]
	Test("LLM profile full projection: " . _PFI_CanonicalMode . " remains editable (llm-profile-projection-canonical)",
		_PFI_Run.Bind(_PFI_CanonicalMode))

_PFI_UnknownApiSelection(State) {
	Built := TOML_BuildConfigUpdatedContent(State.World.ConfigPath,
		[{Section: "llm", Key: "api_entry_id", Value: "future-api-selection-must-survive"}])
	AssertTrue(Built is Map && Built.Get("status", "") == "ok")
	State.ExternalImage := Built["content"]
	AssertTrue(FSWriteDurable(State.World.ConfigPath, State.ExternalImage))
	AssertTrue(ConfigFullStateCanPersist())
}

Test("LLM profile opening source: explicit unknown API selection is preserved (llm-profile-projection-unknown-api)",
	_PFI_Run.Bind("edit-preopen-api-unknown"))

; Keep the production profile collector: this public regression first aligns
; a real full-state source, then checks that editing LLM leaves other rows alone.
_PFNL_Input(State, Prompt, Title, Options, Default := "") {
	State.Inputs += 1
	AssertTrue(Prompt != "" && Title != "")
	return {Result: "OK", Value: State.Inputs == 1 ? "Edited A" : "edited-a"}
}

_PFNL_Case(External, Control := "") {
	global Features, _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner, _VendorDir
	PreviousContext := _PEC_InstallFixture()
	World := 0
	WasSuspended := A_IsSuspended
	PreviousCritical := Critical("Off")
	SavedHotkeys := _LLM_Menu_ProfileHotkeyOwner
	SavedVendor := _VendorDir
	State := {Inputs: 0, Notices: [], NoticeLevels: []}
	try {
		Suspend(false)
		World := _LSP_World()
		_LLM_Menu_ProfileHotkeyOwner := 0
		_VendorDir := World.ConfigPath . "-no-webview-loader"
		Profiles := [_PFI_Profile("user_profile_a", "original-a"), _PFI_Profile("user_profile_b", "original-b")]
		_LLM_Menu["user_profiles"] := Profiles
		_LLM_Menu["profile_id"] := "user_profile_a"
		_LLM_Menu["enabled"] := false
		Initial := _ConfigCollectFullSaveUpdates(Features, _LLM_Menu)
		AssertTrue(Initial is Array && Initial.Length > 0,
			"The genuine full-state collector must build all production rows before the public action")
		AssertTrue(TOML_ConfigBatchWrite(World.ConfigPath, _ConfigPrepareTypedUpdates(Initial)),
			"The actual native writer must admit the unchanged current full-state fixture")
		InitialImage := FSConfigReadUtf8Exact(World.ConfigPath)
		InitialMenu := _LLM_Menu
		CurrentLocale := I18nGetLocale()
		ExpectedLocale := External ? (CurrentLocale == "en" ? "fr" : "en") : CurrentLocale
		ExternalImage := InitialImage
		if External {
			Built := TOML_BuildConfigUpdatedContent(World.ConfigPath,
				[{Section: "script", Key: "locale", Value: ExpectedLocale}])
			AssertTrue(Built is Map && Built.Get("status", "") == "ok")
			ExternalImage := Built["content"]
			AssertTrue(StrCompare(ExternalImage, InitialImage, true) != 0)
			AssertTrue(FSWriteDurable(World.ConfigPath, ExternalImage))
		}
		AssertTrue(ConfigFullStateCanPersist(), "The real current schema must admit this valid pre-opening external locale")
		Port := Map("input", _PFNL_Input.Bind(State), "notify", _PFI_Notify.Bind(State),
			"apply", ObjBindMethod(World, "ApplyCommitted"), "acquire", _LMT_Acquire, "settle", _LMT_Settle)
		if Control == "memory-rebase" {
			State.MemoryRoot := Map("future_runtime_metadata", "retained")
			Port["collect"] := _PFSC_CollectThenAddRoot.Bind(State)
		} else if Control == "broad-collector"
			Port["collect"] := _ConfigCollectFullSaveUpdates
		else
			AssertFalse(Port.Has("collect"), "Only the genuine production profile collector may serialize this public action")
		Result := LLM_Menu_PromptEditProfile(Profiles[1], Port)
		if Control == "memory-rebase"
			AssertTrue(Features.Has("fixture_unknown_non_llm") && Features["fixture_unknown_non_llm"] == State.MemoryRoot,
				"Scoped LLM publication must retain an unrelated current RAM root and its exact identity")
		if Control == "broad-collector" {
			AssertFalse(Result, "An injected complete collector cannot broaden the profile's configuration ownership")
			AssertEqual(0, World.ApplyCalls)
			AssertEqual(2, State.Inputs)
			AssertEqual(InitialImage, FSConfigReadUtf8Exact(World.ConfigPath))
			AssertTrue(_LLM_Menu == InitialMenu && ManifestValuesEqual(Profiles, _LLM_Menu["user_profiles"]))
			AssertTrue(State.Notices.Length > 0)
			return
		}
		Observed := TOML_ParseFreshFileTyped(World.ConfigPath)
		LocaleRead := _TOML_DocumentLookup(Observed, ["script", "locale"])
		ActualLocale := LocaleRead["found"] ? LocaleRead["value"] : ManifestDefaultFor("script.locale")
		Preserved := ActualLocale == ExpectedLocale
		_TestPrint("# profile-nonllm-source external=" . External . " apply_calls=" . World.ApplyCalls
			. " input_calls=" . State.Inputs . " physical_locale_preserved=" . Preserved)
		AssertTrue(Preserved, "A public LLM profile edit cannot overwrite another persisted preference changed before opening")
		AssertTrue(World.ApplyCalls <= 1)
		if World.ApplyCalls == 1 {
			AssertTrue(Result)
			AssertEqual(2, State.Inputs)
			Rows := _LLM_Menu_DeserializeUserProfiles(Observed["llm"]["user_profiles"])
			AssertEqual("edited-a", Rows[1]["system_single"])
			AssertEqual("original-b", Rows[2]["system_single"])
		} else {
			AssertTrue(External, "The unmodified current full-state source must actually save the profile")
			AssertFalse(Result)
			AssertEqual(ExternalImage, FSConfigReadUtf8Exact(World.ConfigPath))
			AssertTrue(_LLM_Menu == InitialMenu && ManifestValuesEqual(Profiles, _LLM_Menu["user_profiles"]))
			AssertTrue(State.Notices.Length > 0)
		}
	} finally {
		try {
			if World is _LSP_World
				World.Restore()
		} finally {
			_PEC_RestoreFixture(PreviousContext)
			_LLM_Menu_ProfileHotkeyOwner := SavedHotkeys
			_VendorDir := SavedVendor
			Suspend(WasSuspended)
			Critical(PreviousCritical)
		}
	}
}

for _PFNL_External in [false, true]
	Test("LLM full-state opening: " . (_PFNL_External ? "external locale" : "current control")
		. " preserves non-LLM preferences (llm-profile-nonllm-source)", _PFNL_Case.Bind(_PFNL_External))

; Memory-scope control only: this observer adds unknown unrelated metadata after
; the real candidate was cloned. It makes no claim of an OS producer/race proof.
_PFSC_CollectThenAddRoot(State, CandidateFeatures, CandidateMenu) {
	global Features
	Updates := _LLM_Menu_ProfileProjectionUpdates(CandidateFeatures, CandidateMenu)
	Features["fixture_unknown_non_llm"] := State.MemoryRoot
	return Updates
}
for _PFSC_Control in ["memory-rebase", "broad-collector"]
	Test("LLM profile scoped ownership: " . _PFSC_Control . " preserves unrelated state (llm-profile-nonllm-scope)",
		_PFNL_Case.Bind(false, _PFSC_Control))
