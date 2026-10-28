; tests/live/live_checks.ahk

; ==============================================================================
; MODULE: Live Driver Checks
; DESCRIPTION:
; The commands the maintainer's Windows checks run against a real, isolated
; ErgoptiPlus.ahk (see live_harness.ahk). Each acts on the live process, the
; way the maintainer would, and reports one line the orchestrator judges.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ Observation =======
; ==============================
; ==============================

/** Reports the process and how many tray rows it holds. */
LiveCmdInfo(Args) {
	return "pid=" . ProcessExist() . " rows=" . LiveTrayRows().Length
		. " suspended=" . A_IsSuspended . " script=" . A_ScriptName
}

/** Writes the whole live tray tree, one row per line, to <dir>\live\tree.txt. */
LiveCmdTree(Args) {
	Text := ""
	for Row in LiveTrayRows() {
		Indent := ""
		loop Row.Path.Length - 1
			Indent .= "  "
		Text .= Indent . (Row.IsSub ? "[+] " : "") . Row.Caption . "  #" . Row.Id . " f=" . Row.Flags . "`n"
	}
	LiveWrite(LiveDir() . "\tree.txt", Text)
	return "rows=" . LiveTrayRows().Length
}

/** Lists the leaf rows whose caption matches the regular expression, one per line. */
LiveCmdRows(Args) {
	Text := ""
	for Row in LiveFindRows(Args[1], Args.Length >= 2 ? Args[2] : "") {
		Under := ""
		for Index, Part in Row.Path
			Under .= (Index > 1 ? " > " : "") . Part
		Text .= Under . (LiveRowChecked(Row) ? "  [checked]" : "") . (Row.Flags & 3 ? "  [disabled]" : "") . " | "
	}
	return Text
}

/**
 * Clicks the one leaf row reached by a path. Each argument names one level: a
 * plain text is an exact caption, "re:" a regular expression, "t:" a locale key.
 */
LiveCmdClick(Args) {
	Row := LiveRowByPath(Args)
	LiveClickRow(Row)
	return "clicked " . Row.Caption
}

/**
 * Posts the same row's click several times, pumping between them, as a user
 * who clicks again would. Arguments: the count, the pause in ms, then the path.
 */
LiveCmdClickRepeat(Args) {
	Count := Integer(Args[1])
	Pause := Integer(Args[2])
	Path := Args.Clone()
	Path.RemoveAt(1, 2)
	Row := LiveRowByPath(Path)
	loop Count {
		LiveClickRow(Row)
		LivePump(Pause)
	}
	return "clicked " . Count . " times " . Row.Caption
}

/**
 * Clicks the Reload row, waits until its successor is launched and the driver
 * is still waiting for it to close, then sends the local reload command's own
 * request (token, file and registered window message, as tools/control does)
 * into that window. Returns the result record the driver published.
 */
LiveCmdReloadRequestDuringReload(Args) {
	global _DriverControl
	if !IsObject(_DriverControl)
		throw Error("the driver control is not running")
	Row := LiveRowByPath(["re:Reload$"])
	LiveClickRow(Row)
	LiveWaitFor(() => ReloadTerminalHandoffPending() is Map, "the Reload click to launch its successor", 15000)
	Successor := ReloadTerminalHandoffPending()["successor"]["pid"]
	Id := "live-" . A_TickCount
	Request := '{"schema":1,"token":"' . _DriverControl.Token . '","request_id":"' . Id . '"}'
	File := FileOpen(_DriverControl.Folder . "\reload.request", "w", "UTF-8-RAW")
	File.Write(Request)
	File.Close()
	Message := DllCall("RegisterWindowMessageW", "Str", _DriverControl.Spec["windows_message"], "UInt")
	Acknowledged := 0
	Sent := DllCall("SendMessageTimeoutW", "Ptr", A_ScriptHwnd, "UInt", Message, "UPtr", ProcessExist(),
		"Ptr", HealthCheck_ControlCreationTime(), "UInt", 3, "UInt", 5000, "UPtr*", &Acknowledged, "Ptr")
	if !Sent || Acknowledged != 1
		throw Error("the driver control endpoint did not acknowledge the request")
	LivePump(600)
	Result := FileRead(_DriverControl.Folder . "\reload.result", "UTF-8")
	return "successor=" . Successor . " request=" . Id . " result=" . LiveOneLine(Result)
}

/** Pumps messages for the given milliseconds. */
LiveCmdPump(Args) {
	LivePump(Integer(Args[1]))
	return "pumped"
}





; ==========================
; ==========================
; ======= 2/ Dialogs =======
; ==========================
; ==========================

/**
 * Clicks a row that opens an input box, answers it and reports what it showed.
 * Arguments: the answer, the locale key of the dialog caption, then the row's
 * path (see LiveRowByPath).
 */
LiveCmdAnswerInputBox(Args) {
	Answer := Args[1]
	Title := WindowTitle(t(Args[2]))
	Path := Args.Clone()
	Path.RemoveAt(1, 2)
	Row := LiveRowByPath(Path)
	Seen := {Title: "", Initial: "", Prompt: ""}
	State := LiveDriveWindow(Title . " ahk_class #32770 ahk_pid " . ProcessExist(),
		_LiveAnswerInputBox.Bind(Seen, Answer))
	LiveClickRow(Row)
	LiveAwaitDrive(State, "the input box of '" . Row.Caption . "'")
	LivePump(200)
	return "title=" . Seen.Title . " initial=" . Seen.Initial . " prompt=" . Seen.Prompt
}

_LiveAnswerInputBox(Seen, Answer, Hwnd) {
	Seen.Title := WinGetTitle("ahk_id " . Hwnd)
	Seen.Initial := ControlGetText("Edit1", "ahk_id " . Hwnd)
	Seen.Prompt := ControlGetText("Static1", "ahk_id " . Hwnd)
	ControlSetText(Answer, "Edit1", "ahk_id " . Hwnd)
	ControlClick("Button1", "ahk_id " . Hwnd)
}

/**
 * Clicks a row that opens a window, reports the window's caption and class,
 * lets the page load a moment and closes it. Arguments: the row's path.
 */
LiveCmdOpenWindow(Args) {
	Row := LiveRowByPath(Args)
	Before := LiveVisibleWindows()
	Seen := {Hwnd: 0, Title: "", Class: ""}
	; A picker may be modal: the click's thread then waits for it, so the window
	; is observed and closed from a timer, which can run on top of that thread.
	State := LiveDriveWindow(() => LiveNewWindow(Before), _LiveObserveAndClose.Bind(Seen), 20000)
	LiveClickRow(Row)
	LiveAwaitDrive(State, "a window opened by '" . Row.Caption . "'")
	_LiveAwaitClosed(Seen)
	return "title=" . Seen.Title . " class=" . Seen.Class
}

/**
 * Records the caption and class of a window that just opened and schedules its
 * closing. A timer thread must not wait for the close itself: another timer
 * cannot interrupt it, and the window's own close handling may need one.
 */
_LiveObserveAndClose(Seen, Hwnd) {
	Seen.Hwnd := Hwnd
	Seen.Title := WinGetTitle("ahk_id " . Hwnd)
	Seen.Class := WinGetClass("ahk_id " . Hwnd)
	SetTimer(() => WinClose("ahk_id " . Hwnd), -1200)
}

/** Waits, on the main thread, for the window _LiveObserveAndClose scheduled to close. */
_LiveAwaitClosed(Seen) {
	LiveWaitFor(() => !WinExist("ahk_id " . Seen.Hwnd),
		"the window '" . Seen.Title . "' (" . Seen.Class . ") to close", 15000)
}

/**
 * Builds a key-combination pair's own menu through the driver's code, picks one
 * of its rows by the dispatcher path a click takes, and observes the window it
 * opens, like the user choosing « Tap → … » or « Hold → … ». The pair menu is
 * a native popup at the pointer, which no timer can drive while it is open, so
 * the build stops where the popup would be shown (its test seam). Arguments: a
 * regular expression naming the row to pick, the two key ids and the label.
 */
LiveCmdPairMenuPick(Args) {
	Pattern := Args[1]
	PairId := KeyCombinationPairId(Args[2], Args[3])
	Captured := {Menu: 0}
	KeyCombinationShowPairMenu(PairId, Args[4], (BuiltMenu) => Captured.Menu := BuiltMenu)
	if !(Captured.Menu is Menu)
		throw Error("the pair menu was not built")
	Handle := Captured.Menu.Handle
	Rows := ""
	Chosen := 0
	loop TrayMenuHandleItemCount(Handle) {
		Position := A_Index - 1
		Caption := TrayMenuHandleItemCaption(Handle, Position)
		Rows .= (Rows == "" ? "" : " / ") . Caption
		if !Chosen && Caption != "" && RegExMatch(Caption, Pattern)
			Chosen := TrayMenuHandleItemId(Handle, Position)
	}
	if !Chosen
		throw Error("no row of the pair menu matches '" . Pattern . "': " . Rows)
	Before := LiveVisibleWindows()
	Seen := {Hwnd: 0, Title: "", Class: ""}
	State := LiveDriveWindow(() => LiveNewWindow(Before), _LiveObserveAndClose.Bind(Seen), 25000)
	DllCall("PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x111, "UPtr", Chosen, "Ptr", 0, "Int")
	LiveAwaitDrive(State, "the window opened by '" . Pattern . "'")
	_LiveAwaitClosed(Seen)
	return "rows=" . Rows . " title=" . Seen.Title . " class=" . Seen.Class
}

/**
 * Clicks a row whose command may first ask a question the user must confirm
 * (enabling the metrics shows a security warning): a dialog of this process
 * whose caption matches the regular expression is answered with its first
 * button (Yes or OK) and reported; no dialog is not an error. Arguments: the
 * caption pattern, then the row's path.
 */
LiveCmdClickConfirming(Args) {
	Pattern := Args[1]
	Path := Args.Clone()
	Path.RemoveAt(1)
	Row := LiveRowByPath(Path)
	Seen := {Title: "", Text: ""}
	State := LiveDriveWindow(() => LiveDialogMatching(Pattern), _LiveConfirm.Bind(Seen), 8000, true)
	LiveClickRow(Row)
	LiveAwaitDrive(State, "the question of '" . Row.Caption . "'")
	return "dialog=" . (Seen.Title == "" ? "none" : Seen.Title)
}

_LiveConfirm(Seen, Hwnd) {
	Seen.Title := WinGetTitle("ahk_id " . Hwnd)
	ControlClick("Button1", "ahk_id " . Hwnd)
}

/**
 * Opens the unused-settings window and the API endpoint dialog for real and
 * reports the caption the operating system holds for each.
 */
LiveCmdWindowTitles(Args) {
	global ConfigurationFile
	if !ConfigCleanupWindow.Open(ConfigurationFile)
		throw Error("the unused-settings window did not open")
	Host := ConfigCleanupWindow.Current
	Unused := WinGetTitle("ahk_id " . Host.Gui.Hwnd)
	Host.Close()
	LivePump(300)

	Seen := {Title: "", Class: ""}
	State := LiveDriveWindow("ahk_class #32770 ahk_pid " . ProcessExist(), _LiveReadAndAcknowledge.Bind(Seen), 20000)
	SetTimer(_LLM_Menu_TestActiveApiEntry.Bind(0, ""), -1)
	LiveAwaitDrive(State, "the API endpoint dialog")
	return "unused=" . Unused . " api=" . Seen.Title
}

_LiveReadAndAcknowledge(Seen, Hwnd) {
	Seen.Title := WinGetTitle("ahk_id " . Hwnd)
	Seen.Class := WinGetClass("ahk_id " . Hwnd)
	ControlClick("Button1", "ahk_id " . Hwnd)
}





; =========================
; =========================
; ======= 3/ Typing =======
; =========================
; =========================

global _LiveEditGui := 0
global _LiveEdit := 0

/** Opens a window of this process with a focused edit control to receive typed keys. */
LiveCmdEditOpen(Args) {
	global _LiveEditGui, _LiveEdit
	if IsObject(_LiveEditGui)
		throw Error("the typing target is already open")
	Kind := Args.Length >= 1 ? Args[1] : "edit"
	_LiveEditGui := Gui("+AlwaysOnTop", "Ergopti live typing target")
	if Kind == "rich" {
		; A rich edit control deletes a word on Ctrl+Backspace, as Notepad does.
		DllCall("LoadLibraryW", "Str", "Msftedit.dll", "Ptr")
		_LiveEdit := _LiveEditGui.Add("Custom", "ClassRICHEDIT50W w520 h120 +0x200004 +0x40")
	} else
		_LiveEdit := _LiveEditGui.AddEdit("w520 h120 Multi WantTab", "")
	_LiveEditGui.Show("w560 h160")
	WinActivate("ahk_id " . _LiveEditGui.Hwnd)
	if !WinWaitActive("ahk_id " . _LiveEditGui.Hwnd, , 5)
		throw Error("the typing target did not take the foreground")
	_LiveEdit.Focus()
	LivePump(300)
	return "hwnd=" . _LiveEditGui.Hwnd
}

/** The text typed so far, with line breaks shown as the two characters backslash-n. */
LiveCmdEditValue(Args) {
	global _LiveEdit
	if !IsObject(_LiveEdit)
		throw Error("the typing target is not open")
	Text := ControlGetText(_LiveEdit.Hwnd)
	return "value=" . StrReplace(StrReplace(Text, "`r", ""), "`n", "\n")
}

/** Puts a text in the typing target and selects all of it, as a user would before Win+S. */
LiveCmdEditSelect(Args) {
	global _LiveEdit, _LiveEditGui
	ControlSetText(Args[1], _LiveEdit.Hwnd)
	WinActivate("ahk_id " . _LiveEditGui.Hwnd)
	_LiveEdit.Focus()
	SendMessage(0xB1, 0, -1, _LiveEdit.Hwnd)
	LivePump(150)
	return "selected"
}

/** What the hotstring engine believes has been typed since its last reset. */
LiveCmdHotstringBuffer(Args) {
	global HSE_Buffer
	return "buffer=" . HSE_Buffer
}

/** Turns CapsWord on or off as its trigger does, and reports whether it is on. */
LiveCmdCapsWordToggle(Args) {
	ToggleCapsWord()
	return "enabled=" . (CapsWordEnabled ? 1 : 0)
}

/** Whether CapsWord is on. */
LiveCmdCapsWordState(Args) {
	return "enabled=" . (CapsWordEnabled ? 1 : 0)
}

/** Forgets everything the hotstring engine has seen, as a word boundary the user left would. */
LiveCmdHotstringReset(Args) {
	HSE_HardReset()
	return "reset"
}

/** Empties the typing target and gives it the focus again. */
LiveCmdEditClear(Args) {
	global _LiveEdit, _LiveEditGui
	ControlSetText("", _LiveEdit.Hwnd)
	WinActivate("ahk_id " . _LiveEditGui.Hwnd)
	_LiveEdit.Focus()
	LivePump(150)
	return "cleared"
}

/** Closes the typing target. */
LiveCmdEditClose(Args) {
	global _LiveEdit, _LiveEditGui
	if IsObject(_LiveEditGui)
		_LiveEditGui.Destroy()
	_LiveEditGui := 0
	_LiveEdit := 0
	return "closed"
}





; ==================================
; ==================================
; ======= 4/ Versions window =======
; ==================================
; ==================================

/**
 * Opens the Versions window for real, waits for the fetched release list and
 * switches every channel tab, reporting after each whether the spinner showed,
 * which tab is active and how many releases are listed. The page filters the
 * list it holds, so a switch must answer inside the click.
 */
LiveCmdVersionsTabs(Args) {
	global _CLW_WebView
	; Under memory pressure the driver opens its lighter native window instead.
	if !_CLW_WebView2Available() || WebView_ShouldUseNativeFallback()
		throw Error("native fallback: the driver would open its native Versions window (WebView2 missing or free memory too low)")
	Changelog_Open(Args.Length >= 1 ? Args[1] : "stable")
	LiveWaitFor(() => IsSet(_CLW_WebView) && IsObject(_CLW_WebView), "the Versions window", 30000)
	Count := () => _LiveScript("document.querySelectorAll('#release-list .release-item').length")
	try LiveWaitFor(() => Count() > 0, "the release list", 90000)
	catch as Err
		throw Error("no release list arrived (the window needs the network): " . Err.Message)
	Tabs := _LiveScript("[...document.querySelectorAll('#channel-toggle [data-channel]')].map(function (b) { return b.getAttribute('data-channel'); })")
	Report := "tabs=" . Tabs.Length
	for Index, Id in Tabs {
		Seen := _LiveScript("(function () { var b = document.querySelectorAll('#channel-toggle [data-channel]')[" . (Index - 1) . "]; b.click();"
			. " var o = document.getElementById('loading-overlay');"
			. " return { active: document.querySelector('#channel-toggle .active').getAttribute('data-channel'),"
			. " spinner: (o && o.style.display !== 'none') ? 1 : 0,"
			. " rows: document.querySelectorAll('#release-list .release-item').length }; })()")
		Report .= " " . Id . "=" . Seen["active"] . "/spinner:" . Seen["spinner"] . "/rows:" . Seen["rows"]
	}
	Changelog_Close()
	return Report
}

/** Runs a script in the Versions page and returns its JSON result as AutoHotkey values. */
_LiveScript(Script) {
	global _CLW_WebView
	return JsonParse(_CLW_WebView.ExecuteScriptAsync(Script).await())
}





; ===============================
; ===============================
; ======= 5/ Config lease =======
; ===============================
; ===============================

global _LiveLeaseToken := 0

/** Takes the configuration write lease, as a save in progress holds it. */
LiveCmdLeaseHold(Args) {
	global ConfigurationFile, _LiveLeaseToken
	if IsObject(_LiveLeaseToken)
		throw Error("the live lease is already held")
	Token := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "live-check")
	if !(Token is Object)
		throw Error("the configuration lease was not free")
	_LiveLeaseToken := Token
	return "held"
}

/** Releases the lease LiveCmdLeaseHold took. */
LiveCmdLeaseRelease(Args) {
	global _LiveLeaseToken
	if !IsObject(_LiveLeaseToken)
		throw Error("no live lease is held")
	Released := _ConfigWriteLeaseRelease(_LiveLeaseToken)
	_LiveLeaseToken := 0
	return "released=" . Released
}

/** Lists the dialogs this process shows, so an error window cannot go unseen. */
LiveCmdDialogs(Args) {
	Text := ""
	for Title in LiveDialogs()
		Text .= (Text == "" ? "" : " | ") . Title
	return "dialogs=" . Text
}

/**
 * Assigns a key-combination pair's tap or hold the way its picker's choice does
 * (the same functions, which save the configuration and reload). Arguments: the
 * two key ids, "tap" or "hold", and for a tap the action id; a hold takes the
 * first holdable option the shared hold picker offers.
 */
LiveCmdPairAssign(Args) {
	PairId := KeyCombinationPairId(Args[1], Args[2])
	if Args[3] == "tap" {
		Done := SetKeyCombinationTap(PairId, Args[4])
		return "pair=" . PairId . " tap=" . Args[4] . " started=" . (Done ? 1 : 0)
	}
	HoldId := ""
	for Option in TapHoldHoldOptions() {
		if Option["kind"] != "none" {
			HoldId := Option["id"]
			break
		}
	}
	if HoldId == ""
		throw Error("the hold picker offers no holdable option")
	Done := SetKeyCombinationHold(PairId, HoldId)
	return "pair=" . PairId . " hold=" . HoldId . " started=" . (Done ? 1 : 0)
}

/** Reports a feature value as the live driver holds it, with its AutoHotkey type. Arguments: section, key. */
LiveCmdFeatureValue(Args) {
	global Features
	if !Features.Has(Args[1]) || !(Features[Args[1]] is Map) || !Features[Args[1]].Has(Args[2])
		return "feature=" . Args[1] . "." . Args[2] . " absent=1"
	Value := Features[Args[1]][Args[2]]
	return "feature=" . Args[1] . "." . Args[2] . " type=" . Type(Value) . " value=" . String(Value)
}

/** Reports what the dispatcher holds for a row: id, callback, token, flags. */
LiveCmdRowInfo(Args) {
	global _MenuDispatchCallbacks, _MenuDispatchTokens
	Row := LiveRowByPath(Args)
	return "id=" . Row.Id . " callback=" . _MenuDispatchCallbacks.Has(Row.Id)
		. " token=" . _MenuDispatchTokens.Has(Row.Id) . " flags=" . Row.Flags
}

LiveRegister("info", LiveCmdInfo)
LiveRegister("tree", LiveCmdTree)
LiveRegister("rows", LiveCmdRows)
LiveRegister("click", LiveCmdClick)
LiveRegister("rowinfo", LiveCmdRowInfo)
LiveRegister("click_repeat", LiveCmdClickRepeat)
LiveRegister("click_confirming", LiveCmdClickConfirming)
LiveRegister("reload_request_during_reload", LiveCmdReloadRequestDuringReload)
LiveRegister("pump", LiveCmdPump)
LiveRegister("answer_inputbox", LiveCmdAnswerInputBox)
LiveRegister("open_window", LiveCmdOpenWindow)
LiveRegister("edit_open", LiveCmdEditOpen)
LiveRegister("edit_value", LiveCmdEditValue)
LiveRegister("edit_clear", LiveCmdEditClear)
LiveRegister("edit_select", LiveCmdEditSelect)
LiveRegister("hse_buffer", LiveCmdHotstringBuffer)
LiveRegister("hse_reset", LiveCmdHotstringReset)
LiveRegister("capsword_toggle", LiveCmdCapsWordToggle)
LiveRegister("capsword_state", LiveCmdCapsWordState)
LiveRegister("edit_close", LiveCmdEditClose)
LiveRegister("versions_tabs", LiveCmdVersionsTabs)
LiveRegister("lease_hold", LiveCmdLeaseHold)
LiveRegister("lease_release", LiveCmdLeaseRelease)
LiveRegister("dialogs", LiveCmdDialogs)
LiveRegister("window_titles", LiveCmdWindowTitles)
LiveRegister("pair_assign", LiveCmdPairAssign)
LiveRegister("feature_value", LiveCmdFeatureValue)
LiveRegister("pair_menu_pick", LiveCmdPairMenuPick)
