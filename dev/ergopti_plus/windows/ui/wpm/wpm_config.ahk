; ui/wpm/wpm_config.ahk

; ==============================================================================
; MODULE: WPM Widget — Configuration Persistence
; DESCRIPTION:
; Startup loading and runtime saving of WPM widget settings: shared TOML
; constants (dimensions, colors, timings), per-user config (position,
; visibility, color mode, graph mode), and position-reset helpers.
;
; Split from ui/wpm/init.ahk; see that file for the full module overview.
; ==============================================================================





; =====================================
; =====================================
; ======= 8/ Config persistence =======
; =====================================
; =====================================

; Reads one required key of a parsed canon, or records it as missing.
; @param Cache {Map} ParseTomlFile() result.
; @param Section {String}
; @param Key {String}
; @param Missing {Array} Receives "[section] key" for every absent key.
; @returns The value, or 0 when absent.
_WPMWidget_Need(Cache, Section, Key, Missing) {
		Value := IniCacheGet(Cache, Section, Key)
		if (Value == "_" || Value == "") {
				Missing.Push("[" . Section . "] " . Key)
				return 0
		}
		return Value
}

; Reads one required timing, or records it as missing.
_WPMWidget_NeedTiming(Section, Key, Missing) {
		try return TimingsGet(Section, Key)
		catch as Err {
				Missing.Push("timings [" . Section . "] " . Key . " (" . Err.Message . ")")
				return 0
		}
}

; Reads _shared/modules/wpm_widget/constants.toml — the canon macOS and Linux
; draw from too — and the timings registry into WPMWidgetConst. No key carries
; a copied default: one missing key keeps the widget off and names itself.
; @returns {Integer} true when every key was read.
WPMWidget_LoadSharedConst() {
		global _SharedDir
		wpm_c := ParseTomlFile(_SharedDir . "\modules\wpm_widget\constants.toml")
		if !wpm_c.Count {
				LoggerError("WPMWidget", "_shared/modules/wpm_widget/constants.toml not found — the widget stays off.")
				return false
		}
		Missing := []
		_hex := (s) => (SubStr(s, 1, 1) = "#") ? SubStr(s, 2) : s

		; [compact]
		WPMWidgetConst.W                := Integer(_WPMWidget_Need(wpm_c, "compact", "width", Missing))
		WPMWidgetConst.H                := Integer(_WPMWidget_Need(wpm_c, "compact", "height", Missing))
		WPMWidgetConst.H_NUMBER         := Integer(_WPMWidget_Need(wpm_c, "compact", "height_number", Missing))
		WPMWidgetConst.H_GAP            := Integer(_WPMWidget_Need(wpm_c, "compact", "height_gap", Missing))
		WPMWidgetConst.H_UNIT           := Integer(_WPMWidget_Need(wpm_c, "compact", "height_unit", Missing))
		WPMWidgetConst.NUMBER_FONT_SIZE := Integer(_WPMWidget_Need(wpm_c, "compact", "number_font_size", Missing))
		WPMWidgetConst.UNIT_FONT_SIZE   := Integer(_WPMWidget_Need(wpm_c, "compact", "unit_font_size", Missing))
		WPMWidgetConst.UNIT_DARKEN      := Float(_WPMWidget_Need(wpm_c, "compact", "unit_strip_darken_factor", Missing))
		WPMWidgetConst.CORNER_R         := Integer(_WPMWidget_Need(wpm_c, "compact", "corner_radius", Missing))
		WPMWidgetConst.EDGE_MARGIN      := Integer(_WPMWidget_Need(wpm_c, "compact", "edge_margin", Missing))

		; [graph]
		WPMWidgetConst.GRAPH_W            := Integer(_WPMWidget_Need(wpm_c, "graph", "width", Missing))
		WPMWidgetConst.GRAPH_H            := Integer(_WPMWidget_Need(wpm_c, "graph", "height", Missing))
		WPMWidgetConst.GRAPH_CORNER_R     := Integer(_WPMWidget_Need(wpm_c, "graph", "corner_radius", Missing))
		WPMWidgetConst.GRAPH_PAD          := Integer(_WPMWidget_Need(wpm_c, "graph", "padding", Missing))
		WPMWidgetConst.GRAPH_HISTORY      := Integer(_WPMWidget_Need(wpm_c, "graph", "history_samples", Missing))
		WPMWidgetConst.GRAPH_SCALE_MAX    := Integer(_WPMWidget_Need(wpm_c, "graph", "scale_max", Missing))
		WPMWidgetConst.GRAPH_LABEL_PX     := Integer(_WPMWidget_Need(wpm_c, "graph", "text_size", Missing))
		WPMWidgetConst.GRAPH_BG           := _hex(_WPMWidget_Need(wpm_c, "graph", "background", Missing))
		WPMWidgetConst.GRAPH_BG_ALPHA     := Float(_WPMWidget_Need(wpm_c, "graph", "background_alpha", Missing))
		WPMWidgetConst.GRAPH_BORDER       := _hex(_WPMWidget_Need(wpm_c, "graph", "border", Missing))
		WPMWidgetConst.GRAPH_BORDER_ALPHA := Float(_WPMWidget_Need(wpm_c, "graph", "border_alpha", Missing))
		WPMWidgetConst.GRAPH_BORDER_W     := Integer(_WPMWidget_Need(wpm_c, "graph", "border_width", Missing))
		WPMWidgetConst.GRAPH_LINE_W       := Integer(_WPMWidget_Need(wpm_c, "graph", "line_width", Missing))
		WPMWidgetConst.GRAPH_LINE_ALPHA   := Float(_WPMWidget_Need(wpm_c, "graph", "line_alpha", Missing))
		WPMWidgetConst.GRAPH_FILL_ALPHA   := Float(_WPMWidget_Need(wpm_c, "graph", "fill_alpha", Missing))
		WPMWidgetConst.GRAPH_TEXT         := _hex(_WPMWidget_Need(wpm_c, "graph", "text_color", Missing))

		; [colors] — without the leading '#', as AHK Gui colours take them
		WPMWidgetConst.COLOR_BG_MANUAL  := _hex(_WPMWidget_Need(wpm_c, "colors", "bg_manual", Missing))
		WPMWidgetConst.COLOR_BG_AI      := _hex(_WPMWidget_Need(wpm_c, "colors", "bg_ai", Missing))
		WPMWidgetConst.COLOR_BG_IDLE    := _hex(_WPMWidget_Need(wpm_c, "colors", "bg_idle", Missing))
		WPMWidgetConst.COLOR_TXT_ACTIVE := _hex(_WPMWidget_Need(wpm_c, "colors", "text_active", Missing))
		WPMWidgetConst.COLOR_TXT_IDLE   := _hex(_WPMWidget_Need(wpm_c, "colors", "text_idle", Missing))
		WPMWidgetConst.COLOR_FALLBACK   := _hex(_WPMWidget_Need(wpm_c, "colors", "fallback_accent", Missing))

		; [neutral_sources]
		Neutral := Map()
		if wpm_c.Has("neutral_sources") && (wpm_c["neutral_sources"] is Map) {
				for Name, IsNeutral in wpm_c["neutral_sources"]
						if IsNeutral
								Neutral[Name] := true
		}
		if !Neutral.Count
				Missing.Push("[neutral_sources]")
		WPMWidgetConst.NEUTRAL := Neutral

		; [transparency]
		WPMWidgetConst.ALPHA_ACTIVE := Integer(_WPMWidget_Need(wpm_c, "transparency", "alpha_active", Missing))
		WPMWidgetConst.ALPHA_IDLE   := Integer(_WPMWidget_Need(wpm_c, "transparency", "alpha_idle", Missing))

		; Timings, from the registry every driver reads.
		WPMWidgetConst.IDLE_HIDE_MS        := _WPMWidget_NeedTiming("ui", "wpm_widget_idle_hide_ms", Missing)
		WPMWidgetConst.COLOR_HOLD_MS       := _WPMWidget_NeedTiming("ui", "wpm_color_hold_ms", Missing)
		WPMWidgetConst.TICK_MS             := _WPMWidget_NeedTiming("ui", "wpm_widget_update_ms", Missing)
		WPMWidgetConst.WINDOW_MS           := _WPMWidget_NeedTiming("keylogger", "wpm_window_ms", Missing)
		WPMWidgetConst.WPM_MIN_DURATION_MS := _WPMWidget_NeedTiming("keylogger", "wpm_min_duration_ms", Missing)

		if Missing.Length {
				Names := ""
				for _, Name in Missing
						Names .= (Names == "" ? "" : ", ") . Name
				LoggerError("WPMWidget", "The WPM canon is missing {1} — the widget stays off.", Names)
				return false
		}
		LoggerDone("WPMWidget", "Shared constants loaded (W={1} H={2} graph={3}x{4} tick={5}ms).",
				WPMWidgetConst.W, WPMWidgetConst.H, WPMWidgetConst.GRAPH_W, WPMWidgetConst.GRAPH_H,
				WPMWidgetConst.TICK_MS)
		return true
}


; Called once at startup to restore position and visibility from config.
_WPMWidget_ConfigBoolean(Raw, Key) {
	if (Raw is String) && Raw == "_"
		return false
	if !(Raw is Integer) || (Raw != 0 && Raw != 1)
		throw TypeError("WPM config value must be a TOML boolean", -1, Key)
	return Raw == 1
}

_WPMWidget_RectCenterIsOnScreen(X, Y, Width, Height, WorkAreas) {
	CenterX := X + Width / 2
	CenterY := Y + Height / 2
	for _, Area in WorkAreas {
		if (CenterX >= Area.Left && CenterX < Area.Right
				&& CenterY >= Area.Top && CenterY < Area.Bottom)
			return true
	}
	return false
}

_WPMWidget_CurrentWorkAreas() {
	Areas := []
	Loop MonitorGetCount() {
		MonitorGetWorkArea(A_Index, &Left, &Top, &Right, &Bottom)
		Areas.Push({ Left: Left, Top: Top, Right: Right, Bottom: Bottom })
	}
	if Areas.Length == 0
		throw Error("Windows reported no monitor work area for the WPM widget")
	return Areas
}

WPMWidget_LoadConfig(Cache, WorkAreas := unset) {
		if !WPMWidget_LoadSharedConst() {
				WPMWidget.visible := false
				return
		}
		raw_vis    := IniCacheGet(Cache, "metrics", WPMWidgetConst.CFG_VISIBLE)
		raw_x      := IniCacheGet(Cache, "metrics", WPMWidgetConst.CFG_X)
		raw_y      := IniCacheGet(Cache, "metrics", WPMWidgetConst.CFG_Y)
		raw_colors := IniCacheGet(Cache, "metrics", WPMWidgetConst.CFG_COLORS)
		raw_graph  := IniCacheGet(Cache, "metrics", WPMWidgetConst.CFG_GRAPH)
		Visible := _WPMWidget_ConfigBoolean(raw_vis, WPMWidgetConst.CFG_VISIBLE)
		UseColors := _WPMWidget_ConfigBoolean(raw_colors, WPMWidgetConst.CFG_COLORS)
		ShowGraph := _WPMWidget_ConfigBoolean(raw_graph, WPMWidgetConst.CFG_GRAPH)

		; Position is one atomic configuration value: accepting X while blindly
		; converting a malformed Y throws during boot after other input subsystems
		; are already live. Retain the class defaults unless BOTH coordinates are
		; explicitly present and integer-shaped.
		if (raw_x != "_" && raw_x != "" && IsInteger(raw_x)
				&& raw_y != "_" && raw_y != "" && IsInteger(raw_y)) {
				SavedX := Integer(raw_x)
				SavedY := Integer(raw_y)
				SurfaceX := ShowGraph
					? SavedX + WPMWidgetConst.W - WPMWidgetConst.GRAPH_W : SavedX
				SurfaceY := ShowGraph
					? SavedY + WPMWidgetConst.H - WPMWidgetConst.GRAPH_H : SavedY
				SurfaceW := ShowGraph ? WPMWidgetConst.GRAPH_W : WPMWidgetConst.W
				SurfaceH := ShowGraph ? WPMWidgetConst.GRAPH_H : WPMWidgetConst.H
				; Saved coordinates may belong to a monitor that was disconnected.
				; Validate the actual mode-specific surface against every current work
				; area. Requiring its centre to remain on-screen leaves a substantial,
				; draggable portion visible without rejecting legitimate negative
				; coordinates on monitors placed left or above the primary display.
				CurrentAreas := IsSet(WorkAreas)
					? WorkAreas : _WPMWidget_CurrentWorkAreas()
				if _WPMWidget_RectCenterIsOnScreen(SurfaceX, SurfaceY,
						SurfaceW, SurfaceH, CurrentAreas) {
						WPMWidget.pos_x := SavedX
						WPMWidget.pos_y := SavedY
				}
		}
		WPMWidget.use_colors := UseColors
		WPMWidget.show_graph := ShowGraph
		WPMWidget.visible := Visible
		LoggerDone("WPMWidget", "Config loaded — raw_vis=[{1}] visible={2}, x={3}, y={4}, colors={5}, graph={6}.",
				raw_vis, WPMWidget.visible, WPMWidget.pos_x, WPMWidget.pos_y,
				WPMWidget.use_colors, WPMWidget.show_graph)
}

_WPMWidget_SaveBuilt(BuildFn, Operation, WriterFn := 0, NotifyFn := 0) {
	global ConfigurationFile
	Committed := ConfigCommitBuilt(ConfigurationFile, Operation, BuildFn,
		WriterFn, NotifyFn)
	return (Committed is Integer) && Committed == 1
}

; Publication stays inside the gateway's short Critical window. Direct callers
; own only GUI effects after the durable configuration and live state agree.
_WPMWidget_PublishVisibleCandidate(TargetVisible) {
	WPMWidget.visible := TargetVisible
}

_WPMWidget_PublishPositionCandidate(TargetX, TargetY) {
	WPMWidget.pos_x := TargetX
	WPMWidget.pos_y := TargetY
}

_WPMWidget_PublishDisplayCandidate(TargetColors, TargetGraph, TargetX, TargetY) {
	WPMWidget.use_colors := TargetColors
	WPMWidget.show_graph := TargetGraph
	WPMWidget.pos_x := TargetX
	WPMWidget.pos_y := TargetY
}

_WPMWidget_BuildVisibleCandidate(HasVisible, Visible) {
	TargetVisible := HasVisible ? !!Visible : WPMWidget.visible
	PublishFn := _WPMWidget_PublishVisibleCandidate.Bind(TargetVisible)
	return { updates: [
		{ Section: "metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: TargetVisible },
	], publish: PublishFn }
}

_WPMWidget_BuildVisibleToggleCandidate() {
	return _WPMWidget_BuildVisibleCandidate(true, !WPMWidget.visible)
}

WPMWidget_SaveVisible(Visible := unset, WriterFn := 0, NotifyFn := 0) {
	HasVisible := IsSet(Visible)
	VisibleValue := false
	if HasVisible
		VisibleValue := Visible
	BuildFn := _WPMWidget_BuildVisibleCandidate.Bind(HasVisible, VisibleValue)
	return _WPMWidget_SaveBuilt(BuildFn, "widget visibility", WriterFn, NotifyFn)
}

WPMWidget_ToggleVisibleConfig(WriterFn := 0, NotifyFn := 0) {
	return _WPMWidget_SaveBuilt(_WPMWidget_BuildVisibleToggleCandidate,
		"widget visibility", WriterFn, NotifyFn)
}

WPMWidget_Toggle(WriterFn := 0, NotifyFn := 0, ShowFn := 0, HideFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WPMWidget_Toggle(WriterFn, NotifyFn, ShowFn, HideFn)
		finally Critical(InheritedCritical)
	}
	if !WPMWidget_ToggleVisibleConfig(WriterFn, NotifyFn)
		return false
	if WPMWidget.visible {
		if HasMethod(ShowFn, "Call")
			ShowFn.Call()
		else
			WPMWidget_Show()
	} else {
		if HasMethod(HideFn, "Call")
			HideFn.Call()
		else
			WPMWidget_Hide()
	}
	return true
}

_WPMWidget_BuildPositionCandidate(HasX, X, HasY, Y) {
	TargetX := HasX ? X : WPMWidget.pos_x
	TargetY := HasY ? Y : WPMWidget.pos_y
	PublishFn := _WPMWidget_PublishPositionCandidate.Bind(TargetX, TargetY)
	return { updates: [
		{ Section: "metrics", Key: WPMWidgetConst.CFG_X, Value: TargetX },
		{ Section: "metrics", Key: WPMWidgetConst.CFG_Y, Value: TargetY },
	], publish: PublishFn }
}

WPMWidget_SavePosition(X := unset, Y := unset, WriterFn := 0, NotifyFn := 0) {
	HasX := IsSet(X)
	HasY := IsSet(Y)
	XValue := 0
	YValue := 0
	if HasX
		XValue := X
	if HasY
		YValue := Y
	BuildFn := _WPMWidget_BuildPositionCandidate.Bind(HasX, XValue,
		HasY, YValue)
	return _WPMWidget_SaveBuilt(BuildFn, "widget position", WriterFn, NotifyFn)
}

; Resets the widget to its default bottom-right position and saves it to config.
WPMWidget_ResetPosition(WriterFn := 0, NotifyFn := 0, DefaultPosFn := 0,
		ShowPosFn := 0, MoveFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WPMWidget_ResetPosition(WriterFn, NotifyFn, DefaultPosFn,
			ShowPosFn, MoveFn)
		finally Critical(InheritedCritical)
	}
	if HasMethod(DefaultPosFn, "Call") {
		DefaultPos := DefaultPosFn.Call()
		def_x := DefaultPos.x
		def_y := DefaultPos.y
	} else
		WPMWidget_DefaultPos(&def_x, &def_y)
	if !WPMWidget_SavePosition(def_x, def_y, WriterFn, NotifyFn)
		return false
	if WPMWidget.visible {
		if HasMethod(ShowPosFn, "Call") {
			ShowPos := ShowPosFn.Call()
			show_x := ShowPos.x
			show_y := ShowPos.y
		} else
			WPMWidget_ShowPos(&show_x, &show_y)
		gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
		if gui_ref {
			try {
				if HasMethod(MoveFn, "Call")
					MoveFn.Call(gui_ref, show_x, show_y)
				else
					gui_ref.Move(show_x, show_y)
			}
		}
	}
	return true
}

_WPMWidget_BuildDisplayCandidate(HasColors, Colors, HasGraph, Graph, HasX, X,
		HasY, Y) {
	TargetColors := HasColors ? !!Colors : WPMWidget.use_colors
	TargetGraph := HasGraph ? !!Graph : WPMWidget.show_graph
	TargetX := HasX ? X : WPMWidget.pos_x
	TargetY := HasY ? Y : WPMWidget.pos_y
	PublishFn := _WPMWidget_PublishDisplayCandidate.Bind(TargetColors,
		TargetGraph, TargetX, TargetY)
	return { updates: [
		{ Section: "metrics", Key: WPMWidgetConst.CFG_COLORS, Value: TargetColors },
		{ Section: "metrics", Key: WPMWidgetConst.CFG_GRAPH, Value: TargetGraph },
		{ Section: "metrics", Key: WPMWidgetConst.CFG_X,      Value: TargetX },
		{ Section: "metrics", Key: WPMWidgetConst.CFG_Y,      Value: TargetY },
	], publish: PublishFn }
}

_WPMWidget_BuildDisplayToggleCandidate(Field) {
	switch Field {
	case "colors":
		return _WPMWidget_BuildDisplayCandidate(true,
			!WPMWidget.use_colors, false, false, false, 0, false, 0)
	case "graph":
		return _WPMWidget_BuildDisplayCandidate(false, false,
			true, !WPMWidget.show_graph, true, -1, true, -1)
	default:
		throw ValueError("Unknown WPM display toggle field: " . Field)
	}
}

WPMWidget_SaveConfig(Colors := unset, Graph := unset, X := unset, Y := unset,
		WriterFn := 0, NotifyFn := 0) {
	HasColors := IsSet(Colors)
	HasGraph := IsSet(Graph)
	HasX := IsSet(X)
	HasY := IsSet(Y)
	ColorsValue := false
	GraphValue := false
	XValue := 0
	YValue := 0
	if HasColors
		ColorsValue := Colors
	if HasGraph
		GraphValue := Graph
	if HasX
		XValue := X
	if HasY
		YValue := Y
	BuildFn := _WPMWidget_BuildDisplayCandidate.Bind(
		HasColors, ColorsValue,
		HasGraph, GraphValue,
		HasX, XValue,
		HasY, YValue)
	return _WPMWidget_SaveBuilt(BuildFn, "widget display settings",
		WriterFn, NotifyFn)
}

WPMWidget_ToggleColorsConfig(WriterFn := 0, NotifyFn := 0) {
	BuildFn := _WPMWidget_BuildDisplayToggleCandidate.Bind("colors")
	return _WPMWidget_SaveBuilt(BuildFn, "widget display settings",
		WriterFn, NotifyFn)
}

WPMWidget_ToggleGraphConfig(WriterFn := 0, NotifyFn := 0) {
	BuildFn := _WPMWidget_BuildDisplayToggleCandidate.Bind("graph")
	return _WPMWidget_SaveBuilt(BuildFn, "widget display settings",
		WriterFn, NotifyFn)
}
