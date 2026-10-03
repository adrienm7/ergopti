; infra/webview_browser_warmup.ahk

; ==============================================================================
; MODULE: Shared Browser Background Warmup
; DESCRIPTION:
; Retains a blank controller on an invisible real window. Async completions own
; their exact promises; startup never awaits Chromium and teardown fences late
; controllers before destroying their native host.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Owns one asynchronous environment/controller chain and its invisible host. */
class WebViewBrowserWarmup {
	__New(EnvironmentFn, ControllerFn, HostFn) {
		for Fn in [EnvironmentFn, ControllerFn, HostFn]
			if !HasMethod(Fn, "Call")
				throw TypeError("Browser warmup factories must be callable")
		this.EnvironmentFn := EnvironmentFn
		this.ControllerFn := ControllerFn
		this.HostFn := HostFn
		this.Started := false
		this.Stopped := false
		this.Host := 0
		this.EnvironmentPromise := 0
		this.ControllerPromise := 0
		this.Controller := 0
	}

	/** Dispatches background creation once, without pumping or awaiting. */
	Begin() {
		if this.Stopped
			throw Error("Stopped browser warmup cannot restart")
		if this.Started
			return false
		this.Started := true
		this.BeginMs := BootClockWallMs()
		this.BeginCpuMs := BootClockCpuMs()
		try {
			this.Host := this.HostFn.Call()
			Promise := this.EnvironmentFn.Call()
			this.EnvironmentPromise := Promise
			Promise.onSettled(ObjBindMethod(this, "EnvironmentReady", Promise),
				ObjBindMethod(this, "Failed", "environment", Promise))
		} catch as Err {
			this.Stop()
			throw Err
		}
		LoggerInfo("WebView", "Shared browser warmup dispatched without awaiting.")
		return true
	}

	EnvironmentReady(Promise, Environment) {
		if this.EnvironmentPromise !== Promise
			return false
		this.EnvironmentPromise := 0
		if this.Stopped
			return false
		try {
			NextPromise := this.ControllerFn.Call(Environment, this.Host.Hwnd)
			this.ControllerPromise := NextPromise
			NextPromise.onSettled(ObjBindMethod(this, "ControllerReady", NextPromise),
				ObjBindMethod(this, "Failed", "controller", NextPromise))
		} catch as Err {
			this.Stop()
			LoggerError("WebView", "Shared browser warmup dispatch failed: {1}.", Err.Message)
			return false
		}
		return true
	}

	ControllerReady(Promise, Controller) {
		if this.ControllerPromise !== Promise || this.Stopped {
			Controller.Close()
			if this.ControllerPromise == Promise {
				this.ControllerPromise := 0
				this.DestroyHost()
			}
			return false
		}
		this.ControllerPromise := 0
		this.Controller := Controller
		try Controller.IsVisible := false
		catch as Err {
			this.Stop()
			LoggerError("WebView", "Shared browser warmup visibility failed: {1}.", Err.Message)
			return false
		}
		LoggerInfo("WebView", Format("Shared browser warm in {1:.3f} ms; cpu={2:.3f} ms.",
			BootClockWallMs() - this.BeginMs, BootClockCpuMs() - this.BeginCpuMs))
		return true
	}

	Failed(Stage, Promise, Reason) {
		if Stage == "environment" && this.EnvironmentPromise == Promise
			this.EnvironmentPromise := 0
		else if Stage == "controller" && this.ControllerPromise == Promise
			this.ControllerPromise := 0
		else
			return false
		LoggerError("WebView", "Shared browser warmup {1} failed: {2}.", Stage,
			IsObject(Reason) ? Reason.Message : Reason)
		this.Stop()
		return false
	}

	/** Keeps an in-flight controller's host alive until its real terminal callback. */
	Stop() {
		WasStopped := this.Stopped
		this.Stopped := true
		if this.Controller {
			this.Controller.Close()
			this.Controller := 0
		}
		if !this.ControllerPromise
			this.DestroyHost()
		if !WasStopped
			LoggerInfo("WebView", "Shared browser warmup retired.")
		return !WasStopped
	}

	DestroyHost() {
		if this.Host {
			this.Host.Destroy()
			this.Host := 0
		}
	}
}

/** Dispatches the sole shared environment owner for background browser warmup. */
_WebView_BeginSharedEnvironment(Loader) {
	global _WebView_SharedEnv, _WebView_SharedEnvCreating, _WebView_SharedEnvBootPromise
	global _WebView_SharedEnvBackground, WEBVIEW_SHARED_UDIR
	if _WebView_SharedEnv
		return Promise.resolve(_WebView_SharedEnv)
	if _WebView_SharedEnvCreating {
		if IsObject(_WebView_SharedEnvBootPromise)
			return _WebView_SharedEnvBootPromise
		throw Error("Shared environment dispatch is reentrant")
	}
	_WebView_SharedEnvCreating := true
	_WebView_SharedEnvBackground := true
	try {
		FSEnsureDirectoryStrict(WEBVIEW_SHARED_UDIR)
		Pending := WebView2.CreateEnvironmentAsync(0, WEBVIEW_SHARED_UDIR, "", Loader)
		_WebView_SharedEnvBootPromise := Pending
		Pending.onSettled(_WebView_SharedEnvironmentSettled.Bind(Pending, true),
			_WebView_SharedEnvironmentSettled.Bind(Pending, false))
		return Pending
	} catch {
		_WebView_SharedEnvBootPromise := 0
		_WebView_SharedEnvCreating := false
		_WebView_SharedEnvBackground := false
		throw
	}
}

/** Builds a real, never-shown host; HWND_MESSAGE cannot reliably retain Chromium. */
_WebView_BrowserWarmHost() {
	return WMBrowserWarmHost()
}

/** Returns the unique session owner without creating native resources. */
_WebView_BrowserWarmOwner() {
	global _VendorDir
	static Owner := WebViewBrowserWarmup(
		() => _WebView_BeginSharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll"),
		(Environment, Hwnd) => Environment.CreateCoreWebView2ControllerAsync(Hwnd),
		_WebView_BrowserWarmHost)
	return Owner
}

/** Starts browser work asynchronously when the existing RAM policy permits it. */
WebView_BeginBrowserWarmup() {
	global _VendorDir
	if !IsSet(WebView2) || !FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
		return false
	if WebView_ShouldUseNativeFallback() {
		LoggerInfo("WebView", "Shared browser warmup skipped by the RAM admission policy.")
		return false
	}
	try return _WebView_BrowserWarmOwner().Begin()
	catch as Err {
		LoggerError("WebView", "Shared browser warmup could not start: {1}.", Err.Message)
		return false
	}
}

/** Retires only this driver's invisible browser anchor; shared profile stays owned. */
WebView_StopBrowserWarmup() {
	global _WebView_SharedEnvRetired
	_WebView_SharedEnvRetired := true
	return _WebView_BrowserWarmOwner().Stop()
}
