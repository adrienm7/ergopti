; tests/support/wpm_widget_state_contract.ahk

; The headless runner deliberately omits the UI-only WPM display module, while
; the production SaveFullConfig canonicalization path reads its static state.
; A minimal contract double lets this test execute that real path instead of
; silently skipping it through the runner's otherwise-unset globals. The real
; MetricsFilters class is included centrally because its persistence paths now
; have behavioural global-barrier coverage.
class WPMWidgetConst {
	static CFG_VISIBLE := "wpm_widget_visible"
	static STORE_X := ""
	static STORE_Y := ""
	static CFG_COLORS := "wpm_widget_colors"
	static CFG_GRAPH := "wpm_widget_graph"
}

class WPMWidget {
	static visible := false
	static pos_x := 0
	static pos_y := 0
	static use_colors := false
	static show_graph := false
	static _gdip_font := 0
	static _gdip_fmt := 0
}

