; lib/metrics/metrics_shortcuts.ahk

; ==============================================================================
; MODULE: Metrics Shortcuts
; DESCRIPTION:
; Persists and applies user-defined hotkeys for the two metrics dashboards.
; Mirrors the role of `apply_metrics_shortcut` / `apply_apps_time_shortcut`
; on the Hammerspoon side.
;
; FEATURES & RATIONALE:
; 1. INI persistence: the chosen hotkey (e.g. "^!m") is saved next to the
;    other AHK config so it survives restarts and is editable by hand.
; 2. Toggle binding: only one hotkey at a time per action — re-binding
;    automatically unregisters the previous one.
; 3. AHK ↔ HS naming: the user types "cmd+alt+m" or "ctrl+alt+m"; we
;    translate to AHK modifier syntax (^!#+) for Hotkey().
;
; STORAGE FORMAT (metrics_shortcuts.ini):
;   [shortcuts]
;   typing = ctrl+alt+m
;   apps   = ctrl+alt+t
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; AHK modifier prefix mapping. ``cmd`` is treated as ``win`` since macOS Cmd
; ≡ Windows key on a typical layout.
global METRICS_MOD_MAP := Map(
		"ctrl",   "^",
		"alt",    "!",
		"option", "!",
		"shift",  "+",
		"win",    "#",
		"cmd",    "#"
)





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
		static typing_str        := ""    ; e.g. "ctrl+alt+m"
		static apps_str          := ""
		static typing_ahk        := ""    ; e.g. "^!m"  (active hotkey string)
		static apps_ahk          := ""
		; Real-time WPM display prefs.
		static wpm_menubar_colors     := false  ; Color-code menubar WPM by keystroke origin
}





; =====================================
; =====================================
; ======= 3/ Path + INI helpers =======
; =====================================
; =====================================

; Persistence delegates to lib/config_shortcuts.ahk which owns the
; [shortcuts] section inside <config_dir>/config.toml. The MS_* names
; survive as thin shims so existing call sites keep working without
; needing a global rename.
MS_LoadFromIni() {
		CS_Load()
}

MS_SaveToIni() {
		CS_Save()
}





; =========================================
; =========================================
; ======= 4/ AHK hotkey translation =======
; =========================================
; =========================================

MS_ToAhkSyntax(human) {
		; "ctrl+alt+m" → "^!m"
		; Returns "" when the input is empty / malformed.
		human := Trim(StrLower(human))
		if (human = "")
				return ""
		parts := StrSplit(human, "+", " `t")
		if (parts.Length < 1)
				return ""

		key  := parts[parts.Length]
		mods := ""
		Loop parts.Length - 1 {
				m := Trim(parts[A_Index])
				; An unrecognised modifier must reject the whole string, not be dropped.
				; Dropping it still yields a syntactically valid Hotkey() name, so
				; Hotkey() succeeds, MS_BindHotkey sees success and
				; MS_ShouldPersistShortcut persists it — and "control+alt+m" (a typo for
				; "ctrl") silently binds Alt+M instead. The user then sees their own
				; text echoed back as the active binding while a different key fires,
				; on this boot and every boot after, since MS_ApplyAll replays it.
				if !METRICS_MOD_MAP.Has(m) {
						try LoggerWarn("MetricsShortcuts",
								"Rejected shortcut '{1}': unknown modifier '{2}'.", human, m)
						return ""
				}
				mods .= METRICS_MOD_MAP[m]
		}

		; Both single-char ("m") and named ("f1", "space", "enter") keys are valid
		; Hotkey() names as bare concatenation — braces are Send syntax only.
		return mods . key
}





; ==========================================
; ==========================================
; ======= 5/ Hotkey (un)registration =======
; ==========================================
; ==========================================

MS_BindHotkey(prev_ahk, new_human, callback) {
		; Returns the new ahk-syntax string actually bound, or "".
		if (prev_ahk != "") {
				try Hotkey(prev_ahk, "Off")
		}
		if (new_human = "")
				return ""
		new_ahk := MS_ToAhkSyntax(new_human)
		if (new_ahk = "")
				return ""
		try {
				Hotkey(new_ahk, callback, "On")
				return new_ahk
		}
		catch as err {
				MsgBox(Format(t("metrics.shortcut_register_error"), new_human, err.Message),
						t("metrics.shortcut_invalid_title"), "Iconx")
				return ""
		}
}

MS_ApplyAll(ToggleTypingFn, ToggleAppsFn) {
		; (Re)register both hotkeys based on the current persisted strings.
		MetricsShortcuts.typing_ahk := MS_BindHotkey(
				MetricsShortcuts.typing_ahk,
				MetricsShortcuts.typing_str,
				ToggleTypingFn)
		MetricsShortcuts.apps_ahk := MS_BindHotkey(
				MetricsShortcuts.apps_ahk,
				MetricsShortcuts.apps_str,
				ToggleAppsFn)
}





; =====================================
; =====================================
; ======= 6/ Interactive editor =======
; =====================================
; =====================================

; Decides whether a candidate shortcut string is safe to persist to disk.
; ``raw`` is the trimmed, lower-cased user input; ``bound_ahk`` is what
; MS_BindHotkey() actually managed to register ("" on a rejected Hotkey() call
; OR on an explicit clear). A cleared shortcut (raw == "") is always safe to
; persist. A non-empty raw that failed registration must NOT be persisted --
; else the same broken string is replayed by MS_ApplyAll() on every future
; boot, re-triggering the Hotkey() failure (and its blocking MsgBox) forever.
; @param raw {String} The trimmed, lower-cased user input.
; @param bound_ahk {String} The AHK-syntax hotkey MS_BindHotkey() bound, or "".
; @returns {Boolean} True when ``raw`` is safe to write to the persisted state.
MS_ShouldPersistShortcut(raw, bound_ahk) {
		return (raw = "") || (bound_ahk != "")
}

MS_PromptShortcut(which, ToggleFn) {
		; Shows an InputBox to capture the new shortcut. ``which`` ∈
		; {"typing", "apps"}. Empty string clears the binding.
		label := (which = "typing") ? t("keylogger_ui.typing_metrics") : t("keylogger_ui.app_metrics")
		cur   := (which = "typing") ? MetricsShortcuts.typing_str : MetricsShortcuts.apps_str
		msg := t("metrics.shortcut_format_hint")
		ib := InputBox(msg, Format(t("metrics.shortcut_prompt_title"), label), "w400 h160", cur)
		if (ib.Result != "OK")
				return
		raw := Trim(StrLower(ib.Value))

		if (which = "typing") {
				new_ahk := MS_BindHotkey(MetricsShortcuts.typing_ahk, raw, ToggleFn)
				if MS_ShouldPersistShortcut(raw, new_ahk) {
						MetricsShortcuts.typing_str := raw
				} else {
						LoggerWarn("MetricsShortcuts", "Shortcut '{1}' failed Hotkey() registration for '{2}' — keeping previous value '{3}' instead of persisting the broken string.", raw, which, MetricsShortcuts.typing_str)
				}
				MetricsShortcuts.typing_ahk := new_ahk
		} else {
				new_ahk := MS_BindHotkey(MetricsShortcuts.apps_ahk, raw, ToggleFn)
				if MS_ShouldPersistShortcut(raw, new_ahk) {
						MetricsShortcuts.apps_str := raw
				} else {
						LoggerWarn("MetricsShortcuts", "Shortcut '{1}' failed Hotkey() registration for '{2}' — keeping previous value '{3}' instead of persisting the broken string.", raw, which, MetricsShortcuts.apps_str)
				}
				MetricsShortcuts.apps_ahk := new_ahk
		}
		MS_SaveToIni()
}

MS_GetDisplayLabel(which) {
		s := (which = "typing") ? MetricsShortcuts.typing_str : MetricsShortcuts.apps_str
		if (s = "")
				return t("menu.metrics.shortcut_none")
		return s
}
