; infra/metrics/metrics_shortcuts.ahk

; ==============================================================================
; MODULE: Metrics Preferences
; DESCRIPTION:
; Owns collection consent and WPM color preferences through the shared
; configuration lease. Dashboard actions use the ordinary shortcut and gesture
; owners; historical dedicated shortcut fields remain unowned source data.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class MetricsShortcuts {
		; OFF by default. The keylogger captures every keystroke, so we never
		; auto-enable it: the user must tick it on once and confirm the
		; warning dialog. The choice persists across reloads via INI.
		static enabled           := false
		; Real-time WPM display prefs.
		static wpm_menubar_colors     := false  ; Color-code menubar WPM by keystroke origin
}





; =====================================
; =====================================
; ======= 3/ Path + INI helpers =======
; =====================================
; =====================================

; The configuration owner builds the Metrics preference batch under its lease.
; Historical dashboard binding leaves are deliberately absent from this owner.
MS_SaveBuiltToIni(Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
		Committed := CS_SaveBuilt(Context, BuildFn, WriterFn, NotifyFn)
		return (Committed is Integer) && Committed == 1
}

_MS_PreferenceConfigKey(Prop) {
		static Keys := Map(
				"enabled", "metrics_enabled",
				"wpm_menubar_colors", "metrics_wpm_menubar_colors"
		)
		return Keys.Get(Prop, "")
}

_MS_BuildPreferencePlan(Prop, Target) {
		ConfigKey := _MS_PreferenceConfigKey(Prop)
		if (ConfigKey = "")
				throw ValueError("Unknown metrics preference '" . Prop . "'.")
		Candidate := !!Target
		return {
				updates: [{ Section: "metrics", Key: ConfigKey, Value: Candidate }],
				publish: _MS_PublishPreferenceCandidate.Bind(Prop, Candidate)
		}
}

_MS_PublishPreferenceCandidate(Prop, Candidate) {
		MetricsShortcuts.%Prop% := Candidate
}

MS_CommitPreference(Prop, Target, WriterFn := 0, NotifyFn := 0) {
		return MS_SaveBuiltToIni("the '" . Prop . "' metrics preference",
				_MS_BuildPreferencePlan.Bind(Prop, Target), WriterFn, NotifyFn)
}
