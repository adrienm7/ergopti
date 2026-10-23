; ui/config_cleanup/init.ahk

; ==============================================================================
; MODULE: Configuration Cleanup Window
; DESCRIPTION:
; A bounded WebView preview over the existing backup-first cleanup transaction.
; The host owns the path, scan and source bytes; page messages name actions only.
; ==============================================================================

#Include ../../infra/webview_utils.ahk

class ConfigCleanupSession {
	static Sequence := 0
	Closed := false
	Busy := false
	Source := ""
	Scan := 0

	__New(Path) {
		ConfigCleanupSession.Sequence += 1
		this.Path := Path
		this.Token := String(ConfigCleanupSession.Sequence)
		this.State := Map("session", this.Token, "path", Path, "status", "empty", "keys", [])
	}

	; Captures the exact source around the scanner so a racing writer cannot
	; associate an older preview with newer confirmation bytes.
	Refresh(ReadFn := FSReadUtf8Exact, FindFn := ConfigUnusedKeysFind) {
		if this.Closed
			return 0
		Before := ReadFn.Call(this.Path)
		if this.Closed
			return 0
		Scan := FindFn.Call(this.Path)
		if this.Closed
			return 0
		After := ReadFn.Call(this.Path)
		; Every I/O may pump a close. Publish one snapshot only while the session
		; still owns it; a closed window must not recover its discarded scan.
		PreviousCritical := Critical("On")
		try {
			if this.Closed
				return 0
			this.Scan := Scan
			this.State["keys"] := Scan["keys"]
			this.State["reason_key"] := "dialog.unused_keys.reason.unreadable"
			if (Scan["status"] != "ok")
				this.State["status"] := "failed"
			else if !(Before == After)
				this.State["status"] := "changed"
			else {
				this.Source := After
				this.State["status"] := Scan["keys"].Length ? "ready" : "empty"
			}
			return this.State
		} finally Critical(PreviousCritical)
	}

	Close() {
		this.Closed := true
		this.Scan := 0
	}

	; Returns zero for an invalid, duplicate or stale action.
	Handle(Message) {
		if this.Closed || this.Busy
			return 0
		if (Message is String && Message == "ready")
			return this.Scan ? this.State : this.Refresh()
		if !(Message is Map)
			return 0
		Action := Message.Get("action", "")
		Token := Message.Get("session", "")
		if (Action == "close" && (Token == this.Token || Token == "")) {
			this.Close()
			return 0
		}
		if (Token !== this.Token)
			return 0
		if (Action == "refresh")
			return this.Refresh()
		if (Action != "clean" || this.State["status"] != "ready")
			return 0
		this.Busy := true
		try Result := ConfigUnusedKeysRemove(this.Path, this.Scan["keys"], , , , this.Source)
		finally this.Busy := false
		Status := Result["status"]
		this.State["status"] := Status
		if (Status == "removed") {
			this.State["keys"] := []
			this.State["backup"] := Result["backup"]
			this.State["removed"] := Result["removed"]
		} else if (Status != "changed") {
			this.State["status"] := "failed"
			Reasons := Map("backup_failed", "backup", "unreadable", "unreadable", "write_failed", "write")
			this.State["reason_key"] := "dialog.unused_keys.reason." . Reasons[Status]
		}
		return this.Closed ? 0 : this.State
	}

	; Encodes only the page contract, never the private source bytes.
	Json() {
		Fields := ""
		for Name in ["session", "path", "status", "backup", "reason_key"] {
			if this.State.Has(Name)
				Fields .= (Fields == "" ? "" : ",") . JsonStringLiteral(Name) . ":" . JsonStringLiteral(this.State[Name])
		}
		Rows := ""
		for Entry in this.State["keys"] {
			Row := ""
			for Name in ["section", "key", "value"]
				Row .= (Row == "" ? "" : ",") . JsonStringLiteral(Name) . ":" . JsonStringLiteral(Entry[Name])
			Rows .= (Rows == "" ? "" : ",") . "{" . Row . "}"
		}
		return "{" . Fields . ',"keys":[' . Rows . '],"removed":' . this.State.Get("removed", 0) . "}"
	}
}

class ConfigCleanupWindow extends WebViewHost {
	static Current := 0
	Building := false
	Cancelled := false

	static Open(Path) {
		Existing := ConfigCleanupWindow.Current
		if IsObject(Existing) && !Existing.ResetDone {
			if Existing.Building || Existing.Cancelled
				return false
			return WMPresentWindow(Existing.Gui)
		}
		WebViewHost._LoadManifest()
		Host := ConfigCleanupWindow()
		Host.AppId := "config_cleanup"
		Host.Session := ConfigCleanupSession(Path)
		; The host names the window from the manifest and adds the product name.
		Host.Opts := Map("NoActivate", true, "OnReady", (ReadyHost) => ReadyHost.Deliver("ready"),
			"OnMessage", (MessageHost, Message) => MessageHost.Deliver(Message))
		ConfigCleanupWindow.Current := Host
		try Built := Host._Build()
		catch as Err {
			Host.Close()
			LoggerError("ConfigCleanup", "The cleanup window could not be created: {1}.", Err.Message)
			Built := false
		}
		if Host.Cancelled
			return false
		if !Built {
			Host.Close()
			NotifierSend(t("healthcheck.status.failed"), Map("title", t("dialog.unused_keys.title"), "level", "warning"))
			return false
		}
		Host.Gui.OnEvent("Escape", (*) => Host.Close())
		return true
	}

	; Native creation pumps messages. Keep the Gui alive until the controller
	; returns, then release any cancelled build before Open can publish it.
	_Build() {
		this.Building := true
		try return super._Build()
		finally {
			this.Building := false
			if this.Cancelled
				this.Close()
		}
	}

	_Geometry() {
		Geo := super._Geometry()
		MonitorGetWorkArea(MonitorGetPrimary(), &Left, &Top, &Right, &Bottom)
		Scale := A_ScreenDPI / 96
		Geo.w := Min(Geo.w, Floor((Right - Left) / Scale))
		Geo.h := Min(Geo.h, Floor((Bottom - Top - SysGet(4) - 2 * SysGet(33)) / Scale))
		Geo.min_w := Min(Geo.min_w, Geo.w)
		Geo.min_h := Min(Geo.min_h, Geo.h)
		return Geo
	}

	; A confirmation can arrive while another configuration write holds its lease:
	; the page message interrupts that writer's thread, which keeps the lease
	; until this one returns, so running the cleanup now could only be refused.
	; It waits for the write through the menu commands' bounded deferral instead.
	; @param Message {String|Map} Page message.
	; @param BusyFn {Func} Test seam: whether a configuration write is in progress.
	; @param ArmFn {Func} Test seam for the one-shot retry timer.
	Deliver(Message, BusyFn := 0, ArmFn := 0) {
		if this.ResetDone || this.Cancelled
			return
		if (Message is Map) && Message.Get("action", "") == "clean" {
			MenuCommandRun(ObjBindMethod(this, "_DeliverNow"), [Message], 0, BusyFn, ArmFn)
			return
		}
		this._DeliverNow(Message)
	}

	_DeliverNow(Message) {
		if this.ResetDone || this.Cancelled
			return
		if this.Session.Handle(Message)
			this.Eval("window.receiveConfigCleanup(" . this.Session.Json() . ")")
		if this.Session.Closed
			this.Close()
	}

	Close() {
		this.Cancelled := true
		this.Session.Close()
		if this.Building {
			if this.Gui {
				try this.Gui.Hide()
				catch as Err
					LoggerWarn("ConfigCleanup", "The closing cleanup window could not be hidden: {1}.", Err.Message)
			}
			return
		}
		super.Close()
		if (ConfigCleanupWindow.Current == this)
			ConfigCleanupWindow.Current := 0
	}
}
