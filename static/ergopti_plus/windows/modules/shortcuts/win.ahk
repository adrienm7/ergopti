; modules/shortcuts/win.ahk

; ==============================================================================
; MODULE: Shortcuts — Win-key Combos
; DESCRIPTION:
; Win-layer shortcuts: CapsLock toggle, line selection, screenshot, GPT link,
; hex color picker, note-taking, keep-awake simulation, surround-with-parens,
; search/regedit/path navigation, title-case, uppercase, mouse teleport,
; spotlight overlay and Downloads opener.
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
				; Tray callbacks remain available while native Suspend is active. Refuse
				; a new session here because its timers and InputHook bypass Suspend.
				if A_IsSuspended
						return false
				if ActivitySimulation
						return true
				; A previous Stop refusal leaves the exact observer owned for retry. Never
				; overwrite that handle, or repeated sessions would leak native hooks.
				if IsObject(AwakeInputHook) and !AwakeStopCancellationHook() {
						LoggerError("shortcuts", "Keep-awake cannot restart while its prior keypress observer remains live.")
						return false
				}
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
						StopActivitySimulation(false)
						return false
				}
				; Suspend can arrive after a tray callback enters this function. Do not
				; arm a second cancellation mechanism after lifecycle teardown began.
				if A_IsSuspended {
						StopActivitySimulation(false)
						return false
				}
				; Start a fast timer to instantly detect if the user moves the mouse
				SetTimer(AwakeCheckMouseMoved, 150)
				; Use InputHook to detect any keypress -- does not conflict with other hotkeys
				try {
						AwakeInputHook := AwakeCreateCancellationHook()
						AwakeInputHook.Start()
				} catch as Err {
						LoggerError("shortcuts", "Keep-awake keypress-cancel InputHook arming failed: {1}.", Err.Message)
						StopActivitySimulation(false)
						return false
				}
				if A_IsSuspended {
						StopActivitySimulation(false)
						return false
				}
				try TrayTip(t("keepawake.started"), t("keepawake.title"), "Iconi Mute")
				return true
		}

		ToggleActivitySimulation(*) {
				global ActivitySimulation
				if ActivitySimulation {
						StopActivitySimulation()
				} else {
						StartActivitySimulation()
				}
		}

		StopActivitySimulation(Notify := true) {
				global ActivitySimulation, AwakeInputHook
				; Ergopti_OnSuspendEnter calls this unconditionally on every pause so
				; keep-awake can never outlive a suspend ("pause = tout eteint"
				; invariant). Capture the prior state so the "stopped" toast below only
				; fires when keep-awake was actually running -- otherwise every single
				; pause (AltGr+Enter included) shows a false "antiveille desactive"
				; notification even when it was never turned on.
				WasActive := ActivitySimulation
				ActivitySimulation := False
				; Retire this session's queued cancellation before a successor starts.
				SetTimer(StopActivitySimulation, 0)
				SetTimer(SimulateActivity, 0)
				SetTimer(AwakeCheckMouseMoved, 0)
				SetTimer(AwakeReturnToOrigin, 0)
				; Disarm mouse-button cancel hooks
				try Hotkey("~*$LButton", AwakeCancelOnMouse, "Off")
				try Hotkey("~*$RButton", AwakeCancelOnMouse, "Off")
				try Hotkey("~*$MButton", AwakeCancelOnMouse, "Off")
				; Stop the keypress detector
				HookStopped := AwakeStopCancellationHook()
				if WasActive and Notify
						try TrayTip(t("keepawake.stopped"), t("keepawake.title"), "Iconi Mute")
				return HookStopped
		}

		AwakeStopCancellationHook() {
				global AwakeInputHook
				if !IsSet(AwakeInputHook) or !IsObject(AwakeInputHook)
						return true
				Hook := AwakeInputHook
				FailureMessage := ""
				PreviousCritical := Critical("On")
				try {
						try Hook.Stop()
						catch as Err
								FailureMessage := Err.Message
						if FailureMessage == "" and AwakeInputHook == Hook
								AwakeInputHook := ""
				} finally Critical(PreviousCritical)
				if FailureMessage != "" {
						LoggerError("shortcuts", "Could not stop the keep-awake keypress observer; cleanup ownership was retained: {1}.", FailureMessage)
						return false
				}
				return true
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
						if Type(arg1) == "Integer" and Type(arg2) == "Integer" and AwakeIsIgnoredModifierKey(arg1, arg2)
								return
						; A Kana-style layout's AltGr is neither Ctrl nor Alt.
						if GetKeyState("Ctrl") or GetKeyState("Alt") or GetKeyState("LWin") or GetKeyState("RWin")
								or GetKeyState(KS_AltGrKeyName())
								return
				}
				global ActivitySimulation
				if ActivitySimulation {
						StopActivitySimulation()
				}
		}

		AwakeCreateCancellationHook() {
				; Keep cancellation observational: V preserves the triggering input, while
				; N is required for navigation and other non-text key notifications.
				Hook := InputHook("V L0 I")
				Hook.KeyOpt("{All}", "N")
				Hook.OnChar := AwakeCancelOnKeypress
				Hook.OnKeyDown := AwakeCancelOnKeypress
				return Hook
		}

		; The AltGr key is matched by scan code: a Kana-style layout gives it a
		; virtual key other than VK_RMENU.
		AwakeIsIgnoredModifierKey(VirtualKey, ScanCode) {
				return VirtualKey == GetKeyVK("Ctrl") or VirtualKey == GetKeyVK("Alt")
						or VirtualKey == GetKeyVK("LWin") or VirtualKey == GetKeyVK("RWin")
						or VirtualKey == GetKeyVK("LCtrl") or VirtualKey == GetKeyVK("RCtrl")
						or VirtualKey == GetKeyVK("LAlt") or VirtualKey == GetKeyVK("RAlt")
						or ScanCode == KS_AltGrScanCode()
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
				; As on Linux, an empty selection opens nothing; the log says so,
				; so the shortcut never ends without a trace.
				if (SelectedText = "") {
						LoggerInfo("Search", "copy_selected_path: the selection is empty; nothing opened.")
						return
				}
				if SearchInExplorer {
						GetPath(SelectedText)
						return
				}
				SearchPath(SelectedText)
		}

		; Opens what the selection names, classified by infra/open_target.ahk
		; (the rule the macOS and Linux drivers share): a URL, an IP address, a
		; file or folder, a registry key, ms-settings: or shell:. Plain text is
		; searched. A target that is recognised but cannot be opened (a path that
		; does not exist, a bare file name) is reported, never searched instead:
		; the user asked to open that thing.
		SearchPath(SelectedText, LaunchFn := Run, ReportFn := _SearchReportUnopened) {
				Target := OpenTarget_Classify(SelectedText)
				Kind := Target["kind"]
				Value := Target["target"]
				if (Kind == "empty") {
						try LaunchFn.Call(Features["shortcuts"]["search"]["search_engine"])
						catch as SearchError {
								LoggerWarn("Search", "Could not open search engine: {1}.", SearchError.Message)
						}
						return false
				}
				if (Kind == "search") {
						; Preserve the existing CRLF-to-space selection policy, then encode one component.
						Query := UriEncode(StrReplace(Value, "`r`n", " "))
						try LaunchFn.Call(Features["shortcuts"]["search"]["search_engine_url_query"] . Query)
						catch as SearchError {
								LoggerWarn("Search", "Could not open search URL: {1}.", SearchError.Message)
						}
						return false
				}
				LoggerStart("Search", "Opening the selected {1} '{2}'…", Kind, Value)
				if (Kind == "path") {
						if !FileExist(Value) {
								ReportFn.Call("open_target.missing_path", Value, "no file or folder exists at that path")
								return false
						}
						; Quoted, the whole path is one file for the shell: no part of a
						; selected path can become a program's arguments.
						try LaunchFn.Call('"' . Value . '"', , "Max")
						catch as SearchError {
								ReportFn.Call("open_target.open_failed", Value, SearchError.Message)
								return false
						}
				} else if (Kind == "registry") {
						try Jumped := RegJump(Value)
						catch as SearchError {
								ReportFn.Call("open_target.open_failed", Value, SearchError.Message)
								return false
						}
						if !Jumped {
								LoggerWarn("Search", "Registry navigation to '{1}' did not launch Regedit.", Value)
								return false
						}
				} else if (Kind == "url") {
						; The classifier admits no whitespace in a URL, so the shell
						; receives one target and no arguments.
						try LaunchFn.Call(Value)
						catch as SearchError {
								ReportFn.Call("open_target.open_failed", Value, SearchError.Message)
								return false
						}
				} else if (Kind == "file_name") {
						; Outside Explorer the selection carries no folder, and guessing
						; one would open a different file of the same name.
						ReportFn.Call("open_target.bare_file_name", Value, "a file name without its folder cannot be located")
						return false
				} else {
						ReportFn.Call("open_target.open_failed", Value, "unexpected target kind " . Kind)
						return false
				}
				LoggerSuccess("Search", "Handed the selected {1} '{2}' to the shell.", Kind, Value)
				return true
		}

		; Logs a recognised target that could not be opened and tells the user why.
		; @param {String} MessageKey The locale key, whose %s receives the target.
		; @param {String} Target The classified target.
		; @param {String} Reason English detail for the log.
		_SearchReportUnopened(MessageKey, Target, Reason) {
				LoggerError("Search", "Could not open '{1}': {2}.", Target, Reason)
				try TrayTip(StrReplace(t(MessageKey), "%s", Target), "ErgoptiPlus", "Iconx Mute")
				catch as Err {
						LoggerError("Search", "The notice for '{1}' could not be shown: {2}.", Target, Err.Message)
				}
		}

		; Open Regedit and navigate to RegPath.
		; RegPath accepts both HKEY_LOCAL_MACHINE and HKLM formats.
		RegJump(RegPath, CommitFn := _RegJumpCommit) {
				return CommitFn.Call(_RegJumpNormalizePath(RegPath), Reg_WriteString, WMExists, WMKill, Run)
		}

		; Search accepts roots and optional machine labels without regard to case.
		; Strip that label before finding the root, then expand only its own span.
		_RegJumpNormalizePath(RegPath) {
				RegPath := Trim(RegExReplace(RegPath, "i)^(?:Computer|Ordinateur)\\"), "\")
				RootKey := StrSplit(RegPath, "\")[1]
				KeyMap := Map(
						"HKCR", "HKEY_CLASSES_ROOT",
						"HKCU", "HKEY_CURRENT_USER",
						"HKLM", "HKEY_LOCAL_MACHINE",
						"HKU", "HKEY_USERS",
						"HKCC", "HKEY_CURRENT_CONFIG"
				)
				return KeyMap.Get(StrUpper(RootKey), RootKey) . SubStr(RegPath, StrLen(RootKey) + 1)
		}

		_RegJumpCommit(RegPath, WriteFn, ExistsFn, KillFn, RunFn) {
				global _SelectionCaptureNextId
				SelectionId := _SelectionCaptureNextId
				; Persist first so a refused registry write cannot destroy the user's
				; currently open Registry Editor session and then reopen a stale key.
				if !WriteFn.Call("HKCU\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit",
						"LastKey", RegPath)
						throw Error("Regedit LastKey registry write was refused")
				if ExistsFn.Call("Registry Editor") && !KillFn.Call("Registry Editor")
						throw Error("existing Registry Editor window could not be closed")
				; WinKill pumps messages during its native window delay. A completed
				; close cannot authorize a new launch after pause or command revocation.
				if A_IsSuspended || _SelectionCaptureNextId != SelectionId {
						LoggerInfo("Search", "Registry navigation cancelled before launch: {1}.",
								A_IsSuspended ? "driver paused" : "selection command superseded")
						return false
				}
				RunFn.Call("Regedit.exe")
				return true
		}

		GetPath(Path) {
				PathWithBackslash := Path
				PathWithSlash := StrReplace(Path, "\", "/")
				return _GetPathCopyFlow(PathWithSlash, PathWithBackslash,
						CB_Write, SetTimer, MsgBox, Sleep, ChangeButtonNames)
		}

		_GetPathCopyFlow(PathWithSlash, PathWithBackslash, WriteFn,
				ScheduleFn, PromptFn, SleepFn, RenameFn) {
				global _SelectionCaptureNextId
				SelectionId := _SelectionCaptureNextId
				if !_GetPathCopyCurrent(SelectionId)
						return false
				if !WriteFn.Call(PathWithSlash) {
						try LoggerWarn("shortcuts",
								"GetPath could not copy the slash-form path; success UI was suppressed.")
						return false
				}
				; One-shot timer (-50 ms): fires once only, so it auto-cancels even if the
				; MsgBox is dismissed before the timer tick, preventing an infinite loop.
				if !_GetPathCopyCurrent(SelectionId)
						return false
				ScheduleFn.Call(_GetPathRenameCurrent.Bind(SelectionId, RenameFn), -50)
				if !_GetPathCopyCurrent(SelectionId)
						return false
				; The shared locale strings use printf-style ``%s`` for cross-platform
				; compatibility with the Hammerspoon driver. AHK v2's Format() expects
				; ``{1}``-style placeholders and would leave ``%s`` verbatim, so the
				; substitution is done with StrReplace here.
				Result := PromptFn.Call(StrReplace(t("dialog.path_copy.msg_with_question"), "%s", PathWithSlash),
						t("dialog.path_copy.title"), "YesNo")
				; MsgBox pumps hotkeys: a pause or newer selection revokes this response.
				if !_GetPathCopyCurrent(SelectionId)
						return false
				if (Result == "No") {
						if !WriteFn.Call(PathWithBackslash) {
								try LoggerWarn("shortcuts",
										"GetPath could not copy the backslash-form path; success UI was suppressed.")
								return false
						}
						if !_GetPathCopyCurrent(SelectionId)
								return false
						SleepFn.Call(200)
						if !_GetPathCopyCurrent(SelectionId)
								return false
						PromptFn.Call(StrReplace(t("dialog.path_copy.msg_simple"), "%s", PathWithBackslash))
				}
				return true
		}
		_GetPathCopyCurrent(SelectionId) {
				global _SelectionCaptureNextId
				return !A_IsSuspended && _SelectionCaptureNextId == SelectionId
		}

		_GetPathRenameCurrent(SelectionId, RenameFn) {
				if !_GetPathCopyCurrent(SelectionId)
						return false
				return RenameFn.Call()
		}

		ChangeButtonNames() {
				return _ChangeButtonNamesWith(WMExists, WMActivate, ControlSetText)
		}

		_ChangeButtonNamesWith(ExistsFn, ActivateFn, SetTextFn) {
				Title := t("dialog.path_copy.title")
				if !ExistsFn.Call(Title)
						return false
				if !ActivateFn.Call(Title)
						return false
				try {
						SetTextFn.Call(t("dialog.path_copy.btn_quit"), "Button1")
						SetTextFn.Call(t("dialog.path_copy.btn_backslash"), "Button2")
						return true
				} catch as Err {
						; The MsgBox can close between any two window operations. This timer
						; is cosmetic, so retire the lost-window race without escalating it.
						try LoggerDebug("shortcuts",
								"Path-copy button rename stopped after the dialog closed: {1}.",
								Err.Message)
						return false
				}
		}
}

if Features["shortcuts"]["title_case"] {
		; Win + W (TitleCase)
		AddShortcut("#", "w", ConvertToTitleCase)

		; The same transform as the titlecase_selection action (infra/text_case.ahk).
		ConvertToTitleCase(*) {
				GestureTransformSelection(TextCaseToggleTitle)
		}
}

if Features["shortcuts"]["uppercase"] {
		; Win + U (Uppercase)
		AddShortcut("#", "u", ConvertToUppercase)

		; The same transform as the uppercase_selection action (infra/text_case.ahk).
		ConvertToUppercase(*) {
				GestureTransformSelection(TextCaseToggleUpper)
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
						Ui_MsgBox(t("shortcuts.no_other_monitor"))
						return
				}

				Point := MCGetPosStrict()
				CurX := Point["x"], CurY := Point["y"]

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
		AddShortcut("#", "'", (*) => (SpotlightPoint := MCGetPosStrict(), SpotlightMouseAt(SpotlightPoint["x"], SpotlightPoint["y"], 5000)))
}

; SpotlightMouseAt is defined in infra/spotlight.ahk and included globally before this module.

if Features["shortcuts"]["open_downloads"] {
		; Win + D (Downloads)
		AddShortcut("#", "d", OpenDownloads)

		OpenDownloads(*) {
				try {
						return _OpenDownloadsWith(GetKnownFolderDownloads, Run)
				} catch as Err {
						LoggerError("Shortcuts", "OpenDownloads failed: {1}", Err.Message)
						try TrayTip("Could not open Downloads.", "ErgoptiPlus", "Iconx Mute")
						return false
				}
		}

		; Explorer opens the current Shell-known path asynchronously, including a
		; folder redirected by the user or by company policy.
		_OpenDownloadsWith(ResolveFn, LaunchFn) {
				DownloadsPath := ResolveFn.Call()
				LaunchFn.Call('explorer.exe "' DownloadsPath '"')
				return true
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

		; The Downloads known-folder id is stable across display languages and
		; profile relocation. The Shell owns both its path and the allocated string.
		GetKnownFolderDownloads(CallFn := DllCall) {
				FolderId := Buffer(16, 0)
				NumPut("UInt", 0x374DE290, "UShort", 0x123F, "UShort", 0x4565,
						"UInt", 0xC4396491, "UInt", 0x7B465E92, FolderId)
				PathSlot := Buffer(A_PtrSize, 0)
				; Resolve the configured path even if its directory is temporarily offline.
				Result := CallFn.Call("shell32\SHGetKnownFolderPath", "Ptr", FolderId,
						"UInt", 0x4000, "Ptr", 0, "Ptr", PathSlot, "Int")
				PathPtr := NumGet(PathSlot, 0, "Ptr")
				try {
						if Result < 0
								throw Error(Format("Downloads known-folder lookup failed (HRESULT 0x{:08X}).", Result & 0xFFFFFFFF))
						if !PathPtr
								throw Error("Downloads known-folder lookup returned no path.")
						return StrGet(PathPtr, "UTF-16")
				} finally {
						if PathPtr
								CallFn.Call("ole32\CoTaskMemFree", "Ptr", PathPtr)
				}
		}

		; UriDecode is defined in infra/text_utils.ahk and visible globally.
}
