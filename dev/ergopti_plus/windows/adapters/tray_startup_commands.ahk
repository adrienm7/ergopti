; adapters/tray_startup_commands.ahk

; ==============================================================================
; MODULE: Native Tray Startup Commands
; DESCRIPTION:
; The actual tray root exposes lifecycle commands before input initialization.
; Retain one accepted intent until its ordinary command owner becomes ready.
; No temporary window, placeholder or loading surface is constructed.
; ==============================================================================

#Requires AutoHotkey v2.0

class TrayStartupCommands {
	/** Owns at most one command accepted from the native bootstrap root. */
	__New(ReadyFn, CommandFn, ScheduleFn := 0) {
		if !HasMethod(ReadyFn, "Call") || !HasMethod(CommandFn, "Call")
			throw TypeError("Startup commands require readiness and dispatch owners")
		this.ReadyFn := ReadyFn
		this.CommandFn := CommandFn
		this.ScheduleFn := HasMethod(ScheduleFn, "Call") ? ScheduleFn : SetTimer
		this.Pending := ""
		this.Active := true
		this.DispatchFn := ObjBindMethod(this, "Dispatch")
	}

	Request(Id, *) {
		if !this.Active || this.Pending != ""
			return false
		if Id != "suspend" && Id != "reload" && Id != "quit"
			throw ValueError("Unknown startup command", -1, Id)
		this.Pending := Id
		try LoggerInfo("BootProfile", Format("Native startup command '{1}' admitted (input_ready={2}).",
			Id, this.ReadyFn.Call()))
		if this.ReadyFn.Call()
			this.ScheduleFn.Call(this.DispatchFn, -1)
		return true
	}

	NotifyReady() {
		if !this.Active || !this.ReadyFn.Call()
			return false
		if this.Pending != ""
			this.ScheduleFn.Call(this.DispatchFn, -1)
		return true
	}

	Dispatch() {
		if !this.Active || !this.ReadyFn.Call() || this.Pending == ""
			return false
		Id := this.Pending
		this.Pending := ""
		this.CommandFn.Call(Id)
		return true
	}

	Retire() {
		this.Active := false
		this.Pending := ""
	}

	Complete() {
		if this.Pending != ""
			return false
		this.Retire()
		return true
	}
}

/** First-run setup owns tray requests because that process never becomes ready. */
TrayStartupOnboarding() {
	global _ob_gui, ConfigurationFile
	if !FileExist(ConfigurationFile)
		return true
	if !IsOnboardingActive()
		return false
	if IsSet(_ob_gui) && IsObject(_ob_gui)
		WMPresentWindow(_ob_gui)
	return true
}

/** Executes admitted intents through the ordinary menu command owner. */
TrayStartupCommand(Id) {
	Commands := Map("suspend", ToggleSuspend, "reload", ActivateReload, "quit", ActivateExitApp)
	return MenuCommandRun(MenuStartupSafeCommand(Commands[Id]), [])
}
