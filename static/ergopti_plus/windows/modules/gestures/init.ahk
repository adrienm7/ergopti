; modules/gestures/init.ahk
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
for _GestureLabelIndex, _GestureLabelSlot in ["tap_3", "swipe_3_up", "swipe_3_down", "swipe_3_left", "swipe_3_right",
              "tap_4", "swipe_4_up", "swipe_4_down", "swipe_4_left", "swipe_4_right"] {
    GESTURE_SLOT_LABELS[_GestureLabelSlot] := t("gesture.slots." . _GestureLabelSlot)
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


#Include actions.ahk





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

    try {
		GestureInvokeAction(ActionName, GestureBindingId("gesture", slot))
        LoggerInfo("gestures", "Gesture {1} dispatched successfully.", slot)
    } catch as e {
        try LoggerError("gestures", "Gesture {1} action '{2}' threw: {3}.", slot, ActionName, e.Message)
    }
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

    ; Clear the flag FIRST, before the asynchronous touchpad worker starts —
    ; the PnP cycle can still kill the AHK process by tearing down the HID hook.
    ; Clearing after launch would leave the flag set and the auto-relaunched
    ; script could loop forever, never reaching initMenu.
    try TOML_BatchWrite(ConfigurationFile,
        [{ Section: "ahk.gestures", Key: "auto_configure_on_next_start", Value: false }])

    ; Defer the registry write + worker launch until the auto-execute tail
    ; (notably initMenu in ErgoptiPlus.ahk) has settled. The PnP operation then
    ; runs in its own elevated process and is polled without blocking AHK.
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
