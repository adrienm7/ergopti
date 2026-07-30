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

; Reads _shared/modules/wpm_widget/constants.toml and _shared/modules/timings/constants.toml at
; startup and populates the zero-initialised fields of WPMWidgetConst.
; Logs an error and leaves the zeros in place if the file cannot be found.
WPMWidget_LoadSharedConst() {
		global _SharedDir
		wpm_path     := _SharedDir . "\modules\wpm_widget\constants.toml"
		timings_path := _SharedDir . "\modules\timings\constants.toml"

		wpm_c := ParseTomlFile(wpm_path)
		if !wpm_c.Count {
				LoggerError("WPMWidget", "_shared/modules/wpm_widget/constants.toml not found — widget non-functional.")
				return
		}

		; [compact]
		WPMWidgetConst.W                := Integer(IniCacheGet(wpm_c, "compact", "width",                  "80"))
		WPMWidgetConst.H                := Integer(IniCacheGet(wpm_c, "compact", "height",                 "68"))
		WPMWidgetConst.H_NUMBER         := Integer(IniCacheGet(wpm_c, "compact", "height_number",          "44"))
		WPMWidgetConst.H_GAP            := Integer(IniCacheGet(wpm_c, "compact", "height_gap",             "4"))
		WPMWidgetConst.H_UNIT           := Integer(IniCacheGet(wpm_c, "compact", "height_unit",            "20"))
		WPMWidgetConst.NUMBER_FONT_SIZE := Integer(IniCacheGet(wpm_c, "compact", "number_font_size",       "20"))
		WPMWidgetConst.UNIT_FONT_SIZE   := Integer(IniCacheGet(wpm_c, "compact", "unit_font_size",         "8"))
		WPMWidgetConst.UNIT_DARKEN      := Float(IniCacheGet(wpm_c, "compact",   "unit_strip_darken_factor","0.40"))

		; [colors]  — strip leading '#' for AHK Gui compatibility
		_strip := (s) => (SubStr(s, 1, 1) = "#") ? SubStr(s, 2) : s
		WPMWidgetConst.COLOR_BG_MANUAL  := _strip(IniCacheGet(wpm_c, "colors", "bg_manual",   "#0055cc"))
		WPMWidgetConst.COLOR_BG_AI      := _strip(IniCacheGet(wpm_c, "colors", "bg_ai",       "#7a30b0"))
		WPMWidgetConst.COLOR_BG_IDLE    := _strip(IniCacheGet(wpm_c, "colors", "bg_idle",     "#1a1a2e"))
		WPMWidgetConst.COLOR_TXT_ACTIVE := _strip(IniCacheGet(wpm_c, "colors", "text_active", "#ffffff"))
		WPMWidgetConst.COLOR_TXT_IDLE   := _strip(IniCacheGet(wpm_c, "colors", "text_idle",   "#555577"))

		; [colors] — HSL normalisation target (same brightness as bg_manual)
		WPMWidgetConst.COLOR_WIDGET_L := Float(IniCacheGet(wpm_c, "colors", "widget_hsl_l", "0.40"))
		WPMWidgetConst.COLOR_WIDGET_S := Float(IniCacheGet(wpm_c, "colors", "widget_hsl_s", "1.00"))

		; [transparency]
		WPMWidgetConst.ALPHA_ACTIVE := Integer(IniCacheGet(wpm_c, "transparency", "alpha_active", "220"))
		WPMWidgetConst.ALPHA_IDLE   := Integer(IniCacheGet(wpm_c, "transparency", "alpha_idle",   "140"))

		; _shared/modules/timings/constants.toml
		tim_c := ParseTomlFile(timings_path)
		if tim_c.Count {
				WPMWidgetConst.IDLE_HIDE_MS  := Integer(IniCacheGet(tim_c, "ui", "wpm_widget_idle_hide_ms", "3000"))
				WPMWidgetConst.COLOR_HOLD_MS := Integer(IniCacheGet(tim_c, "ui", "wpm_color_hold_ms",       "1000"))
		} else {
				LoggerError("WPMWidget", "_shared/modules/timings/constants.toml not found — IDLE_HIDE_MS and COLOR_HOLD_MS defaulting.")
				WPMWidgetConst.IDLE_HIDE_MS  := 3000
				WPMWidgetConst.COLOR_HOLD_MS := 1000
		}

		LoggerDone("WPMWidget", "Shared constants loaded (W={1} H={2} darken={3} idle={4}ms color_hold={5}ms).",
				WPMWidgetConst.W, WPMWidgetConst.H, WPMWidgetConst.UNIT_DARKEN, WPMWidgetConst.IDLE_HIDE_MS, WPMWidgetConst.COLOR_HOLD_MS)
}


; Called once at startup to restore position and visibility from config.
WPMWidget_LoadConfig(Cache) {
		WPMWidget_LoadSharedConst()
		raw_vis    := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_VISIBLE)
		raw_x      := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_X)
		raw_y      := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_Y)
		raw_colors := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_COLORS)
		raw_graph  := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_GRAPH)

		; Position is one atomic configuration value: accepting X while blindly
		; converting a malformed Y throws during boot after other input subsystems
		; are already live. Retain the class defaults unless BOTH coordinates are
		; explicitly present and integer-shaped.
		if (raw_x != "_" && raw_x != "" && IsInteger(raw_x)
				&& raw_y != "_" && raw_y != "" && IsInteger(raw_y)) {
				MonitorGetWorkArea(, , , , &wb_check)
				saved_y := Integer(raw_y)
				; Discard saved position if it places the widget below the work area —
				; this catches stale coordinates from older versions that used a different anchor.
				if (saved_y + WPMWidgetConst.H <= wb_check) {
						WPMWidget.pos_x := Integer(raw_x)
						WPMWidget.pos_y := saved_y
				}
		}
		if (raw_colors = "1" || raw_colors = true)
				WPMWidget.use_colors := true
		if (raw_graph = "1" || raw_graph = true)
				WPMWidget.show_graph := true

		if (raw_vis = "1" || raw_vis = true)
				WPMWidget.visible := true
		LoggerDone("WPMWidget", "Config loaded — raw_vis=[{1}] visible={2}, x={3}, y={4}, colors={5}, graph={6}.",
				raw_vis, WPMWidget.visible, WPMWidget.pos_x, WPMWidget.pos_y,
				WPMWidget.use_colors, WPMWidget.show_graph)
}

_WPMWidget_SaveBatch(Updates, Operation) {
		global ConfigurationFile
		try {
				if TOML_BatchWrite(ConfigurationFile, Updates)
						return true
				LoggerError("WPMWidget", "Could not persist {1}; live widget state was not changed.", Operation)
		} catch as err {
				LoggerError("WPMWidget", "Could not persist {1}: {2}; live widget state was not changed.",
						Operation, err.Message)
		}
		return false
}

WPMWidget_SaveVisible(Visible := unset) {
		TargetVisible := IsSet(Visible) ? !!Visible : WPMWidget.visible
		return _WPMWidget_SaveBatch([
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: TargetVisible ? "1" : "0" },
		], "widget visibility")
}

WPMWidget_SavePosition(X := unset, Y := unset) {
		TargetX := IsSet(X) ? X : WPMWidget.pos_x
		TargetY := IsSet(Y) ? Y : WPMWidget.pos_y
		return _WPMWidget_SaveBatch([
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_X, Value: String(TargetX) },
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_Y, Value: String(TargetY) },
		], "widget position")
}

; Resets the widget to its default bottom-right position and saves it to config.
WPMWidget_ResetPosition() {
		WPMWidget_DefaultPos(&def_x, &def_y)
		if !WPMWidget_SavePosition(def_x, def_y)
				return false
		WPMWidget.pos_x := def_x
		WPMWidget.pos_y := def_y
		if WPMWidget.visible {
				WPMWidget_ShowPos(&show_x, &show_y)
				gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
				if gui_ref
						try gui_ref.Move(show_x, show_y)
		}
		return true
}

WPMWidget_SaveConfig(Colors := unset, Graph := unset, X := unset, Y := unset) {
		TargetColors := IsSet(Colors) ? !!Colors : WPMWidget.use_colors
		TargetGraph := IsSet(Graph) ? !!Graph : WPMWidget.show_graph
		TargetX := IsSet(X) ? X : WPMWidget.pos_x
		TargetY := IsSet(Y) ? Y : WPMWidget.pos_y
		return _WPMWidget_SaveBatch([
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS, Value: TargetColors ? "1" : "0" },
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,  Value: TargetGraph  ? "1" : "0" },
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_X,      Value: String(TargetX) },
				{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_Y,      Value: String(TargetY) },
		], "widget display settings")
}
