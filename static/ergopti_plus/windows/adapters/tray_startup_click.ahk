; adapters/tray_startup_click.ahk

; ==============================================================================
; MODULE: Tray Startup Click Admission
; DESCRIPTION:
; Observes native menu navigation and admits early context requests once the real
; bootstrap commands are installed. Headless probes may retain a request until
; publication instead of entering an interactive native loop.
; ==============================================================================

#Requires AutoHotkey v2.0

class TrayStartupClick {
	/**
	 * Installs one notification owner for a driver instance.
	 * @param {Func} ReadyFn Whether the usable root is available.
	 * @param {Func} ShowFn Optional native-menu presentation port.
	 * @param {Func} ScheduleFn Optional one-shot scheduler port.
	 * @param {Func} InstallFn Optional message registration port.
	 */
	__New(ReadyFn, ShowFn := 0, ScheduleFn := 0, InstallFn := 0,
			PopupFn := 0, CloseFn := 0, EarlyOwnerFn := 0, EarlyNativeFn := 0) {
		if !HasMethod(ReadyFn, "Call")
			throw TypeError("Tray startup admission requires a readiness owner")
		this.ReadyFn := ReadyFn
		this.PopupFn := PopupFn
		this.CloseFn := CloseFn
		this.EarlyOwnerFn := EarlyOwnerFn
		this.EarlyNativeFn := EarlyNativeFn
		this.Generation := 0
		this.Scheduled := false
		this.ShowFn := HasMethod(ShowFn, "Call") ? ShowFn : () => A_TrayMenu.Show()
		this.ScheduleFn := HasMethod(ScheduleFn, "Call") ? ScheduleFn : SetTimer
		this.Pending := false
		this.RequestCount := 0
		this.RequestedAt := 0
		this.MenuLoopOpen := false
		this.MenuLoopAt := 0
		this.OnMessageFn := ObjBindMethod(this, "OnTrayMessage")
		this.OnMenuLoopFn := ObjBindMethod(this, "OnNativeMenuLoop")
		Install := HasMethod(InstallFn, "Call") ? InstallFn : OnMessage
		Install.Call(0x404, this.OnMessageFn, 1)
		Install.Call(0x211, this.OnMenuLoopFn, 1)
		Install.Call(0x212, this.OnMenuLoopFn, 1)
	}

	OnNativeMenuLoop(wParam, lParam, msg, hwnd) {
		if (msg == 0x211 && !this.MenuLoopOpen) {
			this.MenuLoopAt := A_TickCount
			this.MenuLoopOpen := true
			try BootProfile_MenuNavigation(true)
			try LoggerStart("TrayMenu", "Native menu navigation started; AHK timers are blocked.")
		} else if (msg == 0x212 && this.MenuLoopOpen) {
			this.MenuLoopOpen := false
			try BootProfile_MenuNavigation(false)
			try LoggerSuccess("TrayMenu", "Native menu navigation ended after {1} ms; AHK timers can resume.",
				TickElapsed(this.MenuLoopAt))
		}
	}

	OnTrayMessage(wParam, lParam, msg, hwnd) {
		Notification := lParam & 0xFFFF
		; Leave balloon events and other native actions to their existing owners.
		if (Notification != 0x205 && Notification != 0x7B) || this.ReadyFn.Call()
			return
		if HasMethod(this.EarlyOwnerFn, "Call") && this.EarlyOwnerFn.Call()
			return 0
		if HasMethod(this.EarlyNativeFn, "Call") && this.EarlyNativeFn.Call() {
			if this.RequestCount > 0 {
				; A second bootstrap menu would suspend the remaining work again.
				; Retain this explicit request until the full root publishes instead.
				if !this.Pending
					this.RequestedAt := A_TickCount
				this.Pending := true
				this.RequestCount += 1
				try LoggerInfo("BootProfile", Format("Repeated early tray request retained for complete publication: requests={1}.",
					this.RequestCount))
				return 0
			}
			this.RequestCount += 1
			try LoggerInfo("BootProfile", Format("Early click admitted to the native tray: notification_lag={1} ms.",
				TickElapsed(DllCall("GetMessageTime", "UInt"))))
			return
		}
		if !this.Pending
			this.RequestedAt := A_TickCount
		this.Pending := true
		this.RequestCount += 1
		if HasMethod(this.PopupFn, "Call") {
			StartMs := BootClockWallMs()
			MessageLagMs := TickElapsed(DllCall("GetMessageTime", "UInt"))
			this.PopupFn.Call()
			this.PopupElapsedMs := BootClockWallMs() - StartMs
			try LoggerInfo("BootProfile", Format("Early tray callback completed: notification_lag={1} ms, callback={2:.3f} ms.",
				MessageLagMs, this.PopupElapsedMs))
		}
		; A numeric result consumes this notification before AHK enters its menu loop.
		return 0
	}

	NotifyReady() {
		if !this.ReadyFn.Call()
			throw Error("Tray startup requests cannot be released before root publication")
		if !this.Pending {
			if !this.Scheduled && HasMethod(this.CloseFn, "Call")
				this.CloseFn.Call()
			return false
		}
		this.Pending := false
		this.Scheduled := true
		this.ScheduleFn.Call(ObjBindMethod(this, "ShowPending", this.Generation), -1)
		return true
	}

	CancelPending() {
		this.Pending := false
		this.Scheduled := false
		this.Generation += 1
	}

	ShowPending(Generation) {
		if Generation != this.Generation || !this.ReadyFn.Call()
			return
		this.Scheduled := false
		try LoggerInfo("BootProfile", Format("Opening the ready tray after {1} early request(s); request wait={2} ms.",
			this.RequestCount, TickElapsed(this.RequestedAt)))
		if HasMethod(this.CloseFn, "Call")
			this.CloseFn.Call()
		this.ShowFn.Call()
	}
}
