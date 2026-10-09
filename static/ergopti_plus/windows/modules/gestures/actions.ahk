; modules/gestures/actions.ahk

; ==============================================================================
; MODULE: Gesture Action Catalogue & Implementations
; DESCRIPTION:
; Mirrors macos/modules/gestures/actions.lua. Contains the complete gesture
; action registry (GESTURE_ACTIONS Map), all action implementation functions
; (GestureScreenshotInstant, GestureOpenConfiguredURL, etc.), the picker walk
; over the generated catalogue (GestureActionPickerItems, from
; _generated/action_catalogue.ahk), and the shared state used by the
; dispatcher (GestureAssignments, window-cycle tracker).
;
; Included by modules/gestures/init.ahk after the constants block.
; ==============================================================================

; Action registry — each action has a label and an execution function
global GESTURE_ACTIONS := Map(
		"run_program", { Fn: (BindingId := "") => ProgramActions_Run(BindingId) },
		"none", {
				Fn: (*) => 0,
		},
		; --- Mouse ---
		"left_click_toggle", {
				Fn: (*) => GestureToggleLeftClick(),
		},
		"right_click_toggle", {
				Fn: (*) => GestureToggleRightClick(),
		},
		; --- Editing ---
		; --- Keys ---
		; Key and Mods name the keystroke an action types, so a tap-hold sends it
		; under the held modifiers (TapHoldEmitKeyTap, which still routes a Tab
		; through the LLM wrapper).
		"tab", {
				Fn: (*) => LLM_Tooltip_FireTabOrAccept([]),
				Key: "Tab",
				Mods: [],
		},
		; --- Tabs ---
		"tab_prev", {
				Fn: (*) => GestureSendShortcut("^+{Tab}"),
				Key: "Tab",
				Mods: ["Ctrl", "Shift"],
		},
		"tab_next", {
				Fn: (*) => GestureSendShortcut("^{Tab}"),
				Key: "Tab",
				Mods: ["Ctrl"],
		},
		; --- Browser navigation ---
		"nav_back", {
				Fn: (*) => GestureSendShortcut("!{Left}"),
				Key: "Left",
				Mods: ["Alt"],
		},
		"nav_forward", {
				Fn: (*) => GestureSendShortcut("!{Right}"),
				Key: "Right",
				Mods: ["Alt"],
		},
		; --- Windows & Desktops ---
		"win_prev", {
				Fn: (*) => GestureCycleWindows(False),
		},
		"win_next", {
				Fn: (*) => GestureCycleWindows(True),
		},
		"win_app_prev", {
				Fn: (*) => GestureCycleAppWindows(False),
		},
		"win_app_next", {
				Fn: (*) => GestureCycleAppWindows(True),
		},
		; desktop_prev / desktop_next are the catalogue's Ctrl+Win+Arrow rows,
		; which stop at the first and last desktop as Windows does; these two
		; wrap to the other end (modules/gestures/virtual_desktops.ahk).
		"desktop_prev_wrap", {
				Fn: (*) => GestureDesktopNavigateWrap("prev"),
		},
		"desktop_next_wrap", {
				Fn: (*) => GestureDesktopNavigateWrap("next"),
		},
		; --- Cursor movement ---
		; --- Arrows ---
		; --- Selection ---
		; --- Media ---
		; --- System ---
		; Each capture target ships in two flavours: the *_clipboard variant
		; copies the image to the Windows clipboard for immediate paste into
		; the focused app, and the *_save variant writes a timestamped PNG
		; to %USERPROFILE%\Pictures\screenshots\. Defaults across the project
		; favour the clipboard variants because they keep the user inside
		; their current workflow without producing files they then have to
		; clean up.
		"screenshot_window_clipboard", {
				Fn: (*) => GestureScreenshotWindow("clipboard"),
		},
		"screenshot_window_save", {
				Fn: (*) => GestureScreenshotWindow("save"),
		},
		"screenshot_region_clipboard", {
				Fn: (*) => GestureScreenshotRegion("clipboard"),
		},
		"screenshot_region_save", {
				Fn: (*) => GestureScreenshotRegion("save"),
		},
		"screenshot_fullscreen_clipboard", {
				Fn: (*) => GestureScreenshotFullscreen("clipboard"),
		},
		"screenshot_fullscreen_save", {
				Fn: (*) => GestureScreenshotFullscreen("save"),
		},
		"lock_screen", {
				Fn: (*) => DllCall("LockWorkStation"),
		},
		; --- UI windows ---
		; Each UI action follows the same three-state pattern: if the window is
		; closed, open it; if open and focused, close it; if open but in the
		; background, raise it to the foreground.
		"open_metrics_typing", {
				Fn: (*) => GestureToggleOrFocusUI("metrics_typing"),
		},
		"open_metrics_apps", {
				Fn: (*) => GestureToggleOrFocusUI("metrics_apps"),
		},
		"open_hotstrings_editor", {
				Fn: (*) => GestureToggleOrFocusUI("hotstrings_editor"),
		},
		"open_paths_editor", {
				Fn: (*) => GestureToggleOrFocusUI("paths_editor"),
		},
		; --- User files ---
		"open_script_source", {
				Fn: (*) => Run('notepad.exe "' . A_ScriptFullPath . '"'),
		},
		"open_personal_shortcuts", {
				Fn: (*) => GestureEditPersonalShortcuts(),
		},
		"open_personal_hotstrings", {
				Fn: (*) => GestureOpenIfExists(ScriptInformation["PersonalTomlPath"]),
		},
		"open_personal_info", {
				Fn: (*) => GestureOpenIfExists(ScriptInformation["PersonalInfoTomlPath"]),
		},
		"open_config", {
				Fn: (*) => GestureOpenIfExists(IsSet(ConfigurationFile) ? ConfigurationFile : ""),
		},
		"open_logs_folder", {
				Fn: (*) => OpenLogsFolder(),
		},
		"open_today_log", {
				Fn: (*) => OpenTodayLog(),
		},
		"open_error_log", {
				Fn: (*) => OpenErrorLog(),
		},
		; --- Script management ---
		"script_pause_toggle", {
				Fn: (*) => ToggleSuspend(),
		},
		"script_reload", {
				Fn: (*) => (LoggerInfo("Gestures", "Reload requested by the script_reload action."), ReloadPreservingSuspend()),
		},
		"script_save_reload", {
				Fn: (*) => GestureSaveAndReload(),
		},
		"script_quit", {
				Fn: (*) => ExitApp(),
		},
		; --- Debug (AHK only — Hammerspoon Console covers the three) ---
		"open_window_spy", {
				Fn: (*) => WindowSpy(),
		},
		"open_list_vars", {
				Fn: (*) => ConsoleWindow_Open("list_vars"),
		},
		"open_key_history", {
				Fn: (*) => ConsoleWindow_Open("key_history"),
		},
		; --- Advanced system actions ---
		"screen_capture_instant", {
				Fn: (*) => GestureScreenshotInstant(),
		},
		"open_url", {
				Fn: (BindingId := "") => GestureOpenConfiguredURL(BindingId),
		},
		"pick_color", {
				Fn: (*) => GesturePickColor(),
		},
		"take_note", {
				Fn: (*) => GestureTakeNote(),
		},
		"activity_simulation", {
				Fn: (*) => (
						IsSet(ToggleActivitySimulation) ? ToggleActivitySimulation() : LoggerWarn("gestures", "Activity Simulation is disabled in shortcuts config.")
				),
		},
		"search_web", {
				Fn: (BindingId := "") => GestureSearchWeb(BindingId),
		},
		"wrap_selection", {
				Fn: (BindingId := "") => GestureWrapSelection(BindingId),
		},
		"send_text", {
				Fn: (BindingId := "") => GestureSendInput("send_text", BindingId),
		},
		"send_key", {
				Fn: (BindingId := "") => GestureSendInput("send_key", BindingId),
		},
		"send_shortcut", {
				Fn: (BindingId := "") => GestureSendInput("send_shortcut", BindingId),
		},
		; The Win+D and Win+S shortcuts' own functions (modules/shortcuts/win.ahk),
		; so a gesture and the fixed shortcut cannot drift apart.
		"open_downloads", {
				Fn: (*) => OpenDownloads(),
		},
		"copy_selected_path", {
				Fn: (*) => Search(),
		},
		"open_file_manager", {
				Fn: (*) => GestureRunShellTarget("explorer.exe", "open_file_manager"),
		},
		"open_system_settings", {
				Fn: (*) => GestureRunShellTarget("ms-settings:", "open_system_settings"),
		},
		"teleport_mouse", {
				Fn: (*) => GestureTeleportMouse(),
		},
		"spotlight_mouse", {
				Fn: (*) => (MouseGetPos(&_Mx, &_My), SpotlightMouseAt(_Mx, _My, 5000)),
		},
		"toggle_capslock", {
				Fn: (*) => ToggleCapsLock(),
		},
		"microsoft_bold", {
				Fn: (*) => (MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")),
		},
		"paste_plain", {
				Fn: (*) => GesturePastePlain(),
		},
		; --- AI ---
		; The manual prediction trigger; it logs and shows every refusal itself.
		; The binding id is not forwarded: its only parameter is a test seam.
		"llm_generate_prediction", {
				Fn: (*) => LLM_Menu_TriggerPrediction(),
		},
		; The same request with the prompt (and count) the binding names; the
		; llm_predict_<profile> presets are registered below the Map.
		"llm_prompt_prediction", {
				Fn: (BindingId := "") => GesturePromptPrediction(BindingId),
		},
		; Live mode on with the prompt (and count) the binding names, or off.
		"llm_live_prompt_toggle", {
				Fn: (BindingId := "") => GestureLivePromptToggle(BindingId),
		},
		; The selection translated into the language the binding names.
		"llm_translate_context", { Fn: GestureTranslateContext },
		"llm_translate_selection", {
				Fn: (BindingId := "") => GestureTranslateSelection(BindingId),
		},
		; The AI agent: actions proposed for the selection or for a typed
		; command, and its automatic mode switched on or back to "on action".
		; Each shows its own refusals.
		"llm_agent_selection", {
				Fn: (*) => LLM_Agent_TriggerSelection(),
		},
		"llm_agent_command", {
				Fn: (*) => LLM_Agent_TriggerCommand(),
		},
		"llm_agent_auto_toggle", {
				Fn: (*) => LLM_Agent_ToggleAuto(),
		},
		; --- Tap-hold tap actions (exposed here so the tap picker can list them) ---
		; These are dispatched by the tap-hold runtime directly; the Fn below fires
		; when the action is triggered via a gesture slot instead.
		"one_shot_shift", {
				Fn: (*) => OneShotShift(),
		},
		"caps_word", {
				Fn: (*) => ToggleCapsWord(),
		},
		"alt_tab_monitor", {
				Fn: (*) => AltTabMonitor(),
		},
		"alt_tab_windows", {
				Fn: (*) => AltTabAll(),
		},
		"caps_lock", {
				Fn: (*) => ToggleCapsLock(),
		},
)

; ── Actions the shared catalogue fully describes ────────────────────────────
;
; 62 entries used to be written out above, each one spelling a key and its
; modifiers into a lambda — `copy` as TextPressKey("c", ["Ctrl"]), and the same
; fact spelled again in the macOS and Linux registries. Three copies of one
; thing, where a wrong copy is invisible: a `copy` action that sends Ctrl+X is
; not a crash and not a failing test.
;
; They now come from _shared/modules/actions/actions.toml through
; _generated/gesture_emit_actions.ahk. Registered HERE, at static-init: a
; handler built by anything deferred off the boot path would open a window in
; which a gesture fires and finds nothing registered.
for _EmitId, _Emit in GestureEmitActionsData() {
		if _Emit.HasOwnProp("Seq") {
				; Raw send sequence — no portable key/modifier form exists for it.
				GESTURE_ACTIONS[_EmitId] := { Fn: _GestureMakeSeqEmitter(_Emit.Seq) }
		} else {
				GESTURE_ACTIONS[_EmitId] := { Fn: _GestureMakeKeyEmitter(_Emit.Key, _Emit.Mods),
						Key: _Emit.Key, Mods: _Emit.Mods }
		}
}

; ── One ready-made prompt action per built-in profile ──────────────────────
;
; llm_predict_<id> is llm_prompt_prediction with that built-in profile and the
; AI menu's count. Registered from LLM_PROFILE_BUILTIN_ORDER, the driver's list
; of the built-ins in _shared/modules/llm/profiles.json, so a new built-in gets
; its action with no second list to update; the catalogue parity test fails if
; the generated catalogue and this registry ever disagree.
for _PresetProfileId in LLM_PROFILE_BUILTIN_ORDER {
		GESTURE_ACTIONS["llm_predict_" . _PresetProfileId] := { Fn: _GestureMakePromptPresetRunner(_PresetProfileId) }
}

; ── The tone ladder on the selection ────────────────────────────────────────
;
; llm_tone_more_formal / _familiar and their _cycle variants, one per
; direction x cycle entry of LLM_ToneActions (modules/llm/tone_action.ahk).
for _ToneActionId, _ToneStep in LLM_ToneActions() {
		GESTURE_ACTIONS[_ToneActionId] := { Fn: _GestureMakeToneRunner(_ToneStep.Direction, _ToneStep.Cycle) }
}

; ── Answering what is on the screen ────────────────────────────────────────
;
; llm_screen_region, llm_screen_full and llm_screen_error, one per entry of
; LLM_VisionActions (modules/llm/vision_action.ahk); the binding's llm_vision
; parameter names the vision backend.
for _VisionActionId, _VisionKind in LLM_VisionActions() {
		GESTURE_ACTIONS[_VisionActionId] := { Fn: _GestureMakeVisionRunner(_VisionActionId) }
}

; Every persisted gesture action must name the live catalogue.  The empty
; sentinel is exclusive to tap-hold, where it means native key passthrough.
GestureActionIsAssignable(ActionName, AllowNative := false) {
		global GESTURE_ACTIONS
		if !(ActionName is String)
				return false
		if (AllowNative && ActionName == "")
				return true
		return GESTURE_ACTIONS.Has(ActionName)
}

; Built in helper functions rather than inline: a closure created inside a loop
; captures the LOOP VARIABLE, so every handler would end up emitting whatever
; the last iteration happened to leave there. Passing the values as parameters
; gives each closure its own copy.
_GestureMakeKeyEmitter(Key, Mods) {
		return (*) => TextPressKey(Key, Mods)
}

_GestureMakeSeqEmitter(Seq) {
		return (*) => SendFinalResult(Seq)
}

; Same reason: the profile id arrives as a parameter, so each preset keeps its own.
_GestureMakePromptPresetRunner(ProfileId) {
		return (*) => LLM_Menu_TriggerPredictionWith(ProfileId, 0)
}

; Same reason: the direction and the cycle flag arrive as parameters.
_GestureMakeToneRunner(Direction, Cycle) {
		return (*) => LLM_Tone_Trigger(Direction, Cycle)
}

; Same reason: the action id arrives as a parameter.
_GestureMakeVisionRunner(ActionId) {
		return (BindingId := "") => GestureScreenVision(ActionId, BindingId)
}


; Returns the translated label for a gesture action, through the label key the
; generated catalogue declares for it. Returns the raw action name when the key
; is absent — labels are not hardcoded in GESTURE_ACTIONS, so the locale is the
; single source of truth, and test-action-catalogue-codegen.cjs fails on a
; catalogue label key missing from any locale.
_GestureActionLabel(Name) {
	global GESTURE_MODIFIER_ACTION_LABELS, GESTURE_ACTION_CATALOGUE
	if GESTURE_MODIFIER_ACTION_LABELS.Has(Name)
		return GESTURE_MODIFIER_ACTION_LABELS[Name]
	Key := (IsSet(GESTURE_ACTION_CATALOGUE) && GESTURE_ACTION_CATALOGUE.Actions.Has(Name))
		? GESTURE_ACTION_CATALOGUE.Actions[Name].LabelKey
		: "sg_actions." . Name
	Translated := t(Key)
	; t() returns the raw key when no translation is found — treat that as a miss
	if (Translated != Key)
		return Translated
	return Name
}


; --- Advanced system action implementations ---

GestureScreenshotInstant() {
		; Gesture callbacks use the driver's message thread too.  Contain window,
		; filesystem, and shell errors and never present a modal dialog from here.
		try {
				WinGetPos(&WX, &WY, &WW, &WH, "A")
				if (WW = 0 or WH = 0) {
						try TrayTip(t("shortcuts.no_active_window"), t("shortcuts.screenshot_title"), "Iconx Mute")
						return
				}
				FilePath := GestureScreenshotPath()
				; Route through the hardened shared capture path instead of an inline
				; fire-and-forget PowerShell block. GestureCaptureRegion escapes the path for
				; PowerShell (a USERPROFILE containing an apostrophe used to break the inline
				; single-quoted save call and kill the worker silently), polls the postcondition
				; with a deadline, fails closed while suspended, and reports success ONLY once
				; the file actually exists — the old code announced "saved" before the worker
				; had even run, so a failed capture still claimed success.
				LoggerStart("gestures", "Capturing screen to '{1}'…", FilePath)
				GestureCaptureRegion(WX, WY, WW, WH, "save", FilePath, GestureScreenshotComplete.Bind("Instant", "save", FilePath))
		} catch as Err {
				LoggerError("gestures", "GestureScreenshotInstant launch failed: {1}", Err.Message)
				try TrayTip("Screenshot could not start.", "ErgoptiPlus", "Iconx Mute")
		}
}

; Runs the llm_prompt_prediction action of one binding: its stored value names
; the prompt and, optionally, the count. The value is re-validated here, since
; the configuration file can be edited by hand; the prompt's existence is the
; trigger's check, which shows the unknown-prompt notice.
; @param {String} BindingId The binding whose parameter to read.
; @param {Func} FireFn Test seam forwarded to LLM_Menu_TriggerPredictionWith.
; @returns {Boolean} True when a prediction was requested.
GesturePromptPrediction(BindingId := "", FireFn := 0) {
		Value := GestureGetActionParameter(BindingId, "llm_prompt_prediction")
		Parsed := LLM_PromptAction_Parse(Value, &Reason)
		if !(Parsed is Map) {
				LoggerWarn("gestures", "llm_prompt_prediction ignored for binding '{1}': {2}.", BindingId, Reason)
				return false
		}
		return LLM_Menu_TriggerPredictionWith(Parsed["profile_id"],
				Parsed.Get("num_predictions", 0), FireFn, Parsed.Get("translation_target", ""))
}

; Runs the llm_live_prompt_toggle action of one binding. While live mode is on,
; any toggle binding turns it off, whatever it names, even a value no longer
; valid: the user must always be able to leave. Otherwise the stored value is
; re-validated like llm_prompt_prediction's and names the prompt and count.
; @param {String} BindingId The binding whose parameter to read.
; @returns {Boolean} True when live mode changed state.
GestureLivePromptToggle(BindingId := "") {
		if LLM_Engine_LiveIsActive()
				return LLM_Menu_StopLiveMode()
		Value := GestureGetActionParameter(BindingId, "llm_live_prompt_toggle")
		Parsed := LLM_PromptAction_Parse(Value, &Reason)
		if !(Parsed is Map) {
				LoggerWarn("gestures", "llm_live_prompt_toggle ignored for binding '{1}': {2}.", BindingId, Reason)
				return false
		}
		return LLM_Menu_ToggleLiveMode(Parsed["profile_id"], Parsed.Get("num_predictions", 0),
				Parsed.Get("translation_target", ""))
}

; Runs a screen action of one binding: its stored value names the vision
; backend, validated and resolved by the trigger, which shows every refusal.
; @param {String} ActionId llm_screen_region, llm_screen_full or llm_screen_error.
; @param {String} BindingId The binding whose parameter to read.
; @returns {Boolean} True when the capture started.
GestureScreenVision(ActionId, BindingId := "") {
		return LLM_Vision_Trigger(LLM_VisionActions()[ActionId],
				GestureGetActionParameter(BindingId, ActionId), LLM_Vision_AnswersKey(ActionId))
}

; Runs the llm_translate_selection action of one binding: its stored value
; names the target language, validated by the trigger after the refusals it
; shares with llm_generate_prediction.
; @param {String} BindingId The binding whose parameter to read.
; @returns {Boolean} True when the selection capture started.
GestureTranslateContext(BindingId := "", FireFn := 0) {
	Value := GestureGetActionParameter(BindingId, "llm_translate_context")
	if !LLM_Translate_IsValid(Value)
		return false
	return LLM_Menu_TriggerPredictionWith("translate", 1, FireFn, Value)
}

GestureTranslateSelection(BindingId := "") {
		return LLM_Translate_Trigger(GestureGetActionParameter(BindingId, "llm_translate_selection"))
}

GestureOpenConfiguredURL(BindingId := "") {
		URL := GestureGetActionParameter(BindingId, "open_url")
		ErrorText := ""
		if !GestureValidateActionParameter("open_url", URL, &ErrorText) {
				LoggerWarn("gestures", "open_url ignored for binding '{1}': {2}", BindingId, ErrorText)
				return
		}
		; URL validation proves shape, not launchability: shell associations and
		; policy may still reject it.  Keep that OS failure inside the gesture
		; callback so it cannot reach the keyboard driver's global error handler.
		try Run(URL)
		catch as Err {
				LoggerError("gestures", "open_url launch failed for binding '{1}': {2}", BindingId, Err.Message)
				try TrayTip("Could not open the configured URL.", "ErgoptiPlus", "Iconx Mute")
		}
}

; Opens a shell target (an executable or a URI such as ms-settings:). A refusal
; stays inside the gesture callback and is logged, never escalated to the
; driver's global error handler.
; @param {String} Target
; @param {String} ActionName For the log line.
GestureRunShellTarget(Target, ActionName) {
		try Run(Target)
		catch as Err
				LoggerError("gestures", "{1} could not open '{2}': {3}", ActionName, Target, Err.Message)
}

GesturePickColor() {
		; Gesture callbacks share the driver's single message thread.  Do not let
		; a PixelGetColor/clipboard failure escape or a blocking dialog stall input.
		try {
				MouseGetPos(&MouseX, &MouseY)
				HexColor := "#" . StrLower(SubStr(PixelGetColor(MouseX, MouseY, "RGB"), 3))
				if !CB_Write(HexColor)
						throw Error("clipboard write failed")
				TrayTip(HexColor, "ErgoptiPlus", "Iconi Mute")
		} catch as Err {
				LoggerError("gestures", "GesturePickColor failed: {1}", Err.Message)
				TrayTip("Color copy failed.", "ErgoptiPlus", "Iconx Mute")
		}
}

GestureTakeNote() {
		; Preserve the gesture's historical no-newline behaviour while delegating
		; every blocking/OS step to the same job used by the Win+N shortcut.
		return _TakeNoteQueueFromFeatures(false)
}



GestureSearchWeb(BindingId := "") {
		EngineQuery := GestureGetActionParameter(BindingId, "search_web")
		ErrorText := ""
		if !GestureValidateActionParameter("search_web", EngineQuery, &ErrorText) {
				LoggerWarn("gestures", "search_web ignored for binding '{1}': {2}", BindingId, ErrorText)
				return
		}
		GetSelectionAsync((Text) => _GestureSearchWebSelectionReady(Text, EngineQuery))
}

_GestureSearchWebSelectionReady(Text, EngineQuery) {
		SelectedText := Trim(Text)
		if (SelectedText = "")
				return
		SelectedText := StrReplace(SelectedText, "`r`n", " ")
		try Run(StrReplace(EngineQuery, "%s", UriEncode(SelectedText)))
		catch as Err {
				try LoggerError("gestures", "search_web launch failed: {1}", Err.Message)
		}
}

GestureTeleportMouse() {
		Monitors := []
		Count := MonitorGetCount()
		loop Count {
				MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
				Monitors.Push({Left: Left, Top: Top, Right: Right, Bottom: Bottom})
		}
		if (Count < 2) {
				Ui_MsgBox(t("shortcuts.no_other_monitor"))
				return
		}
		MouseGetPos(&CurX, &CurY)
		CurrentIndex := 1
		for I, Mon in Monitors {
				if (CurX >= Mon.Left and CurX < Mon.Right and CurY >= Mon.Top and CurY < Mon.Bottom) {
						CurrentIndex := I
						break
				}
		}
		NextIndex := (Mod(CurrentIndex, Count) + 1)
		Target := Monitors[NextIndex]
		TargetX := Target.Left + (Target.Right - Target.Left) // 2
		TargetY := Target.Top + (Target.Bottom - Target.Top) // 2
		MCSetPos(TargetX, TargetY)
		SpotlightMouseAt(TargetX, TargetY, 3000)
}

; Case action id -> the pure transform it applies to the selection
; (infra/text_case.ahk). The registry below and the shared-corpus replay
; (tests/unit/test_text_case_vectors.ahk) both read this map, so an id cannot be
; tested against one transform and run another.
; @returns {Map}
GestureCaseTransforms() {
		static Transforms := Map(
				"selection_uppercase", TextCaseUpper,
				"selection_lowercase", TextCaseLower,
				"selection_titlecase", TextCaseTitle,
				"uppercase_selection", TextCaseToggleUpper,
				"titlecase_selection", TextCaseToggleTitle,
		)
		return Transforms
}

; Captures the selection, applies Transform and pastes the result over it. The
; Win+U / Win+W shortcuts go through here too.
; @param {Func} Transform String -> String.
GestureTransformSelection(Transform) {
		GetSelectionAsync((Text) => _GestureSendTransformedSelection(Text, Transform))
}

_GestureSendTransformedSelection(Text, Transform) {
		; No-op on an empty/failed capture: async cancellation must never turn into
		; a stale SendInstant paste.
		if (Text = "")
				return
		SyntheticOwner := 0
		try SyntheticOwner := KL_MarkSynthetic("case-transform")
		try {
				SendInstant(Transform.Call(Text))
				SetTimer((*) => KL_ClearSynthetic(SyntheticOwner), -300)
		} catch {
				KL_ClearSynthetic(SyntheticOwner)
				throw
		}
}

; Built in a helper rather than inline, so each registered closure captures its
; own transform instead of the loop variable.
_GestureMakeCaseAction(Transform) {
		return (*) => GestureTransformSelection(Transform)
}

for _CaseActionId, _CaseTransform in GestureCaseTransforms()
		GESTURE_ACTIONS[_CaseActionId] := { Fn: _GestureMakeCaseAction(_CaseTransform) }

; The pair a wrap_selection parameter names, resolved against the built-in
; catalogue (_WS_BUILTIN_PAIRS, loaded from _shared/modules/wrap_symbols/wrap_symbols.json).
; @param {String} Value The stored parameter.
; @returns {Map|String} Map("left", ..., "right", ...), or "" when it names none.
GestureWrapPairFor(Value) {
		global _WS_BUILTIN_PAIRS
		return WrapPairParse(Value, _WS_BUILTIN_PAIRS)
}

; The transform wrap_selection applies for one binding: its own stored pair
; around the selection. "" when the binding stores no valid pair.
; @param {String} BindingId
; @returns {Func|String}
GestureWrapSelectionTransform(BindingId) {
		Pair := GestureWrapPairFor(GestureGetActionParameter(BindingId, "wrap_selection"))
		if !(Pair is Map)
				return ""
		return _GestureMakeWrapTransform(Pair["left"], Pair["right"])
}

_GestureMakeWrapTransform(Left, Right) {
		return (Text) => Left . Text . Right
}

; Wraps the selection with the binding's pair. Nothing selected: nothing is
; typed (the capture returns "" and the paste is skipped).
GestureWrapSelection(BindingId := "") {
		Transform := GestureWrapSelectionTransform(BindingId)
		if !(Transform is Func) {
				LoggerWarn("gestures", "wrap_selection ignored for binding '{1}': no valid pair is stored.", BindingId)
				return
		}
		GestureTransformSelection(Transform)
}

; Types the binding's text, or presses its key or shortcut (send_text, send_key,
; send_shortcut). The gesture's own Ctrl+Win+Shift carrier is released first, as
; for every shortcut a gesture sends, so it cannot join the chord.
; @param {String} ActionName send_text, send_key or send_shortcut.
; @param {String} BindingId The binding whose parameter holds the value.
; @returns {Boolean} True when the input was sent.
GestureSendInput(ActionName, BindingId := "") {
		Kind := GestureActionParameterSpec(ActionName)
		Parsed := SendInputParse(Kind, GestureGetActionParameter(BindingId, ActionName))
		if !(Parsed is Map) {
				LoggerWarn("gestures", "{1} ignored for binding '{2}': no valid value is stored.", ActionName, BindingId)
				return false
		}
		if !GestureReleaseOwnedCarrierModifiers()
				return false
		if !SendInputEmit(Kind, Parsed) {
				LoggerError("gestures", "{1} for binding '{2}' was not sent.", ActionName, BindingId)
				return false
		}
		; The length of a text, never the text: it is the user's own and may be private.
		LoggerDebug("gestures", "{1} for binding '{2}' sent {3}.", ActionName, BindingId,
				(Kind == "text") ? StrLen(Parsed["text"]) . " character(s)" : Parsed["canonical"])
		return true
}

; Deferred clipboard restore for GesturePastePlain. Runs on a negative-delay
; SetTimer so the synthetic ^v has already consumed the coerced text before the
; user's original (possibly non-text) clipboard is put back.
_GesturePastePlainRestore(OldClip, OwnedSequence, OwnerToken) {
		return CB_RestoreOwnedAllEventually(OldClip, OwnedSequence, OwnerToken,
				"gesture_paste_plain")
}

GesturePastePlain() {
		if not WinActive("ahk_exe EXCEL.EXE") {
				; Strip rich formatting only when the clipboard holds text. CB_Read()
				; returns "" for non-text payloads (image/file list); the self-assign
				; round-trip on those would destroy them, so we skip the strip and
				; paste the content as-is instead.
				if CB_Read() != "" {
						; Skip the save/restore dance while SendInstant is already mid-flight
						; to avoid a second thread trampling the in-flight clipboard before
						; the first paste settles.
						OwnerToken := CB_TryBeginPasteTransaction("gesture_paste_plain")
						if !OwnerToken {
								SendFinalResult("^v")
								return
						}
						; Snapshot the FULL clipboard (all formats) before coercing to
						; plain text. A_Clipboard := A_Clipboard keeps only the text form,
						; silently dropping any image/HTML/RTF the user may still want, so
						; we restore the original after the paste settles -- mirroring
						; SendInstant's save/paste/deferred-restore guarantee.
						OldClip := CB_SaveAll()
						if (Type(OldClip) == "String" && OldClip == "__CB_SAVE_ERROR__") {
								CB_EndOwnedTransaction(OwnerToken)
								try LoggerWarn("gestures", "GesturePastePlain: clipboard snapshot failed; using native paste.")
								SendFinalResult("^v")
								return
						}
						PlainText := CB_Read()
						OwnedSequence := 0
						try {
								if !CB_Write(PlainText)
										throw Error("clipboard write failed")
								OwnedSequence := CB_GetSequenceNumber()
								if !OwnedSequence
										throw Error("clipboard sequence unavailable")
								SendFinalResult("^v")
								SetTimer(_GesturePastePlainRestore.Bind(OldClip, OwnedSequence, OwnerToken), -SEND_INSTANT_PASTE_DELAY_MS)
						} catch as e {
								try CB_RestoreOwnedAllEventually(OldClip, OwnedSequence,
										OwnerToken, "gesture_paste_plain_rollback", true,
										!OwnedSequence)
								try LoggerError("gestures", "GesturePastePlain threw during paste — clipboard rollback retained: {1}.", e.Message)
						}
				} else {
						SendFinalResult("^v")
				}
		} else {
				SendFinalResult("^+v")
		}
}

; Modifier + key actions are generated from the cross-driver catalogue. This
; replaces the former partial, AHK-only Ctrl/Alt/Win tables with every non-empty
; combination of Ctrl, Shift, Alt and Win for every catalogue key.
global GESTURE_MODIFIER_ACTION_LABELS := Map()
global GESTURE_MODIFIER_ACTION_GROUPS := []

_GestureJoin(Values, Separator) {
		Result := ""
		for Index, Value in Values
				Result .= (Index = 1 ? "" : Separator) . Value
		return Result
}

_GestureRegisterModifierChords() {
		global GESTURE_ACTIONS, GESTURE_MODIFIER_ACTION_LABELS, GESTURE_MODIFIER_ACTION_GROUPS, _SharedDir

		Path := _SharedDir . "\modules\actions\modifier_chords.json"
		Raw := FSRead(Path)
		if (Raw = false) {
				try LoggerWarn("gestures", "Cannot load shared modifier chords from '{1}'.", Path)
				return
		}
		try Root := JsonParse(Raw)
		catch as Err {
				try LoggerWarn("gestures", "Cannot load shared modifier chords: {1}", Err.Message)
				return
		}
		if !(Root is Map) || !Root.Has("keys") || !Root.Has("platforms") || !Root["platforms"].Has("windows")
				return
		Platform := Root["platforms"]["windows"]
		if !Platform.Has("modifiers") || !(Platform["modifiers"] is Array)
				return

		Modifiers := Platform["modifiers"]
		Keys      := Root["keys"]
		MaxMask   := (1 << Modifiers.Length) - 1
		loop MaxMask {
				Mask      := A_Index
				IdParts   := []
				LabelParts := []
				Prefixes  := []
				loop Modifiers.Length {
						Bit := A_Index - 1
						if !(Mask & (1 << Bit))
								continue
						Modifier := Modifiers[A_Index]
						IdParts.Push(Modifier["id"])
						LabelParts.Push(Modifier["label"])
						Prefixes.Push(Modifier["ahk_prefix"])
				}
				IdPrefix := _GestureJoin(IdParts, "_")
				LabelPrefix := _GestureJoin(LabelParts, " + ")
				SendPrefix := _GestureJoin(Prefixes, "")
				Group := { Label: LabelPrefix, Actions: [] }
				for _, KeyDef in Keys {
						KeyId   := KeyDef["id"]
						KeyCode := KeyDef.Has("windows_key") ? KeyDef["windows_key"] : KeyId
						; The Send form may be braced ("{Space}"); the key a tap-hold
						; types is the bare name, which the hotkey form always is.
						BareKey := KeyDef.Has("windows_hotkey_key") ? KeyDef["windows_hotkey_key"] : KeyCode
						ActionId := IdPrefix . "_" . KeyId
						GESTURE_MODIFIER_ACTION_LABELS[ActionId] := LabelPrefix . " + " . KeyDef["label"]
						Group.Actions.Push(ActionId)
						GESTURE_ACTIONS[ActionId] := {
								Fn: ((_keys) => (*) => GestureSendShortcut(_keys))(SendPrefix . KeyCode),
								Key: BareKey,
								Mods: IdParts.Clone(),
						}
				}
				GESTURE_MODIFIER_ACTION_GROUPS.Push(Group)
		}
}

_GestureRegisterModifierChords()

; Opens an arbitrary path in Notepad if it exists. Used by every "open user
; file" gesture so a fresh install with no personal_info.toml yet quietly
; falls through instead of spawning Notepad on a blank path.
GestureOpenIfExists(Path) {
		if (Path = "" or !FileExist(Path)) {
				return
		}
		Run('notepad.exe "' . Path . '"')
}

; Toggle / focus / open helper shared by every ui_* action above.
; Centralising the three-state logic keeps the action map declarative
; and the per-UI lookup table is the only piece that needs editing
; when a new dashboard / editor lands.
GestureToggleOrFocusUI(which) {
		; Lookup table: which → { hwnd_getter, opener, closer }.
		; - hwnd_getter returns the current window HWND if open, 0 otherwise.
		; - opener is the function that opens the UI from scratch.
		; - closer destroys the UI window.
		switch which {
				case "metrics_typing":
						GestureGenericToggleUI(
								() => KLWV.windows.Has("typing") ? KLWV.windows["typing"]["gui"].Hwnd : 0,
								() => KLUI_ToggleTyping(),
								() => KLWV.windows.Has("typing") ? KLWV_Close("typing") : 0
						)
				case "metrics_apps":
						GestureGenericToggleUI(
								() => KLWV.windows.Has("apps") ? KLWV.windows["apps"]["gui"].Hwnd : 0,
								() => KLUI_ToggleApps(),
								() => KLWV.windows.Has("apps") ? KLWV_Close("apps") : 0
						)
				case "hotstrings_editor":
						; The TOML editor is a transient Gui — no persistent handle
						; tracked, so we can't reliably foreground an existing one.
						; Always open: a second call surfaces the most recent window.
						try OpenPersonalEditor()
				case "paths_editor":
						try FilePathsEditor()
		}
}

; Close-if-focused, foreground-if-background, open-if-closed for any UI
; whose host exposes an HWND. The three callbacks let each UI plug its
; own handle / open / close functions without duplicating the dispatch
; logic.
GestureGenericToggleUI(get_hwnd_fn, open_fn, close_fn) {
		try {
				return _GestureGenericToggleUIWith(
						get_hwnd_fn,
						open_fn,
						close_fn,
						(Hwnd) => WMExists("ahk_id " . Hwnd),
						(*) => WinGetID("A"),
						(Hwnd) => WMActivate("ahk_id " . Hwnd)
				)
		} catch as Err {
				LoggerError("gestures", "GestureGenericToggleUI dispatch failed: {1}.", Err.Message)
				return false
		}
}

_GestureGenericToggleUIWith(get_hwnd_fn, open_fn, close_fn, exists_fn, focused_fn, activate_fn) {
		hwnd := get_hwnd_fn.Call()
		if !(hwnd && exists_fn.Call(hwnd)) {
				open_fn.Call()
				return true
		}

		if (focused_fn.Call() = hwnd) {
				close_fn.Call()
				return true
		}
		if activate_fn.Call(hwnd)
				return true

		; Activation can lose a close race after the first existence probe. Reopen
		; only when absence is now proven; a live HWND must never be duplicated.
		if !exists_fn.Call(hwnd) {
				open_fn.Call()
				return true
		}
		throw Error("Existing UI window refused activation.")
}

; True when the foreground window is a shell / terminal. Ctrl+S there is not a
; document save (consoles use XOFF pause or other bindings) — skip it so
; Kana+Backspace reload does not disturb PowerShell when AHK is active.
_GestureIsTerminalForeground() {
		try {
				cls := WinGetClass("A")
				exe := WinGetProcessName("A")
		} catch {
				return false
		}
		if (cls = "ConsoleWindowClass" || cls = "CASCADIA_HOSTING_WINDOW_CLASS"
				|| cls = "PseudoConsoleWindow") {
				return true
		}
		static TerminalExes := Map(
				"WindowsTerminal.exe", true, "wt.exe", true,
				"pwsh.exe", true, "powershell.exe", true, "cmd.exe", true)
		return TerminalExes.Has(exe)
}

; Save the active document with Ctrl+S then reload — mirrors the legacy
; AltGr+BackSpace shortcut that pre-dated the action registry.
GestureSaveAndReload() {
		if !_GestureIsTerminalForeground() {
				TextPressKey("s", ["Ctrl"])
				Sleep(300)
		}
		ReloadPreservingSuspend()
}

; Ensure personal_shortcuts.ahk exists (creating it from the template on
; first use) before opening it in Notepad.
GestureEditPersonalShortcuts() {
		Path := ScriptInformation["PersonalAhkPath"]
		; AllowReload=false: opening the file for editing must never restart the driver
		; (the unconditional Reload/ExitApp in EnsurePersonalShortcutsFile would kill this
		; process before the Run below, so the editor never opened when the file/stub was
		; freshly (re)created).
		if !EnsurePersonalShortcutsFile(Path, false) {
				ConfigReportPersistenceFailure("the personal shortcuts bootstrap")
				return false
		}
		try {
				Run('notepad.exe "' . Path . '"')
				return true
		} catch as Err {
				try LoggerError("Gestures", "Could not open personal shortcuts at '{1}': {2}.", Path, Err.Message)
				return false
		}
}

; The Windows action catalogue, generated from _shared/modules/actions/actions.toml
; by tools/codegen/codegen-action-catalogue.cjs and already filtered to this
; platform. It used to be built by parsing the TOML with ParseTomlFile inside a
; loader deferred off the boot path (a SetTimer worth ~100 ms); the generated
; file is plain data, so there is nothing left to defer and no window in which
; the picker is empty.
global GESTURE_ACTION_CATALOGUE := GestureActionCatalogueData()
global GestureActionParameters := Map()

; Ordered action ids the picker lists, modifier-chord block expanded, "none"
; included. The single list every picker and the parity test walk.
; @returns {Array}
GestureActionPickerIds() {
		global GESTURE_ACTION_CATALOGUE, GESTURE_MODIFIER_ACTION_GROUPS
		Ids := []
		for _, Item in GESTURE_ACTION_CATALOGUE.SgItems {
				switch Item.Kind {
						case "action":
								Ids.Push(Item.Id)
						case "modifier_chords":
								for _, Group in GESTURE_MODIFIER_ACTION_GROUPS
										for _, ActionId in Group.Actions
												Ids.Push(ActionId)
						case "heading":
								continue
						default:
								throw ValueError("Unknown action catalogue item kind '" . Item.Kind . "'.")
				}
		}
		return Ids
}

; Ordered picker items for the active language: headings carry their level and
; translated text, actions their id and label. "none" is left out because both
; pickers add their own translated "nothing" row.
; @returns {Array} of { Type: "heading", Level, Text } / { Type: "action", Id, Label }
GestureActionPickerItems() {
		global GESTURE_ACTION_CATALOGUE, GESTURE_MODIFIER_ACTION_GROUPS
		Items := []
		for _, Item in GESTURE_ACTION_CATALOGUE.SgItems {
				switch Item.Kind {
						case "heading":
								Items.Push({ Type: "heading", Level: Item.Level, Text: _GestureHeadingText(Item.Key) })
						case "action":
								if (Item.Id != "none")
										Items.Push({ Type: "action", Id: Item.Id, Label: _GestureActionLabel(Item.Id) })
						case "modifier_chords":
								; One sub-heading per modifier combination. The combination label
								; ("Ctrl + Shift") is language-neutral; the words around it are not,
								; which is why this used to read "Raccourcis Ctrl" in every locale.
								Template := t(Item.GroupKey)
								for _, Group in GESTURE_MODIFIER_ACTION_GROUPS {
										Items.Push({ Type: "heading", Level: Item.Level,
												Text: StrReplace(Template, "{1}", Group.Label) })
										for _, ActionId in Group.Actions
												Items.Push({ Type: "action", Id: ActionId, Label: _GestureActionLabel(ActionId) })
								}
						default:
								throw ValueError("Unknown action catalogue item kind '" . Item.Kind . "'.")
				}
		}
		return Items
}

; The translated text of one picker heading. Older header values carry a
; leading "#" from when the level was spelled inside the text; the level now
; comes only from the catalogue, so the marker is stripped.
_GestureHeadingText(Key) {
		Text := t(Key)
		while (SubStr(Text, 1, 1) = "#")
				Text := SubStr(Text, 2)
		return Text
}

; Explicit restore actions from the manifest recommendation (constants.ahk).
global GESTURE_FACTORY_DEFAULTS := GestureRecommendedActions()

; Current assignments start neutral; explicit config overrides them later.
global GestureAssignments := Map()
for _GestureAssignmentSlot in GestureSlotIds()
		GestureAssignments[_GestureAssignmentSlot] := ManifestDefaultFor("gestures." . _GestureAssignmentSlot)

; Window cycle tracker — ordered by manual user activation (most-recent first).
; _GestureCycling is set True while our own WinActivate runs so the WinEvent
; hook ignores the synthetic focus change and keeps the list stable.
global _GestureWinOrder   := []   ; Array of HWNDs, index 1 = most recently manually focused
global _GestureCycling    := False
global _GestureWinHook    := 0    ; DllCall hook handle
; HWNDs we just activated programmatically (cycle gestures), mapped to the tick at
; activation time. The EVENT_SYSTEM_FOREGROUND for our own WinActivate is delivered
; ASYNCHRONOUSLY (OUTOFCONTEXT hook), so the synchronous _GestureCycling boolean is
; already cleared by the time it fires and the recency tracker would otherwise record
; our own activation as a manual one. _GestureOnForeground consumes a matching HWND
; within the TTL below to fence the async event (gesture-cycle-winevent-async-fence).
global _GestureSelfActivated := Map()
global GESTURE_SELF_ACTIVATE_TTL_MS := 500  ; ms a self-activation's WinEvent is expected within

; Upper bound on the recency tracker. WinEvent fires on every foreground change,
; so on a machine left running for days opening/closing thousands of transient
; windows the list would otherwise grow without limit — costing an O(n) prune on
; every win_next/win_prev gesture and slowly climbing memory. Stale HWNDs are
; filtered out at read time (_GestureOrderedWindows), so dropping the oldest
; tracked entries past this cap only loses deep history no cycle would reach.
global GESTURE_WIN_ORDER_MAX := 64
