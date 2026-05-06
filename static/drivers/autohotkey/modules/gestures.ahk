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
; In Settings > Bluetooth & devices > Touchpad > Advanced gesture configuration,
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
global GESTURE_SLOT_LABELS := Map(
    "tap_3", "Tap 3 doigts",
    "swipe_3_up", "Swipe 3 doigts ↑",
    "swipe_3_down", "Swipe 3 doigts ↓",
    "swipe_3_left", "Swipe 3 doigts ←",
    "swipe_3_right", "Swipe 3 doigts →",
    "tap_4", "Tap 4 doigts",
    "swipe_4_up", "Swipe 4 doigts ↑",
    "swipe_4_down", "Swipe 4 doigts ↓",
    "swipe_4_left", "Swipe 4 doigts ←",
    "swipe_4_right", "Swipe 4 doigts →",
)

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
        Label: "Désactivé",
        Fn: (*) => 0,
    },
    ; --- Selection & navigation ---
    "selection_toggle", {
        Label: "Toggle sélection",
        Fn: (*) => GestureToggleSelection(),
    },
    "app_switcher", {
        Label: "Alt-Tab",
        Fn: (*) => SendEvent("!{Tab}"),
    },
    ; --- Editing ---
    "copy", {
        Label: "Copier",
        Fn: (*) => SendEvent("^c"),
    },
    "paste", {
        Label: "Coller",
        Fn: (*) => SendEvent("^v"),
    },
    "cut", {
        Label: "Couper",
        Fn: (*) => SendEvent("^x"),
    },
    "undo", {
        Label: "Annuler",
        Fn: (*) => SendEvent("^z"),
    },
    "redo", {
        Label: "Rétablir",
        Fn: (*) => SendEvent("^y"),
    },
    "select_all", {
        Label: "Tout sélectionner",
        Fn: (*) => SendEvent("^a"),
    },
    "find", {
        Label: "Rechercher",
        Fn: (*) => SendEvent("^f"),
    },
    ; --- Keys ---
    "enter", {
        Label: "Entrée",
        Fn: (*) => SendEvent("{Enter}"),
    },
    "tab", {
        Label: "Tab",
        Fn: (*) => SendEvent("{Tab}"),
    },
    "escape", {
        Label: "Échap",
        Fn: (*) => SendEvent("{Escape}"),
    },
    "backspace", {
        Label: "Suppr. arrière",
        Fn: (*) => SendEvent("{BackSpace}"),
    },
    "delete", {
        Label: "Supprimer",
        Fn: (*) => SendEvent("{Delete}"),
    },
    ; --- Tabs ---
    "tab_new", {
        Label: "Nouvel onglet",
        Fn: (*) => SendEvent("^t"),
    },
    "tab_close", {
        Label: "Fermer onglet",
        Fn: (*) => SendEvent("^w"),
    },
    "tab_prev", {
        Label: "Onglet précédent",
        Fn: (*) => SendEvent("^+{Tab}"),
    },
    "tab_next", {
        Label: "Onglet suivant",
        Fn: (*) => SendEvent("^{Tab}"),
    },
    ; --- Windows & Desktops ---
    "win_prev", {
        Label: "Fenêtre précédente",
        Fn: (*) => SendEvent("!+{Tab}"),
    },
    "win_next", {
        Label: "Fenêtre suivante",
        Fn: (*) => SendEvent("!{Tab}"),
    },
    "close_window", {
        Label: "Fermer la fenêtre",
        Fn: (*) => SendEvent("!{F4}"),
    },
    "fullscreen", {
        Label: "Plein écran",
        Fn: (*) => SendEvent("{F11}"),
    },
    "snap_left", {
        Label: "Ancrer à gauche",
        Fn: (*) => SendEvent("#{Left}"),
    },
    "snap_right", {
        Label: "Ancrer à droite",
        Fn: (*) => SendEvent("#{Right}"),
    },
    "maximize", {
        Label: "Maximiser",
        Fn: (*) => SendEvent("#{Up}"),
    },
    "desktop_prev", {
        Label: "Bureau précédent",
        Fn: (*) => SendEvent("^#{Left}"),
    },
    "desktop_next", {
        Label: "Bureau suivant",
        Fn: (*) => SendEvent("^#{Right}"),
    },
    "desktop_new", {
        Label: "Nouveau bureau",
        Fn: (*) => SendEvent("^#d"),
    },
    "desktop_close", {
        Label: "Fermer le bureau",
        Fn: (*) => SendEvent("^#{F4}"),
    },
    "task_view", {
        Label: "Vue des tâches",
        Fn: (*) => SendEvent("#{Tab}"),
    },
    "minimize_all", {
        Label: "Tout minimiser",
        Fn: (*) => SendEvent("#d"),
    },
    ; --- Media ---
    "vol_up", {
        Label: "Volume +",
        Fn: (*) => SendEvent("{Volume_Up}"),
    },
    "vol_down", {
        Label: "Volume -",
        Fn: (*) => SendEvent("{Volume_Down}"),
    },
    "mute", {
        Label: "Muet/Unmute",
        Fn: (*) => SendEvent("{Volume_Mute}"),
    },
    "track_play", {
        Label: "Lecture/Pause",
        Fn: (*) => SendEvent("{Media_Play_Pause}"),
    },
    "track_next", {
        Label: "Piste suivante",
        Fn: (*) => SendEvent("{Media_Next}"),
    },
    "track_prev", {
        Label: "Piste précédente",
        Fn: (*) => SendEvent("{Media_Prev}"),
    },
    ; --- System ---
    "screenshot", {
        Label: "Capture d'écran",
        Fn: (*) => SendEvent("#+s"),
    },
    "lock_screen", {
        Label: "Verrouiller",
        Fn: (*) => DllCall("LockWorkStation"),
    },
    "notification_center", {
        Label: "Notifications",
        Fn: (*) => SendEvent("#n"),
    },
    ; --- Script management ---
    "ahk_reload", {
        Label: "Recharger ErgoptiPlus",
        Fn: (*) => Reload(),
    },
    "ahk_suspend", {
        Label: "Suspendre ErgoptiPlus",
        Fn: (*) => ToggleSuspend(),
    },
    "ahk_edit", {
        Label: "Ouvrir personal.ahk",
        Fn: (*) => Run('notepad.exe "' . ScriptInformation["PersonalAhkPath"] . '"'),
    },
    "ahk_quit", {
        Label: "Quitter ErgoptiPlus",
        Fn: (*) => ExitApp(),
    },
)

; Ordered list of action names for the menu (same order as Hammerspoon)
global GESTURE_ACTION_NAMES := [
    "none",
    ; Selection & navigation
    "selection_toggle", "app_switcher",
    ; Editing
    "copy", "paste", "cut", "undo", "redo", "select_all", "find",
    ; Keys
    "enter", "tab", "escape", "backspace", "delete",
    ; Tabs
    "tab_new", "tab_close", "tab_prev", "tab_next",
    ; Windows & Desktops
    "win_prev", "win_next", "close_window", "fullscreen",
    "snap_left", "snap_right", "maximize",
    "desktop_prev", "desktop_next", "desktop_new", "desktop_close",
    "task_view", "minimize_all",
    ; Media
    "vol_up", "vol_down", "mute",
    "track_play", "track_next", "track_prev",
    ; System
    "screenshot", "lock_screen", "notification_center",
    ; Script management
    "ahk_reload", "ahk_suspend", "ahk_edit", "ahk_quit",
]

; Current action assignments — read from INI or defaults
global GestureAssignments := Map(
    "tap_3", "selection_toggle",
    "swipe_3_up", "task_view",
    "swipe_3_down", "minimize_all",
    "swipe_3_left", "tab_prev",
    "swipe_3_right", "tab_next",
    "tap_4", "none",
    "swipe_4_up", "task_view",
    "swipe_4_down", "minimize_all",
    "swipe_4_left", "desktop_prev",
    "swipe_4_right", "desktop_next",
)

; Selection mode state
global GestureDragEnabled := False
global GestureKeyboardHook := 0

; ==========================================
; ==========================================
; ======= 2/ Selection Toggle Engine =======
; ==========================================
; ==========================================

; Activates or deactivates drag selection mode.
; Any subsequent keystroke automatically cancels it.
GestureToggleSelection() {
    global GestureDragEnabled

    if (GestureDragEnabled) {
        GestureStopSelection()
        return
    }

    LoggerDebug("gestures", "Enabling drag selection mode…")
    Click("Left", "Down")
    GestureDragEnabled := True

    ; Install a keyboard hook that cancels selection on any key press
    GestureStartKeyboardWatcher()
    LoggerInfo("gestures", "Drag selection mode enabled.")
}

; Cancels drag selection and releases the mouse button.
GestureStopSelection() {
    global GestureDragEnabled

    if (!GestureDragEnabled) {
        return
    }

    LoggerDebug("gestures", "Disabling drag selection mode…")
    GestureStopKeyboardWatcher()
    Click("Left", "Up")
    GestureDragEnabled := False
    LoggerInfo("gestures", "Drag selection mode disabled.")
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

; Callback fired on any key press while selection is active.
GestureOnKeyDown(ih, vk, sc) {
    ; Any keystroke cancels drag selection
    GestureStopSelection()
}

; Also cancel on physical left click — user clicked manually
#HotIf GestureDragEnabled
~LButton:: {
    GestureStopSelection()
}
#HotIf

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

    LoggerDebug("gestures", "Dispatching gesture: %s -> %s.", slot, ActionName)
    try GESTURE_ACTIONS[ActionName].Fn()
    LoggerInfo("gestures", "Gesture %s dispatched successfully.", slot)
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

; 3 finger tap
^#+F1:: GestureDispatch("tap_3")

; 3 finger swipe up
^#+F2:: GestureDispatch("swipe_3_up")

; 3 finger swipe down
^#+F3:: GestureDispatch("swipe_3_down")

; 3 finger swipe left
^#+F4:: GestureDispatch("swipe_3_left")

; 3 finger swipe right
^#+F5:: GestureDispatch("swipe_3_right")

; 4 finger tap
^#+F6:: GestureDispatch("tap_4")

; 4 finger swipe up
^#+F7:: GestureDispatch("swipe_4_up")

; 4 finger swipe down
^#+F8:: GestureDispatch("swipe_4_down")

; 4 finger swipe left
^#+F9:: GestureDispatch("swipe_4_left")

; 4 finger swipe right
^#+F10:: GestureDispatch("swipe_4_right")

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
    IniWrite(action, ConfigurationFile, "Gestures", slot)
}

; Attempts to configure Windows touchpad gestures via the registry.
; Sets all gesture actions to "Custom shortcut" so they send our key combos.
; Returns true on success, false if registry writes failed.
GestureAutoConfigureRegistry() {
    global GESTURE_REG_PATH, GESTURE_REG_ACTIONS, GESTURE_REG_CUSTOM_VALUE

    LoggerStart("gestures", "Auto-configuring touchpad gestures via registry…")
    Errors := 0

    for Slot, RegName in GESTURE_REG_ACTIONS {
        try {
            RegWrite(GESTURE_REG_CUSTOM_VALUE, "REG_DWORD", GESTURE_REG_PATH, RegName)
        } catch as e {
            Errors += 1
            LoggerError("gestures", "Failed to write registry value %s: %s.", RegName, e.Message)
        }
    }

    if (Errors > 0) {
        LoggerError("gestures", "Auto-configuration failed with %d error(s).", Errors)
        return False
    }

    LoggerSuccess("gestures", "Registry values written — restart may be required.")
    return True
}

; Shows setup instructions to the user.
GestureShowSetupInstructions() {
    Instructions := "Configuration des gestes du touchpad`n"
        . "══════════════════════════════════`n`n"
        . "Ouvrir : Paramètres > Bluetooth et appareils > Pavé tactile`n"
        . "         > Configuration avancée des mouvements`n`n"
        . "Pour chaque geste, sélectionner « Raccourci personnalisé »`n"
        . "puis taper le raccourci indiqué :`n`n"

    for Slot in GESTURE_SLOTS {
        Instructions .= "  " . GESTURE_SLOT_LABELS[Slot] . " :  "
            . GESTURE_SHORTCUT_LABELS[Slot] . "`n"
    }

    Instructions .= "`nOu cliquer « Configurer automatiquement » dans le menu`n"
        . "pour écrire ces raccourcis directement dans le registre.`n"
        . "(Un redémarrage peut être nécessaire.)"

    MsgBox(Instructions, "ErgoptiPlus — Gestes du touchpad", "Iconi")
}

; Opens Windows Settings to the touchpad page.
GestureOpenTouchpadSettings() {
    try Run("ms-settings:devices-touchpad")
}

; Read configuration on load
GesturesReadConfig()

LoggerSuccess("gestures", "Gestures module initialised — ready.")
