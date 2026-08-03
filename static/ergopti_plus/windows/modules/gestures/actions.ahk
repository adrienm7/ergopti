; modules/gestures/actions.ahk

; ==============================================================================
; MODULE: Gesture Action Catalogue & Implementations
; DESCRIPTION:
; Mirrors macos/modules/gestures/actions.lua. Contains the complete gesture
; action registry (GESTURE_ACTIONS Map), all action implementation functions
; (GestureScreenshotInstant, GestureOpenConfiguredURL, etc.), the deferred
; catalogue loader (_GestureLoadActionCatalog), and the shared state used by
; the dispatcher (GestureAssignments, window-cycle tracker).
;
; Included by modules/gestures/init.ahk after the constants block.
; ==============================================================================

; Action registry — each action has a label and an execution function
global GESTURE_ACTIONS := Map(
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
		"tab", {
				Fn: (*) => LLM_Tooltip_FireTabOrAccept([]),
		},
		; --- Tabs ---
		"tab_prev", {
				Fn: (*) => GestureSendShortcut("^+{Tab}"),
		},
		"tab_next", {
				Fn: (*) => GestureSendShortcut("^{Tab}"),
		},
		; --- Browser navigation ---
		"nav_back", {
				Fn: (*) => GestureSendShortcut("!{Left}"),
		},
		"nav_forward", {
				Fn: (*) => GestureSendShortcut("!{Right}"),
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
				Fn: (*) => Reload(),
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
				Fn: (*) => ListVars(),
		},
		"open_key_history", {
				Fn: (*) => KeyHistory(),
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
		"teleport_mouse", {
				Fn: (*) => GestureTeleportMouse(),
		},
		"uppercase_selection", {
				Fn: (*) => GestureToggleUppercase(),
		},
		"titlecase_selection", {
				Fn: (*) => GestureToggleTitleCase(),
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
; _generated/gesture_emit_actions.ahk. Registered HERE, at static-init, and not
; in _GestureLoadActionCatalog(): that loader is deliberately deferred off the
; boot path, so building handlers there would open a window in which a gesture
; fires and finds nothing registered.
for _EmitId, _Emit in GestureEmitActionsData() {
		if _Emit.HasOwnProp("Seq") {
				; Raw send sequence — no portable key/modifier form exists for it.
				GESTURE_ACTIONS[_EmitId] := { Fn: _GestureMakeSeqEmitter(_Emit.Seq) }
		} else {
				GESTURE_ACTIONS[_EmitId] := { Fn: _GestureMakeKeyEmitter(_Emit.Key, _Emit.Mods) }
		}
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


; Returns the translated label for a gesture action.
; Uses t("sg_actions.X") from the active locale JSON as the canonical source.
; Falls back to the raw action name when the key is absent — labels are no
; longer hardcoded in GESTURE_ACTIONS, so the locale is the single source of truth.
_GestureActionLabel(Name) {
	global GESTURE_MODIFIER_ACTION_LABELS
	if GESTURE_MODIFIER_ACTION_LABELS.Has(Name)
		return GESTURE_MODIFIER_ACTION_LABELS[Name]
	Key := "sg_actions." . Name
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
				PicsDir := EnvGet("USERPROFILE") . "\Pictures\screenshots"
				if !DirExist(PicsDir)
						DirCreate(PicsDir)
				Timestamp := FormatTime(, "yyyy_MM_dd_HH") . "h" . FormatTime(, "mm") . "min" . FormatTime(, "ss") . "sec"
				FilePath := PicsDir . "\screenshot_" . Timestamp . ".png"
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
		global Features
		DatedNotes := false
		DestFolder := A_Desktop
		if IsSet(Features) and Features.Has("shortcuts")
				and Features["shortcuts"].Has("take_note")
				and IsObject(Features["shortcuts"]["take_note"]) {
				TN := Features["shortcuts"]["take_note"]
				if TN.Has("dated_notes")
						DatedNotes := (TN["dated_notes"] = true)
				if TN.Has("destination_folder") and TN["destination_folder"] != ""
						DestFolder := TN["destination_folder"]
		}
		FileName := DatedNotes
				? "Notes_" . FormatTime(, "dd_MM_yyyy") . ".txt"
				: "Notes.txt"
		FilePath := DestFolder . "\" . FileName
		if not FileExist(FilePath)
				FileAppend("", FilePath)
		PreviousTitleMatchMode := A_TitleMatchMode
		try {
				SetTitleMatchMode(2)
				; Qualify with ahk_exe notepad.exe to avoid stealing focus from any
				; other window (Explorer, browser tab…) whose title happens to contain
				; the note filename (e.g. "Notes.txt" in the address bar).
				NotepadMatch := FileName . " ahk_exe notepad.exe"
				if WMExists(NotepadMatch) {
						WMActivate(NotepadMatch)
						NoteWindowIsActive := WinWaitActive(NotepadMatch, , 3)
				} else {
						Run('notepad.exe "' . FilePath . '"')
						WinWait(NotepadMatch, , 7)
						WMActivate(NotepadMatch)
						NoteWindowIsActive := WinWaitActive(FileName . " ahk_exe notepad.exe", , 3)
				}
				; WinWaitActive returns 0 (not a throw) on timeout, so a slow/blocked
				; Notepad launch must not fall through to a bare WinMaximize -- that
				; operates on the last-found-window and throws TargetError when the
				; wait never actually found one (same bug as the already-fixed sibling
				; TakeNote in modules/shortcuts/win.ahk).
				if not NoteWindowIsActive {
						LoggerWarn("GestureTakeNote", "Notepad window '{1}' never became active -- skipping maximize.", NotepadMatch)
				} else {
						WinMaximize()
						Sleep(100)
				}
		} finally {
				SetTitleMatchMode(PreviousTitleMatchMode)
		}
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
		try Run(StrReplace(EngineQuery, "%s", GestureUrlEncode(SelectedText)))
		catch as Err {
				try LoggerError("gestures", "search_web launch failed: {1}", Err.Message)
		}
}

; Encodes the selected Unicode text as an RFC 3986 query component. Partial
; replacement (only '&', '+', …) corrupts spaces, accents and '=' in searches.
GestureUrlEncode(Value) {
		Bytes := Buffer(StrPut(Value, "UTF-8"))
		StrPut(Value, Bytes, "UTF-8")
		Encoded := ""
		Loop Bytes.Size - 1 {
				Byte := NumGet(Bytes, A_Index - 1, "UChar")
				if ((Byte >= 0x41 && Byte <= 0x5A) || (Byte >= 0x61 && Byte <= 0x7A)
						|| (Byte >= 0x30 && Byte <= 0x39) || Byte = 0x2D || Byte = 0x2E
						|| Byte = 0x5F || Byte = 0x7E) {
						Encoded .= Chr(Byte)
				} else {
						Encoded .= "%" . Format("{:02X}", Byte)
				}
		}
		return Encoded
}

GestureTeleportMouse() {
		Monitors := []
		Count := MonitorGetCount()
		loop Count {
				MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
				Monitors.Push({Left: Left, Top: Top, Right: Right, Bottom: Bottom})
		}
		if (Count < 2) {
				MsgBox(t("shortcuts.no_other_monitor"))
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

GestureToggleUppercase() {
		GetSelectionAsync(_GestureToggleUppercaseSelection)
}

_GestureToggleUppercaseSelection(Text) {
		; No-op on an empty/failed capture: async cancellation must never turn into
		; a stale SendInstant paste.
		if (Text = "")
				return
		try KL_MarkSynthetic("case-transform")
		if RegExMatch(Text, "[a-zà-ÿ]")
				SendInstant(Format("{:U}", Text))
		else
				SendInstant(Format("{:L}", Text))
		SetTimer((*) => KL_ClearSynthetic(), -300)
}

GestureToggleTitleCase() {
		GetSelectionAsync(_GestureToggleTitleCaseSelection)
}

_GestureToggleTitleCaseSelection(Text) {
		; No-op on an empty/failed capture (see GestureToggleUppercase).
		if (Text = "")
				return
		TitleCasePattern :=
				"^(?:[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*[ \t\r\n]+)*[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*$"
		UpperCasePattern := "^[A-ZÉÈÀÙÂÊÎÔÛÇ0-9''\(\),.\-:;!?\s]+$"
		try KL_MarkSynthetic("case-transform")
		if RegExMatch(Text, TitleCasePattern)
				SendInstant(Format("{:L}", Text))
		else
				SendInstant(Format("{:T}", Text))
		SetTimer((*) => KL_ClearSynthetic(), -300)
}

; Deferred clipboard restore for GesturePastePlain. Runs on a negative-delay
; SetTimer so the synthetic ^v has already consumed the coerced text before the
; user's original (possibly non-text) clipboard is put back.
_GesturePastePlainRestore(OldClip, OwnedSequence) {
		global _SEND_INSTANT_CLIP_BUSY
		try {
				; A user's later copy owns a different sequence and must survive this
				; deferred cleanup rather than being replaced with our old snapshot.
				if (OwnedSequence != 0 && CB_GetSequenceNumber() = OwnedSequence)
						CB_RestoreAll(OldClip)
		} finally {
				_SEND_INSTANT_CLIP_BUSY := false
		}
}

GesturePastePlain() {
		global _SEND_INSTANT_CLIP_BUSY
		if not WinActive("ahk_exe EXCEL.EXE") {
				; Strip rich formatting only when the clipboard holds text. CB_Read()
				; returns "" for non-text payloads (image/file list); the self-assign
				; round-trip on those would destroy them, so we skip the strip and
				; paste the content as-is instead.
				if CB_Read() != "" {
						; Skip the save/restore dance while SendInstant is already mid-flight
						; to avoid a second thread trampling the in-flight clipboard before
						; the first paste settles.
						if _SEND_INSTANT_CLIP_BUSY {
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
								try LoggerWarn("gestures", "GesturePastePlain: clipboard snapshot failed; using native paste.")
								SendFinalResult("^v")
								return
						}
						PlainText := CB_Read()
						_SEND_INSTANT_CLIP_BUSY := true
						OwnedSequence := 0
						try {
								if !CB_Write(PlainText)
										throw Error("clipboard write failed")
								OwnedSequence := CB_GetSequenceNumber()
								if !OwnedSequence
										throw Error("clipboard sequence unavailable")
								SendFinalResult("^v")
								SetTimer(_GesturePastePlainRestore.Bind(OldClip, OwnedSequence), -SEND_INSTANT_PASTE_DELAY_MS)
						} catch as e {
								if (!OwnedSequence || CB_GetSequenceNumber() = OwnedSequence)
										CB_RestoreAll(OldClip)
								_SEND_INSTANT_CLIP_BUSY := false
								try LoggerError("gestures", "GesturePastePlain threw during paste — clipboard and guard restored: {1}.", e.Message)
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
						ActionId := IdPrefix . "_" . KeyId
						GESTURE_MODIFIER_ACTION_LABELS[ActionId] := LabelPrefix . " + " . KeyDef["label"]
						Group.Actions.Push(ActionId)
						GESTURE_ACTIONS[ActionId] := {
								Fn: ((_keys) => (*) => GestureSendShortcut(_keys))(SendPrefix . KeyCode),
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
		hwnd := 0
		try hwnd := get_hwnd_fn.Call()
		if (hwnd && WMExists("ahk_id " . hwnd)) {
				focused := 0
				try focused := WinGetID("A")
				if (focused = hwnd) {
						try {
								close_fn.Call()
						} catch as Err {
								LoggerError("gestures", "GestureGenericToggleUI close_fn threw: {1}.", Err.Message)
						}
				} else {
						try WMActivate("ahk_id " . hwnd)
				}
				return
		}
		try {
				open_fn.Call()
		} catch as Err {
				LoggerError("gestures", "GestureGenericToggleUI open_fn threw: {1}.", Err.Message)
		}
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
		EnsurePersonalShortcutsFile(Path, false)
		Run('notepad.exe "' . Path . '"')
}

; Ordered list of action names for the menu — built from the shared TOML so
; Hammerspoon and AHK always show the same picker order, filtering each side
; to its own platform entries. "--" entries become visual separators;
; "#Titre" entries become non-selectable section headers.
global GESTURE_ACTION_NAMES := []
global GESTURE_AX_NAMES := []
global GESTURE_ACTION_PARAMETER_SPECS := Map()
global GestureActionParameters := Map()

; True when a catalogue `platform` field claims this driver.
;
; The field is "all", one driver key, or a comma-separated list of them. The
; list form exists because the field could not previously say "two drivers out
; of three": the two window cyclers ship on Windows and macOS and not on Linux,
; and both single-value answers were false — "all" put dead rows in the Linux
; picker, "ahk" or "hs" hid half the feature.
_GestureActionClaimsThisPlatform(Platform) {
		if (Platform = "" || Platform = "all")
				return true
		for _, Key in StrSplit(Platform, ",", " `t")
				if (Key = "ahk")
						return true
		return false
}

; Populate GESTURE_ACTION_NAMES / GESTURE_AX_NAMES by parsing the shared
; cross-platform action registry (actions.toml). These lists are only needed
; when the gesture-picker menu is built — which happens in the deferred
; initMenu phase (~250 ms after boot). Deferring the TOML parse off the
; critical boot path removes ~100 ms from the gestures module init time.
; A run-once SetTimer(-1) fires ~1 ms after the auto-execute section finishes,
; well before initMenu runs, so the lists are always ready for the menu.
_GestureLoadActionCatalog(*) {
		global GESTURE_ACTION_NAMES, GESTURE_AX_NAMES, GESTURE_ACTIONS, GESTURE_MODIFIER_ACTION_GROUPS, GESTURE_ACTION_PARAMETER_SPECS, _SharedDir

		GESTURE_ACTION_NAMES := []
		GESTURE_AX_NAMES := []
		GESTURE_ACTION_PARAMETER_SPECS := Map()

		_SharedToml := _SharedDir . "\modules\actions\actions.toml"
		_Toml       := ParseTomlFile(_SharedToml)

		; Build GESTURE_ACTION_NAMES from [sg_order].items, keeping only entries
		; that are sentinels ("--", "#…") or actions whose platform is "all"/"ahk".
		if _Toml.Has("sg_order") && _Toml["sg_order"].Has("items") {
				for _, _Item in _Toml["sg_order"]["items"] {
						; Sentinels and headers pass through unconditionally
						if (_Item = "--" || SubStr(_Item, 1, 1) = "#") {
								GESTURE_ACTION_NAMES.Push(_Item)
								continue
						}
						; The shared modifier-chord placeholder expands to the complete
						; platform-native matrix registered from modifier_chords.json.
						if (SubStr(_Item, 1, 1) = "_") {
								if (_Item = "_modifier_chords_placeholder") {
										for _, _Group in GESTURE_MODIFIER_ACTION_GROUPS {
												GESTURE_ACTION_NAMES.Push("##Raccourcis " . _Group.Label)
												for _, _ActionId in _Group.Actions
														GESTURE_ACTION_NAMES.Push(_ActionId)
										}
								}
								continue
						}
						; Regular action — keep if platform is "all" or "ahk"
						_SecKey := "sg_actions." . _Item
						if _Toml.Has(_SecKey) {
								if _Toml[_SecKey].Has("parameter")
										GESTURE_ACTION_PARAMETER_SPECS[_Item] := _Toml[_SecKey]["parameter"]
								_Plat := _Toml[_SecKey].Has("platform") ? _Toml[_SecKey]["platform"] : "all"
								if _GestureActionClaimsThisPlatform(_Plat)
										GESTURE_ACTION_NAMES.Push(_Item)
						} else if GESTURE_ACTIONS.Has(_Item) {
								; Action exists in registry but not in shared TOML — include it
								GESTURE_ACTION_NAMES.Push(_Item)
						}
				}
		}

		; Build GESTURE_AX_NAMES from [ax_order].items, same filtering logic.
		if _Toml.Has("ax_order") && _Toml["ax_order"].Has("items") {
				for _, _Item in _Toml["ax_order"]["items"] {
						_SecKey := "ax_actions." . _Item
						if _Toml.Has(_SecKey) {
								_Plat := _Toml[_SecKey].Has("platform") ? _Toml[_SecKey]["platform"] : "all"
								if _GestureActionClaimsThisPlatform(_Plat)
										GESTURE_AX_NAMES.Push(_Item)
						}
				}
		}
}
; Run-once, deferred off the boot path. MUST be a negative NON-ZERO period:
; AHK v2 treats -0 as 0, and SetTimer(fn, 0) DISABLES the timer (the callback
; never fires), which left GESTURE_ACTION_NAMES empty and the action picker
; blank. -1 fires once ~1 ms after the auto-execute section finishes.
SetTimer(_GestureLoadActionCatalog, -1)

; Factory gesture slot actions — mirrors features_manifest.ahk defaults.
global GESTURE_FACTORY_DEFAULTS := Map(
		"tap_3", "left_click_toggle",
		"swipe_3_up", "tab_new",
		"swipe_3_down", "tab_close",
		"swipe_3_left", "tab_prev",
		"swipe_3_right", "tab_next",
		"tap_4", "screenshot_window_clipboard",
		"swipe_4_up", "win_app_next",
		"swipe_4_down", "win_app_prev",
		"swipe_4_left", "desktop_prev",
		"swipe_4_right", "desktop_next",
)

; Current action assignments — read from config.toml or factory defaults.
global GestureAssignments := Map()
for _GestureAssignmentSlot, _GestureAssignmentAction in GESTURE_FACTORY_DEFAULTS
		GestureAssignments[_GestureAssignmentSlot] := _GestureAssignmentAction

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
