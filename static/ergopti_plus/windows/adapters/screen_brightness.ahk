; adapters/screen_brightness.ahk

; ==============================================================================
; MODULE: Native Screen Brightness Owner
; DESCRIPTION:
; Runs potentially blocking WMI backlight providers in a bounded Job-owned child.
; A worker exit alone never proves that a screen reached its requested target.
; Cancellation debt retains the exact native handle until retirement succeeds.
; ==============================================================================

#Requires AutoHotkey v2.0

class ScreenBrightnessOwner {
	static generation := 0
	static job := 0
	static spawn_fn := 0
	static notify_fn := 0
	static data := 0
}

/**
 * Loads native action encodings from the shared catalogue.
 * @returns {Map} Canonical screen brightness policy.
 */
ScreenBrightnessData() {
	global _SharedDir
	if ScreenBrightnessOwner.data is Map
		return ScreenBrightnessOwner.data
	Data := JsonParse(FileRead(_SharedDir . "\modules\actions\brightness.json", "UTF-8"))
	if !(Data is Map) || Data.Get("version", 0) != 1 || !(Data.Get("actions", 0) is Map)
		throw ValueError("Invalid shared screen brightness policy.")
	ScreenBrightnessOwner.data := Data
	return Data
}

/**
 * Starts one backlight request without blocking the input callback.
 * @param {String} Action Canonical brightness action id.
 * @param {Func|0} Done Optional terminal callback receiving an acknowledged Boolean.
 * @returns {Boolean} The native request was acquired, not physical screen success.
 */
ScreenBrightnessRequest(Action, Done := 0) {
	global _SharedDir, _VendorDir
	Data := ScreenBrightnessData()
	if !Data["actions"].Has(Action)
		throw ValueError("Unknown screen brightness action.")
	if A_IsSuspended || IsObject(ScreenBrightnessOwner.job)
		return false
	Id := ++ScreenBrightnessOwner.generation
	Job := Map("id", Id, "action", Action, "done", Done, "data", Data,
		"started", A_TickCount, "canceled", false, "handle", 0)
	Spawn := IsObject(ScreenBrightnessOwner.spawn_fn)
		? ScreenBrightnessOwner.spawn_fn : ShellRunner_SpawnTreeOwned
	Args := ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File",
		_VendorDir . "\ergopti_brightness_worker.ps1", "-PolicyPath",
		_SharedDir . "\modules\actions\brightness.json", "-Action", Action]
	try Handle := Spawn.Call("powershell.exe", Args,
		ScreenBrightnessCompleted.Bind(Id), , , Data["max_receipt_bytes"])
	catch as Err {
		LoggerError("ScreenBrightness", "Worker acquisition failed: {1}.", Err.Message)
		return false
	}
	if !IsObject(Handle)
		return false
	Job["handle"] := Handle
	ScreenBrightnessOwner.job := Job
	try Started := Handle.start()
	catch as Err {
		LoggerError("ScreenBrightness", "Worker start failed: {1}.", Err.Message)
		Started := false
	}
	Started := (Started is Integer) && Started == true
	if !IsObject(ScreenBrightnessOwner.job) || ScreenBrightnessOwner.job["id"] != Id
		return Started
	if !Started {
		ScreenBrightnessCancel("start-refused", Id)
		return false
	}
	SetTimer(ScreenBrightnessPoll, ScreenBrightnessData()["worker_poll_ms"])
	LoggerDebug("ScreenBrightness", "Native request acquired ({1}, generation {2}).", Action, Id)
	return true
}

/**
 * Cancels and retains the native owner until exact physical retirement is acknowledged.
 * @param {String} Reason Lifecycle refusal reason.
 * @param {Integer} ExpectedId Optional exact generation; zero cancels the current lifecycle owner.
 * @returns {Boolean} No owned child or cleanup debt remains.
 */
ScreenBrightnessCancel(Reason := "canceled", ExpectedId := 0) {
	Job := ScreenBrightnessOwner.job
	if !IsObject(Job)
		return true
	if ExpectedId != 0 && Job["id"] != ExpectedId
		return false
	Job["canceled"] := true
	try Retired := Job["handle"].requestTerminate()
	catch as Err {
		LoggerError("ScreenBrightness", "Worker retirement threw ({1}): {2}.", Reason, Err.Message)
		Retired := false
	}
	if !(Retired is Integer) || Retired != true {
		LoggerError("ScreenBrightness", "Worker retirement refused ({1}); ownership retained.", Reason)
		SetTimer(ScreenBrightnessPoll, ScreenBrightnessData()["worker_poll_ms"])
		return false
	}
	; requestTerminate may invoke the terminal synchronously. A vanished owner
	; means that callback already claimed notification and retirement.
	if IsObject(ScreenBrightnessOwner.job) && ScreenBrightnessOwner.job["id"] == Job["id"]
		ScreenBrightnessCompleted(Job["id"], 1, "", "")
	return true
}

; Runs while a worker or native retirement debt exists, including during Suspend.
ScreenBrightnessPoll() {
	Job := ScreenBrightnessOwner.job
	if !IsObject(Job) {
		SetTimer(ScreenBrightnessPoll, 0)
		return
	}
	if Job["canceled"] || A_IsSuspended
		ScreenBrightnessCancel("suspended-or-canceled")
	else if TickExpired(Job["started"], Job["data"]["worker_timeout_ms"])
		ScreenBrightnessCancel("timeout")
}

; ShellRunner invokes this only after the child tree and its resources settle.
ScreenBrightnessCompleted(Id, ExitCode, Stdout, Stderr) {
	Job := ScreenBrightnessOwner.job
	if !IsObject(Job) || Job["id"] != Id
		return
	ScreenBrightnessOwner.job := 0
	SetTimer(ScreenBrightnessPoll, 0)
	Receipt := 0
	if ExitCode == 0 && StrLen(Stdout) <= Job["data"]["max_receipt_bytes"] {
		try Receipt := JsonParse(Stdout)
	}
	Acknowledged := !Job["canceled"] && !A_IsSuspended
		&& BrightnessAcknowledged(Job["data"], Job["action"], Receipt)
	if !Acknowledged {
		LoggerWarn("ScreenBrightness", "Native request was not acknowledged ({1}).", Job["action"])
		if !Job["canceled"] && !A_IsSuspended && (Receipt is Map)
				&& (Receipt.Get("version", "") is Integer)
				&& Receipt["version"] == Job["data"]["version"]
				&& (Receipt.Get("action", 0) is String)
				&& StrCompare(Receipt["action"], Job["action"], true) == 0
				&& (Receipt.Get("status", 0) is String)
				&& StrCompare(Receipt.Get("status", ""), "unsupported", true) == 0 {
			Notify := IsObject(ScreenBrightnessOwner.notify_fn)
				? ScreenBrightnessOwner.notify_fn : _ScreenBrightnessNotifyUnsupported
			try Notify.Call(Job["action"])
			catch as Err
				LoggerError("ScreenBrightness", "Unsupported notice failed: {1}.", Err.Message)
		}
	}
	if IsObject(Job["done"])
		Job["done"].Call(Acknowledged)
}

_ScreenBrightnessNotifyUnsupported(Action) {
	return NotifierSend(t("healthcheck.probe.unsupported"),
		Map("title", t("sg_actions." . Action), "level", "warning"))
}
