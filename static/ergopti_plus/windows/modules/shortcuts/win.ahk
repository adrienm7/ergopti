; modules/shortcuts/win.ahk

; ==============================================================================
; MODULE: Shortcuts — Win-key Combos
; DESCRIPTION:
; Win-layer shortcuts: CapsLock toggle, line selection, screenshot, GPT link,
; hex color picker, note-taking, keep-awake simulation, surround-with-parens,
; search/regedit/path navigation, title-case, uppercase, mouse teleport,
; spotlight overlay, Downloads opener, and the screen-instant SC029 hotkey.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 5/ WIN SHORTCUTS =======
; ================================
; ================================

#HotIf IsSet(Features) and Features["shortcuts"]["win_caps_lock"]
; Win + "CapsLock" to toggle CapsLock
#SC03A:: ToggleCapsLock()
#HotIf

if Features["shortcuts"]["select_line"] {
		; Win + A (All)
		AddShortcut("#", "a", SelectLine)

		SelectLine(*) {
				; Synthetic Home/End are invisible to the prefix watcher's InputHook, so
				; the hotstring buffers must be told the caret moved — otherwise the next
				; expansion backspaces over the selected line instead of its own trigger.
				SendFinalResult("{Home}{Shift Down}{End}{Shift Up}", false, true)
		}
}

if Features["shortcuts"]["screen"] {
		; Win + H (ScreensHot)
		AddShortcut("#", "h", (*) => SendFinalResult("#+s"))
}

if Features["shortcuts"]["gpt"]["enabled"] {
		; Win + G (GPT)
		AddShortcut("#", "g", LaunchGptShortcut)

		LaunchGptShortcut(*) {
				; A configured URL is external input and Run() can throw (malformed URI,
				; policy denial, unavailable shell association).  This is a hook callback,
				; so fail locally with visible nonblocking feedback rather than escalating
				; through the global error handler and risking keyboard dispatch.
				try {
						Link := Features["shortcuts"]["gpt"]["link"]
						if (Type(Link) != "String" or Trim(Link) = "")
								throw Error("configured GPT link is empty or invalid")
						Run(Link)
				} catch as Err {
						LoggerError("shortcuts", "LaunchGptShortcut failed: {1}", Err.Message)
						try TrayTip("Could not open the configured GPT link.", "ErgoptiPlus", "Iconx Mute")
				}
		}
}

if Features["shortcuts"]["get_hex_value"] {
		; Win + X (heX)
		AddShortcut("#", "x", GetHexValue)

		GetHexValue(*) {
				; This is a keyboard-hotkey callback: no blocking UI or unguarded desktop /
				; clipboard operation may keep the hook thread occupied.  TrayTip gives
				; the same visible result while returning control to the keyboard loop.
				try {
						MouseGetPos(&MouseX, &MouseY)
						HexColor := "#" . StrLower(SubStr(PixelGetColor(MouseX, MouseY, "RGB"), 3))
						if !CB_Write(HexColor)
								throw Error("clipboard write failed")
						TrayTip(HexColor, "ErgoptiPlus", "Iconi Mute")
				} catch as Err {
						LoggerError("shortcuts", "GetHexValue failed: {1}", Err.Message)
						TrayTip("Color copy failed.", "ErgoptiPlus", "Iconx Mute")
				}
		}
}

if Features["shortcuts"]["take_note"]["enabled"] {
		; Win + N (Note)
		AddShortcut("#", "n", TakeNote)
}

if Features["shortcuts"]["move"] {
		; Win + M (Move)
		AddShortcut("#", "m", ToggleActivitySimulation)

		; Jitter parameters -- mirrored from Hammerspoon's AWAKE_JITTER_* constants
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
				; These arm the CANCELLATION paths — swallowing a failure silently would leave
				; keep-awake running with no way for the user to interrupt it (§5.3: never
				; swallow without at minimum a LoggerError).
				try {
						Hotkey("~*$LButton", AwakeCancelOnMouse, "On")
						Hotkey("~*$RButton", AwakeCancelOnMouse, "On")
						Hotkey("~*$MButton", AwakeCancelOnMouse, "On")
				} catch as Err {
						LoggerError("shortcuts", "Keep-awake mouse-cancel hook arming failed: {1}.", Err.Message)
				}
				; Start a fast timer to instantly detect if the user moves the mouse
				SetTimer(AwakeCheckMouseMoved, 150)
				; Use InputHook to detect any keypress -- does not conflict with other hotkeys
				try {
						AwakeInputHook := InputHook("L0 I")
						AwakeInputHook.OnChar := AwakeCancelOnKeypress
						AwakeInputHook.OnKeyDown := AwakeCancelOnKeypress
						AwakeInputHook.Start()
				} catch as Err {
						LoggerError("shortcuts", "Keep-awake keypress-cancel InputHook arming failed: {1}.", Err.Message)
				}
				try TrayTip(t("keepawake.started"), t("keepawake.title"), "Iconi Mute")
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
				; Ergopti_OnSuspendEnter calls this unconditionally on every pause so
				; keep-awake can never outlive a suspend ("pause = tout eteint"
				; invariant). Capture the prior state so the "stopped" toast below only
				; fires when keep-awake was actually running -- otherwise every single
				; pause (AltGr+Enter included) shows a false "antiveille desactive"
				; notification even when it was never turned on.
				WasActive := ActivitySimulation
				ActivitySimulation := False
				SetTimer(SimulateActivity, 0)
				SetTimer(AwakeCheckMouseMoved, 0)
				SetTimer(AwakeReturnToOrigin, 0)
				; Disarm mouse-button cancel hooks
				try Hotkey("~*$LButton", AwakeCancelOnMouse, "Off")
				try Hotkey("~*$RButton", AwakeCancelOnMouse, "Off")
				try Hotkey("~*$MButton", AwakeCancelOnMouse, "Off")
				; Stop the keypress detector
				if IsSet(AwakeInputHook) and IsObject(AwakeInputHook) {
						try AwakeInputHook.Stop()
						AwakeInputHook := ""
				}
				if WasActive
						try TrayTip(t("keepawake.stopped"), t("keepawake.title"), "Iconi Mute")
		}

		AwakeReturnToOrigin() {
				if A_IsSuspended
						return
				global ActivitySimulation, AwakeOriginX, AwakeOriginY
				if ActivitySimulation {
						MCSetPos(AwakeOriginX, AwakeOriginY)
				}
		}

		AwakeCheckMouseMoved() {
				if A_IsSuspended
						return
				global ActivitySimulation, AwakeOriginX, AwakeOriginY
				if not ActivitySimulation
						return
				MouseGetPos(&CurX, &CurY)
				if (Abs(CurX - AwakeOriginX) > AWAKE_JITTER_PX or Abs(CurY - AwakeOriginY) > AWAKE_JITTER_PX) {
						SetTimer(StopActivitySimulation, -1)
				}
		}

		AwakeCancelOnMouse(*) {
				if A_IsSuspended
						return
				global ActivitySimulation
				if ActivitySimulation {
						StopActivitySimulation()
				}
		}

		AwakeCancelOnKeypress(ih, arg1:="", arg2:="") {
				if A_IsSuspended
						return
				; Ignore key presses with modifiers to prevent the trigger hotkey
				; from instantly deactivating the keep-awake mode silently.
				if Type(ih) == "InputHook" {
						if GetKeyState("Ctrl") or GetKeyState("Alt") or GetKeyState("LWin") or GetKeyState("RWin")
								return
				}
				global ActivitySimulation
				if ActivitySimulation {
						StopActivitySimulation()
				}
		}

		SimulateActivity(ResetOnly := False) {
				if A_IsSuspended
						return
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
				; the user touched the mouse or touchpad -- stop without moving again.
				MouseGetPos(&CurX, &CurY)
				if (LastX != -1 and (Abs(CurX - LastX) > AWAKE_JITTER_PX or Abs(CurY - LastY) > AWAKE_JITTER_PX)) {
						StopActivitySimulation()
						return
				}

				; Move to a random offset around the captured origin (+-AWAKE_JITTER_PX)
				OffX := Random(-AWAKE_JITTER_PX, AWAKE_JITTER_PX)
				OffY := Random(-AWAKE_JITTER_PX, AWAKE_JITTER_PX)
				MCSetPos(AwakeOriginX + OffX, AwakeOriginY + OffY)

				; Signal OS activity without a visible keystroke
				SendFinalResult("{VKFF}")

				; Record the jitter position so the next tick's user-move check is accurate
				LastX := AwakeOriginX + OffX
				LastY := AwakeOriginY + OffY

				; Return to origin via a separate one-shot timer -- avoids blocking the thread
				; with Sleep(), which would delay input-cancel detection by up to AWAKE_RETURN_MS
				SetTimer(AwakeReturnToOrigin, -AWAKE_RETURN_MS)

				; Re-schedule the next tick at a new random interval
				SetTimer(SimulateActivity, Random(AWAKE_TICK_MIN_MS, AWAKE_TICK_MAX_MS))
		}

}

if Features["shortcuts"]["surround_with_parentheses"] {
		; Same declaration as SelectLine: the payload ends with the caret parked at
		; line start, nowhere near the text the buffers still describe.
		AddShortcut("#", "o", SurroundLineWithParentheses)

		SurroundLineWithParentheses(*) {
				SendFinalResult("{Home}({End}){Home}", false, true)
		}
}

if Features["shortcuts"]["search"]["enabled"] {
		; Win + S (Search)
		AddShortcut("#", "s", Search)

		Search(*) {
				SearchInExplorer := WinActive("ahk_exe explorer.exe") != 0
				GetSelectionAsync((Text) => _SearchSelectionReady(Text, SearchInExplorer))
		}

		_SearchSelectionReady(Text, SearchInExplorer) {
				SelectedText := Trim(Text)
				if (SelectedText = "")
						return
				if SearchInExplorer {
						GetPath(SelectedText)
						return
				}
				SearchPath(SelectedText)
		}

		SearchPath(SelectedText) {
				; The result of each of those regexes is a boolean

				; Detects Windows file paths like C:/ or D:\ (supports forward and backward slashes)
				; Invalid Windows path characters are excluded: <>:"|?*
				FilePath := RegExMatch(
						SelectedText,
						"^[A-Za-z]:[\\/](?:[^<>:" . '"' . "|?*\r\n]+[\\/]?)*$"
				)

				; Detects Windows Registry paths (optional Computer\ or Ordinateur\ prefix)
				; Matches both full names (HKEY_CLASSES_ROOT...) and abbreviations (HKCR, HKCU, etc.)
				RegeditPath := RegExMatch(
						SelectedText,
						"i)^(?:Computer\\|Ordinateur\\)?(?:HKEY_(?:CLASSES_ROOT|CURRENT_USER|LOCAL_MACHINE|USERS|CURRENT_CONFIG)|HK(?:CR|CU|LM|U|CC))(?:\\[^\r\n]*)?$"
				)

				; Detects full URLs with protocol (http, https, ftp, file, etc.)
				; Protocol must start with a letter and be 2-9 characters long
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

				; AHK-18: FilePath regex matches SHAPE only — verify existence before Run so a
				; selected-but-non-existent path string falls through to the web-search branch
				; instead of throwing an OSError that escalates to the crash-report error net.
				if (FilePath and FileExist(SelectedText)) {
						try Run(SelectedText, , "Max")
						catch as SearchError {
								LoggerWarn("Search", "Could not open path '{1}': {2}.", SelectedText, SearchError.Message)
						}
				} else if RegeditPath {
						try RegJump(SelectedText)
						catch as SearchError {
								LoggerWarn("Search", "Could not jump to registry path '{1}': {2}.", SelectedText, SearchError.Message)
						}
				} else {
						; Modify some characters that screw up the URL
						SelectedText := StrReplace(SelectedText, "`r`n", " ")
						SelectedText := StrReplace(SelectedText, "#", "%23")
						SelectedText := StrReplace(SelectedText, "&", "%26")
						SelectedText := StrReplace(SelectedText, "+", "%2b")
						SelectedText := StrReplace(SelectedText, '"', "%22")

						if URLPath {
								try Run(SelectedText)
								catch as SearchError {
										LoggerWarn("Search", "Could not open URL '{1}': {2}.", SelectedText, SearchError.Message)
								}
						} else if (WebsitePath) {
								try Run("https://" . SelectedText)
								catch as SearchError {
										LoggerWarn("Search", "Could not open website '{1}': {2}.", SelectedText, SearchError.Message)
								}
						} else if (SelectedText == "") { ; If nothing was copied
								try Run(Features["shortcuts"]["search"]["search_engine"])
								catch as SearchError {
										LoggerWarn("Search", "Could not open search engine: {1}.", SearchError.Message)
								}
						} else {
								try Run(Features["shortcuts"]["search"]["search_engine_url_query"] . SelectedText)
								catch as SearchError {
										LoggerWarn("Search", "Could not open search URL: {1}.", SearchError.Message)
								}
						}
				}
		}

		; Open Regedit and navigate to RegPath.
		; RegPath accepts both HKEY_LOCAL_MACHINE and HKLM formats.
		RegJump(RegPath) {
				; Close existing Registry Editor to ensure target key is selected next time
				if WMExists("Registry Editor") {
						WMKill("Registry Editor")
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

				; Set the last selected key in Regedit so it opens directly to the target on launch
				Reg_WriteString("HKCU\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit", "LastKey", RegPath)
				Run("Regedit.exe")
		}

		GetPath(Path) {
				PathWithBackslash := Path
				PathWithSlash := StrReplace(Path, "\", "/")
				CB_Write(PathWithSlash)

				; One-shot timer (-50 ms): fires once only, so it auto-cancels even if the
				; MsgBox is dismissed before the timer tick, preventing an infinite loop.
				SetTimer ChangeButtonNames, -50
				; The shared locale strings use printf-style ``%s`` for cross-platform
				; compatibility with the Hammerspoon driver. AHK v2's Format() expects
				; ``{1}``-style placeholders and would leave ``%s`` verbatim, so the
				; substitution is done with StrReplace here.
				Result := MsgBox(StrReplace(t("dialog.path_copy.msg_with_question"), "%s", PathWithSlash),
						t("dialog.path_copy.title"), "YesNo")
				if (Result == "No") {
						CB_Write(PathWithBackslash)
						Sleep(200)
						MsgBox(StrReplace(t("dialog.path_copy.msg_simple"), "%s", PathWithBackslash))
				}
		}
		ChangeButtonNames() {
				if not WMExists(t("dialog.path_copy.title"))
						return
				WMActivate(t("dialog.path_copy.title"))
				ControlSetText(t("dialog.path_copy.btn_quit"), "Button1") ; Note: ControlSetText has no port adapter — AHK-specific UI manipulation
				ControlSetText(t("dialog.path_copy.btn_backslash"), "Button2") ; Note: ControlSetText has no port adapter — AHK-specific UI manipulation
		}
}

if Features["shortcuts"]["title_case"] {
		; Win + W (TitleCase)
		AddShortcut("#", "w", ConvertToTitleCase)

		ConvertToTitleCase(*) {
				GetSelectionAsync(_ConvertToTitleCaseSelection)
		}

		_ConvertToTitleCaseSelection(Text) {
				; No-op on an empty/failed capture: an async timeout/cancellation must
				; never turn into a stale SendInstant paste.
				if (Text = "")
						return

				; Pattern to detect if text is already in title case:
				; Each word starts with an uppercase letter (including accented),
				; followed by lowercase letters (including accented) or digits or allowed symbols.
				; Words are separated by spaces, tabs or returns ([ \t\r\n]).
				TitleCasePattern :=
						"^(?:[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*[ \t\r\n]+)*[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9''\(\),.\-:;!?\-]*$"
				; Pattern to detect if text is all uppercase (including accented), digits, spaces, and allowed symbols
				UpperCasePattern := "^[A-ZÉÈÀÙÂÊÎÔÛÇ0-9''\(\),.\-:;!?\s]+$"

				try KL_MarkSynthetic("case-transform")
				if RegExMatch(Text, TitleCasePattern) {
						; Text is Title Case -> convert to lowercase
						SendInstant(Format("{:L}", Text))
				} else if RegExMatch(Text, UpperCasePattern) {
						; Text is UPPERCASE -> convert to TitleCase
						SendInstant(Format("{:T}", Text))
				} else {
						; Otherwise, convert to TitleCase
						SendInstant(Format("{:T}", Text))
				}
				SetTimer((*) => KL_ClearSynthetic(), -300)
		}
}

if Features["shortcuts"]["uppercase"] {
		; Win + U (Uppercase)
		AddShortcut("#", "u", ConvertToUppercase)

		ConvertToUppercase(*) {
				GetSelectionAsync(_ConvertToUppercaseSelection)
		}

		_ConvertToUppercaseSelection(Text) {
				; No-op on an empty/failed capture: an async timeout/cancellation must
				; never turn into a stale SendInstant paste.
				if (Text = "")
						return
				; Check if the selected text contains at least one lowercase letter
				try KL_MarkSynthetic("case-transform")
				if RegExMatch(Text, "[a-zà-ÿ]") {
						SendInstant(Format("{:U}", Text)) ; Convert to uppercase
				} else {
						SendInstant(Format("{:L}", Text)) ; Convert to lowercase
				}
				SetTimer((*) => KL_ClearSynthetic(), -300)
		}
}

if Features["shortcuts"]["teleport_mouse"] {
		; Win + T (Teleport)
		AddShortcut("#", "t", TeleportMouse)

		TeleportMouse(*) {
				Monitors := []
				Count := MonitorGetCount()
				loop Count {
						MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
						Monitors.Push({Left: Left, Top: Top, Right: Right, Bottom: Bottom, Index: A_Index})
				}

				if (Count < 2) {
						MsgBox(t("shortcuts.no_other_monitor"))
						return
				}

				MouseGetPos(&CurX, &CurY)

				; Find which monitor currently holds the cursor
				CurrentIndex := 1
				for _, Mon in Monitors {
						if (CurX >= Mon.Left and CurX < Mon.Right and CurY >= Mon.Top and CurY < Mon.Bottom) {
								CurrentIndex := _
								break
						}
				}

				; Pick the next monitor cyclically
				NextIndex := (Mod(CurrentIndex, Count) + 1)
				Target := Monitors[NextIndex]
				TargetX := Target.Left + (Target.Right - Target.Left) // 2
				TargetY := Target.Top + (Target.Bottom - Target.Top) // 2

				MCSetPos(TargetX, TargetY)
				SpotlightMouseAt(TargetX, TargetY, 3000)
		}
}

if Features["shortcuts"]["spotlight_mouse"] {
		; Win + '
		AddShortcut("#", "'", (*) => (MouseGetPos(&Mx, &My), SpotlightMouseAt(Mx, My, 5000)))
}

#HotIf IsSet(Features) and Features["shortcuts"]["screen_instant"]
; SC029 (²/$ -- key left of 1) -- instant screenshot of the active window, saved to Pictures
SC029:: {
		; The gesture entry owns the shared staged worker and contains every OS
		; boundary. Keeping the hotkey as a pure delegate prevents a future sibling
		; PowerShell process from escaping suspend and shutdown cancellation.
		GestureScreenshotInstant()
}
#HotIf

; SpotlightMouseAt is defined in infra/spotlight.ahk and included globally before this module.

if Features["shortcuts"]["open_downloads"] {
		; Win + D (Downloads)
		AddShortcut("#", "d", OpenDownloads)

		OpenDownloads(*) {
				; Resolve the real Downloads folder via SHGetKnownFolderPath --
				; locale-independent and respects user-relocated folders. Falls back
				; to %USERPROFILE%\Downloads if the API call fails.
				DownloadsPath := GetKnownFolderDownloads()
				if (DownloadsPath == "") {
						DownloadsPath := EnvGet("USERPROFILE") "\Downloads"
				}

				; This keyboard hotkey must never enumerate Shell.Application or wait
				; for Explorer: either COM boundary can block all remapping for seconds.
				; Explorer opens/reuses the resolved known path asynchronously itself.
				try {
						Run('explorer.exe "' DownloadsPath '"')
				} catch as Err {
						LoggerError("Shortcuts", "OpenDownloads failed for '{1}': {2}", DownloadsPath, Err.Message)
						try TrayTip("Could not open Downloads.", "ErgoptiPlus", "Iconx Mute")
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
				; Decode percent-encoded characters (spaces, accents, ...)
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
				for _, Path in Candidates {
						if DirExist(Path) {
								return Path
						}
				}
				return ""
		}

		; UriDecode is defined in infra/text_utils.ahk and visible globally.
}
