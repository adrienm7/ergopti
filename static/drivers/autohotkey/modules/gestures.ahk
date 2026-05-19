; drivers/autohotkey/modules/gestures.ahk

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

#InputLevel 2

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
for _Slot in ["tap_3", "swipe_3_up", "swipe_3_down", "swipe_3_left", "swipe_3_right",
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
        Label: "∅ Disabled",
        Fn: (*) => 0,
    },
    ; --- Mouse ---
    "left_click_toggle", {
        Label: "🖱 L Left click (hold)",
        Fn: (*) => GestureToggleLeftClick(),
    },
    "right_click_toggle", {
        Label: "🖱 R Right click (hold)",
        Fn: (*) => GestureToggleRightClick(),
    },
    "app_switcher", {
        Label: "⇥ Alt+Tab — Previous app",
        Fn: (*) => SendInput("!{Tab}"),
    },
    ; --- Editing ---
    "copy", {
        Label: "⎘ Copy",
        Fn: (*) => SendInput("^c"),
    },
    "paste", {
        Label: "⎘ Paste",
        Fn: (*) => SendInput("^v"),
    },
    "cut", {
        Label: "⎘ Cut",
        Fn: (*) => SendInput("^x"),
    },
    "undo", {
        Label: "↩ Undo",
        Fn: (*) => SendInput("^z"),
    },
    "redo", {
        Label: "↪ Redo",
        Fn: (*) => SendInput("^y"),
    },
    "select_all", {
        Label: "⬚ Select all",
        Fn: (*) => SendInput("^a"),
    },
    "find", {
        Label: "🔍 Find",
        Fn: (*) => SendInput("^f"),
    },
    ; --- Keys ---
    "enter", {
        Label: "↵ Enter",
        Fn: (*) => SendInput("{Enter}"),
    },
    "tab", {
        Label: "⇥ Tab",
        Fn: (*) => SendInput("{Tab}"),
    },
    "escape", {
        Label: "⎋ Escape",
        Fn: (*) => SendInput("{Escape}"),
    },
    "backspace", {
        Label: "⌫ Backspace",
        Fn: (*) => SendInput("{BackSpace}"),
    },
    "delete", {
        Label: "⌦ Delete",
        Fn: (*) => SendInput("{Delete}"),
    },
    ; --- Tabs ---
    "tab_new", {
        Label: "⧉ + New tab",
        Fn: (*) => SendInput("^t"),
    },
    "tab_close", {
        Label: "⧉ × Close tab",
        Fn: (*) => SendInput("^w"),
    },
    "tab_prev", {
        Label: "⧉ ← Previous tab",
        Fn: (*) => GestureSendShortcut("^+{Tab}"),
    },
    "tab_next", {
        Label: "⧉ → Next tab",
        Fn: (*) => GestureSendShortcut("^{Tab}"),
    },
    ; --- Browser navigation ---
    "nav_back", {
        Label: "← Back (navigation)",
        Fn: (*) => GestureSendShortcut("!{Left}"),
    },
    "nav_forward", {
        Label: "→ Forward (navigation)",
        Fn: (*) => GestureSendShortcut("!{Right}"),
    },
    ; --- Windows & Desktops ---
    "win_prev", {
        Label: "◱ ← Previous window",
        Fn: (*) => GestureCycleWindows(False),
    },
    "win_next", {
        Label: "◱ → Next window",
        Fn: (*) => GestureCycleWindows(True),
    },
    "win_app_prev", {
        Label: "◱ ← Prev. window (same app)",
        Fn: (*) => GestureCycleAppWindows(False),
    },
    "win_app_next", {
        Label: "◱ → Next window (same app)",
        Fn: (*) => GestureCycleAppWindows(True),
    },
    "close_window", {
        Label: "◱ × Close window",
        Fn: (*) => SendInput("!{F4}"),
    },
    "fullscreen", {
        Label: "📺 Fullscreen",
        Fn: (*) => SendInput("{F11}"),
    },
    "snap_left", {
        Label: "◧ ← Snap left",
        Fn: (*) => SendInput("#{Left}"),
    },
    "snap_right", {
        Label: "◨ → Snap right",
        Fn: (*) => SendInput("#{Right}"),
    },
    "maximize", {
        Label: "🔲 Maximize",
        Fn: (*) => SendInput("#{Up}"),
    },
    "desktop_prev", {
        Label: "▢ ← Previous desktop",
        Fn: (*) => SendInput("^#{Left}"),
    },
    "desktop_next", {
        Label: "▢ → Next desktop",
        Fn: (*) => SendInput("^#{Right}"),
    },
    "desktop_new", {
        Label: "▢ + New desktop",
        Fn: (*) => SendInput("^#d"),
    },
    "desktop_close", {
        Label: "▢ × Close desktop",
        Fn: (*) => SendInput("^#{F4}"),
    },
    "task_view", {
        Label: "▢ Task View",
        Fn: (*) => SendInput("#{Tab}"),
    },
    "minimize_all", {
        Label: "◱ Minimize all",
        Fn: (*) => SendInput("#d"),
    },
    ; --- Cursor movement ---
    "word_prev", {
        Label: "W ← Previous word",
        Fn: (*) => SendInput("^{Left}"),
    },
    "word_next", {
        Label: "W → Next word",
        Fn: (*) => SendInput("^{Right}"),
    },
    "line_up", {
        Label: "↕ ↑ Previous line",
        Fn: (*) => SendInput("{Up}"),
    },
    "line_down", {
        Label: "↕ ↓ Next line",
        Fn: (*) => SendInput("{Down}"),
    },
    "line_start", {
        Label: "⇤ Line start",
        Fn: (*) => SendInput("{Home}"),
    },
    "line_end", {
        Label: "⇥ Line end",
        Fn: (*) => SendInput("{End}"),
    },
    "para_prev", {
        Label: "¶ ↑ Previous paragraph",
        Fn: (*) => SendInput("^{Up}"),
    },
    "para_next", {
        Label: "¶ ↓ Next paragraph",
        Fn: (*) => SendInput("^{Down}"),
    },
    "doc_start", {
        Label: "⤒ Document start",
        Fn: (*) => SendInput("^{Home}"),
    },
    "doc_end", {
        Label: "⤓ Document end",
        Fn: (*) => SendInput("^{End}"),
    },
    ; --- Arrows ---
    "arrow_up", {
        Label: "↑ Arrow Up",
        Fn: (*) => SendInput("{Up}"),
    },
    "arrow_down", {
        Label: "↓ Arrow Down",
        Fn: (*) => SendInput("{Down}"),
    },
    "arrow_left", {
        Label: "← Arrow Left",
        Fn: (*) => SendInput("{Left}"),
    },
    "arrow_right", {
        Label: "→ Arrow Right",
        Fn: (*) => SendInput("{Right}"),
    },
    ; --- Selection ---
    "sel_up", {
        Label: "✎ ↑ Select Up",
        Fn: (*) => SendInput("+{Up}"),
    },
    "sel_down", {
        Label: "✎ ↓ Select Down",
        Fn: (*) => SendInput("+{Down}"),
    },
    "sel_left", {
        Label: "✎ ← Select Left",
        Fn: (*) => SendInput("+{Left}"),
    },
    "sel_right", {
        Label: "✎ → Select Right",
        Fn: (*) => SendInput("+{Right}"),
    },
    "sel_word_prev", {
        Label: "✎ W ← Sel. prev. word",
        Fn: (*) => SendInput("^+{Left}"),
    },
    "sel_word_next", {
        Label: "✎ W → Sel. next word",
        Fn: (*) => SendInput("^+{Right}"),
    },
    ; --- Media ---
    "vol_up", {
        Label: "🔊 + Volume +",
        Fn: (*) => SendInput("{Volume_Up}"),
    },
    "vol_down", {
        Label: "🔊 - Volume -",
        Fn: (*) => SendInput("{Volume_Down}"),
    },
    "mute", {
        Label: "🔇 Mute/Unmute",
        Fn: (*) => SendInput("{Volume_Mute}"),
    },
    "brightness_up", {
        Label: "☀ + Brightness +",
        Fn: (*) => SendInput("{Brightness_Up}"),
    },
    "brightness_down", {
        Label: "☀ - Brightness -",
        Fn: (*) => SendInput("{Brightness_Down}"),
    },
    "track_play", {
        Label: "⏯ Play/Pause",
        Fn: (*) => SendInput("{Media_Play_Pause}"),
    },
    "track_next", {
        Label: "⏭ Next track",
        Fn: (*) => SendInput("{Media_Next}"),
    },
    "track_prev", {
        Label: "⏮ Previous track",
        Fn: (*) => SendInput("{Media_Prev}"),
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
        Label: "📸 ⊞ Copy window",
        Fn: (*) => GestureScreenshotWindow("clipboard"),
    },
    "screenshot_window_save", {
        Label: "📸 ⊞ Save window",
        Fn: (*) => GestureScreenshotWindow("save"),
    },
    "screenshot_region_clipboard", {
        Label: "📸 ⬚ Copy region",
        Fn: (*) => GestureScreenshotRegion("clipboard"),
    },
    "screenshot_region_save", {
        Label: "📸 ⬚ Save region",
        Fn: (*) => GestureScreenshotRegion("save"),
    },
    "screenshot_fullscreen_clipboard", {
        Label: "📸 🖥 Copy screen",
        Fn: (*) => GestureScreenshotFullscreen("clipboard"),
    },
    "screenshot_fullscreen_save", {
        Label: "📸 🖥 Save screen",
        Fn: (*) => GestureScreenshotFullscreen("save"),
    },
    "screen_record", {
        Label: "⏺ Screen recording",
        Fn: (*) => SendInput("#!r"),
    },
    "lock_screen", {
        Label: "🔒 Lock screen",
        Fn: (*) => DllCall("LockWorkStation"),
    },
    "notification_center", {
        Label: "🔔 Notifications",
        Fn: (*) => SendInput("#n"),
    },
    ; --- UI windows ---
    ; Each UI action follows the same three-state pattern: if the window is
    ; closed, open it; if open and focused, close it; if open but in the
    ; background, raise it to the foreground.
    "open_metrics_typing", {
        Label: "📊 Typing stats",
        Fn: (*) => GestureToggleOrFocusUI("metrics_typing"),
    },
    "open_metrics_apps", {
        Label: "📊 App stats",
        Fn: (*) => GestureToggleOrFocusUI("metrics_apps"),
    },
    "open_hotstrings_editor", {
        Label: "⌨ Hotstrings editor",
        Fn: (*) => GestureToggleOrFocusUI("hotstrings_editor"),
    },
    "open_paths_editor", {
        Label: "📂 Paths editor",
        Fn: (*) => GestureToggleOrFocusUI("paths_editor"),
    },
    ; --- User files ---
    "open_script_source", {
        Label: "🛠 Source code",
        Fn: (*) => Run('notepad.exe "' . A_ScriptFullPath . '"'),
    },
    "open_personal_shortcuts", {
        Label: "👤 Personal shortcuts",
        Fn: (*) => GestureEditPersonalShortcuts(),
    },
    "open_personal_hotstrings", {
        Label: "👤 Personal hotstrings",
        Fn: (*) => GestureOpenIfExists(ScriptInformation["PersonalTomlPath"]),
    },
    "open_personal_info", {
        Label: "👤 Personal info",
        Fn: (*) => GestureOpenIfExists(ScriptInformation["PersonalInfoTomlPath"]),
    },
    "open_config", {
        Label: "⚙ Configuration",
        Fn: (*) => GestureOpenIfExists(IsSet(ConfigurationFile) ? ConfigurationFile : ""),
    },
    "open_logs_folder", {
        Label: "📁 Logs folder",
        Fn: (*) => OpenLogsFolder(),
    },
    "open_today_log", {
        Label: "📄 Today's log",
        Fn: (*) => OpenTodayLog(),
    },
    ; --- Script management ---
    "script_pause_toggle", {
        Label: "⏸/▶ Suspend / Resume",
        Fn: (*) => ToggleSuspend(),
    },
    "script_reload", {
        Label: "↻ Reload",
        Fn: (*) => Reload(),
    },
    "script_save_reload", {
        Label: "↻ Save and reload",
        Fn: (*) => GestureSaveAndReload(),
    },
    "script_quit", {
        Label: "✕ Quit",
        Fn: (*) => ExitApp(),
    },
    ; --- Debug (AHK only — Hammerspoon Console covers the three) ---
    "open_window_spy", {
        Label: "Window Spy",
        Fn: (*) => WindowSpy(),
    },
    "open_list_vars", {
        Label: "Variable state",
        Fn: (*) => ListVars(),
    },
    "open_key_history", {
        Label: "Key history",
        Fn: (*) => KeyHistory(),
    },
    ; --- Advanced system actions ---
    "select_line", {
        Label: "☰ Select line",
        Fn: (*) => SendFinalResult("{Home}{Shift Down}{End}{Shift Up}"),
    },
    "screen_capture", {
        Label: "📸 Selective capture (Win+Shift+S)",
        Fn: (*) => SendFinalResult("#+s"),
    },
    "screen_capture_instant", {
        Label: "📸 Instant capture (window)",
        Fn: (*) => GestureScreenshotInstant(),
    },
    "open_url", {
        Label: "🌐 Open a link (configurable)",
        Fn: (*) => GestureOpenConfiguredURL(),
    },
    "pick_color", {
        Label: "🎨 HEX colour under cursor",
        Fn: (*) => GesturePickColor(),
    },
    "take_note", {
        Label: "📝 Take a note",
        Fn: (*) => GestureTakeNote(),
    },
    "activity_simulation", {
        Label: "🖱 Simulate activity (anti-sleep)",
        Fn: (*) => GestureToggleActivitySimulation(),
    },
    "surround_parens", {
        Label: "() Surround with parentheses",
        Fn: (*) => SendFinalResult("{Home}({End}){Home}"),
    },
    "search_web", {
        Label: "🔍 Web search (configurable)",
        Fn: (*) => GestureSearchWeb(),
    },
    "teleport_mouse", {
        Label: "🖱 Teleport mouse",
        Fn: (*) => GestureTeleportMouse(),
    },
    "uppercase_selection", {
        Label: "AA Uppercase / lowercase",
        Fn: (*) => GestureToggleUppercase(),
    },
    "titlecase_selection", {
        Label: "Aa Title case",
        Fn: (*) => GestureToggleTitleCase(),
    },
    "spotlight_mouse", {
        Label: "🔦 Mouse spotlight",
        Fn: (*) => (MouseGetPos(&_Mx, &_My), SpotlightMouseAt(_Mx, _My, 5000)),
    },
    "toggle_capslock", {
        Label: "⇪ Toggle CapsLock",
        Fn: (*) => ToggleCapsLock(),
    },
    "microsoft_bold", {
        Label: "𝐁 Ctrl+B Microsoft (→ Ctrl+G)",
        Fn: (*) => (MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")),
    },
    "paste_plain", {
        Label: "⎘ Paste without formatting",
        Fn: (*) => GesturePastePlain(),
    },
)

; Returns the translated label for a gesture action.
; Prefers t("sg_actions.X") from the active locale JSON; falls back to the
; hardcoded English label in GESTURE_ACTIONS so new locales never show raw keys.
_GestureActionLabel(Name) {
	global GESTURE_ACTIONS
	Key := "sg_actions." . Name
	Translated := t(Key)
	if (Translated != Key)
		return Translated
	return GESTURE_ACTIONS.Has(Name) ? GESTURE_ACTIONS[Name].Label : Name
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
    TmpScript := A_Temp . "\hs_screenshot.ps1"
    ScriptContent := "Add-Type -AssemblyName System.Drawing`n"
        . "$bmp = New-Object System.Drawing.Bitmap(" . WW . ", " . WH . ")`n"
        . "$g = [System.Drawing.Graphics]::FromImage($bmp)`n"
        . "$g.CopyFromScreen(" . WX . ", " . WY . ", 0, 0, $bmp.Size)`n"
        . "$bmp.Save('" . FilePath . "')`n"
        . "$g.Dispose(); $bmp.Dispose()"
    FileDelete(TmpScript)
    FileAppend(ScriptContent, TmpScript, "UTF-8")
    RunWait('powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' . TmpScript . '"',, "Hide")
    TrayTip(Format(t("notify.screenshot_saved_path"), FilePath), t("notify.screenshot_title"), "Iconi Mute")
}

GestureOpenConfiguredURL() {
    global _IniCache
    URL := IniCacheGet(_IniCache, "Shortcuts.Actions", "open_url")
    if (URL = "_" or URL = "")
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
    global _IniCache
    DatedRaw := IniCacheGet(_IniCache, "Shortcuts.Actions", "take_note_dated")
    DatedNotes := (DatedRaw = "true")
    FolderRaw := IniCacheGet(_IniCache, "Shortcuts.Actions", "take_note_folder")
    DestFolder := (FolderRaw = "_" or FolderRaw = "") ? A_Desktop : FolderRaw
    FileName := DatedNotes
        ? "Notes_" . FormatTime(, "dd_MM_yyyy") . ".txt"
        : "Notes.txt"
    FilePath := DestFolder . "\" . FileName
    if not FileExist(FilePath)
        FileAppend("", FilePath)
    PreviousTitleMatchMode := A_TitleMatchMode
    try {
        SetTitleMatchMode(2)
        if WinExist(FileName) {
            WinActivate(FileName)
            WinWaitActive(FileName, , 3)
        } else {
            Run('notepad.exe "' . FilePath . '"')
            WinWait(FileName, , 7)
            WinActivate(FileName)
            WinWaitActive(FileName, , 3)
        }
        WinMaximize()
        Sleep(100)
    } finally {
        SetTitleMatchMode(PreviousTitleMatchMode)
    }
}

GestureToggleActivitySimulation() {
    global ActivitySimulation
    ActivitySimulation := !ActivitySimulation
    if ActivitySimulation
        SetTimer(GestureSimulateActivity, Random(1000, 5000))
}

GestureSimulateActivity() {
    global ActivitySimulation
    if !ActivitySimulation
        return
    loop Random(3, 8) {
        DllCall("SetCursorPos", "int", Random(0, A_ScreenWidth), "int", Random(0, A_ScreenHeight))
        Sleep(Random(200, 800))
    }
    SendFinalResult("{VKFF}")
}

GestureSearchWeb() {
    global _IniCache
    EngineURL   := IniCacheGet(_IniCache, "Shortcuts.Actions", "search_web_engine")
    EngineQuery := IniCacheGet(_IniCache, "Shortcuts.Actions", "search_web_query")
    if (EngineURL = "_" or EngineURL = "")
        EngineURL := "https://www.google.com"
    if (EngineQuery = "_" or EngineQuery = "")
        EngineQuery := "https://www.google.com/search?q="
    SelectedText := Trim(GetSelection())
    if (SelectedText = "") {
        Run(EngineURL)
    } else {
        SelectedText := StrReplace(SelectedText, "`r`n", " ")
        SelectedText := StrReplace(SelectedText, "#", "%23")
        SelectedText := StrReplace(SelectedText, "&", "%26")
        SelectedText := StrReplace(SelectedText, "+", "%2b")
        SelectedText := StrReplace(SelectedText, "`"", "%22")
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
    DllCall("SetCursorPos", "int", TargetX, "int", TargetY)
    SpotlightMouseAt(TargetX, TargetY, 3000)
}

GestureToggleUppercase() {
    Text := GetSelection()
    if RegExMatch(Text, "[a-zà-ÿ]")
        SendInstant(Format("{:U}", Text))
    else
        SendInstant(Format("{:L}", Text))
}

GestureToggleTitleCase() {
    Text := GetSelection()
    TitleCasePattern :=
        "^(?:[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*[ \t\r\n]+)*[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*$"
    UpperCasePattern := "^[A-ZÉÈÀÙÂÊÎÔÛÇ0-9''\(\),.\-:;!?\s]+$"
    if RegExMatch(Text, TitleCasePattern)
        SendInstant(Format("{:L}", Text))
    else
        SendInstant(Format("{:T}", Text))
}

GesturePastePlain() {
    if not WinActive("ahk_exe EXCEL.EXE") {
        A_Clipboard := A_Clipboard
        SendFinalResult("^v")
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
    if (hwnd && WinExist("ahk_id " . hwnd)) {
        focused := 0
        try focused := WinGetID("A")
        if (focused = hwnd) {
            try close_fn.Call()
        } else {
            try WinActivate("ahk_id " . hwnd)
        }
        return
    }
    try open_fn.Call()
}

; Save the active document with Ctrl+S then reload — mirrors the legacy
; AltGr+BackSpace shortcut that pre-dated the action registry.
GestureSaveAndReload() {
    SendInput("{LControl Down}s{LControl Up}")
    Sleep(300)
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

; Path to the shared cross-platform action registry.
; Resolved from _StaticDir which is already set in ErgoptiPlus.ahk.
_GestureSharedToml := _StaticDir . "\shared\actions.toml"

_GestureTomlData := ParseTomlFile(_GestureSharedToml)

; Build GESTURE_ACTION_NAMES from [sg_order].items, keeping only entries that
; are either a sentinel ("--", "#…") or an action whose platform is "all" / "ahk".
if _GestureTomlData.Has("sg_order") && _GestureTomlData["sg_order"].Has("items") {
    _SgItems := _GestureTomlData["sg_order"]["items"]
    for _Item in _SgItems {
        ; Sentinels and headers pass through unconditionally
        if (_Item = "--" || SubStr(_Item, 1, 1) = "#") {
            GESTURE_ACTION_NAMES.Push(_Item)
            continue
        }
        ; Placeholder keys (_cmd_placeholder, _ctrl_placeholder…) are replaced
        ; by the dynamic ctrl_* block inserted below — skip them here
        if (SubStr(_Item, 1, 1) = "_") {
            if (_Item = "_ctrl_placeholder") {
                GESTURE_ACTION_NAMES.Push("#Raccourcis ^ (Ctrl)")
                _CtrlKeys := "abcdefghijklmnopqrstuvwxyz"
                loop StrLen(_CtrlKeys)
                    GESTURE_ACTION_NAMES.Push("ctrl_" . SubStr(_CtrlKeys, A_Index, 1))
                loop 10
                    GESTURE_ACTION_NAMES.Push("ctrl_" . SubStr("0123456789", A_Index, 1))
                for _Sk, _ in _GestureSpecialKeys
                    GESTURE_ACTION_NAMES.Push("ctrl_" . _Sk)
            } else if (_Item = "_ctrl_shift_placeholder") {
                GESTURE_ACTION_NAMES.Push("#Raccourcis ^⇧ (Ctrl+Shift)")
                _CtrlShiftKeys := "abcdefghijklmnopqrstuvwxyz"
                loop StrLen(_CtrlShiftKeys)
                    GESTURE_ACTION_NAMES.Push("ctrl_shift_" . SubStr(_CtrlShiftKeys, A_Index, 1))
            } else if (_Item = "_win_placeholder") {
                GESTURE_ACTION_NAMES.Push("#Raccourcis ⊞ (Win)")
                _WinKeys := "abcdefghijklmnopqrstuvwxyz"
                loop StrLen(_WinKeys)
                    GESTURE_ACTION_NAMES.Push("win_" . SubStr(_WinKeys, A_Index, 1))
                loop 10
                    GESTURE_ACTION_NAMES.Push("win_" . SubStr("0123456789", A_Index, 1))
                for _Sk, _ in _GestureSpecialKeys
                    GESTURE_ACTION_NAMES.Push("win_" . _Sk)
            } else if (_Item = "_alt_placeholder") {
                GESTURE_ACTION_NAMES.Push("#Raccourcis ⎇ (Alt)")
                _AltKeys := "abcdefghijklmnopqrstuvwxyz"
                loop StrLen(_AltKeys)
                    GESTURE_ACTION_NAMES.Push("alt_" . SubStr(_AltKeys, A_Index, 1))
                loop 10
                    GESTURE_ACTION_NAMES.Push("alt_" . SubStr("0123456789", A_Index, 1))
                for _Sk, _ in _GestureSpecialKeys
                    GESTURE_ACTION_NAMES.Push("alt_" . _Sk)
            }
            ; hs-only placeholders (_cmd_placeholder, _hs_ctrl_placeholder…) are silently dropped
            continue
        }
        ; Regular action — keep if platform is "all" or "ahk"
        _SecKey := "sg_actions." . _Item
        if _GestureTomlData.Has(_SecKey) {
            _Plat := _GestureTomlData[_SecKey].Has("platform") ? _GestureTomlData[_SecKey]["platform"] : "all"
            if (_Plat = "all" || _Plat = "ahk")
                GESTURE_ACTION_NAMES.Push(_Item)
        } else if GESTURE_ACTIONS.Has(_Item) {
            ; Action exists in registry but not in shared TOML (e.g. dynamically added) — include it
            GESTURE_ACTION_NAMES.Push(_Item)
        }
    }
}

; Build GESTURE_AX_NAMES from [ax_order].items, same filtering logic.
if _GestureTomlData.Has("ax_order") && _GestureTomlData["ax_order"].Has("items") {
    _AxItems := _GestureTomlData["ax_order"]["items"]
    for _Item in _AxItems {
        _SecKey := "ax_actions." . _Item
        if _GestureTomlData.Has(_SecKey) {
            _Plat := _GestureTomlData[_SecKey].Has("platform") ? _GestureTomlData[_SecKey]["platform"] : "all"
            if (_Plat = "all" || _Plat = "ahk")
                GESTURE_AX_NAMES.Push(_Item)
        }
    }
}

; Current action assignments — read from INI or defaults
global GestureAssignments := Map(
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

; Click hold mode state
global GestureLeftClickHeld  := False
global GestureRightClickHeld := False
global GestureKeyboardHook   := 0

; ===========================================
; ===========================================
; ======= 2/ Right-Click Hold Toggle =======
; ===========================================
; ===========================================

; Sends a shortcut while neutralising the Ctrl+Win+Shift modifiers that the
; touchpad gesture itself is still holding down at callback time. Without this,
; e.g. Ctrl+Shift+Tab sent on top of held Ctrl+Win+Shift collapses to plain Tab.
GestureSendShortcut(Keys) {
    Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    SendInput(Keys)
}

; Returns the list of all visible, non-cloaked top-level windows on the
; current virtual desktop, ordered like the taskbar (oldest → newest Z-order).
; Filters out tool windows, the desktop shell, and the Settings host so the
; cycle stays on real user windows.
GestureGetCyclableWindows(ProcessFilter := "") {
    Result := []
    Ids := WinGetList()
    for HWnd in Ids {
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
            Class := WinGetClass("ahk_id " . HWnd)
            if (Class = "Progman" || Class = "WorkerW" || Class = "Shell_TrayWnd") {
                continue
            }
            ; DWMWA_CLOAKED = 14 — windows on other virtual desktops
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

    ; Stable order independent of focus — HWNDs are monotonic creation IDs.
    ; Without this sort, WinGetList()'s Z-order makes the cycle ping-pong
    ; between the 2 last-used windows (Alt+Tab behaviour).
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

; ==========================================
; ===== Screenshot helpers =====
; ==========================================

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
    HWnd := WinExist("A")
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
        SendInput("#+s")
        LoggerSuccess("gestures", "Snip & Sketch invoked (clipboard mode).")
        return
    }
    Path := GestureScreenshotPath()
    LoggerStart("gestures", "Region screenshot to disk — opening Snip & Sketch…")
    A_Clipboard := ""
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
        WinActivate("ahk_id " . HWnd)
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
; If the target window can't be activated, falls back to the next one in the
; cycle so the user never gets "stuck" at an unactivatable slot.
GestureCycleWindows(Forward) {
    ; Release modifiers still held by the touchpad gesture (Ctrl+Win+Shift)
    ; so WinActivate doesn't trigger the Start menu or other system shortcuts.
    Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    Windows := GestureGetCyclableWindows()
    N := Windows.Length
    if (N < 2) {
        LoggerDebug("gestures", "CycleWindows: only {1} window(s) — nothing to cycle.", N)
        return
    }
    Active := WinExist("A")
    Index := 0
    for I, HWnd in Windows {
        if (HWnd = Active) {
            Index := I
            break
        }
    }
    LoggerDebug("gestures", "CycleWindows: {1} window(s), active idx={2}, forward={3}.",
        N, Index, Forward)
    for I, HWnd in Windows {
        try {
            T := WinGetTitle("ahk_id " . HWnd)
            C := WinGetClass("ahk_id " . HWnd)
            LoggerDebug("gestures", "  [{1}] HWND={2} class='{3}' title='{4}'.", I, HWnd, C, T)
        }
    }

    ; Try up to N-1 candidates so we wrap around even if some windows refuse activation.
    Target := Index
    loop N - 1 {
        Target := GestureNextIndex(Target, N, Forward)
        if GestureActivateWindow(Windows[Target]) {
            LoggerDebug("gestures", "Activated HWND {1} (idx={2}).", Windows[Target], Target)
            return
        }
    }
    LoggerWarn("gestures", "CycleWindows: no candidate could be activated.")
}

; Cycles through windows belonging to the same process as the active window.
GestureCycleAppWindows(Forward) {
    Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
    Active := WinExist("A")
    if (!Active) {
        return
    }
    try ProcName := WinGetProcessName("ahk_id " . Active)
    catch {
        return
    }
    Windows := GestureGetCyclableWindows(ProcName)
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
        if GestureActivateWindow(Windows[Target]) {
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
    LoggerInfo("gestures", "Left-click hold mode enabled.")
}

; Releases the left mouse button if it is currently held by the toggle.
GestureReleaseLeftClick() {
    global GestureLeftClickHeld, GestureRightClickHeld

    if (!GestureLeftClickHeld) {
        return
    }

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
    GestureKeyboardHook := InputHook("L0")
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
    ; Any keystroke releases whichever button(s) are currently held
    GestureReleaseLeftClick()
    GestureReleaseRightClick()
}

; Wrapper required: #HotIf evaluates before globals are assigned at runtime
IsGestureLeftClickHeld() {
    global GestureLeftClickHeld
    return IsSet(GestureLeftClickHeld) ? GestureLeftClickHeld : False
}

IsGestureRightClickHeld() {
    global GestureRightClickHeld
    return IsSet(GestureRightClickHeld) ? GestureRightClickHeld : False
}

; Also release on a physical click so the toggle hands control back.
#HotIf IsGestureLeftClickHeld()
~RButton:: {
    GestureReleaseLeftClick()
}
#HotIf

#HotIf IsGestureRightClickHeld()
~LButton:: {
    GestureReleaseRightClick()
}
#HotIf

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
    LoggerInfo("gestures", "Right-click hold mode enabled.")
}

; Releases the right mouse button if it is currently held by the toggle.
GestureReleaseRightClick() {
    global GestureRightClickHeld, GestureLeftClickHeld

    if (!GestureRightClickHeld) {
        return
    }

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

    if !Features["Gestures"]["Enabled"].Enabled {
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
    try GESTURE_ACTIONS[ActionName].Fn()
    LoggerInfo("gestures", "Gesture {1} dispatched successfully.", slot)
}

; =============================================
; =============================================
; ======= 4/ Hotkey Bindings (Listeners) =======
; =============================================
; =============================================

; These shortcuts must be assigned in Windows Settings > Bluetooth & devices
; > Touchpad > Advanced gesture configuration.
; Use the "Configurer automatiquement" button in the menu to set them via
; the registry, or assign them manually.

; The '$' prefix forces AHK to use the low-level keyboard hook instead of
; RegisterHotKey, which lets us intercept the shortcut even in console hosts
; (PowerShell, cmd, WSL) that would otherwise swallow it before AHK sees it.
$^#+F1:: GestureDispatch("tap_3")
$^#+F2:: GestureDispatch("swipe_3_up")
$^#+F3:: GestureDispatch("swipe_3_down")
$^#+F4:: GestureDispatch("swipe_3_left")
$^#+F5:: GestureDispatch("swipe_3_right")
$^#+F6:: GestureDispatch("tap_4")
$^#+F7:: GestureDispatch("swipe_4_up")
$^#+F8:: GestureDispatch("swipe_4_down")
$^#+F9:: GestureDispatch("swipe_4_left")
$^#+F10:: GestureDispatch("swipe_4_right")

; ==========================================
; ==========================================
; ======= 5/ Configuration & Setup ========
; ==========================================
; ==========================================

; Reads gesture assignments from the INI file.
GesturesReadConfig() {
    global GestureAssignments, _IniCache

    for Slot in GESTURE_SLOTS {
        Value := IniCacheGet(_IniCache, "Gestures", Slot)
        if (Value != "_") {
            GestureAssignments[Slot] := Value
        }
    }
}

; Saves a single gesture assignment to the INI file.
GestureSaveAssignment(slot, action) {
    global GestureAssignments, ConfigurationFile

    GestureAssignments[slot] := action
    TOML_Write(action, ConfigurationFile, "Gestures", slot)
}

; Writes a single REG_DWORD value, logging and counting failures.
GestureRegWriteDword(ValueName, Value, &ErrorsRef) {
    global GESTURE_REG_PATH

    try {
        RegWrite(Value, "REG_DWORD", GESTURE_REG_PATH, ValueName)
        LoggerDebug("gestures", "Wrote {1} = {2}.", ValueName, Value)
    } catch as e {
        ErrorsRef += 1
        LoggerError("gestures", "Failed to write registry value {1}: {2}.", ValueName, e.Message)
    }
}

; Configures Windows touchpad gestures via the registry so that all 10 gesture
; slots send Ctrl+Win+Shift+F1..F10 without any manual Settings configuration.
; Writes the master enables, per-direction enables, Custom*Tap sentinels,
; KeyParams (encoded as (VK<<8)|7), and resets the new-system *Action values
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

; Shows setup instructions to the user.
GestureShowSetupInstructions() {
    Instructions := t("gesture.setup.header")
        . t("gesture.setup.open_path")
        . t("gesture.setup.for_each")

    for Slot in GESTURE_SLOTS {
        Instructions .= "  " . t("gesture.slots." . Slot) . " :  "
            . GESTURE_SHORTCUT_LABELS[Slot] . "`n"
    }

    Instructions .= t("gesture.setup.auto_configure")

    MsgBox(Instructions, t("gesture.setup.title"), "Iconi")
}

; Opens Windows Settings to the touchpad page and reminds the user to drill
; down into the "Mouvements avancés" sub-page (no deep-link URI exists for it).
GestureOpenTouchpadSettings() {
    try Run("ms-settings:devices-touchpad")
    MsgBox(t("gesture.touchpad_open.body"), t("gesture.setup.title"), "Iconi")
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
RawAutoConfig := IniCacheGet(_IniCache, "Gestures", "AutoConfigureOnNextStart")
if (RawAutoConfig == "1" or RawAutoConfig == "true") {
    LoggerStart("gestures", "Consuming AutoConfigureOnNextStart flag from onboarding…")
    try GestureAutoConfigureRegistry()
    try TOML_BatchWrite(ConfigurationFile,
        [{ Section: "Gestures", Key: "AutoConfigureOnNextStart", Value: false }])
    LoggerSuccess("gestures", "AutoConfigureOnNextStart flag consumed and cleared.")
}

LoggerSuccess("gestures", "Gestures module initialised — ready.")
