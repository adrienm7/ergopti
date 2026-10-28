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

_KCSP_Main() {
	try {
		_KCSP_Require(A_Args.Length == 2, "The private child arguments must be exact.")
		Mode := A_Args[1]
		_KCSP_Require(Mode == "collection" || Mode == "driver", "The pause mode must be declared.")
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
