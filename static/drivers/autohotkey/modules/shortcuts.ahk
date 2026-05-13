; static/drivers/autohotkey/modules/shortcuts.ahk

; ==============================================================================
; MODULE: Shortcuts
; DESCRIPTION:
; Defines all keyboard shortcuts (Win, Alt, Ctrl, AltGr combos) built on top
; of the Ergopti layout. Includes CapsWord helpers and the AddShortcut/
; RetrieveScancode utilities that resolve layout-aware scan codes at runtime.
; ==============================================================================

; ==============================
; ==============================
; ======= 1/ UTILITIES =======
; ==============================
; ==============================

; This function makes it possible to create a shortcut that works
; no matter the keyboard layout or the potential emulation of the Ergopti layout on top of it.
; If the keyboard layout changes, the script must be reloaded.
AddShortcut(Modifier, Letter, Callback) {
    Hotkey(Modifier . RetrieveScancode(Letter), Callback)
}

RetrieveScancode(Letter) {
    if RemappedList.Has(Letter) {
        return RemappedList[Letter]
    }
    return Format("sc{:x}", GetKeySC(Letter))
}

; ===============================
; ===============================
; ======= 2/ BASE MODIFIER =======
; ===============================
; ===============================

#HotIf (
    ; We need to handle the shortcut differently when LAlt has been remapped
    not Features["TapHolds"]["LAlt"]["BackSpace"].Enabled ; No need to add the shortcut here, as it is impossible to have this shortcut with a BackSpace key that fires immediately
    and not Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled ; Here we directly change the result on the layer
    and not Features["TapHolds"]["LAlt"]["TabLayer"].Enabled ; Here we directly change the result on the layer
    and not Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled ; Necessary to be able to use OneShotShift on LAlt
)
SC038 & SC03A:: LAltCapsLockShortcut()
#HotIf

LAltCapsLockShortcut() {
    ; All ten possible actions are simple, no Shift inversion or modifier
    ; bracketing needed — delegate to the shared dispatcher.
    RunFirstSimpleAction(Features["Shortcuts"]["LAltCapsLock"])
}

; =================================
; =================================
; ======= 3/ CTRL SHORTCUTS =======
; =================================
; =================================

if Features["Shortcuts"]["Save"].Enabled {
    AddShortcut("^", "j", (*) => SendFinalResult("^s"))
}
if Features["Shortcuts"]["CtrlJ"].Enabled {
    AddShortcut("^", "s", (*) => SendFinalResult("^j"))
}

if Features["Shortcuts"]["MicrosoftBold"].Enabled {
    ; Makes it possible to use the standard shortcuts instead of their translation in Microsoft apps
    AddShortcut(
        "^", "b",
        (*) => MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")
    )
}

if Features["Shortcuts"]["PasteWithoutFormatting"].Enabled {
    ; Ctrl + Shift + V — paste plain text everywhere except Excel, which keeps
    ; its native paste-special behaviour (re-assigning the standard combo there
    ; would break the user's expected workflow).
    AddShortcut("^+", "v", PasteWithoutFormatting)

    PasteWithoutFormatting(*) {
        if not WinActive("ahk_exe EXCEL.EXE") {
            A_Clipboard := A_Clipboard
            SendFinalResult("^v")
        } else {
            SendFinalResult("^+v")
        }
    }
}

; ==================================
; ==================================
; ======= 4/ ALTGR SHORTCUTS =======
; ==================================
; ==================================

; Pre-computed at boot — evaluated once instead of 10 OR comparisons per key press.
global _ALTGR_LALT_ENABLED := HasAnyEnabled(Features["Shortcuts"]["AltGrLAlt"])

; Wrapper required: #HotIf re-evaluates its expression every time the hotkey
; is tested. If the global is read before auto-execute has assigned it, AHK
; raises "global variable has not been assigned a value".
IsAltGrLAltEnabled() {
    global _ALTGR_LALT_ENABLED
    return IsSet(_ALTGR_LALT_ENABLED) ? _ALTGR_LALT_ENABLED : False
}

; Gate on a real AltGr/Kana press so a ghost SC138 (injected by an OS driver
; for AltGr-mapped keys like Bépo's `'`) cannot trigger this shortcut.
#HotIf IsAltGrLAltEnabled() and IsRealAltGrPress()
SC138 & SC038:: AltGrLAltShortcut()
#HotIf

AltGrLAltShortcut() {
    if Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = Ctrl + BackSpace (Can't use Ctrl because of AltGr = Ctrl + Alt)
            SendInput("^{BackSpace}")
        } else {
            SendInput("{BackSpace}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["CapsLock"].Enabled {
        ToggleCapsLock()
    } else if Features["Shortcuts"]["AltGrLAlt"]["CapsWord"].Enabled {
        ToggleCapsWord()
    } else if Features["Shortcuts"]["AltGrLAlt"]["CtrlBackSpace"].Enabled {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = BackSpace (Can't use Ctrl because of AltGr = Ctrl + Alt)
            SendInput("{BackSpace}")
        } else {
            SendInput("^{BackSpace}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["CtrlDelete"].Enabled {
        ; "Shift" + "AltGr" + "LAlt" = Delete (Can't use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            SendInput("{Delete}")
        } else {
            SendInput("^{Delete}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["Delete"].Enabled {
        ; "Shift" + "AltGr" + "LAlt" = Ctrl + Delete (Can't use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            SendInput("^{Delete}")
        } else {
            SendInput("{Delete}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["Enter"].Enabled {
        SendInput("{Enter}")
    } else if Features["Shortcuts"]["AltGrLAlt"]["Escape"].Enabled {
        SendInput("{Escape}")
    } else if Features["Shortcuts"]["AltGrLAlt"]["OneShotShift"].Enabled {
        OneShotShift()
    } else if Features["Shortcuts"]["AltGrLAlt"]["Tab"].Enabled {
        SendInput("{Tab}")
    }
}

global _ALTGR_CAPSLOCK_ENABLED := HasAnyEnabled(Features["Shortcuts"]["AltGrCapsLock"])

; Wrapper required: #HotIf re-evaluates its expression every time the hotkey
; is tested. If the global is read before auto-execute has assigned it, AHK
; raises "global variable has not been assigned a value".
IsAltGrCapsLockEnabled() {
    global _ALTGR_CAPSLOCK_ENABLED
    return IsSet(_ALTGR_CAPSLOCK_ENABLED) ? _ALTGR_CAPSLOCK_ENABLED : False
}

; Gate on real AltGr/Kana press — same rationale as the AltGrLAlt block above.
#HotIf IsAltGrCapsLockEnabled() and IsRealAltGrPress()
SC138 & SC03A:: AltGrCapsLockShortcut()
#HotIf

AltGrCapsLockShortcut() {
    RunFirstSimpleAction(Features["Shortcuts"]["AltGrCapsLock"])
}

; =================================
; =================================
; ======= 5/ WIN SHORTCUTS =======
; =================================
; =================================

#HotIf Features["Shortcuts"]["WinCapsLock"].Enabled
; Win + "CapsLock" to toggle CapsLock
#SC03A:: ToggleCapsLock()
#HotIf

if Features["Shortcuts"]["SelectLine"].Enabled {
    ; Win + A (All)
    AddShortcut("#", "a", SelectLine)

    SelectLine(*) {
        SendFinalResult("{Home}{Shift Down}{End}{Shift Up}")
    }
}

if Features["Shortcuts"]["Screen"].Enabled {
    ; Win + H (ScreensHot)
    AddShortcut("#", "h", (*) => SendFinalResult("#+s"))
}

if Features["Shortcuts"]["GPT"].Enabled {
    ; Win + G (GPT)
    AddShortcut("#", "g", (*) => Run(Features["Shortcuts"]["GPT"].Link))
}

if Features["Shortcuts"]["GetHexValue"].Enabled {
    ; Win + X (heX)
    AddShortcut("#", "x", GetHexValue)

    GetHexValue(*) {
        MouseGetPos(&MouseX, &MouseY)
        HexColor := PixelGetColor(MouseX, MouseY, "RGB")
        HexColor := "#" StrLower(SubStr(HexColor, 3))
        A_Clipboard := HexColor
        Msgbox("La couleur sous le curseur est " HexColor "`nElle a été sauvegardée dans le presse-papiers : " A_Clipboard
        )
    }
}

if Features["Shortcuts"]["TakeNote"].Enabled {
    ; Win + N (Note)
    AddShortcut("#", "n", TakeNote)

    TakeNote(*) {
        ; Determine the file name (with or without date)
        if (Features["Shortcuts"]["TakeNote"].DatedNotes) {
            Date := FormatTime(, "dd_MM_yyyy")
            FileName := "Notes_" Date ".txt"
        } else {
            FileName := "Notes.txt"
        }

        ; Build the full file path
        FilePath := Features["Shortcuts"]["TakeNote"].DestinationFolder "\" FileName

        ; Create the file if it doesn't exist yet
        if not FileExist(FilePath) {
            FileAppend("", FilePath)
        }

        ; Match the window title containing the file name. Save and restore the
        ; global title match mode so other code paths are not impacted.
        PreviousTitleMatchMode := A_TitleMatchMode
        try {
            SetTitleMatchMode(2) ; Partial match
            WinPattern := FileName

            WindowAlreadyOpen := False
            if WinExist(WinPattern) {
                WindowAlreadyOpen := True
                WinActivate(WinPattern)
                WinWaitActive(WinPattern, , 3)
            } else {
                Run('notepad.exe "' . FilePath . '"')
                WinWait(FileName, , 7)
                WinActivate(FileName)
                WinWaitActive(FileName, , 3)
            }

            WinMaximize
            Sleep(100)
            if not WindowAlreadyOpen {
                SendFinalResult("^{End}{Enter}") ; Jump to the end of the file and start a new line
            }
        } finally {
            SetTitleMatchMode(PreviousTitleMatchMode)
        }
    }
}

if Features["Shortcuts"]["Move"].Enabled {
    ; Win + M (Move)
    AddShortcut("#", "m", ToggleActivitySimulation)

    ; Jitter parameters — mirrored from Hammerspoon's AWAKE_JITTER_* constants
    global AWAKE_TICK_MIN_MS   := 1000  ; Minimum interval between ticks
    global AWAKE_TICK_MAX_MS   := 5000  ; Maximum interval between ticks
    global AWAKE_JITTER_PX     := 80    ; Max pixel offset around origin per tick
    global AWAKE_RETURN_MS     := 200   ; Delay before returning cursor to origin

    ; Origin captured at toggle-on; shared between Start and SimulateActivity
    global AwakeOriginX := 0, AwakeOriginY := 0

    ; InputHook used to detect any real keypress while keep-awake is active
    global AwakeInputHook := ""

    StartActivitySimulation(*) {
        global ActivitySimulation, AwakeOriginX, AwakeOriginY, AwakeInputHook
        ActivitySimulation := True
        ; Capture the current cursor position as the jitter origin
        MouseGetPos(&AwakeOriginX, &AwakeOriginY)
        ; Reset the user-move baseline so the first tick never self-cancels
        SimulateActivity(True)
        SetTimer(SimulateActivity, Random(AWAKE_TICK_MIN_MS, AWAKE_TICK_MAX_MS))
        ; Arm mouse-button cancel hooks
        Hotkey("~*$LButton", AwakeCancelOnMouse, "On")
        Hotkey("~*$RButton", AwakeCancelOnMouse, "On")
        Hotkey("~*$MButton", AwakeCancelOnMouse, "On")
        ; Use InputHook to detect any keypress — does not conflict with other hotkeys
        AwakeInputHook := InputHook("L0 I")
        AwakeInputHook.OnChar := AwakeCancelOnKeypress
        AwakeInputHook.OnKeyDown := AwakeCancelOnKeypress
        AwakeInputHook.Start()
        TrayTip(t("keepawake.started"), t("keepawake.title"), "Iconi Mute")
    }

    ToggleActivitySimulation(*) {
        global ActivitySimulation
        if ActivitySimulation {
            StopActivitySimulation()
        } else {
            StartActivitySimulation()
        }
    }

    StopActivitySimulation() {
        global ActivitySimulation, AwakeInputHook
        ActivitySimulation := False
        SetTimer(SimulateActivity, 0)
        SetTimer(AwakeReturnToOrigin, 0)
        ; Disarm mouse-button cancel hooks
        try Hotkey("~*$LButton", AwakeCancelOnMouse, "Off")
        try Hotkey("~*$RButton", AwakeCancelOnMouse, "Off")
        try Hotkey("~*$MButton", AwakeCancelOnMouse, "Off")
        ; Stop the keypress detector
        if IsObject(AwakeInputHook) {
            try AwakeInputHook.Stop()
            AwakeInputHook := ""
        }
        TrayTip(t("keepawake.stopped"), t("keepawake.title"), "Iconi Mute")
    }

    AwakeReturnToOrigin() {
        global ActivitySimulation, AwakeOriginX, AwakeOriginY
        if ActivitySimulation {
            DllCall("SetCursorPos", "int", AwakeOriginX, "int", AwakeOriginY)
        }
    }

    AwakeCancelOnMouse(*) {
        global ActivitySimulation
        if ActivitySimulation {
            SetTimer(StopActivitySimulation, -1)
        }
    }

    AwakeCancelOnKeypress(ih, *) {
        global ActivitySimulation
        if ActivitySimulation {
            SetTimer(StopActivitySimulation, -1)
        }
    }

    SimulateActivity(ResetOnly := False) {
        global ActivitySimulation, AwakeOriginX, AwakeOriginY
        ; LastX/LastY track where the cursor was after the previous synthetic move,
        ; so we can distinguish a real user move from our own jitter.
        static LastX := -1, LastY := -1

        if ResetOnly {
            LastX := -1
            LastY := -1
            return
        }

        if not ActivitySimulation {
            return
        }

        ; If the cursor moved more than AWAKE_JITTER_PX from where we left it,
        ; the user touched the mouse or touchpad — stop without moving again.
        MouseGetPos(&CurX, &CurY)
        if (LastX != -1 and (Abs(CurX - LastX) > AWAKE_JITTER_PX or Abs(CurY - LastY) > AWAKE_JITTER_PX)) {
            StopActivitySimulation()
            return
        }

        ; Move to a random offset around the captured origin (±AWAKE_JITTER_PX)
        OffX := Random(-AWAKE_JITTER_PX, AWAKE_JITTER_PX)
        OffY := Random(-AWAKE_JITTER_PX, AWAKE_JITTER_PX)
        DllCall("SetCursorPos", "int", AwakeOriginX + OffX, "int", AwakeOriginY + OffY)

        ; Signal OS activity without a visible keystroke
        SendFinalResult("{VKFF}")

        ; Record the jitter position so the next tick's user-move check is accurate
        LastX := AwakeOriginX + OffX
        LastY := AwakeOriginY + OffY

        ; Return to origin via a separate one-shot timer — avoids blocking the thread
        ; with Sleep(), which would delay input-cancel detection by up to AWAKE_RETURN_MS
        SetTimer(AwakeReturnToOrigin, -AWAKE_RETURN_MS)

        ; Re-schedule the next tick at a new random interval
        SetTimer(SimulateActivity, Random(AWAKE_TICK_MIN_MS, AWAKE_TICK_MAX_MS))
    }

}

if Features["Shortcuts"]["SurroundWithParentheses"].Enabled {
    AddShortcut("#", "o", (*) => SendFinalResult("{Home}({End}){Home}"))
}

if Features["Shortcuts"]["Search"].Enabled {
    ; Win + S (Search)
    AddShortcut("#", "s", Search)

    Search(*) {
        SelectedText := Trim(GetSelection())
        if WinActive("ahk_exe explorer.exe") {
            GetPath(SelectedText)
        } else {
            SearchPath(SelectedText)
        }
    }

    SearchPath(SelectedText) {
        ; The result of each of those regexes is a boolean

        ; Detects Windows file paths like C:/ or D:\ (supports forward and backward slashes)
        ; Invalid Windows path characters are excluded: <>:"|?*
        FilePath := RegExMatch(
            SelectedText,
            "^[A-Za-z]:[\\/](?:[^<>:`"|?*\r\n]+[\\/]?)*$"
        )

        ; Detects Windows Registry paths (optional Computer\ or Ordinateur\ prefix)
        ; Matches both full names (HKEY_CLASSES_ROOT...) and abbreviations (HKCR, HKCU, etc.)
        RegeditPath := RegExMatch(
            SelectedText,
            "i)^(?:Computer\\|Ordinateur\\)?(?:HKEY_(?:CLASSES_ROOT|CURRENT_USER|LOCAL_MACHINE|USERS|CURRENT_CONFIG)|HK(?:CR|CU|LM|U|CC))(?:\\[^\r\n]*)?$"
        )

        ; Detects full URLs with protocol (http, https, ftp, file, etc.)
        ; Protocol must start with a letter and be 2–9 characters long
        URLPath := RegExMatch(
            SelectedText,
            "i)^[a-z][a-z0-9+\-.]{1,8}://[^\s]+$"
        )

        ; Detects domain names (supports up to 4 subdomain levels, TLD up to 63 chars)
        ; Optionally followed by a path (no spaces allowed)
        WebsitePath := RegExMatch(
            SelectedText,
            "i)^(?:[\w-]{1,63}\.){1,4}[a-z]{2,63}(?:/[^\s]*)?$"
        )

        if FilePath {
            Run(SelectedText, , "Max")
        } else if RegeditPath {
            RegJump(SelectedText)
        } else {
            ; Modify some characters that screw up the URL
            SelectedText := StrReplace(SelectedText, "`r`n", " ")
            SelectedText := StrReplace(SelectedText, "#", "%23")
            SelectedText := StrReplace(SelectedText, "&", "%26")
            SelectedText := StrReplace(SelectedText, "+", "%2b")
            SelectedText := StrReplace(SelectedText, "`"", "%22")

            if URLPath {
                Run(SelectedText)
            } else if (WebsitePath) {
                Run("https://" . SelectedText)
            } else if (SelectedText == "") { ; If nothing was copied
                Run(Features["Shortcuts"]["Search"].SearchEngine)
            } else {
                Run(Features["Shortcuts"]["Search"].SearchEngineURLQuery . SelectedText)
            }
        }
    }

    ; Open Regedit and navigate to RegPath.
    ; RegPath accepts both HKEY_LOCAL_MACHINE and HKLM formats.
    RegJump(RegPath) {
        ; Close existing Registry Editor to ensure target key is selected next time
        if WinExist("Registry Editor") {
            WinKill("Registry Editor")
        }

        ; Normalize leading Computer\ prefix to French "Ordinateur\"
        if SubStr(RegPath, 1, 9) == "Computer\" {
            RegPath := "Ordinateur\" . SubStr(RegPath, 10)
        }

        ; Remove trailing backslash if present
        RegPath := Trim(RegPath, "\")

        ; Extract root key (first component of path)
        RootKey := StrSplit(RegPath, "\")[1]

        ; Convert short root key forms to long forms if necessary
        if !InStr(RootKey, "HKEY_") {
            KeyMap := Map(
                "HKCR", "HKEY_CLASSES_ROOT",
                "HKCU", "HKEY_CURRENT_USER",
                "HKLM", "HKEY_LOCAL_MACHINE",
                "HKU", "HKEY_USERS",
                "HKCC", "HKEY_CURRENT_CONFIG"
            )
            if KeyMap.Has(RootKey) {
                RegPath := StrReplace(RegPath, RootKey, KeyMap[RootKey], , , 1)
            }
        }

        ; Set the last selected key in Regedit. When we will run Regedit, it will open directly to the target
        RegWrite(RegPath, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit", "LastKey")
        Run("Regedit.exe")
    }

    GetPath(Path) {
        PathWithBackslash := Path
        PathWithSlash := StrReplace(Path, "\", "/")
        A_Clipboard := PathWithSlash

        SetTimer ChangeButtonNames, 50
        Result := MsgBox(Format(t("dialog.path_copy.msg_with_question"), A_Clipboard),
            t("dialog.path_copy.title"), "YesNo")
        if (Result == "No") {
            A_Clipboard := PathWithBackslash
            Sleep(200)
            MsgBox(Format(t("dialog.path_copy.msg_simple"), A_Clipboard))
        }
    }
    ChangeButtonNames() {
        if not WinExist(t("dialog.path_copy.title"))
            return ; Keep waiting
        SetTimer ChangeButtonNames, 0
        WinActivate()
        ControlSetText(t("dialog.path_copy.btn_quit"), "Button1")
        ControlSetText(t("dialog.path_copy.btn_backslash"), "Button2")
    }
}

if Features["Shortcuts"]["TitleCase"].Enabled {
    ; Win + W (TitleCase)
    AddShortcut("#", "w", ConvertToTitleCase)

    ConvertToTitleCase(*) {
        Text := GetSelection()

        ; Pattern to detect if text is already in title case:
        ; Each word starts with an uppercase letter (including accented),
        ; followed by lowercase letters (including accented) or digits or allowed symbols.
        ; Words are separated by spaces, tabs or returns ([ \t\r\n]).
        TitleCasePattern :=
            "^(?:[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*[ \t\r\n]+)*[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*$"
        ; Pattern to detect if text is all uppercase (including accented), digits, spaces, and allowed symbols
        UpperCasePattern := "^[A-ZÉÈÀÙÂÊÎÔÛÇ0-9''\(\),.\-:;!?\s]+$"

        if RegExMatch(Text, TitleCasePattern) {
            ; Text is Title Case ➜ convert to lowercase
            SendInstant(Format("{:L}", Text))
        } else if RegExMatch(Text, UpperCasePattern) {
            ; Text is UPPERCASE ➜ convert to TitleCase
            SendInstant(Format("{:T}", Text))
        } else {
            ; Otherwise, convert to TitleCase
            SendInstant(Format("{:T}", Text))
        }
    }
}

if Features["Shortcuts"]["Uppercase"].Enabled {
    ; Win + U (Uppercase)
    AddShortcut("#", "u", ConvertToUppercase)

    ConvertToUppercase(*) {
        Text := GetSelection()
        ; Check if the selected text contains at least one lowercase letter
        if RegExMatch(Text, "[a-zà-ÿ]") {
            SendInstant(Format("{:U}", Text)) ; Convert to uppercase
        } else {
            SendInstant(Format("{:L}", Text)) ; Convert to lowercase
        }
    }
}

if Features["Shortcuts"]["TeleportMouse"].Enabled {
    ; Win + T (Téléport)
    AddShortcut("#", "t", TeleportMouse)

    TeleportMouse(*) {
        Monitors := []
        Count := MonitorGetCount()
        loop Count {
            MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
            Monitors.Push({Left: Left, Top: Top, Right: Right, Bottom: Bottom, Index: A_Index})
        }

        if (Count < 2) {
            MsgBox("Aucun autre moniteur détecté.")
            return
        }

        MouseGetPos(&CurX, &CurY)

        ; Find which monitor currently holds the cursor
        CurrentIndex := 1
        for Mon in Monitors {
            if (CurX >= Mon.Left and CurX < Mon.Right and CurY >= Mon.Top and CurY < Mon.Bottom) {
                CurrentIndex := A_Index
                break
            }
        }

        ; Pick the next monitor cyclically
        NextIndex := (Mod(CurrentIndex, Count) + 1)
        Target := Monitors[NextIndex]
        TargetX := Target.Left + (Target.Right - Target.Left) // 2
        TargetY := Target.Top + (Target.Bottom - Target.Top) // 2

        DllCall("SetCursorPos", "int", TargetX, "int", TargetY)
        SpotlightMouseAt(TargetX, TargetY, 3000)
    }
}

if Features["Shortcuts"]["SpotlightMouse"].Enabled {
    ; Win + '
    AddShortcut("#", "'", (*) => (MouseGetPos(&Mx, &My), SpotlightMouseAt(Mx, My, 5000)))
}

#HotIf Features["Shortcuts"]["ScreenInstant"].Enabled
; SC029 (²/$ — key left of 1) — instant screenshot of the active window, saved to Pictures
SC029:: {
    WinGetPos(&WX, &WY, &WW, &WH, "A")
    if (WW = 0 or WH = 0) {
        MsgBox("Aucune fenêtre active.", "Capture d'écran", "OK T3")
        return
    }
    PicsDir   := EnvGet("USERPROFILE") . "\Pictures\screenshots"
    DirCreate(PicsDir)
    Timestamp := FormatTime(, "yyyy_MM_dd_HH") . "h" . FormatTime(, "mm") . "min" . FormatTime(, "ss") . "sec"
    FilePath  := PicsDir . "\screenshot_" . Timestamp . ".png"

    ; Write a temp PS1 script to avoid all inline quoting issues
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
#HotIf

; Draws a filled yellow circle around (X, Y) and a red × on every other monitor,
; matching the Hammerspoon spotlight visual exactly.
; Dismissed after DurationMs ms or as soon as the mouse moves more than 5 px.
SpotlightMouseAt(X, Y, DurationMs) {
    static RING_RADIUS    := 60     ; Matches Hammerspoon SPOTLIGHT_RADIUS_PX
    static RING_STROKE    := 6      ; Matches SPOTLIGHT_STROKE_PX
    static FILL_ALPHA     := 102    ; 0.40 × 255 — matches SPOTLIGHT_FILL_ALPHA
    static STROKE_ALPHA   := 230    ; 0.90 × 255 — matches OVERLAY_STROKE_ALPHA
    static PAD            := 12     ; Matches SPOTLIGHT_PADDING_PX
    static CROSS_HALF     := 60     ; Matches CROSS_ARM_HALF_PX
    static CROSS_WIDTH    := 14     ; Matches CROSS_ARM_WIDTH_PX
    static DISMISS_POLL   := 100

    ; ARGB values (pre-multiplied alpha not needed for UpdateLayeredWindow with AC_SRC_ALPHA)
    static YELLOW_FILL    := 0x66FFDA00   ; alpha=0x66(102), R=255, G=218, B=0
    static YELLOW_STROKE  := 0xE6FFDA00   ; alpha=0xE6(230)
    static RED_FILL       := 0x66E61A0D   ; alpha=0x66, R=230, G=26, B=13
    static RED_STROKE     := 0xE6E61A0D   ; alpha=0xE6

    ; GDI+ startup — shared token for all windows drawn this call
    DllCall("LoadLibrary", "str", "gdiplus")
    si := Buffer(24, 0)
    NumPut("uint", 1, si)
    DllCall("gdiplus\GdiplusStartup", "ptr*", &pToken := 0, "ptr", si, "ptr", 0)

    ; --- Helper: create a layered window, paint via GDI+ callback, return hwnd ---
    CreateOverlayWindow(WinX, WinY, WinW, WinH, DrawCallback) {
        ; WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
        Hwnd := DllCall("CreateWindowEx",
            "uint",  0x8009C,
            "str",   "Static", "str", "",
            "uint",  0x80000000,   ; WS_POPUP
            "int",   WinX, "int", WinY, "int", WinW, "int", WinH,
            "ptr",   0, "ptr", 0, "ptr", 0, "ptr", 0,
            "ptr")
        if not Hwnd
            return 0

        hScreenDC := DllCall("GetDC", "ptr", 0, "ptr")
        hMemDC    := DllCall("CreateCompatibleDC", "ptr", hScreenDC, "ptr")

        ; 32-bpp DIB section — required for per-pixel alpha in UpdateLayeredWindow
        bi := Buffer(40, 0)
        NumPut("int",   40,    bi,  0)   ; biSize
        NumPut("int",   WinW,  bi,  4)   ; biWidth
        NumPut("int",  -WinH,  bi,  8)   ; biHeight (negative = top-down)
        NumPut("short", 1,     bi, 12)   ; biPlanes
        NumPut("short", 32,    bi, 14)   ; biBitCount
        hBitmap := DllCall("CreateDIBSection", "ptr", hMemDC, "ptr", bi, "uint", 0, "ptr*", 0, "ptr", 0, "uint", 0, "ptr")
        DllCall("SelectObject", "ptr", hMemDC, "ptr", hBitmap)

        ; GDI+ Graphics on the memory DC
        DllCall("gdiplus\GdipCreateFromHDC", "ptr", hMemDC, "ptr*", &pGfx := 0)
        DllCall("gdiplus\GdipSetSmoothingMode",    "ptr", pGfx, "int", 4)   ; AntiAlias
        DllCall("gdiplus\GdipSetCompositingMode",  "ptr", pGfx, "int", 0)   ; SourceOver
        DllCall("gdiplus\GdipSetCompositingQuality","ptr", pGfx, "int", 0)  ; Default

        DrawCallback(pGfx, WinW, WinH)

        DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGfx)

        ; Commit the bitmap to the layered window
        ptDst  := Buffer(8, 0)
        NumPut("int", WinX, ptDst, 0), NumPut("int", WinY, ptDst, 4)
        szWin  := Buffer(8, 0)
        NumPut("int", WinW, szWin, 0), NumPut("int", WinH, szWin, 4)
        ptSrc  := Buffer(8, 0)
        blend  := Buffer(4, 0)
        NumPut("uchar", 0,   blend, 0)   ; BlendOp = AC_SRC_OVER
        NumPut("uchar", 0,   blend, 1)   ; BlendFlags
        NumPut("uchar", 255, blend, 2)   ; SourceConstantAlpha (per-pixel drives it)
        NumPut("uchar", 1,   blend, 3)   ; AlphaFormat = AC_SRC_ALPHA

        DllCall("UpdateLayeredWindow",
            "ptr",  Hwnd,
            "ptr",  hScreenDC,
            "ptr",  ptDst,
            "ptr",  szWin,
            "ptr",  hMemDC,
            "ptr",  ptSrc,
            "uint", 0,
            "ptr",  blend,
            "uint", 2)          ; ULW_ALPHA

        DllCall("ShowWindow", "ptr", Hwnd, "int", 4)   ; SW_SHOWNOACTIVATE

        DllCall("DeleteObject", "ptr", hBitmap)
        DllCall("DeleteDC",     "ptr", hMemDC)
        DllCall("ReleaseDC",    "ptr", 0, "ptr", hScreenDC)

        return Hwnd
    }

    ; --- Draw the yellow filled circle on the cursor's screen ---
    Size   := (RING_RADIUS + PAD) * 2
    WinX   := X - RING_RADIUS - PAD
    WinY   := Y - RING_RADIUS - PAD

    CircleDraw(pGfx, W, H) {
        ; Filled ellipse
        DllCall("gdiplus\GdipCreateSolidFill", "uint", YELLOW_FILL, "ptr*", &pBrush := 0)
        DllCall("gdiplus\GdipFillEllipse",
            "ptr", pGfx, "ptr", pBrush,
            "float", PAD, "float", PAD,
            "float", RING_RADIUS * 2, "float", RING_RADIUS * 2)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", pBrush)

        ; Stroke ellipse
        DllCall("gdiplus\GdipCreatePen1", "uint", YELLOW_STROKE, "float", RING_STROKE, "int", 2, "ptr*", &pPen := 0)
        DllCall("gdiplus\GdipDrawEllipse",
            "ptr", pGfx, "ptr", pPen,
            "float", PAD + RING_STROKE / 2, "float", PAD + RING_STROKE / 2,
            "float", RING_RADIUS * 2 - RING_STROKE, "float", RING_RADIUS * 2 - RING_STROKE)
        DllCall("gdiplus\GdipDeletePen", "ptr", pPen)
    }

    CircleHwnd := CreateOverlayWindow(WinX, WinY, Size, Size, CircleDraw)

    ; --- Draw a red × centered on every OTHER monitor ---
    CrossSize := (CROSS_HALF + PAD) * 2
    CrossHwnds := []

    MonCount := MonitorGetCount()
    loop MonCount {
        MonitorGet(A_Index, &ML, &MT, &MR, &MB)
        ; Skip the monitor that holds the cursor
        if (X >= ML and X < MR and Y >= MT and Y < MB)
            continue

        CX := ML + (MR - ML) // 2
        CY := MT + (MB - MT) // 2

        CWinX := CX - CROSS_HALF - PAD
        CWinY := CY - CROSS_HALF - PAD

        CrossDraw(pGfx, W, H) {
            HW := CROSS_WIDTH / 2

            ; Horizontal bar
            DllCall("gdiplus\GdipCreateSolidFill", "uint", RED_FILL, "ptr*", &pBrush := 0)
            DllCall("gdiplus\GdipFillRectangle",
                "ptr", pGfx, "ptr", pBrush,
                "float", PAD, "float", PAD + CROSS_HALF - HW,
                "float", CROSS_HALF * 2, "float", CROSS_WIDTH)
            ; Vertical bar
            DllCall("gdiplus\GdipFillRectangle",
                "ptr", pGfx, "ptr", pBrush,
                "float", PAD + CROSS_HALF - HW, "float", PAD,
                "float", CROSS_WIDTH, "float", CROSS_HALF * 2)
            DllCall("gdiplus\GdipDeleteBrush", "ptr", pBrush)

            ; Strokes
            DllCall("gdiplus\GdipCreatePen1", "uint", RED_STROKE, "float", RING_STROKE, "int", 2, "ptr*", &pPen := 0)
            DllCall("gdiplus\GdipDrawRectangle",
                "ptr", pGfx, "ptr", pPen,
                "float", PAD + RING_STROKE / 2, "float", PAD + CROSS_HALF - HW + RING_STROKE / 2,
                "float", CROSS_HALF * 2 - RING_STROKE, "float", CROSS_WIDTH - RING_STROKE)
            DllCall("gdiplus\GdipDrawRectangle",
                "ptr", pGfx, "ptr", pPen,
                "float", PAD + CROSS_HALF - HW + RING_STROKE / 2, "float", PAD + RING_STROKE / 2,
                "float", CROSS_WIDTH - RING_STROKE, "float", CROSS_HALF * 2 - RING_STROKE)
            DllCall("gdiplus\GdipDeletePen", "ptr", pPen)
        }

        CrossHwnds.Push(CreateOverlayWindow(CWinX, CWinY, CrossSize, CrossSize, CrossDraw))
    }

    ; --- Poll for mouse move or timeout, then destroy all windows ---
    StartX := X, StartY := Y
    Elapsed := 0
    loop {
        Sleep(DISMISS_POLL)
        Elapsed += DISMISS_POLL
        MouseGetPos(&NowX, &NowY)
        if (Elapsed >= DurationMs or Abs(NowX - StartX) > 5 or Abs(NowY - StartY) > 5)
            break
    }

    if CircleHwnd
        DllCall("DestroyWindow", "ptr", CircleHwnd)
    for Hwnd in CrossHwnds
        DllCall("DestroyWindow", "ptr", Hwnd)

    DllCall("gdiplus\GdiplusShutdown", "ptr", pToken)
}

if Features["Shortcuts"]["OpenDownloads"].Enabled {
    ; Win + D (Downloads)
    AddShortcut("#", "d", OpenDownloads)

    OpenDownloads(*) {
        ; Resolve the real Downloads folder via SHGetKnownFolderPath —
        ; locale-independent and respects user-relocated folders. Falls back
        ; to %USERPROFILE%\Downloads if the API call fails.
        DownloadsPath := GetKnownFolderDownloads()
        if (DownloadsPath == "") {
            DownloadsPath := EnvGet("USERPROFILE") "\Downloads"
        }

        ; Look for an existing Explorer window already showing Downloads.
        ; Iterate every visible window of CabinetWClass / ExploreWClass and
        ; compare its location bar URL — reliable across localisations
        ; (avoids matching "Téléchargements" vs "Downloads" titles).
        try {
            for Win in ComObject("Shell.Application").Windows {
                try {
                    LocalPath := DOMPathToFilesystem(Win.LocationURL)
                    if (LocalPath != "" and StrLower(LocalPath) == StrLower(DownloadsPath)) {
                        Hwnd := Win.HWND
                        if WinExist("ahk_id " Hwnd) {
                            WinActivate("ahk_id " Hwnd)
                            WinShow("ahk_id " Hwnd)
                            return
                        }
                    }
                }
            }
        }

        ; No existing window — open a fresh one and force it to the foreground.
        ; We split executable and argument explicitly to avoid Explorer
        ; misparsing a path containing accents (e.g. "Téléchargements")
        ; as a drive letter.
        Run('explorer.exe "' DownloadsPath '"')
        if WinWait("ahk_class CabinetWClass", , 2) {
            WinActivate
        }
    }

    ; Converts a file:// URL (as returned by IE/Explorer LocationURL) to a
    ; standard Windows path. Returns "" if the URL is not a local file.
    DOMPathToFilesystem(Url) {
        if (SubStr(Url, 1, 8) != "file:///") {
            return ""
        }
        Path := SubStr(Url, 9)
        Path := StrReplace(Path, "/", "\")
        ; Decode percent-encoded characters (spaces, accents, …)
        Path := RegExReplace(Path, "%([0-9A-Fa-f]{2})", "$0")
        Path := UriDecode(Path)
        return Path
    }

    ; Returns the absolute path of the Downloads folder.
    ; Tries several localised and English candidate names under %USERPROFILE%
    ; and returns the first one that actually exists on disk.
    GetKnownFolderDownloads() {
        Profile := EnvGet("USERPROFILE")
        Candidates := [
            Profile "\Téléchargements",
            Profile "\Downloads",
            Profile "\Descargas",
            Profile "\Transferências",
            Profile "\Загрузки",
        ]
        for Path in Candidates {
            if DirExist(Path) {
                return Path
            }
        }
        return ""
    }

    UriDecode(s) {
        Pos := 1
        Out := ""
        while (Pos <= StrLen(s)) {
            Ch := SubStr(s, Pos, 1)
            if (Ch == "%" and Pos + 2 <= StrLen(s)) {
                Hex := SubStr(s, Pos + 1, 2)
                Out .= Chr("0x" Hex)
                Pos += 3
            } else {
                Out .= Ch
                Pos += 1
            }
        }
        return Out
    }
}


; ==============================
; ==============================
; ======= 6/ CAPSWORD =======
; ==============================
; ==============================

; (cf. https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md)

ToggleCapsWord() {
    global CapsWordEnabled := not CapsWordEnabled
    UpdateCapsLockLED()
}

DisableCapsWord() {
    global CapsWordEnabled := False
    UpdateCapsLockLED()
}

UpdateCapsLockLED() {
    if CapsWordEnabled or LayerEnabled {
        SetCapsLockState("On")
    } else {
        SetCapsLockState("Off")
    }
}

; Defines what deactivates the CapsLock triggered by CapsWord
#HotIf CapsWordEnabled
SC039::
{
    SendEvent("{Space}")
    Keywait("SC039") ; Solves bug of 2 sent Spaces when exiting CapsWord with a Space
    DisableCapsWord()
}

; Big Enter key
SC01C::
{
    SendEvent("{Enter}")
    DisableCapsWord()
}

; Mouse click
~LButton::
~RButton::
{
    if (GestureLeftClickHeld) {
        GestureReleaseLeftClick()
    }
    DisableCapsWord()
}
#HotIf
