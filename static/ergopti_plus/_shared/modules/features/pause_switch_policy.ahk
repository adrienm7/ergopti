; _shared/modules/features/pause_switch_policy.ahk

; ==============================================================================
; MODULE: Pause Switch Policy
; DESCRIPTION:
; Decides which keyboard layout a pause, a resume or a quit switches to, from
; the three [layout] settings declared in the features manifest. Twin of
; _shared/lua/layout/pause_switch_policy.lua; both replay
; tests/corpus/layouts/pause_switch_vectors.json. The driver keeps the native
; switch (WM_INPUTLANGCHANGEREQUEST), the picker and the lifecycle hooks.
; ==============================================================================

#Requires AutoHotkey v2.0




; The settings the policy reads, by role.
global PAUSE_SWITCH_POLICY_PATHS := Map(
	"enabled", "layout.pause_switch_enabled",
	"on_pause", "layout.on_pause",
	"on_resume", "layout.on_resume"
)

; Quitting leaves the keyboard on the layout a pause selects: a quit has no
; setting of its own, and a user who wants their system layout back while
; ErgoptiPlus is not typing gets it whether they paused or quit.
global PAUSE_SWITCH_POLICY_EVENT_FIELDS := Map(
	"pause", "on_pause",
	"resume", "on_resume",
	"quit", "on_pause"
)

/**
 * Whether a stored target is a value the setting can hold: a layout id, or ""
 * for « no change ».
 * @param {Any} Value
 * @returns {Boolean}
 */
PauseSwitchPolicyValidTarget(Value) {
	return Value is String
}

/**
 * The layout id a target names, "" for « no change » or a value that is no id.
 * @param {Any} Value
 * @returns {String}
 */
PauseSwitchPolicyTargetId(Value) {
	return (Value is String) ? Value : ""
}

/**
 * The layout an event switches to, "" when nothing switches: the switch is
 * off (only an exact true is on), or the event's target is « no change ».
 * @param {Map} Settings Keys "enabled", "on_pause", "on_resume"; absent = unset.
 * @param {String} Event "pause", "resume" or "quit".
 * @returns {String}
 * @throws {ValueError} For an unknown event.
 * @throws {TypeError} When Settings is not a Map.
 */
PauseSwitchPolicyTarget(Settings, Event) {
	global PAUSE_SWITCH_POLICY_EVENT_FIELDS
	if !(Event is String) || !PAUSE_SWITCH_POLICY_EVENT_FIELDS.Has(Event)
		throw ValueError("unknown pause switch event: " . String(Event))
	if !(Settings is Map)
		throw TypeError("pause switch settings must be a Map")
	Enabled := Settings.Get("enabled", false)
	if !((Enabled is Integer) && Enabled == 1)
		return ""
	return PauseSwitchPolicyTargetId(Settings.Get(PAUSE_SWITCH_POLICY_EVENT_FIELDS[Event], ""))
}
