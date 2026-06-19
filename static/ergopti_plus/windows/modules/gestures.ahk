; drivers/autohotkey/modules/gestures.ahk
; Requires: TextSender, WindowManager, MouseControl

; ==============================================================================
; MODULE: Trackpad Gestures
; DESCRIPTION:
; Mirrors Hammerspoon's gesture system for Windows. Listens for keyboard
; shortcuts assigned to touchpad gestures via Windows Settings (Bluetooth &
; devices > Touchpad > Advanced gesture configuration).
;
; FEATURES & RATIONALE:
; 1. Toggle Selection: Triple-tap activates drag selection, any keystroke cancels.
; 2. Configurable Actions: Each gesture slot maps to an action chosen in the menu.
; 3. Architecture Mirror: Mirrors the Hammerspoon modules/gestures system exactly.
; 4. Auto-Configuration: Can write Windows registry to set up gesture shortcuts.
;
; WINDOWS SETUP:
; In Settings > Bluetooth & devices > Touchpad > Advanced gestures,
; assign the following shortcuts to the corresponding gestures:
;   - 3 finger tap:         Ctrl + Win + Shift + F1
;   - 3 finger swipe up:    Ctrl + Win + Shift + F2
;   - 3 finger swipe down:  Ctrl + Win + Shift + F3
;   - 3 finger swipe left:  Ctrl + Win + Shift + F4
;   - 3 finger swipe right: Ctrl + Win + Shift + F5
;   - 4 finger tap:         Ctrl + Win + Shift + F6
;   - 4 finger swipe up:    Ctrl + Win + Shift + F7
;   - 4 finger swipe down:  Ctrl + Win + Shift + F8
;   - 4 finger swipe left:  Ctrl + Win + Shift + F9
;   - 4 finger swipe right: Ctrl + Win + Shift + F10
; ==============================================================================

; #InputLevel 2 is intentionally NOT set here — ErgoptiPlus.ahk already sets
; it before including this module, so the hotkeys below fire at the correct
; level in production. Omitting it here lets the test runner include this file
; without forcing the keyboard hook installation on a headless CI runner, which
; would block the process indefinitely waiting for a system input device.





; ============================================
; ============================================
; ======= 1/ Constants & Configuration =======
; ============================================
; ============================================

; Registry path for precision touchpad settings
global GESTURE_REG_PATH := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad"

; Registry value names for each gesture action type
global GESTURE_REG_ACTIONS := Map(
    "tap_3", "ThreeFingerTapAction",
    "swipe_3_up", "ThreeFingerSlideUpAction",
    "swipe_3_down", "ThreeFingerSlideDownAction",
    "swipe_3_left", "ThreeFingerSlideLeftAction",
    "swipe_3_right", "ThreeFingerSlideRightAction",
    "tap_4", "FourFingerTapAction",
    "swipe_4_up", "FourFingerSlideUpAction",
    "swipe_4_down", "FourFingerSlideDownAction",
    "swipe_4_left", "FourFingerSlideLeftAction",
    "swipe_4_right", "FourFingerSlideRightAction",
)

; Value meaning "Custom keyboard shortcut" in the registry
global GESTURE_REG_CUSTOM_VALUE := 65535

; Modifier bitmask for KeyParams: Ctrl(1) | Shift(2) | Win(4) = 7
global GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT := 0x07

; Per-slot VK codes for F1..F10 (Windows VK_F1=0x70 … VK_F10=0x79)
; Per-slot VK codes for F1..F10 (Windows VK_F1=0x70 … VK_F10=0x79)
; All slots (taps and swipes) use (VK << 16) | modifiers — confirmed by
; reading the registry after manual configuration in Windows Settings.
global GESTURE_REG_KEY_PARAMS := Map(
    "tap_3", (0x70 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F1
    "swipe_3_up", (0x71 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F2
    "swipe_3_down", (0x72 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F3
    "swipe_3_left", (0x73 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F4
    "swipe_3_right", (0x74 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F5
    "tap_4", (0x75 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F6
    "swipe_4_up", (0x76 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F7
    "swipe_4_down", (0x77 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F8
    "swipe_4_left", (0x78 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F9
    "swipe_4_right", (0x79 << 16) | GESTURE_REG_MODIFIERS_CTRL_WIN_SHIFT,  ; F10
)

; Old-system KeyParams registry value names (the ones Windows actually reads
; when sending the synthesised shortcut). Tap slots use Custom*Tap + KeyParams,
; swipe slots use direction-specific *KeyParams pair.
global GESTURE_REG_KEY_PARAMS_NAMES := Map(
    "tap_3", "CustomThreeFingerTapKeyParams",
    "swipe_3_up", "ThreeFingerUpKeyParams",
    "swipe_3_down", "ThreeFingerDownKeyParams",
    "swipe_3_left", "ThreeFingerLeftKeyParams",
    "swipe_3_right", "ThreeFingerRightKeyParams",
    "tap_4", "CustomFourFingerTapKeyParams",
    "swipe_4_up", "FourFingerUpKeyParams",
    "swipe_4_down", "FourFingerDownKeyParams",
    "swipe_4_left", "FourFingerLeftKeyParams",
    "swipe_4_right", "FourFingerRightKeyParams",
)

; Old-system "enable" registry values that must be set to 65535 to activate
; the gesture / direction. Tap slots use a CustomXxxTap=7 sentinel instead.
global GESTURE_REG_ENABLE_NAMES := Map(
    "swipe_3_up", "ThreeFingerUp",
    "swipe_3_down", "ThreeFingerDown",
    "swipe_3_left", "ThreeFingerLeft",
    "swipe_3_right", "ThreeFingerRight",
    "swipe_4_up", "FourFingerUp",
    "swipe_4_down", "FourFingerDown",
    "swipe_4_left", "FourFingerLeft",
    "swipe_4_right", "FourFingerRight",
)

; Tap slots use a "Custom*Tap=7" sentinel that means "user-defined shortcut".
global GESTURE_REG_CUSTOM_TAP_NAMES := Map(
    "tap_3", "CustomThreeFingerTap",
    "tap_4", "CustomFourFingerTap",
)
global GESTURE_REG_CUSTOM_TAP_VALUE := 7

; Master enables — must be 65535 for the gesture family to be active
global GESTURE_REG_MASTER_ENABLES := [
    "ThreeFingerSlideEnabled",
    "ThreeFingerTapEnabled",
    "FourFingerSlideEnabled",
    "FourFingerTapEnabled",
]

; Slot names — mirrors Hammerspoon's slot identifiers
global GESTURE_SLOTS := [
    "tap_3",
    "swipe_3_up",
    "swipe_3_down",
    "swipe_3_left",
    "swipe_3_right",
    "tap_4",
    "swipe_4_up",
    "swipe_4_down",
    "swipe_4_left",
    "swipe_4_right",
]

; Human-readable labels for each slot
global GESTURE_SLOT_LABELS := Map()
for _, _Slot in ["tap_3", "swipe_3_up", "swipe_3_down", "swipe_3_left", "swipe_3_right",
              "tap_4", "swipe_4_up", "swipe_4_down", "swipe_4_left", "swipe_4_right"] {
    GESTURE_SLOT_LABELS[_Slot] := t("gesture.slots." . _Slot)
}

; Shortcut labels for setup instructions
global GESTURE_SHORTCUT_LABELS := Map(
    "tap_3", "Ctrl + Win + Shift + F1",
    "swipe_3_up", "Ctrl + Win + Shift + F2",
    "swipe_3_down", "Ctrl + Win + Shift + F3",
    "swipe_3_left", "Ctrl + Win + Shift + F4",
    "swipe_3_right", "Ctrl + Win + Shift + F5",
    "tap_4", "Ctrl + Win + Shift + F6",
    "swipe_4_up", "Ctrl + Win + Shift + F7",
    "swipe_4_down", "Ctrl + Win + Shift + F8",
    "swipe_4_left", "Ctrl + Win + Shift + F9",
    "swipe_4_right", "Ctrl + Win + Shift + F10",
)

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
    "app_switcher", {
        Fn: (*) => TextPressKey("Tab", ["Alt"]),
    },
    ; --- Editing ---
    "copy", {
        Fn: (*) => TextPressKey("c", ["Ctrl"]),
    },
    "paste", {
        Fn: (*) => TextPressKey("v", ["Ctrl"]),
    },
    "cut", {
        Fn: (*) => TextPressKey("x", ["Ctrl"]),
    },
    "undo", {
        Fn: (*) => TextPressKey("z", ["Ctrl"]),
    },
    "redo", {
        Fn: (*) => TextPressKey("y", ["Ctrl"]),
    },
    "select_all", {
        Fn: (*) => TextPressKey("a", ["Ctrl"]),
    },
    "find", {
        Fn: (*) => TextPressKey("f", ["Ctrl"]),
    },
    ; --- Keys ---
    "enter", {
        Fn: (*) => TextPressKey("Enter", []),
    },
    "tab", {
        Fn: (*) => LLM_Tooltip_FireTabOrAccept([]),
    },
    "escape", {
        Fn: (*) => TextPressKey("Escape", []),
    },
    "backspace", {
        Fn: (*) => TextPressKey("BackSpace", []),
    },
    "delete", {
        Fn: (*) => TextPressKey("Delete", []),
    },
    ; --- Tabs ---
    "tab_new", {
        Fn: (*) => TextPressKey("t", ["Ctrl"]),
    },
    "tab_close", {
        Fn: (*) => TextPressKey("w", ["Ctrl"]),
    },
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
    "close_window", {
        Fn: (*) => TextPressKey("F4", ["Alt"]),
    },
    "fullscreen", {
        Fn: (*) => TextPressKey("F11", []),
    },
    "snap_left", {
        Fn: (*) => TextPressKey("Left", ["Win"]),
    },
    "snap_right", {
        Fn: (*) => TextPressKey("Right", ["Win"]),
    },
    "maximize", {
        Fn: (*) => TextPressKey("Up", ["Win"]),
    },
    "desktop_prev", {
        Fn: (*) => TextPressKey("Left", ["Ctrl", "Win"]),
    },
    "desktop_next", {
        Fn: (*) => TextPressKey("Right", ["Ctrl", "Win"]),
    },
    "desktop_new", {
        Fn: (*) => TextPressKey("d", ["Ctrl", "Win"]),
    },
    "desktop_close", {
        Fn: (*) => TextPressKey("F4", ["Ctrl", "Win"]),
    },
    "task_view", {
        Fn: (*) => TextPressKey("Tab", ["Win"]),
    },
    "minimize_all", {
        Fn: (*) => TextPressKey("d", ["Win"]),
    },
    ; --- Cursor movement ---
    "word_prev", {
        Fn: (*) => TextPressKey("Left", ["Ctrl"]),
    },
    "word_next", {
        Fn: (*) => TextPressKey("Right", ["Ctrl"]),
    },
    "line_up", {
        Fn: (*) => TextPressKey("Up", []),
    },
    "line_down", {
        Fn: (*) => TextPressKey("Down", []),
    },
    "line_start", {
        Fn: (*) => TextPressKey("Home", []),
    },
    "line_end", {
        Fn: (*) => TextPressKey("End", []),
    },
    "para_prev", {
        Fn: (*) => TextPressKey("Up", ["Ctrl"]),
    },
    "para_next", {
        Fn: (*) => TextPressKey("Down", ["Ctrl"]),
    },
    "doc_start", {
        Fn: (*) => TextPressKey("Home", ["Ctrl"]),
    },
    "doc_end", {
        Fn: (*) => TextPressKey("End", ["Ctrl"]),
    },
    ; --- Arrows ---
    "arrow_up", {
        Fn: (*) => TextPressKey("Up", []),
    },
    "arrow_down", {
        Fn: (*) => TextPressKey("Down", []),
    },
    "arrow_left", {
        Fn: (*) => TextPressKey("Left", []),
    },
    "arrow_right", {
        Fn: (*) => TextPressKey("Right", []),
    },
    ; --- Selection ---
    "sel_up", {
        Fn: (*) => TextPressKey("Up", ["Shift"]),
    },
    "sel_down", {
        Fn: (*) => TextPressKey("Down", ["Shift"]),
    },
    "sel_left", {
        Fn: (*) => TextPressKey("Left", ["Shift"]),
    },
    "sel_right", {
        Fn: (*) => TextPressKey("Right", ["Shift"]),
    },
    "sel_word_prev", {
        Fn: (*) => TextPressKey("Left", ["Ctrl", "Shift"]),
    },
    "sel_word_next", {
        Fn: (*) => TextPressKey("Right", ["Ctrl", "Shift"]),
    },
    ; --- Media ---
    "vol_up", {
        Fn: (*) => TextPressKey("Volume_Up", []),
    },
    "vol_down", {
        Fn: (*) => TextPressKey("Volume_Down", []),
    },
    "mute", {
        Fn: (*) => TextPressKey("Volume_Mute", []),
    },
    "brightness_up", {
        Fn: (*) => TextPressKey("Brightness_Up", []),
    },
    "brightness_down", {
        Fn: (*) => TextPressKey("Brightness_Down", []),
    },
    "track_play", {
        Fn: (*) => TextPressKey("Media_Play_Pause", []),
    },
    "track_next", {
        Fn: (*) => TextPressKey("Media_Next", []),
    },
    "track_prev", {
        Fn: (*) => TextPressKey("Media_Prev", []),
    },
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
    "screen_record", {
        Fn: (*) => TextPressKey("r", ["Win", "Alt"]),
    },
    "lock_screen", {
        Fn: (*) => DllCall("LockWorkStation"),
    },
    "notification_center", {
        Fn: (*) => TextPressKey("n", ["Win"]),
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
    "select_line", {
        Fn: (*) => SendFinalResult("{Home}{Shift Down}{End}{Shift Up}"),
    },
    "screen_capture", {
        Fn: (*) => SendFinalResult("#+s"),
    },
    "screen_capture_instant", {
        Fn: (*) => GestureScreenshotInstant(),
    },
    "ocr_screenshot", {
        Fn: (*) => SendFinalResult("#+t"),
    },
    "open_url", {
        Fn: (*) => GestureOpenConfiguredURL(),
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
    "surround_parens", {
        Fn: (*) => SendFinalResult("{Home}({End}){Home}"),
    },
    "search_web", {
        Fn: (*) => GestureSearchWeb(),
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
    "ctrl_backspace", {
        Fn: (*) => TextPressKey("BackSpace", ["Ctrl"]),
    },
    "ctrl_delete", {
        Fn: (*) => TextPressKey("Delete", ["Ctrl"]),
    },
    "alt_tab_monitor", {
        Fn: (*) => AltTabMonitor(),
    },
    "space", {
        Fn: (*) => TextPressKey("Space", []),
    },
    "caps_lock", {
        Fn: (*) => ToggleCapsLock(),
    },
)

; Returns the translated label for a gesture action.
; Uses t("sg_actions.X") from the active locale JSON as the canonical source.
; Falls back to the raw action name when the key is absent — labels are no
; longer hardcoded in GESTURE_ACTIONS, so the locale is the single source of truth.
_GestureActionLabel(Name) {
	Key := "sg_actions." . Name
	Translated := t(Key)
	; t() returns the raw key when no translation is found — treat that as a miss
	if (Translated != Key)
		return Translated
	return Name
}


; --- Advanced system action implementations ---

GestureScreenshotInstant() {
    WinGetPos(&WX, &WY, &WW, &WH, "A")
    if (WW = 0 or WH = 0) {
        MsgBox(t("shortcuts.no_active_window"), t("shortcuts.screenshot_title"), "OK T3")
        return
    }
    PicsDir   := EnvGet("USERPROFILE") . "\Pictures\screenshots"
    DirCreate(PicsDir)
    Timestamp := FormatTime(, "yyyy_MM_dd_HH") . "h" . FormatTime(, "mm") . "min" . FormatTime(, "ss") . "sec"
    FilePath  := PicsDir . "\screenshot_" . Timestamp . ".png"
    ; Inline the capture code via -Command instead of writing a temp .ps1 file.
    ; A fixed temp-file path caused a race condition: rapid successive calls had the
    ; second PowerShell instance overwrite the file while the first was still reading it
    ; (gesture-screenshot-tempfile-race). Inlining eliminates the shared-file bottleneck
    ; and removes the need for FileDelete + FileAppend on the hotkey thread.
    PsCode := "Add-Type -AssemblyName System.Drawing;"
        . "$bmp=New-Object System.Drawing.Bitmap(" . WW . "," . WH . ");"
        . "$g=[System.Drawing.Graphics]::FromImage($bmp);"
        . "$g.CopyFromScreen(" . WX . "," . WY . ",0,0,$bmp.Size);"
        . "$bmp.Save('" . FilePath . "');"
        . "$g.Dispose();$bmp.Dispose()"
    Run('powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "' . PsCode . '"',, "Hide")
    TrayTip(StrReplace(t("notify.screenshot_saved_path"), "%s", FilePath), t("notify.screenshot_title"), "Iconi Mute")
}

GestureOpenConfiguredURL() {
    global Features
    URL := ""
    if IsSet(Features) and Features.Has("shortcuts")
        and Features["shortcuts"].Has("gpt")
        and IsObject(Features["shortcuts"]["gpt"])
        and Features["shortcuts"]["gpt"].Has("link") {
        URL := Features["shortcuts"]["gpt"]["link"]
    }
    if (URL = "")
        URL := "https://chatgpt.com/"
    Run(URL)
}

GesturePickColor() {
    MouseGetPos(&MouseX, &MouseY)
    HexColor := PixelGetColor(MouseX, MouseY, "RGB")
    HexColor := "#" . StrLower(SubStr(HexColor, 3))
    A_Clipboard := HexColor
    MsgBox(Format(t("shortcuts.color_picker_result"), HexColor, A_Clipboard), t("shortcuts.color_picker_title"))
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
            WinWaitActive(NotepadMatch, , 3)
        } else {
            Run('notepad.exe "' . FilePath . '"')
            WinWait(NotepadMatch, , 7)
            WMActivate(NotepadMatch)
            WinWaitActive(FileName . " ahk_exe notepad.exe", , 3)
        }
        WinMaximize()
        Sleep(100)
    } finally {
        SetTitleMatchMode(PreviousTitleMatchMode)
    }
}



GestureSearchWeb() {
    global Features
    EngineURL   := "https://www.google.com"
    EngineQuery := "https://www.google.com/search?q="
    if IsSet(Features) and Features.Has("shortcuts")
        and Features["shortcuts"].Has("search")
        and IsObject(Features["shortcuts"]["search"]) {
        S := Features["shortcuts"]["search"]
        if S.Has("search_engine") and S["search_engine"] != ""
            EngineURL := S["search_engine"]
        if S.Has("search_engine_url_query") and S["search_engine_url_query"] != ""
            EngineQuery := S["search_engine_url_query"]
    }
    SelectedText := Trim(GetSelection())
    if (SelectedText = "") {
        Run(EngineURL)
    } else {
        SelectedText := StrReplace(SelectedText, "`r`n", " ")
        SelectedText := StrReplace(SelectedText, "#", "%23")
        SelectedText := StrReplace(SelectedText, "&", "%26")
        SelectedText := StrReplace(SelectedText, "+", "%2b")
        SelectedText := StrReplace(SelectedText, '"', "%22")
        Run(EngineQuery . SelectedText)
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
    Text := GetSelection()
    ; No-op on an empty/failed capture: GetSelection returns "" on a ClipWait
    ; timeout, and pasting "" would only clobber the clipboard with a stale paste.
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
    Text := GetSelection()
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
_GesturePastePlainRestore(OldClip) {
    global _SEND_INSTANT_CLIP_BUSY
    A_Clipboard := OldClip
    _SEND_INSTANT_CLIP_BUSY := false
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
            _SEND_INSTANT_CLIP_BUSY := true
            OldClip := ClipboardAll()
            A_Clipboard := A_Clipboard
            SendFinalResult("^v")
            SetTimer(_GesturePastePlainRestore.Bind(OldClip), -SEND_INSTANT_PASTE_DELAY_MS)
        } else {
            SendFinalResult("^v")
        }
    } else {
        SendFinalResult("^+v")
    }
}

; Ctrl+lettre, Ctrl+Shift+lettre, Win+lettre, Alt+lettre — dynamiques (26 × 4 = 104).
_GestureLetters := "abcdefghijklmnopqrstuvwxyz"
loop StrLen(_GestureLetters) {
    _L := SubStr(_GestureLetters, A_Index, 1)
    _U := StrUpper(_L)
    GESTURE_ACTIONS["ctrl_" . _L] := {
        Label: "^ " . _U . " — Ctrl+" . _U,
        Fn: ((_k) => (*) => GestureSendShortcut("^" . _k))(_L),
    }
    GESTURE_ACTIONS["ctrl_shift_" . _L] := {
        Label: "^⇧ " . _U . " — Ctrl+Shift+" . _U,
        Fn: ((_k) => (*) => GestureSendShortcut("^+" . _k))(_L),
    }
    GESTURE_ACTIONS["win_" . _L] := {
        Label: "⊞ " . _U . " — Win+" . _U,
        Fn: ((_k) => (*) => GestureSendShortcut("#" . _k))(_L),
    }
    GESTURE_ACTIONS["alt_" . _L] := {
        Label: "⎇ " . _U . " — Alt+" . _U,
        Fn: ((_k) => (*) => GestureSendShortcut("!" . _k))(_L),
    }
}

; Ctrl+chiffre, Win+chiffre, Alt+chiffre — dynamiques (10 × 3 = 30).
loop 10 {
    _D := SubStr("0123456789", A_Index, 1)
    GESTURE_ACTIONS["ctrl_" . _D] := {
        Label: "^ " . _D . " — Ctrl+" . _D,
        Fn: ((_k) => (*) => GestureSendShortcut("^" . _k))(_D),
    }
    GESTURE_ACTIONS["win_" . _D] := {
        Label: "⊞ " . _D . " — Win+" . _D,
        Fn: ((_k) => (*) => GestureSendShortcut("#" . _k))(_D),
    }
    GESTURE_ACTIONS["alt_" . _D] := {
        Label: "⎇ " . _D . " — Alt+" . _D,
        Fn: ((_k) => (*) => GestureSendShortcut("!" . _k))(_D),
    }
}

; Touches spéciales — ctrl_space, win_space, alt_space, etc.
_GestureSpecialKeys := Map(
    "space",  "{Space}",
    "enter",  "{Enter}",
    "period", ".",
    "comma",  ",",
    "sc029",  "SC029",
)
for _SName, _SCode in _GestureSpecialKeys {
    _DisplayName := StrUpper(SubStr(_SName, 1, 1)) . SubStr(_SName, 2)
    GESTURE_ACTIONS["ctrl_" . _SName] := {
        Label: "^ " . _DisplayName . " — Ctrl+" . _DisplayName,
        Fn: ((_k) => (*) => GestureSendShortcut("^" . _k))(_SCode),
    }
    GESTURE_ACTIONS["win_" . _SName] := {
        Label: "⊞ " . _DisplayName . " — Win+" . _DisplayName,
        Fn: ((_k) => (*) => GestureSendShortcut("#" . _k))(_SCode),
    }
    GESTURE_ACTIONS["alt_" . _SName] := {
        Label: "⎇ " . _DisplayName . " — Alt+" . _DisplayName,
        Fn: ((_k) => (*) => GestureSendShortcut("!" . _k))(_SCode),
    }
}

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
            try close_fn.Call()
        } else {
            try WMActivate("ahk_id " . hwnd)
        }
        return
    }
    try open_fn.Call()
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
    Reload()
}

; Ensure personal_shortcuts.ahk exists (creating it from the template on
; first use) before opening it in Notepad.
GestureEditPersonalShortcuts() {
    Path := ScriptInformation["PersonalAhkPath"]
    EnsurePersonalShortcutsFile(Path)
    Run('notepad.exe "' . Path . '"')
}

; Ordered list of action names for the menu — built from the shared TOML so
; Hammerspoon and AHK always show the same picker order, filtering each side
; to its own platform entries. "--" entries become visual separators;
; "#Titre" entries become non-selectable section headers.
global GESTURE_ACTION_NAMES := []
global GESTURE_AX_NAMES := []

; Populate GESTURE_ACTION_NAMES / GESTURE_AX_NAMES by parsing the shared
; cross-platform action registry (actions.toml). These lists are only needed
; when the gesture-picker menu is built — which happens in the deferred
; initMenu phase (~250 ms after boot). Deferring the TOML parse off the
; critical boot path removes ~100 ms from the gestures module init time.
; SetTimer(-0) fires immediately after the auto-execute section finishes,
; well before initMenu runs, so the lists are always ready for the menu.
_GestureLoadActionCatalog(*) {
    global GESTURE_ACTION_NAMES, GESTURE_AX_NAMES, GESTURE_ACTIONS, _SharedDir, _GestureSpecialKeys

    _SharedToml := _SharedDir . "\actions.toml"
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
            ; Placeholder keys expand into dynamic ctrl_*/win_*/alt_* blocks
            if (SubStr(_Item, 1, 1) = "_") {
                if (_Item = "_ctrl_placeholder") {
                    GESTURE_ACTION_NAMES.Push("#ctrl")
                    loop 26
                        GESTURE_ACTION_NAMES.Push("ctrl_" . SubStr("abcdefghijklmnopqrstuvwxyz", A_Index, 1))
                    loop 10
                        GESTURE_ACTION_NAMES.Push("ctrl_" . SubStr("0123456789", A_Index, 1))
                    for _Sk, _ in _GestureSpecialKeys
                        GESTURE_ACTION_NAMES.Push("ctrl_" . _Sk)
                } else if (_Item = "_ctrl_shift_placeholder") {
                    GESTURE_ACTION_NAMES.Push("#ctrl_shift")
                    loop 26
                        GESTURE_ACTION_NAMES.Push("ctrl_shift_" . SubStr("abcdefghijklmnopqrstuvwxyz", A_Index, 1))
                } else if (_Item = "_win_placeholder") {
                    GESTURE_ACTION_NAMES.Push("#win")
                    loop 26
                        GESTURE_ACTION_NAMES.Push("win_" . SubStr("abcdefghijklmnopqrstuvwxyz", A_Index, 1))
                    loop 10
                        GESTURE_ACTION_NAMES.Push("win_" . SubStr("0123456789", A_Index, 1))
                    for _Sk, _ in _GestureSpecialKeys
                        GESTURE_ACTION_NAMES.Push("win_" . _Sk)
                } else if (_Item = "_alt_placeholder") {
                    GESTURE_ACTION_NAMES.Push("#alt")
                    loop 26
                        GESTURE_ACTION_NAMES.Push("alt_" . SubStr("abcdefghijklmnopqrstuvwxyz", A_Index, 1))
                    loop 10
                        GESTURE_ACTION_NAMES.Push("alt_" . SubStr("0123456789", A_Index, 1))
                    for _Sk, _ in _GestureSpecialKeys
                        GESTURE_ACTION_NAMES.Push("alt_" . _Sk)
                }
                ; hs-only placeholders (_cmd_placeholder, _hs_ctrl_placeholder…) silently dropped
                continue
            }
            ; Regular action — keep if platform is "all" or "ahk"
            _SecKey := "sg_actions." . _Item
            if _Toml.Has(_SecKey) {
                _Plat := _Toml[_SecKey].Has("platform") ? _Toml[_SecKey]["platform"] : "all"
                if (_Plat = "all" || _Plat = "ahk")
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
                if (_Plat = "all" || _Plat = "ahk")
                    GESTURE_AX_NAMES.Push(_Item)
            }
        }
    }
}
SetTimer(_GestureLoadActionCatalog, -0)

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
for _Slot, _Action in GESTURE_FACTORY_DEFAULTS
    GestureAssignments[_Slot] := _Action

; Click hold mode state
global GestureLeftClickHeld  := False
global GestureRightClickHeld := False
global GestureKeyboardHook   := 0

; Window cycle tracker — ordered by manual user activation (most-recent first).
; _GestureCycling is set True while our own WinActivate runs so the WinEvent
; hook ignores the synthetic focus change and keeps the list stable.
global _GestureWinOrder   := []   ; Array of HWNDs, index 1 = most recently manually focused
global _GestureCycling    := False
global _GestureWinHook    := 0    ; DllCall hook handle

; Upper bound on the recency tracker. WinEvent fires on every foreground change,
; so on a machine left running for days opening/closing thousands of transient
; windows the list would otherwise grow without limit — costing an O(n) prune on
; every win_next/win_prev gesture and slowly climbing memory. Stale HWNDs are
; filtered out at read time (_GestureOrderedWindows), so dropping the oldest
; tracked entries past this cap only loses deep history no cycle would reach.
global GESTURE_WIN_ORDER_MAX := 64





; ===========================================
; ==========================================
; ======= 2/ Right-Click Hold Toggle =======
; ==========================================
; ===========================================

; Parses an AHK v2 shortcut string (e.g. "^+{Tab}", "!{Left}", "^t") into a
; TextPressKey-compatible (Key, Modifiers) pair and dispatches via the adapter.
; Handles: ^ = Ctrl, + = Shift, ! = Alt, # = Win.
; Bare letters (no braces) are passed as-is; {…} keys strip the braces.
_GestureParseAndPressKey(Keys) {
    Mods := []
    Pos  := 1
    ; Consume modifier prefix characters one by one. AHK v2 has no break N;
    ; use a flag to exit the outer loop when a non-modifier char is encountered.
    FoundKey := false
    loop {
        if FoundKey
            break
        Ch := SubStr(Keys, Pos, 1)
        switch Ch {
            case "^":
                Mods.Push("Ctrl")
                Pos++
            case "+":
                Mods.Push("Shift")
                Pos++
            case "!":
                Mods.Push("Alt")
                Pos++
            case "#":
                Mods.Push("Win")
                Pos++
            default:
                FoundKey := true
        }
    }
    KeyPart := SubStr(Keys, Pos)
    ; Strip braces from {Key} notation
    if SubStr(KeyPart, 1, 1) = "{" and SubStr(KeyPart, -1) = "}"
        KeyPart := SubStr(KeyPart, 2, StrLen(KeyPart) - 2)
    TextPressKey(KeyPart, Mods)
}

; Sends a shortcut while neutralising the Ctrl+Win+Shift modifiers that the
; touchpad gesture itself is still holding down at callback time. Without this,
; e.g. Ctrl+Shift+Tab sent on top of held Ctrl+Win+Shift collapses to plain Tab.
GestureSendShortcut(Keys) {
    Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    _GestureParseAndPressKey(Keys)
}

; Returns the list of all visible, non-cloaked top-level windows on the
; current virtual desktop, ordered like the taskbar (oldest → newest Z-order).
; Filters out tool windows, the desktop shell, and the Settings host so the
; cycle stays on real user windows.
GestureGetCyclableWindows(ProcessFilter := "") {
    Result := []
    Ids := WMGetList()
    for _, HWnd in Ids {
        try {
            Title := WinGetTitle("ahk_id " . HWnd)
            if (Title = "") {
                continue
            }
            Style := WinGetStyle("ahk_id " . HWnd)
            ; WS_VISIBLE = 0x10000000
            if !(Style & 0x10000000) {
                continue
            }
            ExStyle := WinGetExStyle("ahk_id " . HWnd)
            ; WS_EX_TOOLWINDOW = 0x80 — skip tool palettes
            if (ExStyle & 0x80) {
                continue
            }
            WinClass := WinGetClass("ahk_id " . HWnd)
            if (WinClass = "Progman" || WinClass = "WorkerW" || WinClass = "Shell_TrayWnd") {
                continue
            }
            ; DWMWA_CLOAKED = 14 — windows on other virtual desktops
            ; Note: DwmGetWindowAttribute is Windows-only DWM API — no cross-platform port defined
            Cloaked := 0
            DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", HWnd, "UInt", 14,
                "Int*", &Cloaked, "UInt", 4)
            if (Cloaked) {
                continue
            }
            if (ProcessFilter != "") {
                ProcName := WinGetProcessName("ahk_id " . HWnd)
                if (ProcName != ProcessFilter) {
                    continue
                }
            }
            Result.Push(HWnd)
        }
    }

    ; Sort by HWND ascending (monotonic creation order) for a stable cycle
    ; that does not shift when the active window changes Z-order position.
    N := Result.Length
    loop N - 1 {
        I := A_Index
        loop N - I {
            J := A_Index
            if (Result[J] > Result[J + 1]) {
                Tmp := Result[J]
                Result[J] := Result[J + 1]
                Result[J + 1] := Tmp
            }
        }
    }
    return Result
}





; ====================================================
; ===================================================
; ======= X/ Manual-activation window tracker =======
; ===================================================
; ====================================================

; WinEvent callback fired by Windows whenever a window gains foreground focus.
; Ignored when _GestureCycling is True so our own WinActivate calls do not
; corrupt the manually-built recency order.
_GestureOnForeground(hWinEventHook, Event, HWnd, IdObject, IdChild, Thread, Time) {
    global _GestureWinOrder, _GestureCycling, GESTURE_WIN_ORDER_MAX
    ; Do not churn the tracker while paused — the driver is inert and any
    ; recency recorded now would be stale by the time it resumes.
    if (A_IsSuspended) {
        return
    }
    if (_GestureCycling) {
        return
    }
    ; Skip non-window objects (menus, scroll bars, etc.)
    if (IdObject != 0) {
        return
    }
    ; Remove existing entry for this HWND, then prepend it (most-recent first).
    ; Stop copying once the cap is reached so the list cannot grow unbounded on
    ; long-running sessions; oldest entries past the cap are dropped.
    NewOrder := [HWnd]
    for _, H in _GestureWinOrder {
        if (NewOrder.Length >= GESTURE_WIN_ORDER_MAX) {
            break
        }
        if (H != HWnd) {
            NewOrder.Push(H)
        }
    }
    _GestureWinOrder := NewOrder
}

; Cleans up the WinEvent hook and its machine-code thunk on script exit.
; Also force-releases any held mouse button so a Reload or ExitApp triggered
; while a click-toggle hold is active does not leave the button stuck OS-wide.
_GestureUnhook(*) {
    global _GestureWinHook, _GestureCallbackPtr
    ; Release any OS-level held button before tearing down — the in-process
    ; release paths (InputHook key-watcher, HookDispatcher cross-release) never
    ; run during process exit, so the physical button stays down without this.
    try GestureReleaseLeftClick()
    try GestureReleaseRightClick()
    if (_GestureWinHook) {
        DllCall("UnhookWinEvent", "Ptr", _GestureWinHook)
        _GestureWinHook := 0
    }
    if (_GestureCallbackPtr) {
        CallbackFree(_GestureCallbackPtr)
        _GestureCallbackPtr := 0
    }
}

; Returns _GestureWinOrder pruned to only currently-cyclable windows,
; preserving manual-activation recency order (most-recent at index 1).
; If the list is empty (first use before any manual activation was recorded),
; falls back to GestureGetCyclableWindows() so the feature still works on
; first launch. Accepts an optional ProcessFilter to restrict to one app.
_GestureOrderedWindows(ProcessFilter := "") {
    global _GestureWinOrder
    Cyclable := GestureGetCyclableWindows(ProcessFilter)
    ; Build a Set for O(1) membership check
    CyclableSet := Map()
    for _, H in Cyclable {
        CyclableSet[H] := True
    }
    ; Retain only HWNDs still alive and cyclable, in recency order
    Result := []
    for _, H in _GestureWinOrder {
        if CyclableSet.Has(H) {
            Result.Push(H)
        }
    }
    ; If nothing was tracked yet, fall back to creation-order list
    if (Result.Length = 0) {
        return Cyclable
    }
    ; Append any cyclable windows not yet seen in the tracker
    ; (e.g. opened before ErgoptiPlus was running)
    TrackedSet := Map()
    for _, H in Result {
        TrackedSet[H] := True
    }
    for _, H in Cyclable {
        if !TrackedSet.Has(H) {
            Result.Push(H)
        }
    }
    return Result
}



; ==============================
; ===== Screenshot helpers =====
; ==============================

; Returns the absolute path to the screenshots directory, creating it if missing.
; Mirrors Hammerspoon's convention: %USERPROFILE%\Pictures\screenshots\
GestureScreenshotsDir() {
    Dir := A_MyDocuments . "\..\Pictures\screenshots"
    ; Resolve "..\" — easier to read for the user
    Dir := EnvGet("USERPROFILE") . "\Pictures\screenshots"
    if !DirExist(Dir) {
        try DirCreate(Dir)
    }
    return Dir
}

; Returns a timestamped screenshot filename, e.g. screenshot_2026_05_06_21_15_42.png
GestureScreenshotPath() {
    return GestureScreenshotsDir() . "\screenshot_" . FormatTime(, "yyyy_MM_dd_HH'h'_mm'min'_ss's'") . ".png"
}

; Captures a region using PowerShell + System.Drawing and routes it to the
; requested destination. Coordinates are in screen pixels.
;   Mode = "save"      → write a PNG to Path (must be a valid file path).
;   Mode = "clipboard" → copy the bitmap to the Windows clipboard via
;                        System.Windows.Forms.Clipboard. PowerShell is
;                        launched with -STA because Clipboard.SetImage
;                        requires the calling thread to be in single-
;                        threaded apartment state.
; Returns True on success, False otherwise.
GestureCaptureRegion(X, Y, W, H, Mode, Path := "") {
    if (Mode == "save") {
        EscapedPath := StrReplace(Path, "'", "''")
        PSScript :=
            "Add-Type -AssemblyName System.Drawing;" .
            "$bmp = New-Object System.Drawing.Bitmap " . W . "," . H . ";" .
            "$g = [System.Drawing.Graphics]::FromImage($bmp);" .
            "$g.CopyFromScreen(" . X . "," . Y . ",0,0,(New-Object System.Drawing.Size " . W . "," . H . "));" .
            "$bmp.Save('" . EscapedPath . "', [System.Drawing.Imaging.ImageFormat]::Png);" .
            "$g.Dispose(); $bmp.Dispose();"
        PSArgs := '-NoProfile -WindowStyle Hidden -Command "' . PSScript . '"'
    } else {
        PSScript :=
            "Add-Type -AssemblyName System.Drawing;" .
            "Add-Type -AssemblyName System.Windows.Forms;" .
            "$bmp = New-Object System.Drawing.Bitmap " . W . "," . H . ";" .
            "$g = [System.Drawing.Graphics]::FromImage($bmp);" .
            "$g.CopyFromScreen(" . X . "," . Y . ",0,0,(New-Object System.Drawing.Size " . W . "," . H . "));" .
            "[System.Windows.Forms.Clipboard]::SetImage($bmp);" .
            "$g.Dispose(); $bmp.Dispose();"
        ; -STA is required for Clipboard interop
        PSArgs := '-NoProfile -Sta -WindowStyle Hidden -Command "' . PSScript . '"'
    }
    try {
        RunWait('powershell.exe ' . PSArgs, , "Hide")
        return (Mode == "save") ? (FileExist(Path) ? True : False) : True
    } catch as e {
        LoggerError("gestures", "Screenshot failed: {1}.", e.Message)
        return False
    }
}

; Captures the active window (client + non-client area).
;   Mode = "save"      → write a PNG to disk and TrayTip the path.
;   Mode = "clipboard" → copy the bitmap to the Windows clipboard.
GestureScreenshotWindow(Mode) {
    HWnd := WMExists("A")
    if (!HWnd) {
        LoggerWarn("gestures", "screenshot_window: no active window.")
        return
    }
    try {
        WinGetPos(&X, &Y, &W, &H, "ahk_id " . HWnd)
    } catch {
        LoggerWarn("gestures", "screenshot_window: WinGetPos failed.")
        return
    }
    if (Mode == "save") {
        Path := GestureScreenshotPath()
        LoggerStart("gestures", "Capturing window to '{1}'…", Path)
        if GestureCaptureRegion(X, Y, W, H, "save", Path) {
            LoggerSuccess("gestures", "Window screenshot saved: '{1}'.", Path)
            TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
        }
    } else {
        LoggerStart("gestures", "Capturing window to clipboard…")
        if GestureCaptureRegion(X, Y, W, H, "clipboard") {
            LoggerSuccess("gestures", "Window screenshot copied to clipboard.")
            TrayTip(t("notify.screenshot_copied"), t("notify.clipboard"), "Iconi Mute")
        }
    }
}

; Captures the full virtual screen (all monitors) to disk or clipboard.
GestureScreenshotFullscreen(Mode) {
    X := SysGet(76)  ; SM_XVIRTUALSCREEN
    Y := SysGet(77)  ; SM_YVIRTUALSCREEN
    W := SysGet(78)  ; SM_CXVIRTUALSCREEN
    H := SysGet(79)  ; SM_CYVIRTUALSCREEN
    if (Mode == "save") {
        Path := GestureScreenshotPath()
        LoggerStart("gestures", "Capturing fullscreen to '{1}'…", Path)
        if GestureCaptureRegion(X, Y, W, H, "save", Path) {
            LoggerSuccess("gestures", "Fullscreen screenshot saved: '{1}'.", Path)
            TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
        }
    } else {
        LoggerStart("gestures", "Capturing fullscreen to clipboard…")
        if GestureCaptureRegion(X, Y, W, H, "clipboard") {
            LoggerSuccess("gestures", "Fullscreen screenshot copied to clipboard.")
            TrayTip(t("notify.screenshot_copied"), t("notify.clipboard"), "Iconi Mute")
        }
    }
}

; Triggers Windows' built-in Snip & Sketch region selector via Win+Shift+S.
; Snip & Sketch always copies the result to the clipboard — for the "save"
; mode we additionally watch the clipboard for the resulting image and dump
; it to a timestamped PNG on disk.
GestureScreenshotRegion(Mode) {
    if (Mode == "clipboard") {
        ; Snip & Sketch already places the image on the clipboard — nothing
        ; further to do. Fire-and-forget so the user can keep typing.
        LoggerStart("gestures", "Region screenshot to clipboard — opening Snip & Sketch…")
        TextPressKey("s", ["Shift", "Win"])
        LoggerSuccess("gestures", "Snip & Sketch invoked (clipboard mode).")
        return
    }
    Path := GestureScreenshotPath()
    LoggerStart("gestures", "Region screenshot to disk — opening Snip & Sketch…")
    OldClip := ClipboardAll()
    A_Clipboard := ""
    try {
        SendEvent("#+s")
        ; Wait up to 30 s for the user to finish their selection
        if !ClipWait(30, 2) {
            LoggerWarn("gestures", "Region screenshot: no image captured (timeout or cancel).")
            return
        }
        ; Save the clipboard PNG to disk via PowerShell
        EscapedPath := StrReplace(Path, "'", "''")
        PSScript :=
            "Add-Type -AssemblyName System.Windows.Forms;" .
            "Add-Type -AssemblyName System.Drawing;" .
            "$img = [System.Windows.Forms.Clipboard]::GetImage();" .
            "if ($img) { $img.Save('" . EscapedPath . "', [System.Drawing.Imaging.ImageFormat]::Png) }"
        try {
            RunWait('powershell.exe -NoProfile -Sta -WindowStyle Hidden -Command "' . PSScript . '"', , "Hide")
            if FileExist(Path) {
                LoggerSuccess("gestures", "Region screenshot saved: '{1}'.", Path)
                TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
            } else {
                LoggerWarn("gestures", "Region screenshot: clipboard image was not saved.")
            }
        } catch as e {
            LoggerError("gestures", "Region screenshot save failed: {1}.", e.Message)
        }
    } finally {
        A_Clipboard := OldClip
    }
}

; Activates the window at Windows[Target], restoring it if minimised.
; Returns True if the call did not throw — does NOT verify focus actually moved
; (Windows propagates focus async, and a strict check causes false negatives
; that make the cycle skip windows).
GestureActivateWindow(HWnd) {
    try {
        if (WinGetMinMax("ahk_id " . HWnd) = -1) {
            WinRestore("ahk_id " . HWnd)
        }
        ; Bypass Windows foreground-stealing protection: AttachThreadInput to
        ; the current foreground window's thread, then SetForegroundWindow.
        ForeHwnd := DllCall("GetForegroundWindow", "Ptr")
        ForeThread := DllCall("GetWindowThreadProcessId", "Ptr", ForeHwnd, "Ptr", 0, "UInt")
        TargThread := DllCall("GetWindowThreadProcessId", "Ptr", HWnd, "Ptr", 0, "UInt")
        Attached := False
        if (ForeThread && TargThread && ForeThread != TargThread) {
            Attached := DllCall("AttachThreadInput", "UInt", ForeThread, "UInt", TargThread, "Int", True)
        }
        DllCall("BringWindowToTop", "Ptr", HWnd)
        DllCall("SetForegroundWindow", "Ptr", HWnd)
        WMActivate("ahk_id " . HWnd)
        if (Attached) {
            DllCall("AttachThreadInput", "UInt", ForeThread, "UInt", TargThread, "Int", False)
        }
        return True
    } catch as e {
        LoggerWarn("gestures", "WinActivate failed for HWND {1}: {2}.", HWnd, e.Message)
        return False
    }
}

; Computes the next index in a circular list of size N.
GestureNextIndex(Current, N, Forward) {
    if (Forward) {
        return (Current >= N) ? 1 : Current + 1
    }
    return (Current <= 1) ? N : Current - 1
}

; Cycles through every window across all applications on the current desktop.
; Forward=True selects the next window, Forward=False the previous one.
; Order follows manual user activation history (_GestureWinOrder), not Z-order.
; If the target window can't be activated, falls back to the next one in the
; cycle so the user never gets "stuck" at an unactivatable slot.
GestureCycleWindows(Forward) {
    global _GestureCycling
    ; Capture the active HWND before releasing modifiers — the Send below can
    ; briefly shift focus. WinExist returns the HWND directly (WMExists returns bool).
    Active := WinExist("A")
    ; Release modifiers still held by the touchpad gesture (Ctrl+Win+Shift)
    ; so WinActivate doesn't trigger the Start menu or other system shortcuts.
    Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    Windows := _GestureOrderedWindows()
    N := Windows.Length
    if (N < 2) {
        LoggerDebug("gestures", "CycleWindows: only {1} window(s) — nothing to cycle.", N)
        return
    }
    Index := 0
    for I, HWnd in Windows {
        if (HWnd = Active) {
            Index := I
            break
        }
    }
    LoggerDebug("gestures", "CycleWindows: {1} window(s), active idx={2}, forward={3}.",
        N, Index, Forward)

    ; Try up to N-1 candidates so we wrap around even if some windows refuse activation.
    Target := Index
    loop N - 1 {
        Target := GestureNextIndex(Target, N, Forward)
        ; Suppress the WinEvent hook so this programmatic activation does not
        ; reorder the manual history.
        _GestureCycling := True
        Activated := GestureActivateWindow(Windows[Target])
        _GestureCycling := False
        if Activated {
            LoggerDebug("gestures", "Activated HWND {1} (idx={2}).", Windows[Target], Target)
            return
        }
    }
    LoggerWarn("gestures", "CycleWindows: no candidate could be activated.")
}

; Cycles through windows belonging to the same process as the active window.
; Order follows manual user activation history, same as GestureCycleWindows.
GestureCycleAppWindows(Forward) {
    global _GestureCycling
    ; Capture the active HWND before releasing modifiers — same race as CycleWindows.
    Active := WinExist("A")
    Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    if (!Active) {
        return
    }
    try ProcName := WinGetProcessName("ahk_id " . Active)
    catch {
        return
    }
    Windows := _GestureOrderedWindows(ProcName)
    N := Windows.Length
    if (N < 2) {
        LoggerDebug("gestures", "CycleAppWindows: only {1} window(s) for '{2}'.", N, ProcName)
        return
    }
    Index := 0
    for I, HWnd in Windows {
        if (HWnd = Active) {
            Index := I
            break
        }
    }
    LoggerDebug("gestures", "CycleAppWindows '{1}': {2} window(s), active idx={3}, forward={4}.",
        ProcName, N, Index, Forward)

    Target := Index
    loop N - 1 {
        Target := GestureNextIndex(Target, N, Forward)
        _GestureCycling := True
        Activated := GestureActivateWindow(Windows[Target])
        _GestureCycling := False
        if Activated {
            LoggerDebug("gestures", "Activated HWND {1} (idx={2}).", Windows[Target], Target)
            return
        }
    }
    LoggerWarn("gestures", "CycleAppWindows: no candidate could be activated.")
}

; Activates or deactivates a left-button-held mode. Any subsequent keystroke
; (or physical left-click) automatically releases the button — typically
; firing the system's left-click action wherever the cursor is at that
; moment. Useful as a generic "press left button until I do something"
; toggle which covers context menus, drag-with-left-button workflows
; (browser gestures, 3D viewport rotation, …) and whatever else left-
; click means in the focused app, hence the broader naming over the
; previous "selection" wording.
GestureToggleLeftClick() {
    global GestureLeftClickHeld

    if (GestureLeftClickHeld) {
        GestureReleaseLeftClick()
        return
    }

    LoggerDebug("gestures", "Enabling left-click hold mode…")
    Click("Left", "Down")
    GestureLeftClickHeld := True

    ; Install a keyboard hook that releases the button on any key press
    GestureStartKeyboardWatcher()
    ; Subscribe via HookDispatcher so the shared ~RButton handler is preserved;
    ; a bare Hotkey("~RButton", …) call would replace the dispatcher's handler.
    HookDispatcher.Register("mouse_rdown", GestureReleaseLeftClick)
    LoggerInfo("gestures", "Left-click hold mode enabled.")
}

; Releases the left mouse button if it is currently held by the toggle.
GestureReleaseLeftClick(*) {
    global GestureLeftClickHeld, GestureRightClickHeld

    if (!GestureLeftClickHeld) {
        return
    }

    ; Unsubscribe via HookDispatcher — Hotkey("~RButton", …, "Off") would
    ; disable the shared ~RButton handler that the dispatcher registered.
    HookDispatcher.Unregister("mouse_rdown", GestureReleaseLeftClick)
    LoggerDebug("gestures", "Disabling left-click hold mode…")
    Click("Left", "Up")
    GestureLeftClickHeld := False
    ; Stop the shared watcher only if the right click is also released
    if (!GestureRightClickHeld)
        GestureStopKeyboardWatcher()
    LoggerInfo("gestures", "Left-click hold mode disabled.")
}

; Installs a low-level keyboard hook to detect any key press.
; Uses no flags so both physical and synthetic keys cancel selection
; (e.g. a tap-hold that fires Ctrl+C should also stop the drag).
GestureStartKeyboardWatcher() {
    global GestureKeyboardHook

    GestureStopKeyboardWatcher()
    ; L3: Level 3 (higher than Ergopti's Level 2 hotkeys)
    ; 'V' option: non-consuming hook so keys pass through normally.
    GestureKeyboardHook := InputHook("V L3")
    GestureKeyboardHook.KeyOpt("{All}", "N")
    GestureKeyboardHook.OnKeyDown := GestureOnKeyDown
    GestureKeyboardHook.Start()
}

; Removes the keyboard hook.
GestureStopKeyboardWatcher() {
    global GestureKeyboardHook

    if (GestureKeyboardHook != 0 and IsObject(GestureKeyboardHook)) {
        try GestureKeyboardHook.Stop()
        GestureKeyboardHook := 0
    }
}

; Callback fired on any key press while a click hold is active.
GestureOnKeyDown(ih, vk, sc) {
    if A_IsSuspended {
        ih.Stop()
        GestureReleaseLeftClick()
        GestureReleaseRightClick()
        return
    }

    ; Stop catching keys immediately to avoid recursion
    ih.Stop()

    ; Any keystroke releases whichever button(s) are currently held
    GestureReleaseLeftClick()
    GestureReleaseRightClick()
}

; NOTE: the ~RButton / ~LButton cross-release hotkeys are registered
; dynamically via Hotkey() inside GestureToggleLeftClick / GestureToggleRightClick
; rather than as static #HotIf blocks. Static mouse-button hotkeys install the
; mouse hook at load-time, which blocks indefinitely on a headless CI runner
; that has no physical mouse hardware attached.

; Activates or deactivates a right-button-held mode. Mirrors GestureToggleLeftClick.
GestureToggleRightClick() {
    global GestureRightClickHeld

    if (GestureRightClickHeld) {
        GestureReleaseRightClick()
        return
    }

    LoggerDebug("gestures", "Enabling right-click hold mode…")
    Click("Right", "Down")
    GestureRightClickHeld := True

    ; Install a keyboard hook that releases the button on any key press
    GestureStartKeyboardWatcher()
    ; Subscribe via HookDispatcher so the shared ~LButton handler is preserved;
    ; a bare Hotkey("~LButton", …) call would replace the dispatcher's handler.
    HookDispatcher.Register("mouse_ldown", GestureReleaseRightClick)
    LoggerInfo("gestures", "Right-click hold mode enabled.")
}

; Releases the right mouse button if it is currently held by the toggle.
GestureReleaseRightClick(*) {
    global GestureRightClickHeld, GestureLeftClickHeld

    if (!GestureRightClickHeld) {
        return
    }

    ; Unsubscribe via HookDispatcher — Hotkey("~LButton", …, "Off") would
    ; disable the shared ~LButton handler that the dispatcher registered.
    HookDispatcher.Unregister("mouse_ldown", GestureReleaseRightClick)
    LoggerDebug("gestures", "Disabling right-click hold mode…")
    Click("Right", "Up")
    GestureRightClickHeld := False
    ; Stop the shared watcher only if the left click is also released
    if (!GestureLeftClickHeld)
        GestureStopKeyboardWatcher()
    LoggerInfo("gestures", "Right-click hold mode disabled.")
}





; =====================================
; =====================================
; ======= 3/ Action Dispatching =======
; =====================================
; =====================================

; Executes the action assigned to a gesture slot.
GestureDispatch(slot) {
    global GestureAssignments, GESTURE_ACTIONS, Features

    ; Guard against being called before auto-execute completes (e.g. hotkey fires
    ; during a Reload triggered by enabling metrics)
    if !IsSet(GestureAssignments) or !IsSet(GESTURE_ACTIONS) or !IsSet(Features)
        return

    if !Features["gestures"]["enabled"] {
        return
    }

    if !GestureAssignments.Has(slot) {
        return
    }

    ActionName := GestureAssignments[slot]
    if (ActionName == "none" or !GESTURE_ACTIONS.Has(ActionName)) {
        return
    }

    ; Release all modifiers held down by the touchpad shortcut (Ctrl+Win+Shift)
    ; before firing the action — otherwise SendEvent/Send calls inherit the
    ; still-down state and produce wrong combos on every swipe after the first.
    Send("{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    LoggerDebug("gestures", "Dispatching gesture: {1} -> {2}.", slot, ActionName)

    ; Any tap action (other than the click-toggle itself) must deactivate a held click
    ; so that a selection started with left_click_toggle is properly released first.
    if (ActionName != "left_click_toggle" && ActionName != "right_click_toggle") {
        GestureReleaseLeftClick()
        GestureReleaseRightClick()
    }

    try GESTURE_ACTIONS[ActionName].Fn()
    LoggerInfo("gestures", "Gesture {1} dispatched successfully.", slot)
}





; =============================================
; ==============================================
; ======= 4/ Hotkey Bindings (Listeners) =======
; ==============================================
; =============================================

; These shortcuts must be assigned in Windows Settings > Bluetooth & devices
; > Touchpad > Advanced gesture configuration.
; Use the "Configurer automatiquement" button in the menu to set them via
; the registry, or assign them manually.

; No '$' prefix here — ErgoptiPlus.ahk sets #InputLevel 2 before including
; this module, which installs the low-level keyboard hook at the production
; level. Adding '$' here would also force the hook in the headless test runner
; (which includes this module without #InputLevel 2), causing a hang because
; no physical keyboard device is available on a CI runner.
^#+F1:: GestureDispatch("tap_3")
^#+F2:: GestureDispatch("swipe_3_up")
^#+F3:: GestureDispatch("swipe_3_down")
^#+F4:: GestureDispatch("swipe_3_left")
^#+F5:: GestureDispatch("swipe_3_right")
^#+F6:: GestureDispatch("tap_4")
^#+F7:: GestureDispatch("swipe_4_up")
^#+F8:: GestureDispatch("swipe_4_down")
^#+F9:: GestureDispatch("swipe_4_left")
^#+F10:: GestureDispatch("swipe_4_right")





; ==========================================
; ==========================================
; ======= 5/ Configuration & Setup ========
; ==========================================
; ==========================================

; Reads gesture assignments from the v2 [ahk.gestures] section.
GesturesReadConfig() {
    global GestureAssignments, _IniCache

    for _, Slot in GESTURE_SLOTS {
        Value := IniCacheGet(_IniCache, "ahk.gestures", Slot)
        if (Value != "_") {
            GestureAssignments[Slot] := Value
        }
    }
}

; Saves a single gesture assignment to the v2 [ahk.gestures] section.
GestureSaveAssignment(slot, action) {
    global GestureAssignments, ConfigurationFile

    GestureAssignments[slot] := action
    TOML_Write(action, ConfigurationFile, "ahk.gestures", slot)
}

; Writes a single REG_DWORD value via RegistryLib, counting failures.
GestureRegWriteDword(ValueName, Value, &ErrorsRef) {
    global GESTURE_REG_PATH

    if (!Reg_WriteDword(GESTURE_REG_PATH, ValueName, Value))
        ErrorsRef += 1
}

; Configures Windows touchpad gestures via the registry so that all 10 gesture
; slots send Ctrl+Win+Shift+F1..F10 without any manual Settings configuration.
; Writes the master enables, per-direction enables, Custom*Tap sentinels,
; KeyParams (encoded as (VK<<16)|7), and resets the new-system *Action values
; to 65535 so the old KeyParams system takes precedence.
; Returns true on success, false if any registry write failed.
GestureAutoConfigureRegistry() {
    global GESTURE_REG_PATH, GESTURE_REG_CUSTOM_VALUE
    global GESTURE_REG_ACTIONS, GESTURE_REG_KEY_PARAMS, GESTURE_REG_KEY_PARAMS_NAMES
    global GESTURE_REG_ENABLE_NAMES, GESTURE_REG_CUSTOM_TAP_NAMES
    global GESTURE_REG_CUSTOM_TAP_VALUE, GESTURE_REG_MASTER_ENABLES, GESTURE_SLOTS

    LoggerStart("gestures", "Auto-configuring touchpad gestures via registry…")
    Errors := 0

    ; Master enables — turn the gesture families on
    for _, Name in GESTURE_REG_MASTER_ENABLES {
        GestureRegWriteDword(Name, GESTURE_REG_CUSTOM_VALUE, &Errors)
    }

    ; Per-slot configuration
    for _, Slot in GESTURE_SLOTS {
        ; Direction enables (swipes only)
        if GESTURE_REG_ENABLE_NAMES.Has(Slot) {
            GestureRegWriteDword(GESTURE_REG_ENABLE_NAMES[Slot],
                GESTURE_REG_CUSTOM_VALUE, &Errors)
        }
        ; Custom*Tap=7 sentinel for tap slots
        if GESTURE_REG_CUSTOM_TAP_NAMES.Has(Slot) {
            GestureRegWriteDword(GESTURE_REG_CUSTOM_TAP_NAMES[Slot],
                GESTURE_REG_CUSTOM_TAP_VALUE, &Errors)
        }
        ; KeyParams — actual shortcut encoding (Ctrl+Win+Shift+Fn)
        GestureRegWriteDword(GESTURE_REG_KEY_PARAMS_NAMES[Slot],
            GESTURE_REG_KEY_PARAMS[Slot], &Errors)
        ; New-system *Action — 65535 disables it so KeyParams takes precedence
        GestureRegWriteDword(GESTURE_REG_ACTIONS[Slot],
            GESTURE_REG_CUSTOM_VALUE, &Errors)
    }

    if (Errors > 0) {
        LoggerError("gestures", "Auto-configuration failed with {1} error(s).", Errors)
        return False
    }

    ; The PrecisionTouchPad driver caches gesture mappings in kernel-mode
    ; and ignores WM_SETTINGCHANGE — the only reliable way to apply changes
    ; without a logout is to disable then re-enable the touchpad PnP device,
    ; which is exactly what Windows Settings does internally on apply.
    GestureRestartTouchpadDevice()

    LoggerSuccess("gestures", "All gesture registry values written successfully.")
    return True
}

; Disables then re-enables the touchpad PnP device to force the gesture
; driver to reload its configuration from the registry. Requires admin
; elevation — triggers a UAC prompt via the *RunAs verb.
GestureRestartTouchpadDevice() {
    LoggerStart("gestures", "Restarting touchpad device to apply gesture config…")

    ; Target the "Microsoft Input Configuration Device" — this is the HID
    ; collection node that exposes the Precision Touchpad gesture surface
    ; and reloads its config from the registry on enable. The parent I2C HID
    ; node alone is not enough; we also toggle it as a fallback to cover
    ; vendor variations.
    PsCmd := "$ErrorActionPreference='Stop'; "
        . "$devs = Get-PnpDevice -PresentOnly | Where-Object { "
        . "$_.Class -eq 'HIDClass' -and ( "
        . "$_.FriendlyName -match 'Input Configuration|I2C HID' "
        . ") }; "
        . "foreach ($d in $devs) { "
        . "  Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:`$false -ErrorAction SilentlyContinue "
        . "}; "
        . "Start-Sleep -Milliseconds 500; "
        . "foreach ($d in $devs) { "
        . "  Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:`$false -ErrorAction SilentlyContinue "
        . "}"

    try {
        RunWait('*RunAs powershell.exe -NoProfile -WindowStyle Hidden -Command "' . PsCmd . '"', , "Hide")
        LoggerSuccess("gestures", "Touchpad device restarted — driver reloaded.")
    } catch as e {
        LoggerError("gestures", "Failed to restart touchpad device: {1}.", e.Message)
    }
}

; Build the body of the manual-setup tutorial. Shared by the tray menu and the
; onboarding wizard so the wording stays in lockstep between them.
;
; Locale fragments already embed their own trailing newlines (one after each
; section, two after the header), so they are concatenated as-is here — adding
; extra ``\n`` separators surfaced as visible blank-line clutter inside the
; rendered popup.
GestureBuildSetupInstructions() {
    Body := t("gesture.setup.header") . t("gesture.setup.open_path") . t("gesture.setup.for_each")
    if IsSet(GESTURE_SLOTS) and IsSet(GESTURE_SHORTCUT_LABELS) {
        for _, Slot in GESTURE_SLOTS {
            Body .= "  " . t("gesture.slots." . Slot) . " :  "
                . GESTURE_SHORTCUT_LABELS[Slot] . "`n"
        }
    }
    return Body
}

; Public entry point: shows the gesture setup tutorial in a single panel with
; a one-click "Open touchpad settings" shortcut to ms-settings:devices-touchpad.
; Replaces the previous two-step ``Show instructions`` + ``Open touchpad
; settings`` menu items — the user only needs one path now.
GestureShowManualTutorialDialog() {
    tg := Gui("+AlwaysOnTop", t("onboarding.gestures.register_manual"))
    tg.SetFont("s9", "Segoe UI")
    tg.MarginX := 18
    tg.MarginY := 14
    
    ; Instructions in a read-only Edit (selectable text).
    ; Sized to fit the 10 slots without a scrollbar (h380).
    instructions := GestureBuildSetupInstructions()
    hEdit := tg.AddEdit("ReadOnly w480 h380 -Wrap", instructions)
    
    ; Auto-configure hint placed OUTSIDE the selectable text area.
    tg.AddText("w480 y+12", t("gesture.setup.auto_configure"))
    
    tg.AddText("w480 y+10", t("onboarding.gestures.open_settings_hint"))
    
    ; "Open settings" button gets the default focus.
    btnOpenSettings := tg.AddButton("Default w480 y+8", t("onboarding.gestures.open_settings"))
    btnOpenSettings.OnEvent("Click", (*) => GestureOpenTouchpadSettings())
    
    tg.OnEvent("Close", (*) => tg.Destroy())
    tg.OnEvent("Escape", (*) => tg.Destroy())
    
    tg.Show("AutoSize Center")
    
    ; Force focus to the button so the Edit text is not selected on start,
    ; and an immediate 'Enter' key triggers the settings.
    btnOpenSettings.Focus()
    ; Clear any accidental selection in the edit control
    SendMessage(0x00B1, -1, 0, , "ahk_id " . hEdit.Hwnd) ; EM_SETSEL
}

; Opens Windows Settings to the touchpad page. Used both by the tutorial
; dialog's "Open settings" button and by the onboarding wizard.
GestureOpenTouchpadSettings() {
    try Run("ms-settings:devices-touchpad")
}

; One-shot SetTimer target used by the post-Reload AutoConfigureOnNextStart
; consumer. Wrapped as a named function because AHK fat-arrow lambdas cannot
; contain ``try`` (parser treats it as an identifier). Logs the lifecycle pair
; so a failure here is visible in the log.
_DeferredGestureAutoConfigure(*) {
    LoggerStart("gestures", "Running deferred touchpad auto-configuration…")
    Ok := false
    try {
        Ok := GestureAutoConfigureRegistry()
    } catch as e {
        LoggerError("gestures", "Deferred auto-configuration threw: {1}.", e.Message)
        return
    }
    if Ok {
        LoggerSuccess("gestures", "Deferred touchpad auto-configuration completed.")
    } else {
        LoggerWarn("gestures", "Deferred touchpad auto-configuration reported failure — user can retry from the tray menu.")
    }
}

; Read configuration on load
GesturesReadConfig()

; The onboarding wizard cannot call GestureAutoConfigureRegistry() directly —
; when it runs (first launch, before this module's auto-exec body executes) the
; PrecisionTouchPad registry maps above are still unset. So the wizard instead
; records ``[Gestures] AutoConfigureOnNextStart = true`` in config.toml, and
; this block consumes that flag now that every dependency is available. The
; entry is cleared after one attempt regardless of outcome so we never retry on
; every subsequent reload (the tray menu's "Auto-configure" action stays the
; supported way to retry if something failed here).
global _IniCache, ConfigurationFile
RawAutoConfig := IniCacheGet(_IniCache, "ahk.gestures", "auto_configure_on_next_start")
if (RawAutoConfig == "1" or RawAutoConfig == "true") {
    LoggerStart("gestures", "Consuming auto_configure_on_next_start flag from onboarding…")

    ; Clear the flag FIRST, before any blocking RunWait — the touchpad device
    ; restart inside GestureAutoConfigureRegistry can cause the AHK process to
    ; be killed mid-call (PnP cycling tears down the HID hook). If we clear
    ; after, that kill leaves the flag set and the auto-relaunched script loops
    ; forever, never reaching initMenu — user sees the default tray menu.
    try TOML_BatchWrite(ConfigurationFile,
        [{ Section: "ahk.gestures", Key: "auto_configure_on_next_start", Value: false }])

    ; Defer the actual registry + touchpad restart to a one-shot timer so the
    ; rest of auto-execute (notably initMenu in ErgoptiPlus.ahk) finishes
    ; building the tray BEFORE the UAC prompt + ~20s PowerShell call blocks
    ; the message loop. 2s is enough for the auto-execute tail to settle.
    SetTimer(_DeferredGestureAutoConfigure, -2000)

    LoggerSuccess("gestures", "AutoConfigureOnNextStart flag cleared — touchpad config deferred to T+2s.")
}

; Arm the WinEvent hook that tracks manual window activations.
; Skipped in the headless test runner (_AHK_DRY_RUN is defined by run_all.ahk)
; because SetWinEventHook with OUTOFCONTEXT keeps a message-loop reference alive
; and prevents ExitApp from returning promptly in a console-less CI process.
_GestureWinOrder   := []
_GestureWinHook    := 0
_GestureCallbackPtr := 0
if !IsSet(_AHK_DRY_RUN) {
    ; Store the callback pointer so _GestureUnhook can free it with CallbackFree,
    ; preventing the fixed-size thunk leak on every script reload
    _GestureCallbackPtr := CallbackCreate(_GestureOnForeground, "F", 7)
    _GestureWinHook := DllCall("SetWinEventHook",
        "UInt", 0x0003,           ; EVENT_SYSTEM_FOREGROUND
        "UInt", 0x0003,
        "Ptr",  0,
        "Ptr",  _GestureCallbackPtr,
        "UInt", 0,
        "UInt", 0,
        "UInt", 0x0000)           ; WINEVENT_OUTOFCONTEXT
    OnExit(_GestureUnhook)
}

LoggerSuccess("gestures", "Gestures module initialised — ready.")
