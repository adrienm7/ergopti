; static/ergopti_plus/windows/tests/unit/test_keylogger_window_topology.ahk

_KWT_ResetObservation() {
	KL_Topo_ResetObservation()
}

_KWT_Monitor(Id, Index, Width := 1920) {
	return Map("id", Id, "index", Index, "width", Width)
}

_KWT_Record(Events, Kind, Data) {
	Events.Push(Map("kind", Kind, "data", Data.Clone()))
}

_KWT_MonitorIdentityIsIndependentOfGeometry() {
	Events := []
	LogFn := _KWT_Record.Bind(Events)

	_KWT_ResetObservation()
	KL_Topo_ProcessObservation(101, 100, 100, 800, 600, "normal",
		_KWT_Monitor("DISPLAY-A", 1), "topology.exe", LogFn)
	KL_Topo_ProcessObservation(101, 2100, 100, 800, 600, "normal",
		_KWT_Monitor("DISPLAY-B", 2), "topology.exe", LogFn)
	KL_Topo_ProcessObservation(101, 2100, 100, 800, 600, "normal",
		_KWT_Monitor("DISPLAY-B", 2), "topology.exe", LogFn)

	AssertEqual(2, Events.Length,
		"(ahk5-03-monitor-identity) a stable cross-monitor move must emit both its geometry and monitor transitions")
	AssertEqual("window_move", Events[1]["kind"])
	AssertEqual("monitor_focus_change", Events[2]["kind"])
	AssertEqual("DISPLAY-A", Events[2]["data"]["from_monitor"])
	AssertEqual("DISPLAY-B", Events[2]["data"]["to_monitor"])

	Events := []
	LogFn := _KWT_Record.Bind(Events)
	_KWT_ResetObservation()
	KL_Topo_ProcessObservation(202, 100, 100, 800, 600, "normal",
		_KWT_Monitor("DISPLAY-A", 1), "topology.exe", LogFn)
	KL_Topo_ProcessObservation(202, 100, 100, 800, 600, "normal",
		_KWT_Monitor("DISPLAY-A", 2), "topology.exe", LogFn)
	KL_Topo_ProcessObservation(202, 100, 100, 800, 600, "normal",
		_KWT_Monitor("DISPLAY-A", 2), "topology.exe", LogFn)

	AssertEqual(0, Events.Length,
		"(ahk5-03-monitor-identity) a monitor enumeration reorder with stable physical identity must emit no topology event")
}
Test("keylogger topology: monitor identity is independent from geometry and enumeration order (ahk5-03-monitor-identity)",
	_KWT_MonitorIdentityIsIndependentOfGeometry)
