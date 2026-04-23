; static/drivers/autohotkey/lib/shortcuts.ahk

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
AddShortcut(Modifier, Letter, BehaviorFunction) {
	Scancode := RetrieveScancode(Letter)
	Key := Modifier Scancode
	Hotkey(Key, BehaviorFunction.Call())
}

RetrieveScancode(Letter) {
	if RemappedList.Has(Letter) {
		Scancode := RemappedList[Letter]
	} else {
		Scancode := Format("sc{:x}", GetKeySC(Letter))
	}
	return Scancode
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
	if Features["Shortcuts"]["LAltCapsLock"]["BackSpace"].Enabled {
		SendEvent("{BackSpace}")
	} else if Features["Shortcuts"]["LAltCapsLock"]["CapsLock"].Enabled {
		ToggleCapsLock()
	} else if Features["Shortcuts"]["LAltCapsLock"]["CapsWord"].Enabled {
		ToggleCapsWord()
	} else if Features["Shortcuts"]["LAltCapsLock"]["CtrlBackSpace"].Enabled {
		SendInput("^{BackSpace}")
	} else if Features["Shortcuts"]["LAltCapsLock"]["CtrlDelete"].Enabled {
		SendInput("^{Delete}")
	} else if Features["Shortcuts"]["LAltCapsLock"]["Delete"].Enabled {
		SendInput("{Delete}")
	} else if Features["Shortcuts"]["LAltCapsLock"]["Enter"].Enabled {
		SendInput("{Enter}")
	} else if Features["Shortcuts"]["LAltCapsLock"]["Escape"].Enabled {
		SendInput("{Escape}")
	} else if Features["Shortcuts"]["LAltCapsLock"]["OneShotShift"].Enabled {
		OneShotShift()
	} else if Features["Shortcuts"]["LAltCapsLock"]["Tab"].Enabled {
		SendInput("{Tab}")
	}
}


; =================================
; =================================
; ======= 3/ CTRL SHORTCUTS =======
; =================================
; =================================

if Features["Shortcuts"]["Save"].Enabled {
	AddShortcut("^", "j", (*) => (*) => SendFinalResult("^s"))
}
if Features["Shortcuts"]["CtrlJ"].Enabled {
	AddShortcut("^", "s", (*) => (*) => SendFinalResult("^j"))
}

if Features["Shortcuts"]["MicrosoftBold"].Enabled {
	; Makes it possible to use the standard shortcuts instead of their translation in Microsoft apps
	AddShortcut(
		"^", "b",
		(*) => (*) => MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")
	)
}


; ==================================
; ==================================
; ======= 4/ ALTGR SHORTCUTS =======
; ==================================
; ==================================

#HotIf (
	Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["CapsLock"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["CapsWord"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["CtrlBackSpace"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["CtrlDelete"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["Delete"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["Enter"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["Escape"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["OneShotShift"].Enabled
	or Features["Shortcuts"]["AltGrLAlt"]["Tab"].Enabled
)
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

#HotIf (
	Features["Shortcuts"]["AltGrCapsLock"]["BackSpace"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["CapsLock"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["CapsWord"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["CtrlBackSpace"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["CtrlDelete"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["Delete"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["Enter"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["Escape"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["OneShotShift"].Enabled
	or Features["Shortcuts"]["AltGrCapsLock"]["Tab"].Enabled
)
SC138 & SC03A:: AltGrCapsLockShortcut()
#HotIf

AltGrCapsLockShortcut() {
	if Features["Shortcuts"]["AltGrCapsLock"]["BackSpace"].Enabled {
		SendEvent("{BackSpace}")
	} else if Features["Shortcuts"]["AltGrCapsLock"]["CapsLock"].Enabled {
		ToggleCapsLock()
	} else if Features["Shortcuts"]["AltGrCapsLock"]["CapsWord"].Enabled {
		ToggleCapsWord()
	} else if Features["Shortcuts"]["AltGrCapsLock"]["CtrlBackSpace"].Enabled {
		SendInput("^{BackSpace}")
	} else if Features["Shortcuts"]["AltGrCapsLock"]["CtrlDelete"].Enabled {
		SendInput("^{Delete}")
	} else if Features["Shortcuts"]["AltGrCapsLock"]["Delete"].Enabled {
		SendInput("{Delete}")
	} else if Features["Shortcuts"]["AltGrCapsLock"]["Enter"].Enabled {
		SendInput("{Enter}")
	} else if Features["Shortcuts"]["AltGrCapsLock"]["Escape"].Enabled {
		SendInput("{Escape}")
	} else if Features["Shortcuts"]["AltGrCapsLock"]["OneShotShift"].Enabled {
		OneShotShift()
	} else if Features["Shortcuts"]["AltGrCapsLock"]["Tab"].Enabled {
		SendInput("{Tab}")
	}
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
	AddShortcut("#", "a", (*) => SelectLine)

	SelectLine(*) {
		SendFinalResult("{Home}{Shift Down}{End}{Shift Up}")
	}
}

if Features["Shortcuts"]["Screen"].Enabled {
	; Win + H (ScreensHot)
	AddShortcut("#", "h", (*) => (*) => SendFinalResult("#+s"))
}

if Features["Shortcuts"]["GPT"].Enabled {
	; Win + G (GPT)
	AddShortcut("#", "g", (*) => (*) => Run(Features["Shortcuts"]["GPT"].Link))
}

if Features["Shortcuts"]["GetHexValue"].Enabled {
	; Win + X (heX)
	AddShortcut("#", "x", (*) => GetHexValue)

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
	AddShortcut("#", "n", (*) => TakeNote)

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

		; Match the window title containing the file name
		SetTitleMatchMode(2) ; Partial match
		WinPattern := FileName

		WindowAlreadyOpen := False
		if WinExist(WinPattern) {
			WindowAlreadyOpen := True
			WinActivate(WinPattern)
			WinWaitActive(WinPattern, , 3)
		} else {
			Run("notepad " . FilePath)
			WinWait(FileName, , 7)
			WinActivate(FileName)
			WinWaitActive(FileName, , 3)
		}

		WinMaximize
		Sleep(100)
		if not WindowAlreadyOpen {
			SendFinalResult("^{End}{Enter}") ; Jump to the end of the file and start a new line
		}
	}
}

if Features["Shortcuts"]["Move"].Enabled {
	; Win + M (Move)
	AddShortcut("#", "m", (*) => (*) => ToggleActivitySimulation() SetTimer(SimulateActivity, Random(1000, 5000)))

	ToggleActivitySimulation(*) {
		global ActivitySimulation := not ActivitySimulation
	}
	SimulateActivity() {
		if ActivitySimulation {
			MouseMoveCount := Random(3, 8) ; Randomly select the number of mouse moves
			loop MouseMoveCount {
				MouseX := Random(0, A_ScreenWidth)
				MouseY := Random(0, A_ScreenHeight)
				DllCall("SetCursorPos", "int", MouseX, "int", MouseY)
				Sleep(Random(200, 800)) ; Wait for a short duration
			}
			SendFinalResult("{VKFF}") ; Send the void keypress. Otherwise, despite the mouse moving, it can be seen as inactivity
		}
	}
}

if Features["Shortcuts"]["SurroundWithParentheses"].Enabled {
	AddShortcut("#", "o", (*) => (*) => SendFinalResult("{Home}({End}){Home}"))
}

if Features["Shortcuts"]["Search"].Enabled {
	; Win + S (Search)
	AddShortcut("#", "s", (*) => Search)

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
			if KeyMap.HasKey(RootKey) {
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
		Result := MsgBox("Le chemin`n" A_Clipboard "`na été copié dans le presse-papier. `n`nVoulez-vous la version avec des \ à la place des / ?",
			"Copie du chemin d'accès", "YesNo")
		if (Result == "No") {
			A_Clipboard := PathWithBackslash
			Sleep(200)
			MsgBox("Le chemin`n" A_Clipboard "`na été copié dans le presse-papier.")
		}
	}
	ChangeButtonNames() {
		if not WinExist("Copie du chemin d'accès")
			return ; Keep waiting
		SetTimer ChangeButtonNames, 0
		WinActivate()
		ControlSetText("&Quitter", "Button1")
		ControlSetText("&Backslash (\)", "Button2")
	}
}

if Features["Shortcuts"]["TitleCase"].Enabled {
	; Win + T (TitleCase)
	AddShortcut("#", "t", (*) => ConvertToTitleCase)

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
	AddShortcut("#", "u", (*) => ConvertToUppercase)

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

if Features["Shortcuts"]["SelectWord"].Enabled {
	; Win + W (Word)
	AddShortcut("#", "w", (*) => SelectWord)

	SelectWord(*) {
		SendFinalResult("^{Left}")
		SendFinalResult("{LShift Down}^{Right}{LShift Up}")

		SelectedWord := GetSelection()
		if (SubStr(SelectedWord, -1, 1) == " ") {
			; If the selected word finishes with a space, we remove it from the selection
			SendFinalResult("{LShift Down}{Left}{LShift Up}")
		}
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
	global drag_enabled := 0
	DisableCapsWord()
}
#HotIf
