; ui/menu/menu_metrics.ahk

; ==============================================================================
; MODULE: Tray Menu / Metrics Submenu
; DESCRIPTION:
; Builds the Metrics category submenu: typing/app tracking entries, privacy filters, app exclusion and the WPM widget options.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Canonical state-key getters for the ``disabled_when`` resolver (MG-1) —
; maps the manifest's driver-neutral keys to the concrete AHK state reads
; they proxy. Shared by every dynamic handler below so the dependency graph
; (which item greys out on which toggle) lives once in menu_manifest.json
; instead of being re-derived per handler.
global _MET_STATE_GETTERS := Map(
	"keylogger_enabled",       () => MetricsShortcuts.enabled,
	"wpm_widget_visible",      () => WPMWidget.visible,
	"metrics_widget_colors",   () => WPMWidget.use_colors,
	"metrics_widget_graph",    () => WPMWidget.show_graph,
	; Read by the manifest's checked_when predicates, so the checkmark state is
	; declared beside the row rather than restated in each handler.
	"metrics_filter_private",  () => MetricsFilters.private_browsing,
	"metrics_filter_secure",   () => MetricsFilters.secure_field,
	"metrics_filter_sysauth",  () => MetricsFilters.system_auth,
	; The encryption row became `check` on 2026-08-07, so its tick is read here
	; instead of being set by a handler.
	"metrics_encrypt_enabled", () => KL_Enc_IsEnabled(),
)

; Build the « 📊 Métriques » submenu. The caller publishes the completed tree
; to the tray, so expensive renderer work never runs after the live root has
; been cleared. Its first row is the category switch for the global keylogger
; feature: ticked from MetricsShortcuts.enabled, and clicking it runs
; ToggleMetricsEnabled() with a confirmation dialog before turning ON. The
; parent entry carries the same tick but cannot be clicked: a Win32 item that
; opens a submenu sends no command.
;
; When the feature is OFF, the sub-items remain visible (so the user can
; still see what the menu looks like) but are disabled — no dashboard can
; open, no shortcut binding takes effect.
BuildMetricsMenu() {
	global A_TrayMenu, _MET_STATE_GETTERS

	; The shared declaration owns labels, checks and disabled predicates.
	; This driver supplies native state reads and committed click effects.
	DynHandlers := Map()
	Commands := _MET_ScopeCommands()
	for Id, Handler in Map(
		"metrics_toggle",  (*) => ToggleMetricsEnabled(),
		"wpm_widget",      (*) => _ToggleWpmWidget(),
		"widget_colors",   (*) => _ToggleWpmWidgetColors(),
		"include_realtime", (*) => _ToggleWpmWidgetGraph(),
		"filter_private",  ToggleFilterPrivate,
		"filter_secure",   ToggleFilterSecureField,
		"filter_sysauth",  ToggleFilterSystemAuth,
		"encryption",         ToggleAtRestEncryption,
		"reset_wpm_position", (*) => WPMWidget_ResetPosition(),
		"show_typing",     KLUI_ToggleTyping,
		"show_apps",       KLUI_ToggleApps,
	)
		Commands[Id] := Handler

	; Only the app-exclusion count requires a computed label.
	ListProviders := Map(
		"exclude_apps", (*) => _MET_ExcludeAppsRows(_MET_STATE_GETTERS)
	)

	return MenuRenderer_Build("metrics_menu", "Metrics", DynHandlers, "", ListProviders, Commands, _MET_STATE_GETTERS)
}

; List provider: App exclusion — label reflects current count.
_MET_ExcludeAppsRows(Getters) {
	n := MF_DisabledCount()
	return [Map(
		"label", (n > 0)
			? StrReplace(StrReplace(t("menu.metrics.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
			: t("menu.metrics.exclude_apps"),
		"disabled", MenuRenderer_ResolveDisabledWhen("metrics_menu", "exclude_apps", Getters),
		"action",   OpenMetricsAppPicker)]
}

; Consent is excluded from recommendations by the shared scope declaration.
; The restore alone: the maintainer retired the Metrics clear on 2026-09-30.
; The Configuration clear still composes the metrics settings.
_MET_ScopeCommands(Options := unset) {
	Commands := ConfigScopeMenuCommands("metrics", Map(), IsSet(Options) ? Options : Map())
	Commands.Delete("scope_clear")
	return Commands
}
