; ui/download_window/init.ahk

; ==============================================================================
; MODULE: Managed Download Failure Window
; DESCRIPTION:
; The live updater failure surface uses the shared download window and the
; existing native WebViewHost. Exact document, controller, window session and
; failure epoch checks precede action dispatch. Native receipts remain private.
; ==============================================================================

#Requires AutoHotkey v2.0

; Configured into the updater's staging producer by root boot, never the page.
; @param Failure {Map} Native valid/reason/receipt envelope from the staging parser.
; @param Owner {Map} Exact private terminal updater request.
; @returns {Boolean} True when a current failure window is created or refreshed.
_Updater_ShowManagedDownloadFailure(Failure, Owner) {
	if !(Failure is Map) || !(Owner is Map)
		|| !(_ManagedNetwork_Equal(Failure.Get("reason", ""), "download")
			|| _ManagedNetwork_Equal(Failure.Get("reason", ""), "deadline"))
		|| !_Updater_ManagedFailureOwnerIsCurrent(Owner)
		return false
	Receipt := _ManagedNetworkWindows_True(Failure.Get("valid", false)) ? Failure.Get("receipt", Map()) : Map()
	if !(Receipt is Map)
		Receipt := Map()
	return ManagedDownloadFailureWindow.Show(Receipt, Owner,
		_Updater_ManagedFailureOwnerIsCurrent.Bind(Owner), _Updater_RetryManagedFailure.Bind(Owner))
}

; A delayed retirement may close only the same exact private request it captured.
; @param Owner {Map} Retired updater request.
_Updater_RetireManagedDownloadFailure(Owner) {
	Host := ManagedDownloadFailureWindow.Current
	if IsObject(Host) && Host.Failure.Owner == Owner
		Host.Close()
}

class ManagedDownloadFailureWindow extends WebViewHost {
	static Current := 0
	Building := false
	Cancelled := false
	DocumentUrl := ""
	DocumentPrefix := ""
	RenderedEpoch := 0
	RenderWork := 0
	RenderBudget := 0
	TimerFn := SetTimer
	NativeMode := false
	TerminalClosedFn := 0
	FallbackFn := 0

	static Show(Receipt, Owner, IsCurrentFn, RetryFn := 0, OwnedFolderFn := 0, SafeReport := false, TitleKey := "download_window.window_title", FallbackFn := 0, ClosedFn := 0) {
		_ManagedNetworkWindows_RequireInitialized()
		Existing := ManagedDownloadFailureWindow.Current
		if IsObject(Existing) && Existing.NativeMode {
			Existing.Close()
			Existing := ManagedDownloadFailureWindow.Current
		}
		if IsObject(Existing) && !Existing.ResetDone && !Existing.Cancelled {
			PublishFn := SafeReport ? Existing.Failure.PublishReport.Bind(Existing.Failure) : Existing.Failure.Publish.Bind(Existing.Failure)
			if Existing.Building || !PublishFn.Call(Receipt, Owner, IsCurrentFn, RetryFn, OwnedFolderFn)
				return false
			OldClosed := Existing.TerminalClosedFn
			Existing.TerminalClosedFn := ClosedFn
			Existing.FallbackFn := FallbackFn
			Existing.Opts["Title"] := t(TitleKey)
			if HasMethod(OldClosed, "Call")
				OldClosed.Call()
			return Existing.Publish()
		}
		if WebViewHost._Instances.Has("download_window")
			return false
		WebViewHost._LoadManifest()
		Host := ManagedDownloadFailureWindow()
		Host.AppId := "download_window"
		Host.Failure := ManagedDownloadFailureSession()
		Host.Opts := Map("Title", t(TitleKey), "NoActivate", true)
		Host.TerminalClosedFn := ClosedFn
		Host.FallbackFn := FallbackFn
		PublishFn := SafeReport ? Host.Failure.PublishReport.Bind(Host.Failure) : Host.Failure.Publish.Bind(Host.Failure)
		if !PublishFn.Call(Receipt, Owner, IsCurrentFn, RetryFn, OwnedFolderFn)
			return false
		if !Host._ReserveCurrent(Existing) {
			Host.Failure.Close()
			return false
		}
		try Built := Host._Build()
		catch Any as Err {
			LoggerWarn("ManagedDownload", "The failure window could not be built (error_type={1}).", Type(Err))
			return Host._InitialFallback()
		}
		if !Built || Host.Cancelled || !Host._FailureIsCurrent(Owner, Host.Failure.Epoch)
			return Host._InitialFallback()
		PreviousCritical := Critical("On")
		try {
			Admitted := ManagedDownloadFailureWindow.Current == Host && !WebViewHost._Instances.Has("download_window")
			if Admitted
				WebViewHost._Instances["download_window"] := Host
		} finally {
			Critical(PreviousCritical)
		}
		if !Admitted {
			Host.Close()
			return false
		}
		Host.Gui.OnEvent("Escape", (*) => Host.Close())
		return Host.Publish()
	}


	; Native admission probes may reenter Show before the build starts.
	; Reserve only if the captured singleton and the factory registry are unchanged.
	_ReserveCurrent(ExpectedExisting) {
		PreviousCritical := Critical("On")
		try {
			if ManagedDownloadFailureWindow.Current != ExpectedExisting || WebViewHost._Instances.Has(this.AppId)
				return false
			ManagedDownloadFailureWindow.Current := this
			return true
		} finally {
			Critical(PreviousCritical)
		}
	}

	; A distinct native origin for every host also fences retained controller caches.
	_VhostName() {
		return super._VhostName() . ".session" . this.Failure.Id
	}

	_Build() {
		this.Building := true
		this.DocumentPrefix := "https://" . this._VhostName() . "/ui/download_window/index.html?cb="
		try {
			return super._Build() && !this.Cancelled
		} finally {
			this.Building := false
			if this.Cancelled
				this.Close()
		}
	}

	_HostIsCurrent(ExpectedWindowEpoch) {
		return !A_IsSuspended && !this.ResetDone && !this.Cancelled && !this.Building
			&& ExpectedWindowEpoch == this.Epoch && ManagedDownloadFailureWindow.Current == this
			&& this.HasOwnProp("WebView")
	}

	_NativeIsCurrent(ExpectedWindowEpoch) {
		return this._HostIsCurrent(ExpectedWindowEpoch) && this.DocumentUrl != ""
	}

	; Navigate is asynchronous: capture its admitted actual URL only after navigation.
	; Every subsequent callback and script uses this exact immutable document URL.
	_CaptureDocument(Source, ExpectedWindowEpoch) {
		if !this._HostIsCurrent(ExpectedWindowEpoch) || !(Source is String)
			return false
		if this.DocumentUrl != ""
			return StrCompare(Source, this.DocumentUrl, true) == 0
		Prefix := this.DocumentPrefix
		if Prefix == "" || SubStr(Source, 1, StrLen(Prefix)) != Prefix
			|| !RegExMatch(SubStr(Source, StrLen(Prefix) + 1), "^[0-9]+$")
			return false
		this.DocumentUrl := Source
		return this._NativeIsCurrent(ExpectedWindowEpoch)
	}


	; COM reads can pump replacement, navigation, or producer retirement.
	_DocumentIsCurrent(ExpectedWindowEpoch, ExpectedController) {
		if !this._NativeIsCurrent(ExpectedWindowEpoch) || this.WebView != ExpectedController
			return false
		try Source := ExpectedController.Source
		catch
			return false
		return this._NativeIsCurrent(ExpectedWindowEpoch) && this.WebView == ExpectedController
			&& Source is String && StrCompare(Source, this.DocumentUrl, true) == 0
	}

	_PresentationAdmission(ExpectedWindowEpoch, ExpectedController, Owner, FailureEpoch) {
		Work := this.RenderWork
		if IsObject(Work) && Work.owner == Owner && Work.failure_epoch == FailureEpoch
			&& TickExpired64(Work.start_tick, Work.duration_ms, ManagedNetworkFailureWindows_Now()) {
			this._RenderAcknowledgementExpired(Work)
			return false
		}
		if !this._FailureIsCurrent(Owner, FailureEpoch) || !this._DocumentIsCurrent(ExpectedWindowEpoch, ExpectedController)
			return false
		; Recheck the native producer after COM reentry, then reread its document.
		if !this.Failure.IsCurrent(Owner, FailureEpoch) || !this._DocumentIsCurrent(ExpectedWindowEpoch, ExpectedController)
			return false
		return !this.Failure.Closed && this.Failure.Owner == Owner && this.Failure.Epoch == FailureEpoch
	}

	_FailureIsCurrent(Owner, FailureEpoch) {
		return this._HostIsCurrent(this.Epoch) && this.Failure.IsCurrent(Owner, FailureEpoch)
	}

	_OnWebMessage(Handler, Args) {
		ExpectedWindowEpoch := this.Epoch
		if !this._HostIsCurrent(ExpectedWindowEpoch)
			return
		; The vendored wrapper creates a fresh sender facade for COM callbacks.
		; Compare its actual native pointer, not AHK wrapper object identity.
		if !IsObject(Handler) || !HasProp(Handler, "Ptr") || !HasProp(this.WebView, "Ptr") || Handler.Ptr != this.WebView.Ptr
			return
		ExpectedController := this.WebView
		try Source := Args.Source
		catch
			return
		if !this._CaptureDocument(Source, ExpectedWindowEpoch) || !this._NativeIsCurrent(ExpectedWindowEpoch) || this.WebView != ExpectedController
			return
		try Raw := Args.TryGetWebMessageAsString()
		catch
			return
		if !this._NativeIsCurrent(ExpectedWindowEpoch) || this.WebView != ExpectedController || !(Raw is String)
			|| StrLen(Raw) > 2048 || InStr(Raw, Chr(0))
			return
		if _ManagedNetwork_Equal(Raw, "ready") {
			this._FlushQueue()
			return
		}
		try Payload := JsonParse(Raw)
		catch
			return
		if !(Payload is Map)
			return
		this.TimerFn.Call(this.Deliver.Bind(this, ExpectedWindowEpoch, Payload, ExpectedController), -1)
	}

	_OnNavigationCompleted(Handler, Args) {
		ExpectedWindowEpoch := this.Epoch
		if !this._HostIsCurrent(ExpectedWindowEpoch)
			return
		try Source := this.WebView.Source
		catch
			return
		if this._CaptureDocument(Source, ExpectedWindowEpoch)
			this._FlushQueue()
	}

	Deliver(ExpectedWindowEpoch, Payload, ExpectedController := 0) {
		if !this._NativeIsCurrent(ExpectedWindowEpoch)
			return false
		if !IsObject(ExpectedController)
			ExpectedController := this.WebView
		if !this._DocumentIsCurrent(ExpectedWindowEpoch, ExpectedController)
			return false
		FailureEpoch := this.Failure.Epoch
		Owner := this.Failure.Owner
		CurrentFn := this._PresentationAdmission.Bind(this, ExpectedWindowEpoch, ExpectedController, Owner, FailureEpoch)
		if _ManagedNetwork_Equal(_ManagedNetwork_Get(Payload, "action"), "failure_rendered") {
			Session := _ManagedNetwork_Get(Payload, "session")
			Epoch := _ManagedNetwork_Get(Payload, "epoch")
			if !(Session is Integer) || Session != this.Failure.Id || !(Epoch is Integer) || Epoch != FailureEpoch
				|| !CurrentFn.Call()
				return false
			Work := this.RenderWork
			if !IsObject(Work) || Work.owner != Owner || Work.failure_epoch != FailureEpoch || Work.window_epoch != ExpectedWindowEpoch
				return false
			if TickExpired64(Work.start_tick, Work.duration_ms, ManagedNetworkFailureWindows_Now()) {
				this._RenderAcknowledgementExpired(Work)
				return false
			}
			if !CurrentFn.Call() || this.RenderWork != Work
				return false
			if _ManagedNetworkWindows_True(_ManagedNetwork_Get(Payload, "ok")) {
				PreviousCritical := Critical("On")
				try {
					if !this._HostIsCurrent(ExpectedWindowEpoch) || this.Failure.Owner != Owner || this.Failure.Epoch != FailureEpoch || this.RenderWork != Work
						return false
					; A_TickCount is native monotonic and does not perform COM/I/O.
					Expired := TickExpired64(Work.start_tick, Work.duration_ms, ManagedNetworkFailureWindows_Now())
					if this.RenderWork != Work || this.Failure.Owner != Owner || this.Failure.Epoch != FailureEpoch
						return false
					if !Expired
						this.RenderedEpoch := FailureEpoch
				} finally {
					Critical(PreviousCritical)
				}
				if Expired {
					this._RenderAcknowledgementExpired(Work)
					return false
				}
				this._CancelRenderAcknowledgement(Work)
				return true
			}
			this._SurfaceFallback(ExpectedWindowEpoch, Owner, FailureEpoch, Work)
			return false
		}
		try Accepted := this.Failure.Handle(Payload, CurrentFn)
		catch Any as Err {
			LoggerWarn("ManagedDownload", "The failure action was refused (error_type={1}).", Type(Err))
			return false
		}
		if this.Failure.Owner == 0 && this.Failure.Epoch == FailureEpoch + 1
			this.Close()
		return Accepted
	}

	; Read actual translated bytes before the shared renderer runs; no language fallback.
	_LocaleScript() {
		global _SharedDir, _I18nLocale
		Raw := FileRead(_SharedDir . "\data\locales\" . _I18nLocale . ".json", "UTF-8")
		if !(JsonParse(Raw) is Map)
			throw TypeError("The managed failure locale is invalid")
		return "window._i18n_strings=" . Raw . ";window.i18n_apply(window._i18n_strings);"
	}

	Publish() {
		Owner := this.Failure.Owner
		FailureEpoch := this.Failure.Epoch
		if !this._FailureIsCurrent(Owner, FailureEpoch)
			return false
		Report := this.Failure.Report
		LocaleScript := this._LocaleScript()
		if !this._FailureIsCurrent(Owner, FailureEpoch)
			return false
		Js := "(function(){let ok=false;try{" . LocaleScript
			. "window.clearNetworkFailure();setKind('app_update'," . JsonStringLiteral(this.Opts.Get("Title", t("download_window.window_title"))) . ",null," . this.Failure.Id . ");"
			. "done(false,window._i18n_strings[" . JsonStringLiteral(Report["message_key"]) . "]);"
			. "ok=window.showNetworkFailure(" . ManagedNetworkFailureWindows_ReportJson(Report) . "," . this.Failure.Id . "," . FailureEpoch . ")===true;"
			. "}catch(error){ok=false;}makeHostBridge('dl_bridge')({action:'failure_rendered',session:"
			. this.Failure.Id . ",epoch:" . FailureEpoch . ",ok});})();"
		if !this._FailureIsCurrent(Owner, FailureEpoch)
			return false
		if !this._FailureIsCurrent(Owner, FailureEpoch)
			return false
		Work := {window_epoch: this.Epoch, failure_epoch: FailureEpoch, owner: Owner, js: Js}
		if this.Ready
			this.TimerFn.Call(this._RunFailureScript.Bind(this, Work), -1)
		else
			this.Queue.Push(Work)
		return true
	}

	_RunFailureScript(Work) {
		if !this._NativeIsCurrent(Work.window_epoch) || !this._FailureIsCurrent(Work.owner, Work.failure_epoch)
			return false
		try Source := this.WebView.Source
		catch
			return false
		if !this._CaptureDocument(Source, Work.window_epoch) || !this._FailureIsCurrent(Work.owner, Work.failure_epoch)
			return false
		if !this._ArmRenderAcknowledgement(Work)
			return false
		if !this._NativeIsCurrent(Work.window_epoch) || !this._FailureIsCurrent(Work.owner, Work.failure_epoch)
			return false
		return WebView_RunScriptAsync(this.WebView, Work.js, "ManagedDownload.Failure",
			this._ScriptSettled.Bind(this, Work.window_epoch, Work.owner, Work.failure_epoch))
	}


	; Retain the exact timer callback so teardown cancels its physical registration.
	_ArmRenderAcknowledgement(Work) {
		this._CancelRenderAcknowledgement()
		if !this._NativeIsCurrent(Work.window_epoch) || !this._FailureIsCurrent(Work.owner, Work.failure_epoch)
			return false
		Budget := this.RenderBudget
		if !IsObject(Budget) || Budget.owner != Work.owner || Budget.failure_epoch != Work.failure_epoch || Budget.window_epoch != Work.window_epoch {
			Budget := {owner: Work.owner, failure_epoch: Work.failure_epoch, window_epoch: Work.window_epoch,
				start_tick: ManagedNetworkFailureWindows_Now(), duration_ms: ManagedNetworkFailureWindows_RenderAckTimeout()}
			this.RenderBudget := Budget
		}
		Work.start_tick := Budget.start_tick
		Work.duration_ms := Budget.duration_ms
		Work.ack_timer := this._RenderAcknowledgementExpired.Bind(this, Work)
		this.RenderWork := Work
		Remaining := TickRemaining64(Work.start_tick, Work.duration_ms, ManagedNetworkFailureWindows_Now())
		if Remaining == 0 {
			this._RenderAcknowledgementExpired(Work)
			return false
		}
		try this.TimerFn.Call(Work.ack_timer, -Remaining)
		catch Any as Err {
			LoggerWarn("ManagedDownload", "The rendering deadline could not be registered (error_type={1}).", Type(Err))
			this._SurfaceFallback(Work.window_epoch, Work.owner, Work.failure_epoch, Work)
			return false
		}
		return true
	}

	_CancelRenderAcknowledgement(ExpectedWork := 0) {
		PreviousCritical := Critical("On")
		try {
			Work := this.RenderWork
			if IsObject(ExpectedWork) && Work != ExpectedWork
				return false
			this.RenderWork := 0
		} finally {
			Critical(PreviousCritical)
		}
		if IsObject(Work) && Work.HasOwnProp("ack_timer") {
			try this.TimerFn.Call(Work.ack_timer, 0)
			catch Any as Err {
				; Private ownership is already invalidated, so a queued callback is inert.
				LoggerWarn("ManagedDownload", "The rendering deadline could not be cancelled physically (error_type={1}).", Type(Err))
				return false
			}
		}
		return true
	}

	_RenderAcknowledgementExpired(Work) {
		if this.RenderWork != Work
			return false
		Remaining := TickRemaining64(Work.start_tick, Work.duration_ms, ManagedNetworkFailureWindows_Now())
		if this.RenderWork != Work
			return false
		if Remaining > 0 {
			try this.TimerFn.Call(Work.ack_timer, -Remaining)
			catch
				return this._SurfaceFallback(Work.window_epoch, Work.owner, Work.failure_epoch, Work)
			return false
		}
		; Pause suppresses the notice, never retirement of expired action consent.
		return this._SurfaceFallback(Work.window_epoch, Work.owner, Work.failure_epoch, Work)
	}

	_ScriptSettled(ExpectedWindowEpoch, Owner, FailureEpoch, NativeSucceeded) {
		if !NativeSucceeded
			this._SurfaceFallback(ExpectedWindowEpoch, Owner, FailureEpoch)
	}

	_SurfaceFallback(ExpectedWindowEpoch, Owner, FailureEpoch, ExpectedWork := 0) {
		Detached := this._DetachForClose(ExpectedWindowEpoch, Owner, FailureEpoch, ExpectedWork)
		if !IsObject(Detached)
			return false
		Fallback := this.FallbackFn
		if HasMethod(Fallback, "Call")
			Detached.closed_fn := 0
		this._FinishClose(Detached)
		if HasMethod(Fallback, "Call")
			return _ManagedNetworkWindows_True(Fallback.Call())
		; The captured producer admission is separate from the retired presentation.
		return ManagedNetworkFailureWindows_ShowNotice(Detached.message_key, Detached.producer_current)
	}

	_FlushQueue() {
		if !this._NativeIsCurrent(this.Epoch)
			return
		this.Ready := true
		Queue := this.Queue
		this.Queue := []
		for Work in Queue
			this.TimerFn.Call(this._RunFailureScript.Bind(this, Work), -1)
	}

	_SafetyFlush() {
		ExpectedWindowEpoch := this.Epoch
		if this.Ready || !this._HostIsCurrent(ExpectedWindowEpoch)
			return
		try Source := this.WebView.Source
		catch
			Source := ""
		if this._CaptureDocument(Source, ExpectedWindowEpoch)
			this._FlushQueue()
		else
			this._SurfaceFallback(ExpectedWindowEpoch, this.Failure.Owner, this.Failure.Epoch)
	}

	; All private consent and work is detached before any cancellation or native call.
	_DetachForClose(ExpectedWindowEpoch := unset, Owner := 0, FailureEpoch := 0, ExpectedWork := 0) {
		PreviousCritical := Critical("On")
		try {
			if IsSet(ExpectedWindowEpoch) {
				if this.ResetDone || this.Cancelled || ExpectedWindowEpoch != this.Epoch
					|| ManagedDownloadFailureWindow.Current != this || this.Failure.Closed
					|| this.Failure.Owner != Owner || this.Failure.Epoch != FailureEpoch
					|| !(this.Failure.Report is Map) || (IsObject(ExpectedWork) && this.RenderWork != ExpectedWork)
					return 0
			}
			Detached := {work: this.RenderWork, gui: this.Gui, building: this.Building,
				message_key: this.Failure.Report is Map ? this.Failure.Report["message_key"] : "",
				producer_current: this.Failure.IsCurrentFn, closed_fn: this.TerminalClosedFn}
			this.RenderWork := 0
			this.RenderBudget := 0
			this.TerminalClosedFn := 0
			this.Cancelled := true
			if !this.Failure.Closed
				this.Failure.Close()
			if ManagedDownloadFailureWindow.Current == this
				ManagedDownloadFailureWindow.Current := 0
			if WebViewHost._Instances.Has(this.AppId) && WebViewHost._Instances[this.AppId] == this
				WebViewHost._Instances.Delete(this.AppId)
			return Detached
		} finally {
			Critical(PreviousCritical)
		}
	}

	_FinishClose(Detached) {
		if HasMethod(Detached.closed_fn, "Call")
			Detached.closed_fn.Call()
		if IsObject(Detached.work) && Detached.work.HasOwnProp("ack_timer") {
			try this.TimerFn.Call(Detached.work.ack_timer, 0)
			catch Any as Err
				LoggerWarn("ManagedDownload", "The rendering deadline could not be cancelled physically (error_type={1}).", Type(Err))
		}
		if Detached.building {
			if Detached.gui
				try Detached.gui.Hide()
			return
		}
		this._Reset(true)
		if Detached.gui
			try Detached.gui.Destroy()
		this.Gui := 0
		PreviousCritical := Critical("On")
		try {
			if WebViewHost._Instances.Has(this.AppId) && WebViewHost._Instances[this.AppId] == this
				WebViewHost._Instances.Delete(this.AppId)
		} finally {
			Critical(PreviousCritical)
		}
	}

	_InitialFallback() {
		Fallback := this.FallbackFn
		if HasMethod(Fallback, "Call")
			this.TerminalClosedFn := 0
		this.Close()
		return HasMethod(Fallback, "Call") ? _ManagedNetworkWindows_True(Fallback.Call()) : false
	}

	Close() {
		this._FinishClose(this._DetachForClose())
	}
}

; Safe causes transfer from a completed request into an exact native host intent.
class ManagedNetworkTerminalFailure {
	static Owners := Map()
	static Intents := Map()

	static Current(Scope, Owner) {
		if !IsObject(Owner) || this.Owners.Get(Scope, 0) != Owner || !HasMethod(Owner.CurrentFn, "Call")
			return false
		try Admitted := _ManagedNetworkWindows_True(Owner.CurrentFn.Call())
		catch
			Admitted := false
		return Admitted && this.Owners.Get(Scope, 0) == Owner && !A_IsSuspended
	}

	static Invalidate(Scope, Expected) {
		PreviousCritical := Critical("On")
		try {
			if this.Owners.Get(Scope, 0) != Expected
				return false
			this.Owners.Delete(Scope)
			Expected.CurrentFn := 0
			return true
		} finally Critical(PreviousCritical)
	}

	static Retire(Scope, Expected := 0) {
		PreviousCritical := Critical("On")
		try {
			if !IsObject(Expected)
				this.Intents[Scope] := this.Intents.Get(Scope, 0) + 1
			else if this.Owners.Get(Scope, 0) != Expected
				return false
		} finally Critical(PreviousCritical)
		return this._RetireOwner(Scope, Expected)
	}

	static _RetireOwner(Scope, Expected := 0) {
		Owner := this.Owners.Get(Scope, 0)
		if !IsObject(Owner) || (IsObject(Expected) && Expected != Owner) || !this.Invalidate(Scope, Owner)
			return false
		Host := ManagedDownloadFailureWindow.Current
		if IsObject(Host) && Host.Failure.Owner == Owner
			Host.Close()
		return true
	}

	static Publish(Scope, Report, SourceCurrent, TitleKey, RetryFn := 0, PresentFn := 0) {
		if !(Scope is String) || Scope == "" || !HasMethod(SourceCurrent, "Call")
			|| !_ManagedNetworkWindows_Current(SourceCurrent) || !ManagedNetworkFailureWindows_CanonicalReport(Report)
			return false
		PreviousCritical := Critical("On")
		try {
			Intent := this.Intents.Get(Scope, 0) + 1
			this.Intents[Scope] := Intent
		} finally Critical(PreviousCritical)
		this._RetireOwner(Scope)
		if this.Intents.Get(Scope, 0) != Intent || !_ManagedNetworkWindows_Current(SourceCurrent)
			return false
		Owner := {CurrentFn: SourceCurrent, Report: JsonParse(ManagedNetworkFailureWindows_ReportJson(Report)), TitleKey: TitleKey}
		PreviousCritical := Critical("On")
		try {
			if this.Intents.Get(Scope, 0) != Intent || this.Owners.Has(Scope)
				return false
			this.Owners[Scope] := Owner
		} finally Critical(PreviousCritical)
		CurrentFn := () => ManagedNetworkTerminalFailure.Current(Scope, Owner)
		ClosedFn := () => ManagedNetworkTerminalFailure.Invalidate(Scope, Owner)
		Retry := HasMethod(RetryFn, "Call") ? () => ManagedNetworkTerminalFailure.Retry(Scope, Owner, RetryFn) : 0
		Fallback := () => ManagedNativeFailureWindow.ShowReport(Owner.Report, Owner, CurrentFn, Owner.TitleKey, Retry, ClosedFn)
		try {
			Accepted := HasMethod(PresentFn, "Call")
				? PresentFn.Call(Owner.Report, Owner, CurrentFn, Retry, ClosedFn, Fallback)
				: ManagedDownloadFailureWindow.Show(Owner.Report, Owner, CurrentFn, Retry, 0, true, TitleKey, Fallback, ClosedFn)
		} catch {
			Accepted := false
		}
		if !_ManagedNetworkWindows_True(Accepted) || !this.Current(Scope, Owner) {
			this.Retire(Scope, Owner)
			return false
		}
		return true
	}

	static Retry(Scope, Owner, RetryFn) {
		if !this.Current(Scope, Owner) || !this.Retire(Scope, Owner)
			return false
		return _ManagedNetworkWindows_True(RetryFn.Call())
	}
}

; The native fallback shares manifest geometry, singleton and exact action
; session with the WebView presenter. Only captured native controls can act.
class ManagedNativeFailureWindow extends ManagedDownloadFailureWindow {
	NativeMode := true
	NativeButtons := []

	static ShowReport(Report, Owner, CurrentFn, TitleKey, RetryFn := 0, ClosedFn := 0) {
		if !ManagedNetworkFailureWindows_CanonicalReport(Report) || !_ManagedNetworkWindows_Current(CurrentFn)
			return false
		Previous := ManagedDownloadFailureWindow.Current
		if IsObject(Previous)
			Previous.Close()
		if !_ManagedNetworkWindows_Current(CurrentFn)
			return false
		WebViewHost._LoadManifest()
		Host := ManagedNativeFailureWindow()
		Host.AppId := "download_window"
		Host.Opts := Map("Title", t(TitleKey))
		Host.Failure := ManagedDownloadFailureSession()
		Host.TerminalClosedFn := ClosedFn
		if !Host.Failure.PublishReport(Report, Owner, CurrentFn, RetryFn) || !Host._ReserveCurrent(0) {
			Host.Close()
			return false
		}
		try {
			Host.Building := true
			Geo := Host._Geometry()
			Host.Epoch += 1
			Host.ResetDone := false
			Host.Gui := Host._NewWindow(Geo.min_w . "x" . Geo.min_h)
			Host.Gui.MarginX := 20
			Host.Gui.MarginY := 16
			Host.Gui.Add("Text", "xm ym w" . (Geo.w - 40) . " h140", t(Host.Failure.Report["message_key"]))
			for Action in Host.Failure.Report["actions"] {
				Button := Host.Gui.Add("Button", "xm y+8 w" . (Geo.w - 40) . " h30", t(Action["label_key"]))
				Host.NativeButtons.Push(Button)
				Payload := Map("action", "failure_action", "id", Action["id"], "session", Host.Failure.Id, "epoch", Host.Failure.Epoch)
				Button.OnEvent("Click", Host.NativeAction.Bind(Host, Host.Epoch, Host.Gui, Button, Payload))
			}
			Host.Gui.OnEvent("Close", (*) => Host.Close())
			Host.Gui.OnEvent("Escape", (*) => Host.Close())
			Host.Building := false
			if !_ManagedNetworkWindows_Current(CurrentFn) || ManagedDownloadFailureWindow.Current != Host
				throw Error("The terminal native owner was replaced while building.")
			if WebViewHost._Instances.Has(Host.AppId)
				throw Error("The terminal native singleton was replaced while building.")
			WebViewHost._Instances[Host.AppId] := Host
			Host.Gui.Show("NoActivate w" . Geo.w . " h" . Geo.h . " Center")
			if !Host.NativeCurrent(Host.Epoch, Host.Gui)
				throw Error("The terminal native owner was replaced while showing.")
			return true
		} catch {
			Host.Building := false
			Host.Close()
			return false
		}
	}

	NativeCurrent(Epoch, Gui) {
		return !this.Cancelled && !this.ResetDone && !this.Building && !A_IsSuspended
			&& this.Epoch == Epoch && this.Gui == Gui && ManagedDownloadFailureWindow.Current == this
			&& WebViewHost._Instances.Get(this.AppId, 0) == this
	}

	NativeAction(Epoch, Gui, Button, Payload, Sender, *) {
		if Sender != Button || !this.NativeCurrent(Epoch, Gui)
			return false
		Owner := this.Failure.Owner
		FailureEpoch := this.Failure.Epoch
		CurrentFn := () => this.NativeCurrent(Epoch, Gui) && this.Failure.IsCurrent(Owner, FailureEpoch)
		try Accepted := this.Failure.Handle(Payload, CurrentFn)
		catch
			Accepted := false
		if this.Failure.Owner == 0 && this.Failure.Epoch == FailureEpoch + 1
			this.Close()
		return Accepted
	}
}
