; ui/emulation_picker/init.ahk

; ==============================================================================
; MODULE: Emulation Picker Window
; DESCRIPTION:
; « Layout to emulate › Others… » on Windows: the shared picker page
; (_shared/ui/emulation_picker) in a WebView2 window, every layout the
; emulation can type behind a search field (maintainer decision of 2026-11-25).
; The menu hands it the choices and the same write its rows run, so a layout
; chosen here applies as a menu click does. The macOS and Linux hosts answer
; the same messages through _shared/layouts/engine/emulation/picker_session.lua.
; ==============================================================================

#Include %A_LineFile%\..\..\..\core\ui\engine\webview\availability.ahk
#Include %A_LineFile%\..\..\..\core\ui\engine\webview\utils.ahk

/**
 * The page contract of one picker window: the page sends the id chosen with
 * the session token, and only a choice it was offered is admitted.
 */
class EmulationPickerSession {
	static Sequence := 0
	Closed := false
	Busy := false
	Offered := 0

	/**
	 * @param {Array} Choices Maps { id, label, current }.
	 * @param {Func} ChooseFn (Id) => whether the choice was applied.
	 */
	__New(Choices, ChooseFn) {
		if !(Choices is Array) || !HasMethod(ChooseFn, "Call")
			throw TypeError("The emulation picker needs its choices and choose ports.")
		EmulationPickerSession.Sequence += 1
		this.Token := "emulation-picker-" . EmulationPickerSession.Sequence
		this.Choices := Choices
		this.ChooseFn := ChooseFn
	}

	/**
	 * Handles one page message.
	 * @param {String|Map} Message "ready", or { action: choose|cancel, session, id }.
	 * @returns {Map} { reply: the page state or "", close: whether the window closes }.
	 */
	Handle(Message) {
		Ignored := Map("reply", "", "close", false)
		if this.Closed || this.Busy
			return Ignored
		if (Message is String) {
			if Message != "ready"
				return Ignored
			this.Offered := this.Choices
			return Map("reply", this.Json(false), "close", false)
		}
		if !(Message is Map)
			return Ignored
		Action := Message.Get("action", "")
		Token := Message.Get("session", "")
		; The page may close before its choices arrived: it has no token yet.
		if Action == "cancel" && (Token == this.Token || Token == "") {
			this.Closed := true
			return Map("reply", "", "close", true)
		}
		if Action != "choose" || Token !== this.Token || !(this.Offered is Array)
			return Ignored
		Id := Message.Get("id", "")
		Offered := false
		for Choice in this.Offered
			Offered := Offered || (Id is String && Choice["id"] == Id)
		if !Offered
			return Ignored
		this.Busy := true
		try Applied := this.ChooseFn.Call(Id)
		finally this.Busy := false
		if Applied == true {
			this.Closed := true
			return Map("reply", "", "close", true)
		}
		return Map("reply", this.Json(true), "close", false)
	}

	/** Ends the session: later messages are refused. */
	Close() {
		this.Closed := true
	}

	/**
	 * The state the page receives, as JSON.
	 * @param {Boolean} Refused Whether the last choice was refused.
	 * @returns {String}
	 */
	Json(Refused) {
		Rows := ""
		for Choice in this.Offered
			Rows .= (Rows == "" ? "" : ",") . "{" . JsonStringLiteral("id") . ":" . JsonStringLiteral(Choice["id"])
				. "," . JsonStringLiteral("label") . ":" . JsonStringLiteral(Choice["label"])
				. "," . JsonStringLiteral("current") . ":" . (Choice["current"] ? "true" : "false") . "}"
		return "{" . JsonStringLiteral("session") . ":" . JsonStringLiteral(this.Token)
			. "," . JsonStringLiteral("choices") . ":[" . Rows . "]"
			. (Refused ? "," . JsonStringLiteral("refused") . ":true" : "") . "}"
	}
}

/**
 * Opens the picker, or brings forward the one already open with its session.
 * @param {Array} Choices Maps { id, label, current }, « None » left to the menu.
 * @param {Func} ChooseFn (Id) => whether the choice was applied.
 * @param {Func} OpenFn Test seam: OpenFn(Opts) with WebViewHost.TryOpen's result.
 * @returns {Boolean} Whether a window is open.
 */
EmulationPicker_Open(Choices, ChooseFn, OpenFn := 0) {
	if !HasMethod(OpenFn, "Call")
		OpenFn := (Opts) => WebViewHost.TryOpen("emulation_picker", Opts)
	Session := EmulationPickerSession(Choices, ChooseFn)
	LoggerInfo("EmulationPicker", "Opening the emulation picker with {1} layout(s).", Choices.Length)
	; The emulated layout is configuration: it is chosen while paused, as from the
	; menu (EDD-1). The page owns Escape, as Cancel.
	Host := OpenFn.Call(Map("RunsWhilePaused", true,
		"OnReady", (ReadyHost) => EmulationPicker_Deliver(ReadyHost, Session, "ready"),
		"OnMessage", (MessageHost, Message) => EmulationPicker_Deliver(MessageHost, Session, Message)))
	return IsObject(Host)
}

/**
 * Hands one page message to its session and carries out the answer.
 * @param {Object} Host The window's WebViewHost.
 * @param {EmulationPickerSession} Session
 * @param {String|Map} Message
 */
EmulationPicker_Deliver(Host, Session, Message) {
	Result := Session.Handle(Message)
	if Result["close"] {
		Host.Close()
		LoggerInfo("EmulationPicker", "Emulation picker window closed.")
		return
	}
	if Result["reply"] != ""
		Host.Eval("window.receiveEmulationPicker(" . Result["reply"] . ")")
}
