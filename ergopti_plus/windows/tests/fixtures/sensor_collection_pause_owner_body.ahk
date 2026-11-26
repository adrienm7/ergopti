; tests/fixtures/sensor_collection_pause_owner_body.ahk

; ==============================================================================
; MODULE: Native Sensor Collection Pause Child
; DESCRIPTION:
; The genuine sampler, privacy filter and publication queue run unchanged.
; Only the neutral focus snapshot and passive log boundary belong to the fixture.
; ==============================================================================

#Requires AutoHotkey v2.0

LoggerInfo(*) => 0
LoggerWarn(*) => 0
LoggerError(*) => 0

_KCSP_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_KCSP_PowerSample(Mode, Pwr) {
	global _KCSP_PowerReceipt
	_KCSP_PowerReceipt.Calls += 1
	_KCSP_PowerReceipt.BufferSize := Pwr.Size
	Ac := Mode == "power-ac" ? 1 : Mode == "power-dc" ? 0 : 255
	Battery := Mode == "power-battery-unknown" ? 255 : 73
	NumPut("UChar", Ac, "UChar", 0, "UChar", Battery, Pwr, 0)
	_KCSP_PowerReceipt.Ac := NumGet(Pwr, 0, "UChar")
	_KCSP_PowerReceipt.Battery := NumGet(Pwr, 2, "UChar")
	return 1
}

_KCSP_Main() {
	global _KCSP_PowerReceipt
	try {
		_KCSP_Require(A_Args.Length == 2, "The private child arguments must be exact.")
		Mode := A_Args[1]
		_KCSP_Require(Mode == "collection" || Mode == "driver" || Mode == "power-unknown"
			|| Mode == "power-ac" || Mode == "power-dc" || Mode == "power-battery-unknown", "The test mode must be declared.")
		MetricsFocusCache.event_mode := false
		MetricsFocusCache.state := {valid: true, hwnd: 0, process_name: "sensor-fixture.exe",
			title: "Native sensor fixture", class: "Fixture", last_at: A_TickCount,
			failure_reason: "", timed_out: false}
		MetricsFilters.disabled_apps := Map()
		MetricsFilters.private_browsing := false
		MetricsFilters.secure_field := false
		MetricsFilters.system_auth := false
		Keystats.initialized := true
		Keystats._shutting_down := false
		if InStr(Mode, "power-") == 1 {
			_KCSP_PowerReceipt := {Calls: 0, BufferSize: 0, Ac: -1, Battery: -1}
			KL_Sensors_Tick(_KCSP_PowerSample.Bind(Mode))
			ExpectedAc := Mode == "power-ac" ? 1 : Mode == "power-dc" ? 0 : 255
			ExpectedBattery := Mode == "power-battery-unknown" ? 255 : 73
			FileAppend("RECEIPT sensor-power calls=" . _KCSP_PowerReceipt.Calls
				. " raw_ac=" . _KCSP_PowerReceipt.Ac . " raw_battery=" . _KCSP_PowerReceipt.Battery
				. " buffer_size=" . _KCSP_PowerReceipt.BufferSize . "`n", "*", "UTF-8")
			_KCSP_Require(_KCSP_PowerReceipt.Calls == 1 && _KCSP_PowerReceipt.BufferSize == 12
				&& _KCSP_PowerReceipt.Ac == ExpectedAc && _KCSP_PowerReceipt.Battery == ExpectedBattery,
				"The exact injected SYSTEM_POWER_STATUS must be consumed once before the publication oracle")
			_KCSP_Require(Keystats._pending_entries.Length == 1, "The real sampler must publish exactly one row")
			Row := Keystats._pending_entries[1]
			HasAc := Row.Has("on_ac"), HasBattery := Row.Has("battery_pct")
			FileAppend("OBSERVATION sensor-power mode=" . Mode . " has_ac=" . HasAc
				. " ac=" . (HasAc ? Row["on_ac"] : "absent") . " has_battery=" . HasBattery
				. " battery=" . (HasBattery ? Row["battery_pct"] : "absent") . "`n", "*", "UTF-8")
			_KCSP_Require(Row["type"] == "system_event" && Row["action"] == "system_load"
				&& Row["ram_total_mb"] > 0, "The real publication retains its other native observations")
			if Mode == "power-battery-unknown"
				_KCSP_Require(!HasBattery && !HasAc, "An unknown battery keeps the established omission policy")
			else {
				_KCSP_Require(HasBattery && Row["battery_pct"] == 73, "The known battery percentage remains visible")
				if Mode == "power-unknown"
					_KCSP_Require(!HasAc, "Unknown AC status cannot be published as off-line")
				else
					_KCSP_Require(HasAc && Row["on_ac"] == (Mode == "power-ac"), "Known AC status must remain exact")
			}
			FileAppend("PASS sensor-owner " . Mode . "`n", "*", "UTF-8")
			ExitApp(0)
		}
		KL_Sensors_Tick()
		_KCSP_Require(Keystats._pending_entries.Length == 1, "The genuine unpaused sampler must publish exactly once.")
		First := Keystats._pending_entries[1]
		_KCSP_Require(First["type"] == "system_event" && First["action"] == "system_load"
			&& First["ram_total_mb"] > 0, "The positive must contain the actual native RAM observation.")
		Before := [KLSensors.prev_idle, KLSensors.prev_kernel, KLSensors.prev_user]
		Keystats._pending_entries := []
		if Mode == "collection"
			_KCSP_Require(KL_SuspendCollection(() => true), "The real collection pause must be admitted.")
		else
			Suspend(true)
		_KCSP_Require(KL_CaptureHeld(), "The intended public pause must hold capture.")
		KL_Sensors_Tick()
		FileAppend("OBSERVED native-sensor mode=" . Mode . " queued=" . Keystats._pending_entries.Length
			. " accepted=" . Keystats.health_events_session . "`n", "*", "UTF-8")
		_KCSP_Require(Keystats._pending_entries.Length == 0,
			"A held collection must not publish a new periodic system-load row.")
		_KCSP_Require(Keystats.health_events_session == 1,
			"A held native tick must consume no accepted-event credit.")
		_KCSP_Require(Before[1] == KLSensors.prev_idle && Before[2] == KLSensors.prev_kernel
			&& Before[3] == KLSensors.prev_user, "A held sample must not advance its native counter baseline.")
		if Mode == "collection"
			_KCSP_Require(KL_ResumeCollection(), "The real collection resume must be admitted.")
		else
			Suspend(false)
		KL_Sensors_Tick()
		_KCSP_Require(Keystats._pending_entries.Length == 1
			&& Keystats._pending_entries[1]["action"] == "system_load"
			&& Keystats._pending_entries[1]["_event_id"] == First["_event_id"] + 1,
			"Resume must restore sampling without allocating an identity during the held tick.")
		FileAppend("PASS sensor-owner " . Mode . "`n", "*", "UTF-8")
		ExitApp(0)
	} catch Any as Failure {
		FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
}

_KCSP_Main()
