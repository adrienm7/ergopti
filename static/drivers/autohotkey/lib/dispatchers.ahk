; static/drivers/autohotkey/lib/dispatchers.ahk

; ==============================================================================
; MODULE: Action Dispatchers
; DESCRIPTION:
; Centralised dispatch tables and helpers used by the shortcut and tap-hold
; modules to turn a Features sub-map (e.g. ``Features["Shortcuts"]["AltGrLAlt"]``)
; into the action that should fire when its trigger key is pressed.
;
; FEATURES & RATIONALE:
; 1. ``SIMPLE_ACTIONS`` is the canonical name → action mapping shared by every
;    « pick the first enabled flag and run its action » dispatcher in the
;    codebase. Adding a new action becomes a one-line Map entry instead of
;    propagating a new branch across four sister functions.
; 2. ``RunFirstSimpleAction`` walks a Features sub-map, returns ``true`` if it
;    fired an action, ``false`` otherwise — callers that still need bespoke
;    pre/post handling (Shift inversion, OneShotShiftFix, Ctrl wrap) keep that
;    logic local and only delegate the trailing simple-action cascade.
; 3. ``HasAnyEnabled`` collapses the verbose ``or`` chains used in ``#HotIf``
;    blocks into a single expression evaluated once at boot, eliminating the
;    repeated 10-OR predicate evaluation that otherwise happens on every key
;    press routed through the gated combo.
;
; DEPENDENCIES:
; The action callbacks reference ``ToggleCapsLock``, ``ToggleCapsWord`` and
; ``OneShotShift`` defined in modules/tap_holds.ahk. AHK v2 resolves these
; lazily at call time, so the include order does not matter as long as both
; files are part of the same compilation unit.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Action table =======
; ============================================
; ============================================

; Canonical action map. ``SendEvent`` is used for keys whose output must remain
; eligible for downstream hotstring matching (BackSpace can correct a triggered
; sequence and let the new word fire its own hotstrings). The other actions are
; idempotent system-level operations where ``SendInput`` is preferred for its
; lower latency and inability to cascade unintentionally.
global SIMPLE_ACTIONS := Map(
	"BackSpace",     () => SendEvent("{BackSpace}"),
	"CapsLock",      () => ToggleCapsLock(),
	"CapsWord",      () => ToggleCapsWord(),
	"CtrlBackSpace", () => SendInput("^{BackSpace}"),
	"CtrlDelete",    () => SendInput("^{Delete}"),
	"Delete",        () => SendInput("{Delete}"),
	"Enter",         () => SendInput("{Enter}"),
	"Escape",        () => SendInput("{Escape}"),
	"OneShotShift",  () => OneShotShift(),
	"Tab",           () => SendInput("{Tab}"),
)

; AltGr tap-hold variant. ``{Blind}`` is appended to every Send so the still-held
; AltGr modifier is not re-sent by AHK, and ``UpdateLastSentCharacter`` is paired
; with each text-emitting action so deadkey / hotstring chains downstream see the
; correct previous character (or the empty marker for editing actions).
global TAPHOLD_ALTGR_ACTIONS := Map(
	"BackSpace",     () => (SendEvent("{Blind}{BackSpace}"), UpdateLastSentCharacter("BackSpace")),
	"CapsLock",      () => ToggleCapsLock(),
	"CapsWord",      () => ToggleCapsWord(),
	"CtrlBackSpace", () => (SendEvent("{Blind}^{BackSpace}"), UpdateLastSentCharacter("")),
	"CtrlDelete",    () => (SendEvent("{Blind}^{Delete}"), UpdateLastSentCharacter("")),
	"Delete",        () => (SendEvent("{Blind}{Delete}"), UpdateLastSentCharacter("Delete")),
	"Enter",         () => (SendEvent("{Blind}{Enter}"), UpdateLastSentCharacter("Enter")),
	"Escape",        () => SendEvent("{Escape}"),
	"OneShotShift",  () => OneShotShift(),
	"Tab",           () => (SendEvent("{Blind}{Tab}"), UpdateLastSentCharacter("Tab")),
)




; ==================================================
; ==================================================
; ======= 2/ Dispatch and predicate helpers =======
; ==================================================
; ==================================================

; Walk ``FeatureGroup`` (a Features sub-map of action-name → config object)
; and run the first action whose ``Enabled`` flag is true. Skips the
; ``__Configuration`` sentinel entry. Returns true when an action fired so
; callers can decide whether to also run a fallback path.
RunFirstSimpleAction(FeatureGroup) {
	return _RunFirstActionFromMap(FeatureGroup, SIMPLE_ACTIONS)
}

; Same contract as RunFirstSimpleAction but using the {Blind}/last-character
; variant tailored for AltGr tap-hold dispatch.
RunFirstAltGrTapHoldAction(FeatureGroup) {
	return _RunFirstActionFromMap(FeatureGroup, TAPHOLD_ALTGR_ACTIONS)
}

_RunFirstActionFromMap(FeatureGroup, ActionMap) {
	for ActionName, Cfg in FeatureGroup {
		if (ActionName == "__Configuration") {
			continue
		}
		if (
			IsObject(Cfg)
			and Cfg.HasOwnProp("Enabled")
			and Cfg.Enabled
			and ActionMap.Has(ActionName)
		) {
			try LoggerDebug("Dispatch", "Firing action %s", ActionName)
			ActionMap[ActionName]()
			return true
		}
	}
	return false
}

; Return true when at least one entry in ``Group`` (a Features sub-map) has
; ``Enabled = true``. Used to gate ``#HotIf`` blocks so the predicate is
; evaluated once at boot instead of on every key event.
HasAnyEnabled(Group) {
	for Key, Val in Group {
		if (Key == "__Configuration") {
			continue
		}
		if (IsObject(Val) and Val.HasOwnProp("Enabled") and Val.Enabled) {
			return true
		}
	}
	return false
}
