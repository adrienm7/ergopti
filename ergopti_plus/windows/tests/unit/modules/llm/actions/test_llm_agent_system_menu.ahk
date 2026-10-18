; tests/unit/modules/llm/actions/test_llm_agent_system_menu.ahk

; ==============================================================================
; MODULE: LLM Agent System Menu Rows
; DESCRIPTION:
; The agent's System menu rows (Off, Model, provider captions and apps)
; replay the shared declarations through their native owners and repair
; after a refusal.
; ==============================================================================

#Requires AutoHotkey v2.0





; Both native systems consume one independently authored shared Off declaration.
_LAG_SystemOffCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\agent_system_off.json", "UTF-8"))
}

; Observe the actual native system submenu and its dispatcher-owned first row.
_LAG_NativeSystemOffRow(System, Owned) {
	global _MenuDispatchCallbacks
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	Position := System == "system1" ? 2 : 3
	Handle := DllCall("GetSubMenu", "ptr", Built.Handle, "int", Position, "ptr")
	Assert(Handle != 0, "each actual system owns its native child menu")
	Sub := MenuFromHandle(Handle)
	Id := DllCall("GetMenuItemID", "ptr", Handle, "int", 0, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the actual Off row keeps its native dispatcher")
	return Map("label", _CTC_LabelAt(Sub, 0), "checked", _CTC_IsChecked(Sub, 0),
		"action", _MenuDispatchCallbacks[Id])
}

_LAG_SystemOffSharedRow() {
	Corpus := _LAG_SystemOffCorpus()
	for Vector in Corpus["states"] {
		_LAG_Run(_LAG_Menu("action", Vector["spec"], Vector["spec"]), _LTN_Screen(""), _Body.Bind(Corpus, Vector))
		_Body(Corpus, Vector, Fx, Lines, Sent) {
			Owned := []
			try {
				for System in Corpus["systems"] {
					Off := _LAG_NativeSystemOffRow(System, Owned)
					AssertEqual(t(Corpus["label_key"]), Off["label"], "the same canonical Off label owns both systems")
					AssertEqual(Vector["checked"], Off["checked"], "native checked state stays unchanged")
					AssertTrue(HasMethod(Off["action"], "Call"))
				}
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
Test("LLM agent: shared system Off rows replay independent native states (agent-system-off)", _LAG_SystemOffSharedRow)

_LAG_SystemOffOwnerRefusal() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Agent_CommitFn
		Corpus := _LAG_SystemOffCorpus()
		Declaration := _MR_GetManifestRoot()["agent_system_controls"][1]
		Label := Declaration["i18n"]
		Declaration["i18n"] := Corpus["mutated_label_key"]
		Commit := _LLM_Agent_CommitFn
		Owned := []
		try {
			Off := _LAG_NativeSystemOffRow("system1", Owned)
			AssertEqual(t(Corpus["mutated_label_key"]), Off["label"], "the actual child follows shared label changes")
			_LLM_Agent_CommitFn := (*) => false
			AssertFalse(Off["action"].Call())
			AssertEqual("cerebras", _LLM_Menu["agent_system1"])
			AssertEqual("cerebras", _LLM_Menu["agent_system2"])
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds, "a refused transaction cannot refresh as success")
			_LLM_Agent_CommitFn := Commit
			AssertTrue(Off["action"].Call(), "the retained callback retries through its actual owner")
			AssertEqual("", _LLM_Menu["agent_system1"])
			AssertEqual("cerebras", _LLM_Menu["agent_system2"])
			AssertEqual(1, Fx.Rebuilds)
			AssertFalse(Off["action"].Call(), "Windows keeps its existing already-Off no-op policy")
			AssertEqual(1, Fx.Rebuilds)
		} finally {
			Declaration["i18n"] := Label
			_LLM_Agent_CommitFn := Commit
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared system Off preserves transaction refusal and no-op (agent-system-off)", _LAG_SystemOffOwnerRefusal)


; Independent model-control identity and caption; never emitted by the generator.
_LAG_SystemModelCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\agent_system_model.json", "UTF-8"))
}

; Read the actual last native child and its dispatcher-owned callback.
_LAG_NativeSystemModelRow(System, Owned) {
	global _MenuDispatchCallbacks
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	Position := System == "system1" ? 2 : 3
	Handle := DllCall("GetSubMenu", "ptr", Built.Handle, "int", Position, "ptr")
	Assert(Handle != 0, "the actual system owns its native submenu")
	Sub := MenuFromHandle(Handle)
	Count := DllCall("GetMenuItemCount", "ptr", Handle, "int")
	Assert(Count >= 3, "the model row follows the backend choices")
	Id := DllCall("GetMenuItemID", "ptr", Handle, "int", Count - 1, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the model command keeps the real dispatcher")
	return Map("label", _CTC_LabelAt(Sub, Count - 1), "action", _MenuDispatchCallbacks[Id])
}

_LAG_SystemModelSharedOwner() {
	Corpus := _LAG_SystemModelCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Agent_CommitFn
		Declaration := _MR_GetManifestRoot()[Corpus["section"]][2]
		Label := Declaration["i18n"]
		Commit := _LLM_Agent_CommitFn
		Owned := []
		try {
			for System in Corpus["systems"] {
				Model := _LAG_NativeSystemModelRow(System, Owned)
				AssertEqual(StrReplace(t(Corpus["label_key"]), "{1}", Corpus["model"]), Model["label"])
			}
			Declaration["i18n"] := Corpus["mutated_label_key"]
			Model := _LAG_NativeSystemModelRow("system1", Owned)
			AssertEqual(StrReplace(t(Corpus["mutated_label_key"]), "{1}", Corpus["model"]), Model["label"],
				"the actual native child follows the shared label")
			Fx.PromptAnswers.Push(Map("ok", true, "value", "changed-model"))
			_LLM_Agent_CommitFn := (*) => false
			AssertFalse(Model["action"].Call())
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system1"])
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system2"])
			AssertEqual(0, Fx.Rebuilds)
			AssertEqual(0, Fx.Commits.Length)
			_LLM_Agent_CommitFn := Commit
			Fx.PromptAnswers.Push(Map("ok", true, "value", "changed-model"))
			AssertTrue(Model["action"].Call())
			AssertEqual("cerebras|changed-model", _LLM_Menu["agent_system1"])
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system2"])
			AssertEqual(1, Fx.Rebuilds)
		} finally {
			Declaration["i18n"] := Label
			_LLM_Agent_CommitFn := Commit
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared Model caption keeps actual dispatcher and refusal (agent-system-model)", _LAG_SystemModelSharedOwner)

_LAG_SystemModelSharedOrder() {
	Corpus := _LAG_SystemModelCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		global _LLM_Menu
		Root := _MR_GetManifestRoot()
		Original := Root[Corpus["section"]]
		try {
			Root[Corpus["section"]] := [Original[2], Original[1],
				Map("type", "label", "id", "model_tail_marker", "i18n", "menu.agent.off")]
			Row := _LLM_Agent_SystemRow("agent_system1")
			Items := Row["items"]
			AssertEqual(StrReplace(t(Corpus["label_key"]), "{1}", Corpus["model"]), Items[Items.Length - 2]["label"])
			AssertTrue(Items[Items.Length - 1]["separator"])
			AssertEqual(t("menu.agent.off"), Items[Items.Length]["label"])
			Root[Corpus["section"]] := [Map("type", "---"),
				Map("type", "command", "id", "unowned_agent_model", "i18n", Corpus["label_key"])]
			AssertEqual(0, _LLM_Agent_SystemRow("agent_system1")["items"].Length,
				"an unowned canonical command refuses the whole native provider")
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system1"])
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds)
		} finally {
			Root[Corpus["section"]] := Original
		}
	}
}
Test("LLM agent: shared Model order and unowned-command refusal (agent-system-model)", _LAG_SystemModelSharedOrder)

; Independent prior physical captions; native renderer never emits this corpus.
_LAG_ModelCaptionGetterCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\agent_linux_system_frames.json", "UTF-8"))
}

; Keep all native locale/cache identities and load the actual physical catalogue.
_LAG_WithModelCaptionLocale(Code, Body) {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity
	Saved := Map("locale", _I18nLocale, "cache_set", IsSet(_I18nCache),
		"loaded_set", IsSet(_I18nCacheLoaded), "identity_set", IsSet(_I18nActiveCacheIdentity))
	if Saved["cache_set"]
		Saved["cache"] := _I18nCache
	if Saved["loaded_set"]
		Saved["loaded"] := _I18nCacheLoaded
	if Saved["identity_set"]
		Saved["identity"] := _I18nActiveCacheIdentity
	try {
		_I18nLocale := Code
		_I18nLoadFile(_I18nLocalePath(Code))
		AssertTrue(_I18nCacheLoaded, "the physical native locale loaded")
		Body.Call()
	} finally {
		_I18nLocale := Saved["locale"]
		_I18nCache := Saved["cache_set"] ? Saved["cache"] : unset
		_I18nCacheLoaded := Saved["loaded_set"] ? Saved["loaded"] : unset
		_I18nActiveCacheIdentity := Saved["identity_set"] ? Saved["identity"] : unset
	}
}

_LAG_ModelCaptionGetterLocale(Code) {
	Corpus := _LAG_ModelCaptionGetterCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Code, Corpus))
	_Body(Code, Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale(Code, _Read.Bind(Corpus, Code, Fx))
		_Read(Corpus, Code, Fx) {
			Owned := []
			try {
				for System in ["system1", "system2"] {
					Model := _LAG_NativeSystemModelRow(System, Owned)
					AssertEqual(Corpus["locales"][Code]["windows_native_model"], Model["label"])
					AssertTrue(HasMethod(Model["action"], "Call"))
				}
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
for Code in ["ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
	"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh"]
	Test("LLM agent: canonical native Model caption " . Code . " (agent-model-caption-getter)",
		_LAG_ModelCaptionGetterLocale.Bind(Code))

_LAG_ModelCaptionGetterRefusal() {
	Corpus := _LAG_ModelCaptionGetterCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["spec"], Corpus["spec"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		global _LLM_Menu
		Declaration := _MR_GetManifestRoot()["agent_system_model_controls"][2]
		Getter := Declaration["caption_getter"]
		try {
			Declaration["caption_getter"] := "foreign_model_caption"
			for Key in ["agent_system1", "agent_system2"]
				AssertEqual(0, _LLM_Agent_SystemRow(Key)["items"].Length)
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system1"])
			AssertEqual(Corpus["spec"], _LLM_Menu["agent_system2"])
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds)
		} finally {
			Declaration["caption_getter"] := Getter
		}
		Owned := []
		try {
			for System in ["system1", "system2"]
				AssertTrue(HasMethod(_LAG_NativeSystemModelRow(System, Owned)["action"], "Call"))
		} finally {
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: canonical Model getter refusal and native repair (agent-model-caption-getter)",
	_LAG_ModelCaptionGetterRefusal)


; Original 21-language provider captions captured before this shared migration.
_LAG_WindowsProviderCaptionCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_agent_fixed_captions_original.json", "UTF-8"))
}

_LAG_WindowsProviderCaptionLocale(Code) {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Code, Corpus))
	_Body(Code, Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale(Code, _Read.Bind(Code, Corpus, Fx))
		_Read(Code, Corpus, Fx) {
			global _LLM_Menu, _MenuDispatchCallbacks
			Expected := Corpus["locales"][Code]
			Owned := []
			try {
				_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				AssertEqual(Expected["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Expected["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				AssertEqual(Expected["apps"]["2"], _CTC_LabelAt(Built, 5))
				CommandId := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", 5, "uint")
				AssertTrue(_MenuDispatchCallbacks.Has(CommandId), "the actual picker command reaches the native dispatcher")
				for System in ["system1", "system2"] {
					Row := _LLM_Agent_SystemRow("agent_" . System)
					AssertEqual(Expected["systems"][System]["cerebras"], Row["label"])
					Literal := _LLM_Agent_MenuSystemFrame("agent_" . System, Corpus["literal_native"], Row["items"])
					AssertEqual(Expected["systems"][System]["literal_native"], Literal["label"])
					AssertTrue(Literal["items"] == Row["items"], "the declared group keeps the finished native children")
					_LLM_Menu["agent_" . System] := ""
					AssertEqual(Expected["systems"][System]["off"], _LLM_Agent_SystemRow("agent_" . System)["label"])
				}
				for Count in Corpus["counts"] {
					Apps := []
					Loop Count
						Apps.Push("app" . A_Index . ".exe")
					_LLM_Menu["agent_disabled_apps"] := Apps
					Row := _LLM_Agent_AppsRow()
					AssertEqual(Expected["apps"]["" . Count], Row["label"])
					AssertTrue(HasMethod(Row["action"], "Call"))
				}
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
			} finally {
				for Built in Owned
					_CTC_ReleaseMenu(Built)
			}
		}
	}
}
for Code in ["ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
	"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh"]
	Test("LLM agent: shared Windows fixed provider captions " . Code . " (agent-windows-provider-captions)",
		_LAG_WindowsProviderCaptionLocale.Bind(Code))

_LAG_WindowsProviderFrameRefusal() {
	_LAG_Run(_LAG_Menu("action", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		Root := _MR_GetManifestRoot()
		Owned := []
		try {
			for Entry in [["agent_linux_system1_frame", "agent_system1", 2],
				["agent_linux_system2_frame", "agent_system2", 3],
				["agent_menu", "agent_disabled_apps", 5]] {
				Section := Entry[1], Key := Entry[2], Original := Root[Section]
				try {
					for Fault in ["missing", "foreign getter", "foreign row"] {
						if Key == "agent_disabled_apps"
							Root[Section] := _LAG_WindowsAppsCommandFaultRows(Original, Fault)
						else if Fault == "missing"
							Root.Delete(Section)
						else if Fault == "foreign getter" {
							Broken := Original[1].Clone()
							Broken["caption_getter"] := "unowned_agent_caption"
							Root[Section] := [Broken]
						} else
							Root[Section] := [Original[1], Map("type", "label", "id", "foreign_agent_tail", "i18n", "menu.agent.off")]
						Row := Key == "agent_disabled_apps" ? _LLM_Agent_AppsRow() : _LLM_Agent_SystemRow(Key)
						AssertFalse(Row, Fault . " refuses the actual provider before native append")
						Built := LLM_Agent_MenuBuild()
						Owned.Push(Built)
						AssertTrue(Built is Menu, "other actual Agent providers still build")
						AssertEqual(0, Fx.Commits.Length)
						AssertEqual(0, Fx.Rebuilds)
						Root[Section] := Original
					}
				} finally Root[Section] := Original
				Row := Key == "agent_disabled_apps" ? _LLM_Agent_AppsRow() : _LLM_Agent_SystemRow(Key)
				AssertTrue(Row is Map, "same canonical declaration repair restores its native provider")
			}
		} finally {
			for Built in Owned
				_CTC_ReleaseMenu(Built)
		}
	}
}
Test("LLM agent: shared Windows provider declaration refusal and repair (agent-windows-provider-captions)",
	_LAG_WindowsProviderFrameRefusal)


; Observe the original applications leaf before promoting its dynamic route.
_LAG_OriginalAppsNativeFlags(HostState) {
	AssertTrue(HostState == "paused" || HostState == "off" || HostState == "operational",
		"the original native observation has an explicit host state")
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"], HostState != "off"),
		_LTN_Screen(""), _Body.Bind(HostState, Corpus))
	_Body(HostState, Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(HostState, Corpus, Fx))
		_Read(HostState, Corpus, Fx) {
			global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
			SavedSuspend := A_IsSuspended, PickerOwner := AppPicker_Show
			HadPickerCall := Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
			PickerDescriptor := HadPickerCall ? Object.Prototype.GetOwnPropDesc.Call(PickerOwner, "Call") : false
			Owned := [], PickerCalls := []
			try {
				Suspend(HostState == "paused")
				AssertEqual(HostState == "paused", A_IsSuspended ? true : false,
					"the host's real suspension state is established")
				AssertEqual(HostState != "off", _LLM_Menu["enabled"] ? true : false,
					"the actual prediction-menu switch establishes the off state")
				AssertEqual(HostState != "off", _LLM_Menu_BackendIsReadyForUse() ? true : false,
					"the unchanged native readiness reader admits the actual selected API entry")
				AssertEqual("action", LLM_Agent_Setting("agent_mode"),
					"the separately owned Agent mode stays fixed across host states")
				for Count in Corpus["counts"]
					_LAG_ObserveOriginalAppsNativeFlags(HostState, Count, Corpus, Owned, PickerCalls)
				AssertEqual(3, PickerCalls.Length, "each actual native apps callback reaches the picker boundary once")
				AssertEqual(0, Fx.Commits.Length, "observing the original leaf acknowledges no configuration writes")
				AssertEqual(0, Fx.Rebuilds, "the original observations do not request a tray rebuild")
				AssertEqual(0, Fx.Remote.Length, "the original menu observation starts no remote Agent request")
				AssertEqual(0, Fx.Ollama.Length, "the original menu observation starts no local Agent request")
				AssertEqual(0, Fx.Predictions.Length, "native readiness is read without a prediction request")
			} finally {
				if HadPickerCall
					Object.Prototype.DefineProp.Call(PickerOwner, "Call", PickerDescriptor)
				else if Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
					Object.Prototype.DeleteProp.Call(PickerOwner, "Call")
				for Built in Owned
					_CTC_ReleaseMenu(Built)
				Suspend(SavedSuspend)
			}
		}
	}
}

; Count is a helper parameter: no assertion captures an AHK loop variable.
_LAG_ObserveOriginalAppsNativeFlags(HostState, Count, Corpus, Owned, PickerCalls) {
	global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
	Apps := []
	Loop Count
		Apps.Push("app" . A_Index . ".exe")
	_LLM_Menu["agent_disabled_apps"] := Apps
	Built := LLM_Agent_MenuBuild()
	Owned.Push(Built)
	AssertTrue(Built is Menu, HostState . ": the unchanged Agent builder returns a real native menu")
	AssertEqual(6, TrayMenuItemCount(Built), HostState . ": original mode, two systems, separators and apps order")
	AssertTrue(DllCall("GetSubMenu", "ptr", Built.Handle, "int", 0, "ptr") != 0,
		HostState . ": the original mode submenu stays first")
	AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", 1, "uint", 0x400, "uint") & 0x800) != 0,
		HostState . ": the original separator follows the mode")
	AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
	AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
	AssertTrue(DllCall("GetSubMenu", "ptr", Built.Handle, "int", 2, "ptr") != 0)
	AssertTrue(DllCall("GetSubMenu", "ptr", Built.Handle, "int", 3, "ptr") != 0)
	AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", 4, "uint", 0x400, "uint") & 0x800) != 0,
		HostState . ": the original separator immediately precedes the apps command")
	AssertEqual(Corpus["locales"]["fr"]["apps"]["" . Count], _CTC_LabelAt(Built, 5),
		HostState . ": the native apps count caption matches the untouched independent original corpus")
	AssertEqual(0, DllCall("GetSubMenu", "ptr", Built.Handle, "int", 5, "ptr"),
		HostState . ": apps is an actual leaf, so its flags have no submenu-count high byte")
	Flags := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 5, "uint", 0x400, "uint")
	AssertTrue(Flags != 0xFFFFFFFF, HostState . ": GetMenuState actually acquired the apps leaf")
	AssertEqual(0, Flags,
		HostState . ": original apps leaf is enabled, unchecked, non-default and not a separator")
	CommandId := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", 5, "uint")
	AssertTrue(CommandId != 0 && CommandId != 0xFFFFFFFF, "the actual apps leaf has a native command id")
	AssertTrue(_MenuDispatchCallbacks.Has(CommandId), "the original leaf has an actual dispatcher callback")
	AssertTrue(_MenuDispatchTokens.Has(CommandId), "the actual registration retains its dispatcher token")
	AssertTrue(_MenuDispatchOwnerHandles.Has(Built.Handle), "the dispatcher retains the actual native menu owner")
	AssertTrue(_MenuDispatchCallbacks[CommandId] is Func, "the original native apps callback is callable")

	; All flags above came from the unchanged native builder. Only the GUI boundary
	; is observed below, through the actual callback and LLM_Agent_OpenAppPicker.
	PickerOwner := AppPicker_Show, Before := PickerCalls.Length
	HadPickerCall := Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
	PickerDescriptor := HadPickerCall ? Object.Prototype.GetOwnPropDesc.Call(PickerOwner, "Call") : false
	try {
		Object.Prototype.DefineProp.Call(PickerOwner, "Call", {Call: (ThisPicker, Options) =>
			(AssertTrue(ThisPicker == PickerOwner, "the actual immutable picker entry owns the GUI observer"), PickerCalls.Push(Options))})
		_MenuDispatchCallbacks[CommandId].Call()
		AssertEqual(Before + 1, PickerCalls.Length, "one actual apps callback opens its original picker boundary")
		Options := PickerCalls[PickerCalls.Length]
		AssertTrue(Options is Map)
		AssertEqual("agent:disabled_apps", Options["owner"], "the callback reaches the Agent apps picker owner")
		AssertEqual(Corpus["locales"]["fr"]["apps"]["" . Count], Options["title"],
			"the real picker entry preserves the original independent count caption")
		AssertTrue(Options["initial"] == Apps, "the real picker entry receives the actual native settings list")
		AssertTrue(Options["on_save"] == LLM_Agent_OnAppPickerSave,
			"the original dispatcher callback reaches the genuine Agent save callback")
	} finally {
		if HadPickerCall
			Object.Prototype.DefineProp.Call(PickerOwner, "Call", PickerDescriptor)
		else if Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
			Object.Prototype.DeleteProp.Call(PickerOwner, "Call")
	}
}

Test("LLM agent: original native apps flags while paused (agent-apps-original-native-flags)",
	_LAG_OriginalAppsNativeFlags.Bind("paused"))
Test("LLM agent: original native apps flags with prediction off (agent-apps-original-native-flags)",
	_LAG_OriginalAppsNativeFlags.Bind("off"))
Test("LLM agent: original native apps flags with operational prediction (agent-apps-original-native-flags)",
	_LAG_OriginalAppsNativeFlags.Bind("operational"))

; The Windows command is selected within its sole shared menu, preserving hidden
; Lua siblings and unrelated genuine Agent rows. Ambiguity duplicates that owner.
_LAG_WindowsAppsCommandFaultRows(Original, Fault) {
	Rows := []
	for Item in Original {
		if (Item is Map) && _MR_Get(Item, "id") == "agent_disabled_apps" && _MR_IsForAhk(Item) {
			if Fault == "missing"
				continue
			if Fault == "foreign getter" {
				Broken := Item.Clone()
				Broken["caption_getter"] := "unowned_agent_caption"
				Rows.Push(Broken)
			} else {
				Rows.Push(Item)
				Rows.Push(Item.Clone())
			}
		} else
			Rows.Push(Item)
	}
	return Rows
}

; The central leaf receiver reads the actual native count before finite withdrawal.
_LAG_AgentAppsCommandCustody() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			for Fault in ["before getter Call", "before callback Call", "before current Call", "before renderer Call", "before ambiguity",
				"after getter Call", "after callback Call", "after current Call", "after foreign getter",
				"after foreign callback", "after declaration", "after declaration Has", "after ambiguity", "integer count", "control count"]
				_LAG_AgentAppsCommandFault(Fault, Corpus)
			AssertEqual(0, Fx.Commits.Length)
			AssertEqual(0, Fx.Rebuilds)
			AssertEqual(0, Fx.Remote.Length)
			AssertEqual(0, Fx.Ollama.Length)
		}
	}
}

; Fault is a fresh parameter; count reads never capture a mutable loop variable.
_LAG_AgentAppsCommandFault(Fault, Corpus) {
	global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens
	Root := _MR_GetManifestRoot(), Rows := Root["agent_menu"], SavedRows := Rows.Clone()
	Item := _MR_FindItemById("agent_menu", "agent_disabled_apps"), SavedItem := Item.Clone()
	Action := LLM_Agent_OpenAppPicker, NativeCount := _LLM_Agent_MenuDisabledAppsCount
	Native := Menu(), Calls := Map("count", 0, "foreign", 0)
	Commands := Map("agent_disabled_apps", Action)
	Getters := Map("agent_disabled_apps_count", ReadCount)
	PoisonedOwner := false, DescriptorName := "Call", HadCall := false, SavedCall := false, TeardownPrimary := false
	Poison(Owner, Name := "Call") {
		PoisonedOwner := Owner, DescriptorName := Name
		HadCall := Object.Prototype.HasOwnProp.Call(Owner, Name)
		SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, Name) : false
		Object.Prototype.DefineProp.Call(Owner, Name, {Call: (*) => (Calls["foreign"] += 1, false)})
	}
	Withdraw() {
		if InStr(Fault, "getter Call", true)
			Poison(ReadCount)
		else if InStr(Fault, "callback Call", true)
			Poison(Action)
		else if InStr(Fault, "current Call", true)
			Poison(_MR_NumberedCommandCurrent)
		else if Fault == "before renderer Call"
			Poison(_MR_RenderCommand)
		else if InStr(Fault, "ambiguity", true)
			Rows.Push(Item.Clone())
		else if Fault == "after foreign getter"
			Getters["agent_disabled_apps_count"] := () => (Calls["foreign"] += 1, "0")
		else if Fault == "after foreign callback"
			Commands["agent_disabled_apps"] := (*) => Calls["foreign"] += 1
		else if Fault == "after declaration"
			Item["caption_getter"] := "unowned_agent_caption"
		else if Fault == "after declaration Has"
			Poison(Item, "Has")
	}
	ReadCount() {
		Value := NativeCount.Call()
		Calls["count"] += 1
		if Fault == "integer count"
			return Integer(Value)
		if Fault == "control count"
			return "invalid`ncount"
		Withdraw()
		return Value
	}
	RestoreAuthorities() {
		if PoisonedOwner
			_LAG_AgentAppsRestoreDescriptor(PoisonedOwner, DescriptorName, HadCall, SavedCall)
		Rows.Length := 0
		for Original in SavedRows
			Rows.Push(Original)
		Item.Clear()
		for Field, Value in SavedItem
			Item[Field] := Value
		Commands.Clear(), Commands["agent_disabled_apps"] := Action
		Getters.Clear(), Getters["agent_disabled_apps_count"] := ReadCount
	}
	try {
		_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
		AssertEqual("2", NativeCount.Call(), "the observer starts with the actual production count reader")
		RegisterMenuItem(Native, "Retained apps command destination", Action)
		Native.Check("Retained apps command destination")
		Native.Disable("Retained apps command destination")
		Before := _MR_FrameDestinationSnapshot(Native)
		BeforeRead := InStr(Fault, "before ", true) == 1
		if BeforeRead
			Withdraw()
		Added := MenuRenderer_AppendCommand(Native, "agent_menu", "agent_disabled_apps", Commands, Getters)
		RestoreAuthorities()
		AssertEqual(0, Added, Fault . ": the genuine central command refuses before its first native leaf write")
		AssertEqual(BeforeRead ? 0 : 1, Calls["count"], "withdrawal has the exact actual native-count boundary")
		AssertEqual(0, Calls["foreign"], "foreign getter, callback and currentness observers never execute")
		AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
			"refusal preserves actual destination caption, command id, flags, callback and token")
		AssertEqual(1, TrayMenuItemCount(Native))
		if PoisonedOwner
			_LAG_AgentAppsAssertDescriptor(PoisonedOwner, DescriptorName, HadCall, SavedCall)
		AssertTrue(_MR_FindItemById("agent_menu", "agent_disabled_apps") == Item,
			"the same sole Windows-visible shared command owns exact repair")
		AssertEqual(1, MenuRenderer_AppendCommand(Native, "agent_menu", "agent_disabled_apps", Commands,
			Map("agent_disabled_apps_count", NativeCount)), "exact repair enters the same actual command receiver")
		AssertEqual(2, TrayMenuItemCount(Native))
		AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], _CTC_LabelAt(Native, 1))
		AssertEqual(0, DllCall("GetSubMenu", "ptr", Native.Handle, "int", 1, "ptr"))
		AssertEqual(0, DllCall("GetMenuState", "ptr", Native.Handle, "uint", 1, "uint", 0x400, "uint"),
			"the repaired actual apps command keeps the original enabled unchecked leaf flags")
		Id := DllCall("GetMenuItemID", "ptr", Native.Handle, "int", 1, "uint")
		AssertTrue(Id != 0 && Id != 0xFFFFFFFF)
		AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Action,
			"the actual native repaired command retains the genuine picker callback")
		AssertTrue(_MenuDispatchTokens.Has(Id))
		AssertEqual(0, Calls["foreign"])
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_LAG_AgentAppsRunCleanup(TeardownPrimary, RestoreAuthorities, () => _CTC_ReleaseMenu(Native),
			() => PoisonedOwner ? _LAG_AgentAppsAssertDescriptor(PoisonedOwner, DescriptorName, HadCall, SavedCall) : false)
	}
}

; This subject reaches the actual producer's command registration, not a fake builder.
_LAG_AgentAppsActualBuildRefusal() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			global _LLM_Menu
			Owner := _LLM_Agent_MenuDisabledAppsCount, Calls := Map("foreign", 0)
			HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
			SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
			Owned := [], TeardownPrimary := false
			try {
				_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
				Object.Prototype.DefineProp.Call(Owner, "Call", {Call: (*) => (Calls["foreign"] += 1, "2")})
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				_LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall)
				_LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall)
				AssertTrue(Built is Menu)
				AssertEqual(0, Calls["foreign"], "the genuine Build never invokes a withdrawn actual count getter")
				AssertEqual(4, TrayMenuItemCount(Built), "the existing mode, separator and two actual system groups still build")
				AssertTrue(TrayMenuSubmenuHandle(Built.Handle, 0) != 0)
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				Repaired := LLM_Agent_MenuBuild()
				Owned.Push(Repaired)
				AssertEqual(6, TrayMenuItemCount(Repaired))
				AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], _CTC_LabelAt(Repaired, 5))
				AssertEqual(0, DllCall("GetMenuState", "ptr", Repaired.Handle, "uint", 5, "uint", 0x400, "uint"))
				AssertEqual(0, Calls["foreign"])
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
				AssertEqual(0, Fx.Remote.Length)
				AssertEqual(0, Fx.Ollama.Length)
			} catch as Failure {
				TeardownPrimary := Failure
				throw Failure
			} finally {
				Cleanup := [() => _LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall)]
				for Built in Owned
					Cleanup.Push(_CTC_ReleaseMenu.Bind(Built))
				Cleanup.Push(() => _LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall))
				_LAG_AgentAppsRunCleanup(TeardownPrimary, Cleanup*)
			}
		}
	}
}

_LAG_AgentAppsRestoreDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	if Object.Prototype.HasOwnProp.Call(Owner, Name)
		Object.Prototype.DeleteProp.Call(Owner, Name)
	if HadProperty
		Object.Prototype.DefineProp.Call(Owner, Name, SavedDescriptor)
}
_LAG_AgentAppsAssertDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	AssertEqual(HadProperty, Object.Prototype.HasOwnProp.Call(Owner, Name))
	if !HadProperty
		return
	Actual := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
	ExpectedCount := 0, ActualCount := 0
	for Field, Expected in ObjOwnProps(SavedDescriptor) {
		ExpectedCount += 1
		AssertTrue(Object.Prototype.HasOwnProp.Call(Actual, Field) && Actual.%Field% == Expected)
	}
	for Field in ObjOwnProps(Actual)
		ActualCount += 1
	AssertEqual(ExpectedCount, ActualCount)
}
_LAG_AgentAppsRunCleanup(OriginalFailure, Cleanup*) {
	CleanupFailure := false
	for Operation in Cleanup {
		try Operation.Call()
		catch as Failure {
			if !CleanupFailure
				CleanupFailure := Failure
		}
	}
	if !OriginalFailure && CleanupFailure
		throw CleanupFailure
}
Test("LLM agent: actual shared apps command custody, first leaf refusal and exact native repair (agent-apps-command)",
	_LAG_AgentAppsCommandCustody)
Test("LLM agent: actual Build rejects withdrawn native apps getter and repairs (agent-apps-command)",
	_LAG_AgentAppsActualBuildRefusal)

; Actual producer pre-entry callee authority, observed through its native result.
_LAG_AgentAppsActualBuildEntryRefusal() {
	Corpus := _LAG_WindowsProviderCaptionCorpus()
	_LAG_Run(_LAG_Menu("action", Corpus["backend"], Corpus["backend"]), _LTN_Screen(""), _Body.Bind(Corpus))
	_Body(Corpus, Fx, Lines, Sent) {
		_LAG_WithModelCaptionLocale("fr", _Read.Bind(Corpus, Fx))
		_Read(Corpus, Fx) {
			global _LLM_Menu, _MenuDispatchCallbacks, _MenuDispatchTokens
			Owner := _MR_RenderCommand, Calls := Map("foreign", 0)
			HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
			SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
			PickerOwner := AppPicker_Show, PickerCalls := []
			HadPickerCall := Object.Prototype.HasOwnProp.Call(PickerOwner, "Call")
			PickerDescriptor := HadPickerCall ? Object.Prototype.GetOwnPropDesc.Call(PickerOwner, "Call") : false
			Owned := [], TeardownPrimary := false
			try {
				_LLM_Menu["agent_disabled_apps"] := ["slack.exe", "mail.exe"]
				Object.Prototype.DefineProp.Call(Owner, "Call", {Call: (*) => (Calls["foreign"] += 1, "2")})
				Built := LLM_Agent_MenuBuild()
				Owned.Push(Built)
				_LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall)
				_LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall)
				AssertTrue(Built is Menu)
				AssertEqual(0, Calls["foreign"], "the genuine Build rejects its actual renderer own Call before invoking a foreign callee")
				AssertEqual(4, TrayMenuItemCount(Built), "the existing mode, separator and two actual system groups still build")
				AssertTrue(TrayMenuSubmenuHandle(Built.Handle, 0) != 0)
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system1"]["cerebras"], _CTC_LabelAt(Built, 2))
				AssertEqual(Corpus["locales"]["fr"]["systems"]["system2"]["cerebras"], _CTC_LabelAt(Built, 3))
				Repaired := LLM_Agent_MenuBuild()
				Owned.Push(Repaired)
				AssertEqual(6, TrayMenuItemCount(Repaired))
				AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], _CTC_LabelAt(Repaired, 5))
				AssertEqual(0, DllCall("GetMenuState", "ptr", Repaired.Handle, "uint", 5, "uint", 0x400, "uint"))
				Id := DllCall("GetMenuItemID", "ptr", Repaired.Handle, "int", 5, "uint")
				AssertTrue(Id != 0 && Id != 0xFFFFFFFF)
				AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] is Func,
					"the repaired actual builder registers its genuine apps dispatcher callback")
				AssertTrue(_MenuDispatchTokens.Has(Id))
				Object.Prototype.DefineProp.Call(PickerOwner, "Call", {Call: (ThisPicker, Options) =>
					(AssertTrue(ThisPicker == PickerOwner), PickerCalls.Push(Options))})
				_MenuDispatchCallbacks[Id].Call()
				_LAG_AgentAppsRestoreDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor)
				_LAG_AgentAppsAssertDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor)
				AssertEqual(1, PickerCalls.Length, "the actual repaired native callback reaches the real GUI boundary once")
				AssertEqual("agent:disabled_apps", PickerCalls[1]["owner"])
				AssertEqual(Corpus["locales"]["fr"]["apps"]["2"], PickerCalls[1]["title"])
				AssertTrue(PickerCalls[1]["initial"] == _LLM_Menu["agent_disabled_apps"])
				AssertTrue(PickerCalls[1]["on_save"] == LLM_Agent_OnAppPickerSave)
				AssertEqual(0, Calls["foreign"])
				AssertEqual(0, Fx.Commits.Length)
				AssertEqual(0, Fx.Rebuilds)
				AssertEqual(0, Fx.Remote.Length)
				AssertEqual(0, Fx.Ollama.Length)
			} catch as Failure {
				TeardownPrimary := Failure
				throw Failure
			} finally {
				Cleanup := [() => _LAG_AgentAppsRestoreDescriptor(Owner, "Call", HadCall, SavedCall),
					() => _LAG_AgentAppsRestoreDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor)]
				for Built in Owned
					Cleanup.Push(_CTC_ReleaseMenu.Bind(Built))
				Cleanup.Push(() => _LAG_AgentAppsAssertDescriptor(Owner, "Call", HadCall, SavedCall))
				Cleanup.Push(() => _LAG_AgentAppsAssertDescriptor(PickerOwner, "Call", HadPickerCall, PickerDescriptor))
				_LAG_AgentAppsRunCleanup(TeardownPrimary, Cleanup*)
			}
		}
	}
}

Test("LLM agent: actual Build guards renderer entry and repairs native apps dispatch (agent-apps-command)",
	_LAG_AgentAppsActualBuildEntryRefusal)
