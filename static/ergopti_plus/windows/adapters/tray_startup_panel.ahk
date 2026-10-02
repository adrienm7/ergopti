; adapters/tray_startup_panel.ahk

; ==============================================================================
; MODULE: Modeless Tray Startup Commands
; DESCRIPTION:
; A context click during initialization gets immediate visual feedback without
; entering a native menu loop. Lifecycle commands retain one explicit intent
; until the input owner is ready; the native root takes over after full publication.
; ==============================================================================

#Requires AutoHotkey v2.0

class TrayStartupPanel {
	/**
	 * Owns one temporary command surface and at most one pending command.
	 * @param {Func} ReadyFn Whether lifecycle commands may execute.
	 * @param {Func} CommandFn Admitted command dispatch port.
	 * @param {Func} ScheduleFn One-shot scheduling port.
	 * @param {Func} DismissFn Cancels an outstanding context-menu request.
	 */
	__New(ReadyFn, CommandFn, ScheduleFn := 0, DismissFn := 0) {
		if !HasMethod(ReadyFn, "Call") || !HasMethod(CommandFn, "Call")
			throw TypeError("Startup commands require readiness and dispatch owners")
		this.ReadyFn := ReadyFn
		this.CommandFn := CommandFn
		this.ScheduleFn := HasMethod(ScheduleFn, "Call") ? ScheduleFn : SetTimer
		this.DismissFn := DismissFn
		this.Surface := 0
		this.Pending := ""
		this.Active := true
		this.DispatchFn := ObjBindMethod(this, "Dispatch")
	}

	Prepare() {
		if !this.Active
			return false
		if !IsObject(this.Surface) {
			G := Gui_Create("+ToolWindow -MinimizeBox -MaximizeBox", t("common.loading"))
			G.SetFont("s10")
			this.Status := G.Add("Text", "w260", t("common.loading"))
			this.Buttons := []
			for Id in ["suspend", "reload", "quit"] {
				Button := G.Add("Button", "w260", t("menu.global." . Id))
				Button.OnEvent("Click", ObjBindMethod(this, "Request", Id))
				this.Buttons.Push(Button)
			}
			G.OnEvent("Close", ObjBindMethod(this, "Dismiss"))
			G.OnEvent("Escape", ObjBindMethod(this, "Dismiss"))
			this.Surface := G
			; Autosize once while hidden so the first click only reveals cached controls.
			G.Show("Hide AutoSize")
		}
		this.Refresh()
		return true
	}

	Show(Options := "") {
		if !this.Prepare()
			return false
		if Options == "" {
			CoordMode("Mouse", "Screen")
			MouseGetPos(&X, &Y)
			WinGetPos(, , &Width, &Height, this.Surface.Hwnd)
			loop MonitorGetCount() {
				MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
				if X < Left || X >= Right || Y < Top || Y >= Bottom
					continue
				MonitorGetWorkArea(A_Index, &Left, &Top, &Right, &Bottom)
				Pos := TrayStartupPanelPosition(X, Y, Width, Height, Left, Top, Right, Bottom)
				; Win32 coordinates avoid applying AHK's GUI DPI scale twice.
				if !DllCall("SetWindowPos", "Ptr", this.Surface.Hwnd, "Ptr", 0,
					"Int", Pos.X, "Int", Pos.Y, "Int", 0, "Int", 0, "UInt", 0x15)
					throw OSError()
				break
			}
			Options := ""
		}
		this.Surface.Show(Options)
		return true
	}

	Refresh() {
		if !IsObject(this.Surface)
			return
		this.Status.Text := t("common.loading")
		local Index, Id
		for Index, Id in ["suspend", "reload", "quit"] {
			this.Buttons[Index].Text := t("menu.global." . Id)
			this.Buttons[Index].Enabled := this.Pending == ""
		}
	}

	Request(Id, *) {
		if !this.Active || this.Pending != ""
			return false
		if Id != "suspend" && Id != "reload" && Id != "quit"
			throw ValueError("Unknown startup command", -1, Id)
		this.Pending := Id
		; A command click consumes the request to open the eventual native menu.
		if HasMethod(this.DismissFn, "Call")
			this.DismissFn.Call()
		this.Refresh()
		try LoggerInfo("BootProfile", Format("Startup command '{1}' admitted (input_ready={2}).", Id, this.ReadyFn.Call()))
		if this.ReadyFn.Call()
			this.ScheduleFn.Call(this.DispatchFn, -1)
		return true
	}

	NotifyReady() {
		if !this.Active || !this.ReadyFn.Call()
			return false
		this.Refresh()
		if this.Pending != ""
			this.ScheduleFn.Call(this.DispatchFn, -1)
		return true
	}

	Dispatch() {
		if !this.Active || !this.ReadyFn.Call() || this.Pending == ""
			return false
		Id := this.Pending
		this.Pending := ""
		this.Dismiss()
		this.CommandFn.Call(Id)
		return true
	}

	Dismiss(*) {
		this.Pending := ""
		if IsObject(this.Surface) {
			this.Surface.Destroy()
			this.Surface := 0
		}
		if HasMethod(this.DismissFn, "Call")
			this.DismissFn.Call()
	}

	Retire() {
		this.Active := false
		this.Dismiss()
	}

	Complete() {
		; A queued command still owns its callback even if menu construction wins.
		if this.Pending != ""
			return false
		this.Retire()
		return true
	}
}

/** Keeps a physical-size panel above/left of the cursor inside its work area. */
TrayStartupPanelPosition(X, Y, Width, Height, Left, Top, Right, Bottom) {
	if Width <= 0 || Height <= 0 || Right <= Left || Bottom <= Top
		throw ValueError("Startup panel geometry must have positive dimensions")
	return {X: Max(Left, Min(X - Width, Right - Width)),
		Y: Max(Top, Min(Y - Height, Bottom - Height))}
}

/** First-run setup owns early tray clicks because its process never becomes ready. */
TrayStartupOnboarding() {
	global _ob_gui
	if !IsOnboardingActive()
		return false
	if IsSet(_ob_gui) && IsObject(_ob_gui)
		WMPresentWindow(_ob_gui)
	return true
}

/** Dispatches admitted startup intents through the ordinary menu command owner. */
TrayStartupCommand(Id) {
	Commands := Map("suspend", ToggleSuspend, "reload", ActivateReload, "quit", ActivateExitApp)
	return MenuCommandRun(Commands[Id], [])
}
