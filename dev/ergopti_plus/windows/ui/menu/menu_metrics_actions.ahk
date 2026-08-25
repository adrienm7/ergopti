; ui/menu/menu_metrics_actions.ahk

; ==============================================================================
; MODULE: Tray Menu / Metrics Actions
; DESCRIPTION:
; Click-handler actions for the Metrics submenu: privacy-filter toggles, WPM widget toggles, the app-exclusion picker and the master metrics enable/disable toggle.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Filter preferences publish from the configuration gateway only after the
; candidate is durable. Reload is a second, strictly gated side effect: a
; terminal transition that refuses the commit must never receive a nested
; Reload request from the losing menu callback.
_MetricsReloadAfterCommit(Committed, ReloadFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _MetricsReloadAfterCommit(Committed, ReloadFn)
		finally Critical(InheritedCritical)
	}
	if !(Committed is Integer) || Committed != 1
		return false
	try {
		Reloaded := HasMethod(ReloadFn, "Call")
			? ReloadFn.Call()
			: ReloadPreservingSuspend()
	} catch as Err {
		try LoggerError("MetricsMenu",
			"Could not reload after the durable metrics preference commit: {1}.",
			Err.Message)
		return false
	}
	return (Reloaded is Integer) && Reloaded == 1
}

_MetricsToggleFilterAndReload(Prop, WriterFn := 0, NotifyFn := 0,
		ReloadFn := 0) {
	Committed := MF_CommitFilterToggle(Prop, WriterFn, NotifyFn)
	return _MetricsReloadAfterCommit(Committed, ReloadFn)
}

ToggleFilterPrivate(*) {
	return _MetricsToggleFilterAndReload("private_browsing")
}

ToggleFilterSecureField(*) {
	return _MetricsToggleFilterAndReload("secure_field")
}

ToggleFilterSystemAuth(*) {
	return _MetricsToggleFilterAndReload("system_auth")
}

; At-rest encryption of the typed-text columns. Refuses to enable when no key can
; be derived on this machine — a box that reports encryption while nothing
; encrypts is exactly the macOS defect this feature set out to fix.
;
; The rows ALREADY in data.sql are converted too, but not from here: this handler
; ends in a reload, which would kill any pass started on this stack. The reload
; comes back, restores the setting from the INI and reaches
; KL_Mig_SyncToPosture, which compares the ledger's recorded posture against the
; new one and starts the rewrite there.
ToggleAtRestEncryption(*) {
	return _MetricsToggleEncryptionAndReload()
}

_MetricsToggleEncryptionAndReload(WriterFn := 0, NotifyFn := 0,
		ReloadFn := 0, ApplyFn := 0, AvailableFn := 0) {
	Committed := MF_CommitEncryptionToggle(WriterFn, NotifyFn, ApplyFn,
		AvailableFn)
	return _MetricsReloadAfterCommit(Committed, ReloadFn)
}

; ── WPM toggle helpers — closures capture the menu reference and label strings
; from BuildMetricsMenu locals, so no global state is needed. ──────────────────

_ToggleWpmWidget(menu, widget_lbl, colors_lbl, graph_lbl, ToggleFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _ToggleWpmWidget(menu, widget_lbl, colors_lbl, graph_lbl,
			ToggleFn)
		finally Critical(InheritedCritical)
	}
	Toggled := HasMethod(ToggleFn, "Call") ? ToggleFn.Call() : WPMWidget_Toggle()
	if !(Toggled is Integer) || Toggled != 1
		return
	try menu.ToggleCheck(widget_lbl)
	if WPMWidget.visible {
		try menu.Enable(colors_lbl)
		try menu.Enable(graph_lbl)
	} else {
		try menu.Disable(colors_lbl)
		try menu.Disable(graph_lbl)
	}
}

_ToggleWpmWidgetColors(menu, label, WriterFn := 0, NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _ToggleWpmWidgetColors(menu, label, WriterFn, NotifyFn)
		finally Critical(InheritedCritical)
	}
	if !WPMWidget_ToggleColorsConfig(WriterFn, NotifyFn)
		return
	try menu.ToggleCheck(label)
}

_ToggleWpmWidgetGraph(menu, label, WriterFn := 0, NotifyFn := 0, HideFn := 0,
		ShowFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _ToggleWpmWidgetGraph(menu, label, WriterFn, NotifyFn,
			HideFn, ShowFn)
		finally Critical(InheritedCritical)
	}
    ; Graph and its anchor form one persisted state. Commit the reset before
    ; destroying the live surface, so a disk failure leaves the current widget
    ; fully usable and its menu checkmark unchanged.
    if !WPMWidget_ToggleGraphConfig(WriterFn, NotifyFn)
        return
    was_visible := WPMWidget.visible
    ; Rebuild the widget in the new mode — compact and graph use different Gui layouts.
	if was_visible {
		if HasMethod(HideFn, "Call")
			HideFn.Call()
		else
			WPMWidget_Hide()
	}
	; Destroy existing GUI so it is rebuilt in the correct layout on next show.
	if WPMWidget._gui {
		try WPMWidget._gui.Destroy()
		WPMWidget._gui      := false
		WPMWidget._lbl_wpm  := false
		WPMWidget._lbl_unit := false
	}
	if WPMWidget._graph_gui {
		try WPMWidget._graph_gui.Destroy()
		WPMWidget._graph_gui := false
	}
    try menu.ToggleCheck(label)
	if was_visible {
		if HasMethod(ShowFn, "Call")
			ShowFn.Call()
		else
			WPMWidget_Show()
	}
}

OpenMetricsAppPicker(*) {
	AppPicker_Show(Map(
		"owner",    "metrics:disabled_apps",
		"title",    t("dialog.metrics.exclude_title"),
		"prompt",   t("dialog.metrics.exclude_prompt"),
		"ok_label", t("dialog.metrics.exclude_ok"),
		"initial",  MF_DisabledList(),
		"on_save",  OnMetricsAppPickerSave
	))
}

OnMetricsAppPickerSave(Selected, Receipt) {
	return _MetricsSaveAppPickerAndReload(Selected, 0, 0, 0, Receipt)
}

_MetricsSaveAppPickerAndReload(Selected, WriterFn := 0, NotifyFn := 0,
		ReloadFn := 0, Receipt := 0) {
	; The picker result is normalized into a detached Map by the owned builder;
	; the live exclusion lookup remains unchanged while config.toml is written.
	Committed := MF_CommitDisabledApps(Selected, WriterFn, NotifyFn, Receipt)
	return _MetricsReloadAfterCommit(Committed, ReloadFn)
}

_MetricsSetPreferenceAndReload(Prop, Target, WriterFn := 0, NotifyFn := 0,
		ReloadFn := 0) {
	Committed := MS_CommitPreference(Prop, Target, WriterFn, NotifyFn)
	return _MetricsReloadAfterCommit(Committed, ReloadFn)
}

_MetricsSetEnabledAndReload(Target, WriterFn := 0, NotifyFn := 0,
		ReloadFn := 0) {
	return _MetricsSetPreferenceAndReload("enabled", Target, WriterFn,
		NotifyFn, ReloadFn)
}

; Flip the global keylogger feature with a warning dialog before enabling.
; Persisted via metrics_shortcuts.ini and applied on Reload (the keylogger
; can only initialise its file IO at boot, not mid-session, mirroring the
; Hammerspoon behaviour where toggling the feature triggers HS reload).
ToggleMetricsEnabled() {
	if MetricsShortcuts.enabled {
		; Disabling — no warning needed, just confirm.
		res := MsgBox(
			t("dialog.metrics.disable_confirm"),
			t("dialog.metrics.title"),
			"OKCancel Icon?"
		)
		if (res != "OK")
			return
		return _MetricsSetEnabledAndReload(false)
	}

	; Enabling — explicit warning, OK is the dangerous action. The metrics
	; folder lives under the user-resolved _ConfigDir (paths.toml override
	; honoured) so the displayed path matches reality, even when the user
	; has relocated their config.
	global _ConfigDir
	metrics_path := _ConfigDir . "metrics"
	warn := Format(t("dialog.metrics.enable_warning"), metrics_path)
	; Icon! = exclamation triangle (warning). Iconx is the red error stop
	; sign and was the wrong choice for a "you are about to enable a
	; logging feature" notice.
	res := MsgBox(warn, t("dialog.metrics.security_warning_title"), "OKCancel Icon!")
	if (res != "OK")
		return
	return _MetricsSetEnabledAndReload(true)
}
