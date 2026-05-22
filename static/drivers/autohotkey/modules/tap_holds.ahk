; static/drivers/autohotkey/modules/tap_holds.ahk

; ==============================================================================
; MODULE: Tap-Holds, One-Shot Shift and Navigation Layer
; DESCRIPTION:
; Implements tap-hold behaviours for CapsLock, LShift, LCtrl, LAlt, Space,
; AltGr, RCtrl and Tab keys. Also contains the One-Shot Shift mechanism and
; the full navigation layer (arrows, window management, volume…).
; ==============================================================================

; ==============================
; ==============================
; ======= 1/ Constants =======
; ==============================
; ==============================

; Minimum duration (ms) a tap must last to count as intentional — filters
; spurious firings when another key is chord-pressed with LShift or LCtrl.
global TAP_MIN_DURATION_MS := 50

; Wrapper required: hotkey bodies may fire (e.g. via timers) before the top-
; level auto-execute has finished, so a direct read of TAP_MIN_DURATION_MS
; would error with "global variable has not been assigned a value".
TapMinDurationMs() {
	global TAP_MIN_DURATION_MS
	return IsSet(TAP_MIN_DURATION_MS) ? TAP_MIN_DURATION_MS : 50
}

; Initial delay (ms) before key-repeat starts when BackSpace is held on LAlt or RCtrl.
global KEY_REPEAT_INITIAL_DELAY_MS := 300

; Interval (ms) between successive BackSpace repeats while the key stays held.
global KEY_REPEAT_INTERVAL_MS := 100

; Timeout (s) for the OneShotShift InputHook: how long to wait for the next
; character before giving up and leaving the shift state active.
global ONE_SHOT_SHIFT_TIMEOUT_SEC := 2

; ==============================
; ==============================
; ======= 2/ CAPSLOCK =======
; ==============================
; ==============================

; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock not remapped
#HotIf (
    TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift"
    and not _CapsLockIsPlainBackspace()
    and not CapsLockRemappedCondition()
    and not LayerEnabled
)
SC03A:: {
    if (GetKeyState("SC038", "P")) {
        LAltCapsLockShortcut()
        return
    }
    ToggleCapsLock()
}
#HotIf

#HotIf _CapsLockIsPlainBackspace() and not LayerEnabled
*SC03A:: {
    if (GetKeyState("SC038", "P")) {
        LAltCapsLockShortcut()
        return
    }

    SendEvent("{Blind}{BackSpace}")
}
#HotIf

; "BackSpace" variant: tap_action="backspace" without any hold modifier
; (the v1 *SC03A handler is a plain BackSpace, no Ctrl-on-hold dance).
_CapsLockIsPlainBackspace() {
    return TapHoldTapAction(TapHold, "caps_lock") == "backspace"
        and TapHoldHoldModifier(TapHold, "caps_lock") == ""
}

; Returns true when the CapsLock tap-hold has Ctrl on hold — i.e. one of
; the v1 *Ctrl variants (BackSpaceCtrl, CapsLockCtrl, EnterCtrl, …) is
; active. Drives the *SC03A handler that pre-arms LCtrl Down on press.
CapsLockRemappedCondition() {
    return TapHoldHoldModifier(TapHold, "caps_lock") == "ctrl"
}

#HotIf CapsLockRemappedCondition() and not LayerEnabled
*SC03A:: {
    CtrlActivated := False
    if (GetKeyState("SC01D", "P")) {
        CtrlActivated := True
    }

    if (GetKeyState("SC038", "P")) {
        ; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock remapped
        LAltCapsLockShortcut()
        return
    }

    SendEvent("{LCtrl Down}")
    tap := KeyWait("CapsLock", "T" . TapHoldDuration(TapHold, "caps_lock"))
    if (tap and A_PriorKey == "LControl") {
        SendEvent("{LCtrl Up}")
        CapsLockShortcut(CtrlActivated)
    }
    SendEvent("{LCtrl Up}")
}
#HotIf

CapsLockShortcut(CtrlActivated) {
    if CtrlActivated {
        SendEvent("{LCtrl Down}")
    }

    ; Dispatch on the v2 tap_action — only reachable when hold_modifier
    ; is "ctrl" (otherwise CapsLockRemappedCondition gates us out before
    ; we get here).
    switch TapHoldTapAction(TapHold, "caps_lock") {
        case "backspace":
            SendEvent("{Blind}{BackSpace}")
        case "caps_lock":
            ToggleCapsLock()
        case "caps_word":
            ToggleCapsWord()
        case "ctrl_backspace":
            SendInput("^{BackSpace}")
        case "ctrl_delete":
            SendInput("^{Delete}")
        case "delete":
            SendEvent("{Blind}{Delete}")
        case "enter":
            SendEvent("{Blind}{Enter}")
            DisableCapsWord()
        case "escape":
            SendEvent("{Blind}{Escape}")
        case "one_shot_shift":
            OneShotShift()
        case "tab":
            SendEvent("{Blind}{Tab}")
    }

    SendEvent("{LCtrl Up}")
}

; ==========================================
; ==========================================
; ======= 3/ LSHIFT AND LCTRL =======
; ==========================================
; ==========================================

#HotIf TapHoldTapAction(TapHold, "left_shift") == "copy" and not LayerEnabled
; Tap-hold on "LShift" : Ctrl + C on tap, Shift on hold
~$SC02A::
{
    TimeBefore := A_TickCount
    KeyWait("SC02A")
    TimeAfter := A_TickCount
    tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_shift") * 1000)
    if (
        tap
        and (TimeAfter - TimeBefore) >= TapMinDurationMs()
        and A_PriorKey == "LShift"
    ) { ; A_PriorKey is to be able to fire shortcuts very quickly, under the tap time
        SendInput("{LCtrl Down}c{LCtrl Up}")
    }
}
#HotIf

#HotIf TapHoldTapAction(TapHold, "left_ctrl") == "paste" and not LayerEnabled
; This bug seems resolved now:
; « ~ must not be used here, otherwise [AltGr] [AltGr] … [AltGr], which is supposed to give Tab multiple times, will suddenly block and keep LCtrl activated »

; Tap-hold on "LControl" : Ctrl + V on tap, Ctrl on hold
~$SC01D::
{
    UpdateLastSentCharacter("LControl")
    TimeBefore := A_TickCount
    KeyWait("SC01D")
    TimeAfter := A_TickCount
    tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_ctrl") * 1000)
    if (
        tap
        and (TimeAfter - TimeBefore) >= TapMinDurationMs()
        and A_PriorKey == "LControl"
        and not GetKeyState("SC03A", "P") ; "CapsLock"
        and not GetKeyState("SC038", "P") ; "LAlt"
    ) {
        SendInput("{LCtrl Down}v{LCtrl Up}")
    }
}
#HotIf

; ==============================
; ==============================
; ======= 4/ LALT =======
; ==============================
; ==============================

; LAlt v2 variants share two tap-actions and a hold-layer slot:
;   OneShotShift  -> tap=one_shot_shift, hold_mod=alt
;   TabLayer      -> tap=tab,            hold_layer=nav
;   AltTabMonitor -> tap=alt_tab_monitor, hold_mod=alt
;   BackSpace     -> tap=backspace       (key-repeat, no hold)
;   BackSpaceLayer-> tap=backspace,      hold_layer=nav
; The two backspace variants are distinguished by hold_layer presence.
_LAltIsPlainBackspace() {
    return TapHoldTapAction(TapHold, "left_alt") == "backspace"
        and TapHoldHoldLayer(TapHold, "left_alt") == ""
}
_LAltIsBackspaceLayer() {
    return TapHoldTapAction(TapHold, "left_alt") == "backspace"
        and TapHoldHoldLayer(TapHold, "left_alt") == "nav"
}

#HotIf TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and not LayerEnabled
; Tap-hold on "LAlt" : OneShotShift on tap, Shift on hold
SC038:: {
    if (
        GetKeyState("SC11D", "P")
        or GetKeyState("SC03A", "P")
        or GetKeyState("LShift", "P")
        or GetKeyState("LCtrl", "P")
    ) {
        ; Solves a problem where shorcuts consisting of another key (pressed first) + SC038 (pressed second) triggers the shortcut, but also OneShotShift()
        return
    }

    SendEvent("{LAlt Up}")
    OneShotShift()
    SendInput("{LShift Down}")
    KeyWait("SC038")
    SendInput("{LShift Up}")
}
#HotIf

#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab" and not LayerEnabled
; Tap-hold on "LAlt" : Tab on tap, Layer on hold
SC038::
{
    UpdateLastSentCharacter("LAlt")

    ActivateLayer()
    KeyWait("SC038")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
    tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)
    if tap {
        SendEvent("{Tab}")
    }
}

SC02A & SC038:: SendInput("+{Tab}") ; On "LShift"
if TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" {
    SC11D & SC038:: {
        OneShotShiftFix()
        SendInput("+{Tab}")
    }
}
#SC038:: SendEvent("#{Tab}") ; Doesn't fire when SendInput is used
!SC038:: SendInput("!{Tab}")
#HotIf

#HotIf TapHoldTapAction(TapHold, "left_alt") == "alt_tab_monitor" and not LayerEnabled
; Tap-hold on "LAlt" : AltTabMonitor on tap, Alt on hold
SC038::
{
    Send("{LAlt Down}")
    tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
    if tap {
        Send("{LAlt Up}")
        AltTabMonitor()
    } else {
        KeyWait("SC038")
        Send("{LAlt Up}")
    }
}
#HotIf

#HotIf _LAltIsPlainBackspace() and not LayerEnabled
; "LAlt" becomes BackSpace, and Delete on Shift
*SC038::
{
    BackSpaceActionWithModifiers := BackSpaceLogic()
    if not BackSpaceActionWithModifiers {
        ; If no modifier was pressed
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
        while GetKeyState("SC038", "P") {
            SendEvent("{BackSpace}")
            Sleep(KEY_REPEAT_INTERVAL_MS)
        }
    }
}
#HotIf

#HotIf _LAltIsBackspaceLayer() and not LayerEnabled
; Tap-hold on "LAlt" : BackSpace on tap, Layer on hold
*SC038::
{
    UpdateLastSentCharacter("LAlt")

    ActivateLayer()
    KeyWait("SC038")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
    tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)

    if (
        tap
        and A_PriorKey == "LAlt" ; Prevents triggering BackSpace when the layer is quickly used and then released
        and not GetKeyState("SC03A", "P") ; Fix a sent BackSpace when triggering quickly "LAlt" + "CapsLock"
    ) {
        BackSpaceActionWithModifiers := BackSpaceLogic()
        if not BackSpaceActionWithModifiers {
            ; If no modifier was pressed
            SendEvent("{BackSpace}")
        }
    }
}
#HotIf

BackSpaceLogic() {
    RCtrlIsOneShotShift := TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift"

    if (
        GetKeyState("SC01D", "P")
        and GetKeyState("Shift", "P")
    ) {
        ; "LCtrl" and Shift
        SendInput("^{Delete}")
        return True
    } else if (
        GetKeyState("SC11D", "P")
        and not RCtrlIsOneShotShift
        and GetKeyState("Shift", "P")
    ) {
        ; "RCtrl" when it stays RCtrl and Shift
        SendInput("^{Delete}")
        return True
    } else if (
        GetKeyState("SC01D", "P")
        and RCtrlIsOneShotShift
        and GetKeyState("SC11D", "P")
    ) {
        ; "LCtrl" and Shift on "RCtrl"
        OneShotShiftFix()
        SendInput("^{Right}^{BackSpace}") ; = ^Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        return True
    } else if (
        RCtrlIsOneShotShift
        and GetKeyState("SC11D", "P")
    ) {
        ; Shift on "RCtrl"
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        return True
    } else if GetKeyState("Shift", "P") {
        ; Shift
        SendInput("{Delete}")
        return True
    } else if GetKeyState("SC01D", "P") {
        ; "LCtrl"
        SendInput("^{BackSpace}")
        return True
    } else if (
        not RCtrlIsOneShotShift
        and GetKeyState("SC11D", "P")
    ) {
        ; "RCtrl" when it stays RCtrl
        SendInput("^{BackSpace}")
        return True
    }
    return False
}

; ==============================
; ==============================
; ======= 5/ SPACE =======
; ==============================
; ==============================

; Shared tap logic for all Space tap-hold variants. Reads the next character
; via InputHook; on tap it forwards the Space + next character (avoiding a
; double-space when the next key is also Space). On timeout it delegates to
; HoldFn, which is responsible for activating the held modifier and blocking
; until SC039 is released. Returns true when the timeout (hold) branch fired.
SpaceTapHold(HoldFn) {
    TimeoutSec := TapHoldDuration(TapHold, "space")
    ih := InputHook("L1 T" . TimeoutSec)
    ih.Start()
    ih.Wait()
    if ih.EndReason != "Timeout" {
        ; Tap path: send the Space that was intercepted, then the captured character
        ; (omit it when it is itself a Space to avoid a double-space).
        Text := (ih.Input == " ") ? "" : ih.Input
        SendEvent("{Space}" Text)
        UpdateLastSentCharacter(" ")
        return False
    }
    HoldFn()
    return True
}

; Each #HotIf block maps exactly one SC039 condition to one hold action.
; The SC039 Up companion sends a trailing Space when the key was released
; before the InputHook timeout elapsed and no tap was already sent.

_SpaceHoldCtrl() {
    SendEvent("{LCtrl Down}")
    KeyWait("SC039")
    SendEvent("{LCtrl Up}")
}
_SpaceHoldLayer() {
    ActivateLayer()
    KeyWait("SC039")
    DisableLayer()
}
_SpaceHoldShift() {
    SendEvent("{LShift Down}")
    KeyWait("SC039")
    SendEvent("{LShift Up}")
}

#HotIf TapHoldHoldModifier(TapHold, "space") == "ctrl" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Ctrl on hold
SC039:: SpaceTapHold(_SpaceHoldCtrl)
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled
        and A_TimeSinceThisHotkey <= TapHoldDuration(TapHold, "space")
    ) {
        SendEvent("{Space}")
    }
}
#HotIf

#HotIf TapHoldHoldLayer(TapHold, "space") == "nav" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039:: SpaceTapHold(_SpaceHoldLayer)
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled
        and A_TimeSinceThisHotkey <= TapHoldDuration(TapHold, "space")
    ) {
        SendEvent("{Space}")
        UpdateLastSentCharacter(" ")
    }
}
#HotIf

#HotIf TapHoldHoldModifier(TapHold, "space") == "shift" and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Shift on hold
SC039:: SpaceTapHold(_SpaceHoldShift)
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled
        and A_TimeSinceThisHotkey <= TapHoldDuration(TapHold, "space")
    ) {
        SendEvent("{Space}")
    }
}
#HotIf

; ==============================
; ==============================
; ======= 6/ ALTGR =======
; ==============================
; ==============================

; The standalone ``RAlt::`` hotkey below consumes every AltGr/Kana press while
; it is active, breaking native AltGr typing in any context where the user
; expects their Windows layout to handle the key. We therefore gate it on
; ``not IsOnboardingActive()`` so the wizard's Edit fields (and anything else
; the user types while the first-run wizard is up) receive AltGr characters
; from the OS instead of the tap-hold consuming them.
#HotIf not LayerEnabled and not IsOnboardingActive() and TapHoldIsConfigured(TapHold, "alt_gr")
; Tap-hold on "AltGr"
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . TapHoldDuration(TapHold, "alt_gr"))
    if (tap and (A_PriorKey == "RAlt" or A_PriorKey == "^")) {
        DisableCapsWord()
        AltGrTapHoldDispatchV2()
    }
}

SC01D & ~SC138 Up::
RAlt Up:: {
    UpdateLastSentCharacter("")
}
#HotIf

; Dispatch the single v2 tap_action configured for "alt_gr". Each AltGr
; variant carries the still-held AltGr modifier on its Send (``{Blind}``
; prefix) and pairs the keystroke with an explicit UpdateLastSentCharacter
; so the deadkey / hotstring chain downstream sees the correct previous
; character marker.
AltGrTapHoldDispatchV2() {
    switch TapHoldTapAction(TapHold, "alt_gr") {
        case "backspace":
            SendEvent("{Blind}{BackSpace}")
            UpdateLastSentCharacter("BackSpace")
        case "caps_lock":
            ToggleCapsLock()
        case "caps_word":
            ToggleCapsWord()
        case "ctrl_backspace":
            SendEvent("{Blind}^{BackSpace}")
            UpdateLastSentCharacter("")
        case "ctrl_delete":
            SendEvent("{Blind}^{Delete}")
            UpdateLastSentCharacter("")
        case "delete":
            SendEvent("{Blind}{Delete}")
            UpdateLastSentCharacter("Delete")
        case "enter":
            SendEvent("{Blind}{Enter}")
            UpdateLastSentCharacter("Enter")
        case "escape":
            SendEvent("{Escape}")
        case "one_shot_shift":
            OneShotShift()
        case "tab":
            SendEvent("{Blind}{Tab}")
            UpdateLastSentCharacter("Tab")
    }
}

; ==============================
; ==============================
; ======= 7/ RCTRL =======
; ==============================
; ==============================

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "backspace" and not LayerEnabled
; RCtrl becomes BackSpace, and Delete on Shift
SC11D::
{
    if GetKeyState("LShift", "P") {
        SendInput("{Delete}")
    } else if TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and GetKeyState("SC038", "P") {
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
    } else {
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
        while GetKeyState("SC11D", "P") {
            SendEvent("{BackSpace}")
            Sleep(KEY_REPEAT_INTERVAL_MS)
        }
    }
}
#HotIf

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "tab" and not LayerEnabled
; Tap-hold on "RCtrl" : Tab on tap, Ctrl on hold
~SC11D:: {
    tap := KeyWait("RControl", "T" . TapHoldDuration(TapHold, "right_ctrl"))
    if (tap and A_PriorKey == "RControl") {
        SendEvent("{RCtrl Up}")
        SendEvent("{Tab}") ; To be able to trigger hotstrings with a Tab ending character
    }
}

+SC11D:: SendInput("+{Tab}")
^SC11D:: SendInput("^{Tab}")
^+SC11D:: SendInput("^+{Tab}")
#SC11D:: SendEvent("#{Tab}") ; SendInput doesn't work in that case
#HotIf

#HotIf TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" and not LayerEnabled
; Tap-hold on "RCtrl" : OneShotShift on tap, Shift on hold
SC11D:: {
    OneShotShift()
    SendEvent("{LShift Down}")
    KeyWait("SC11D")
    SendEvent("{LShift Up}")
}
#HotIf

; ==============================
; ==============================
; ======= 8/ TAB =======
; ==============================
; ==============================

#HotIf TapHoldTapAction(TapHold, "tab") == "alt_tab_monitor" and not LayerEnabled
; Tap-hold on "Tab": Alt + Tab on tap, Alt on hold
SC00F::LAlt
SC00F::
{
    SendInput("{LAlt Down}")
    tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
    if tap {
        if TapHoldTapAction(TapHold, "left_alt") == "tab" and GetKeyState("SC038", "P") {
            SendInput("!{Tab}")
        } else {
            SendInput("{LAlt Up}")
            AltTabMonitor()
        }

    }
}
SC00F Up:: SendInput("{LAlt Up}")

; Pass-through for Tab with modifiers so Ctrl+Tab, Shift+Tab etc. still work
; despite the tap-hold intercepting the bare key
^SC00F:: SendEvent("^{Tab}")
^+SC00F:: SendEvent("^+{Tab}")
+SC00F:: SendInput("+{Tab}")
#SC00F:: SendEvent("#{Tab}")
#HotIf

AltTabMonitor() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&MousePosX, &MousePosY)
    MonitorNum := GetMonitorFromPoint(MousePosX, MousePosY)
    if MonitorNum == 0 {
        return ; No monitor found
    }

    CurrentWindowId := WinExist("A")
    AppWindowsOnMonitorFiltered := []

    for WindowId in WinGetList() {
        ; Skip the currently active window
        if WindowId == CurrentWindowId {
            continue
        }

        ; Get window position and size
        WinGetPos(&x, &y, &w, &h, WindowId)

        ; Filter out windows that are too small to be usable
        if (w < 100 || h < 100) {
            continue
        }

        ; Determine which monitor contains the center of the window
        CenterX := x + w // 2
        CenterY := y + h // 2
        if GetMonitorFromPoint(CenterX, CenterY) != MonitorNum {
            continue ; Window is not on the target monitor
        }

        ; Skip windows with no title — often tooltips, overlays, or hidden UI elements, and when dragging files, and windows when a file operation is happening
        if WinGetTitle(WindowId) == "" or WinGetTitle(WindowId) == "Drag" or WinGetClass(WindowId) ==
        "OperationStatusWindow" {
            continue
        }

        ; Exclude known system window classes:
        ; - Shell_TrayWnd: Windows taskbar
        ; - Progman: desktop background
        ; - WorkerW: hidden background windows
        if ["Shell_TrayWnd", "Progman", "WorkerW"].Has(WinGetClass(WindowId)) {
            continue
        }

        ; WindowId passed all filters — add to list
        AppWindowsOnMonitorFiltered.Push(WindowId)
    }

    ; Activate the first relevant window found
    if AppWindowsOnMonitorFiltered.Length > 0 {
        WinActivate(AppWindowsOnMonitorFiltered[1])
    }
}

GetMonitorFromPoint(X, Y) {
    MonitorCount := MonitorGetCount()

    loop MonitorCount {
        ; Get the monitor's rectangle bounding coordinates, for monitor number A_Index
        MonitorGet(A_Index, &MonitorLeft, &MonitorTop, &MonitorRight, &MonitorBottom)

        ; Check if the mouse is inside the monitor
        if (X >= MonitorLeft && X < MonitorRight && Y >= MonitorTop && Y <
            MonitorBottom) {
            return A_Index
        }
    }

    return 0 ; No monitor found
}

; ========================================
; ========================================
; ======= 9/ ONE-SHOT SHIFT =======
; ========================================
; ========================================

OneShotShift() {
    global OneShotShiftEnabled := True
    ihvText := InputHook("L1 T" . ONE_SHOT_SHIFT_TIMEOUT_SEC . " E", "=%$.', " . ScriptInformation["MagicKey"])
    ihvText.KeyOpt("{BackSpace}{Enter}{Delete}", "E") ; End keys to not swallow
    ihvText.Start()
    ihvText.Wait()
    SpecialCharacter := ""

    if (ihvText.EndKey == "=") {
        SpecialCharacter := "º"
    } else if (ihvText.EndKey == "%") {
        SpecialCharacter := " %"
    } else if (ihvText.EndKey == "$") {
        SpecialCharacter := " €"
    } else if (ihvText.EndKey == ".") {
        SpecialCharacter := " :"
    } else if (ihvText.EndKey == ScriptInformation["MagicKey"]) {
        SpecialCharacter := "J" ; OneShotShift + ★ gives J directly
    } else if (ihvText.EndKey == ",") {
        SpecialCharacter := " " Chr(0x3B) ; Chr avoids AHK parser misreading ";" as comment
    } else if (ihvText.EndKey == "'") {
        SpecialCharacter := " ?"
    } else if (ihvText.EndKey == " ") {
        SpecialCharacter := "-"
    }

    if (ihvText.EndReason == "Timeout") {
        return
    } else if SpecialCharacter != "" {
        if OneShotShiftEnabled {
            ActivateHotstrings()
            SendNewResult(SpecialCharacter)
        } else {
            SendNewResult(ihvText.EndKey)
        }
    } else {
        if OneShotShiftEnabled {
            TitleCaseText := Format("{:T}", ihvText.Input)
            SendNewResult(TitleCaseText)
        } else {
            SendNewResult(ihvText.Input)
        }
    }
}

OneShotShiftFix() {
    ; This function and global variable solves a problem when we use the OneShotShift key as a modifier.
    ; In that case, we first press this key, thus firing the OneShotShift() function that will uppercase the next character in the next 2 seconds.
    ; The only way to disable it after it has fired is to modify this global variable by setting global OneShotShiftEnabled := False.
    ; That way, calling this function OneShotShiftFix() won't uppercase the next character in our shortcuts involving the OneShotShift key.
    global OneShotShiftEnabled := False
}

ToggleCapsLock() {
    global CapsWordEnabled := False
    if GetKeyState("CapsLock", "T") {
        SetCapsLockState("Off")
    } else {
        SetCapsLockState("On")
    }
}

; ====================================
; ====================================
; ======= 10/ NAVIGATION LAYER =======
; ====================================
; ====================================

ActivateLayer() {
    global LayerEnabled := True
    ResetNumberOfRepetitions()
    UpdateCapsLockLED()
}
DisableLayer() {
    global LayerEnabled := False
    A_MaxHotkeysPerInterval := 150 ; Restore old value
    UpdateCapsLockLED()
}
ResetNumberOfRepetitions() {
    SetNumberOfRepetitions(1)
}
SetNumberOfRepetitions(NewNumber) {
    global NumberOfRepetitions := NewNumber
}
ActionLayer(action) {
    SendInput(action)
    ResetNumberOfRepetitions()
}

; Fix to get the CapsWord shortcut working when pressing "LAlt" activates the layer
#HotIf (LayerEnabled
    and TapHoldHoldLayer(TapHold, "left_alt") == "nav"
    and (
        Features["shortcuts"]["lalt_caps_lock"]["backspace"]
        or Features["shortcuts"]["lalt_caps_lock"]["caps_lock"]
        or Features["shortcuts"]["lalt_caps_lock"]["caps_word"]
        or Features["shortcuts"]["lalt_caps_lock"]["ctrl_backspace"]
        or Features["shortcuts"]["lalt_caps_lock"]["ctrl_delete"]
        or Features["shortcuts"]["lalt_caps_lock"]["delete"]
        or Features["shortcuts"]["lalt_caps_lock"]["one_shot_shift"]
    )
)
; Overrides the "BackSpace" shortcut on the layer
SC03A:: {
    DisableLayer() LAltCapsLockShortcut()
}
#HotIf

; Fix when LAlt triggers the layer
#HotIf (
    _LAltIsBackspaceLayer()
    and LayerEnabled
)
SC038:: SendInput("{LAlt Up}") ; Necessary to do this, otherwise multicursor triger in VSCode when scrolling in the layer and then leaving it
#HotIf

; Fix when Space triggers the layer
#HotIf (
    TapHoldHoldLayer(TapHold, "space") == "nav"
    and LayerEnabled
)
SC039:: return ; Necessary to do this, otherwise Space keeps being sent while it is held to get the layer
#HotIf

#HotIf LayerEnabled
; The base layer will become this one when the navigation layer variable is set to True

*WheelUp:: {
    A_MaxHotkeysPerInterval := 1000 ; Reduce messages saying too many hotkeys pressed in the interval
    ActionLayer("{Volume_Up " . NumberOfRepetitions . "}") ; Turn on the volume by scrolling up
}
*WheelDown:: {
    A_MaxHotkeysPerInterval := 1000 ; Reduce messages saying too many hotkeys pressed in the interval
    ActionLayer("{Volume_Down " . NumberOfRepetitions . "}") ; Turn down the volume by scrolling down
}

SC01D & ~SC138:: ; RAlt
RAlt:: ; RAlt on QWERTY
{
    ActionLayer("{Escape " . NumberOfRepetitions . "}")
}

; === Number row ===
SC002:: SetNumberOfRepetitions(1) ; On key 1
SC003:: SetNumberOfRepetitions(2) ; On key 2
SC004:: SetNumberOfRepetitions(3) ; On key 3
SC005:: SetNumberOfRepetitions(4) ; On key 4
SC006:: SetNumberOfRepetitions(5) ; On key 5
SC007:: SetNumberOfRepetitions(6) ; On key 6
SC008:: SetNumberOfRepetitions(7) ; On key 7
SC009:: SetNumberOfRepetitions(8) ; On key 8
SC00A:: SetNumberOfRepetitions(9) ; On key 9
SC00B:: SetNumberOfRepetitions(10) ; On key 0

; ======= Left hand =======

; === Top row ===
SC010:: ActionLayer("^+{Home}") ; Select to the beginning of the document
SC011:: ActionLayer("^{Home}") ; Go to the beginning of the document
SC012:: ActionLayer("^{End}") ; Go to the end of the document
SC013:: ActionLayer("^+{End}") ; Select to the end of the document
SC014:: ActionLayer("{F2}")

; === Middle row ===
; ``Format("{X {1}}", N)`` collapsed into direct concatenation — the call
; ran on every navigation keystroke and ``Format`` parses its template each
; time. Concatenation produces the same string with zero parsing overhead.
SC03A:: ActionLayer("{BackSpace " . NumberOfRepetitions . "}") ; "CapsLock" becomes BackSpace
SC01E:: ActionLayer("^+{Up " . NumberOfRepetitions . "}")
SC01F:: ActionLayer("{Up " . NumberOfRepetitions . "}") ; ⇧
SC020:: ActionLayer("{Down " . NumberOfRepetitions . "}") ; ⇩
SC021:: ActionLayer("^+{Down " . NumberOfRepetitions . "}")
SC022:: ActionLayer("{F12}")

; === Bottom row ===
SC056:: ActionLayer("!+{Up " . NumberOfRepetitions . "}")  ; Duplicate the line up
SC02C:: ActionLayer("!{Up " . NumberOfRepetitions . "}") ; Move the line up
SC02D:: ActionLayer("!{Down " . NumberOfRepetitions . "}") ; Move the line down
SC02E:: ActionLayer("!+{Down " . NumberOfRepetitions . "}") ; Duplicate the line down
SC02F:: ActionLayer("{End}{Enter " . NumberOfRepetitions . "}") ; Start a new line below the cursor
; SC030:: ; On K

; ======= Right hand =======

; === Top row ===
SC015:: ActionLayer("+{Home}") ; Select everything to the beginning of the line
SC016:: ActionLayer("^+{Left " . NumberOfRepetitions . "}") ; Select the previous word
SC017:: ActionLayer("+{Left " . NumberOfRepetitions . "}") ; Select the previous character
SC018:: ActionLayer("+{Right " . NumberOfRepetitions . "}") ; Select the next character
SC019:: ActionLayer("^+{Right " . NumberOfRepetitions . "}") ; Select the next word
SC01A:: ActionLayer("+{End}") ; Select everything to the end of the line

; === Middle row ===
SC023:: ActionLayer("#+{Left}") ; Move the window to the left screen
SC024:: ActionLayer("^{Left " . NumberOfRepetitions . "}") ; Move to the previous word
SC025:: ActionLayer("{Left " . NumberOfRepetitions . "}") ; ⇦
SC026:: ActionLayer("{Right " . NumberOfRepetitions . "}") ; ⇨
SC027:: ActionLayer("^{Right " . NumberOfRepetitions . "}") ; Move to the next word
SC028:: ActionLayer("#+{Right}") ; Move the window to the right screen

; === Bottom row ===
SC031:: WinMaximize("A") ; Make the window fullscreen
SC032:: ActionLayer("{Home}") ; Go to the beginning of the line
SC033:: ActionLayer("#{Left}") ; Move the window to the left of the current screen
SC034:: ActionLayer("#{Right}") ; Move the window to the right of the current screen
SC035:: ActionLayer("{End}") ; Go to the end of the line
#HotIf
