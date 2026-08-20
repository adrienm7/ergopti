; ui/menu/menu_taphold.ahk

; ==============================================================================
; MODULE: Tray Menu / Tap-Hold Submenu
; DESCRIPTION:
; Builds the Tap-Hold category: per-key tap and hold pickers, reset/disable-all actions and the closure factory classes that bind a key id to a menu callback.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; Build the TapHolds submenu — one entry per physical key, each with a
; tap picker (modal GUI, same UI as gesture/shortcut pickers) and a hold
; picker submenu, mirroring the macOS Karabiner menu design.
;
; Render shape:
;
;   ☰ Tap-Hold
;     ↳ Réinitialiser les valeurs par défaut
;     ↳ Tout désactiver
;     ↳ ---
;     ↳ Tab  :  Alt-Tab / Alt          [checkmark when configured]
;       ↳ Rien (désactiver)
;       ↳ ---
;       ↳ Tap  → "Alt-Tab"             [opens modal action picker GUI]
;       ↳ Hold → "Alt"                 [opens hold picker submenu]
;     ↳ CapsLock  :  Entrée / Ctrl
;     ↳ …
;
; Tap picker: full GESTURE_ACTIONS list in the searchable modal GUI (ShowActionPicker).
; Hold picker: fixed set from _TH_HoldOptions (modifiers + nav layer + none).
; Both pickers persist immediately via WriteTapHoldTap / WriteTapHoldHold and
; reload the script to refresh the menu.
_BuildTapHoldsSubmenu() {
	Commands := Map(
		"reset_defaults", _TH_ResetAllToDefaults,
		"disable_all",    _TH_DisableAll
	)
	ListProviders := Map("tap_hold_keys", (*) => _TH_KeyRows())
	return MenuRenderer_Build("tap_holds_menu", "TapHolds", "", "", ListProviders, Commands)
}

; List provider: one row per configurable key.
;
; Row DATA since 2026-08-07. The tree is three levels — the key, its disable /
; tap / hold rows, and the hold picker's options — which is what the renderer
; allows, and none of it mutates a live menu: every action writes the user's
; tap_hold.toml and reloads the script, which rebuilds the tray from scratch.
_TH_KeyRows() {
	global TapHold
	Rows := []
	for _, KeyDef in TapHoldKeyDefs() {
		KeyId    := KeyDef["id"]
		KeyLabel := t(KeyDef["i18n"])
		TapLbl   := TapHoldCurrentTapLabel(KeyId)
		HoldLbl  := TapHoldCurrentHoldLabel(KeyId)

		IsConfigured := IsSet(TapHold) and TapHoldIsConfigured(TapHold, KeyId)

		NoneLabel  := t("tap_hold.tap.none")
		NoneHold   := t("tap_hold.hold.none")
		ComboLabel := (TapLbl == NoneLabel and HoldLbl == NoneHold)
			? "—"
			: (TapLbl . "  /  " . HoldLbl)
		ParentLabel := KeyLabel . "  :  " . ComboLabel

		; Indirection avoids a call-site occurrence of the function name before
		; its definition, which would cause the meta test's body-extractor to
		; resolve the wrong function body (see HIGH-07 regression guard).
		_HoldRowsBuilder := _TH_HoldPickerRows

		Rows.Push(Map(
			"label",   ParentLabel,
			"checked", IsConfigured,
			"items", [
				Map("label",    t("tap_hold.action.disable"),
					"disabled", !IsConfigured,
					"action",   _TH_MakeDisableFn(KeyId)),
				Map("separator", true),
				Map("label",  StrReplace(t("tap_hold.picker.tap"), "%s", TapLbl),
					"action", _TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl)),
				Map("label", StrReplace(t("tap_hold.picker.hold"), "%s", HoldLbl),
					"items", _HoldRowsBuilder(KeyId))
			]))
	}
	return Rows
}

; Return the "none" hold option map (first entry in _TH_HoldOptions).
_TH_NoneHoldOpt() {
	global _TH_HoldOptions
	return _TH_HoldOptions[1]
}

; ---- Global tap-hold actions --------------------------------------------------

; Reset all configured keys back to factory defaults by deleting the user
; tap_hold.toml (the loader will fall back to defaults.toml on next reload).
_TH_ResetAllToDefaults(*) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ResetTapHoldConfig()
		finally Critical(InheritedCritical)
	}
	return _TH_ResetTapHoldConfig()
}

; Delete the exact admitted target, then release its owner before Reload tries
; to acquire the process-wide terminal transition. Optional adapters make every
; refusal and path race deterministic in the behavioural suite.
_TH_ResetTapHoldConfig(DeleteFn := 0, AuthorizeFn := 0, ReloadFn := 0) {
	global TapHold
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ResetTapHoldConfig(DeleteFn, AuthorizeFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	for Adapter in [DeleteFn, AuthorizeFn, ReloadFn] {
		if !((Adapter is Integer) && Adapter == 0)
				&& !HasMethod(Adapter, "Call") {
			try LoggerError("TapHoldMenu", "Refusing reset with an invalid transaction adapter.")
			return false
		}
	}
	if !(TapHold is Map) {
		try LoggerError("TapHoldMenu", "Cannot reset tap-holds before live state is initialized.")
		return false
	}
	BoundPath := _TH_TapHoldConfigPath()
	if !(BoundPath is String) || BoundPath == "" {
		try LoggerError("TapHoldMenu", "Cannot reset tap-holds before the target path is initialized.")
		return false
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(BoundPath, "tap-hold-reset")
	if !(OwnerToken is Object) {
		try LoggerError("TapHoldMenu",
			"Cannot reset tap-holds: another configuration transaction is in progress.")
		return false
	}
	try LoggerInfo("TapHoldMenu",
		"Resetting all tap-hold overrides from defaults (script='{1}', pid={2}).",
		A_ScriptName, DriverPid)
	StartState := TapHold
	Authorized := false
	AuthorizeError := ""
	Deleted := false
	DeleteError := ""
	Released := false
	try {
		PreviousCritical := Critical("On")
		try {
			try Authorized := _TH_AuthorizeTapHoldCommit(OwnerToken,
				BoundPath, StartState, AuthorizeFn)
			catch as Err {
				Authorized := false
				AuthorizeError := Err.Message
			}
			Authorized := (Authorized is Integer) && Authorized == 1
		} finally Critical(PreviousCritical)
		if Authorized {
			try Deleted := HasMethod(DeleteFn, "Call")
				? DeleteFn.Call(BoundPath) : FSDeleteStrict(BoundPath)
			catch as Err {
				Deleted := false
				DeleteError := Err.Message
			}
			Deleted := (Deleted is Integer) && Deleted == 1
		}
	} finally {
		Released := _ConfigWriteLeaseRelease(OwnerToken)
	}
	if !(Released is Integer) || Released != 1 {
		try LoggerError("TapHoldMenu",
			"The tap-hold reset owner could not be released; Reload was not requested.")
		return false
	}
	if !Authorized {
		if (AuthorizeError != "") {
			try LoggerError("TapHoldMenu",
				"Authorization before deleting '{1}' failed: {2}. Reset was not applied.",
				BoundPath, AuthorizeError)
		} else {
			try LoggerError("TapHoldMenu",
				"Authorization before deleting '{1}' was refused. Reset was not applied.",
				BoundPath)
		}
		return false
	}
	if !Deleted {
		if (DeleteError != "") {
			try LoggerError("TapHoldMenu",
				"Could not delete '{1}': {2}. Reload was not requested.",
				BoundPath, DeleteError)
		} else {
			try LoggerError("TapHoldMenu",
				"Could not delete '{1}': the delete adapter refused it. Reload was not requested.",
				BoundPath)
		}
		return false
	}
	Reloaded := false
	ReloadError := ""
	try Reloaded := HasMethod(ReloadFn, "Call")
		? ReloadFn.Call("reset_defaults", "")
		: _TH_ReloadTapHoldMenu("reset_defaults", "")
	catch as Err {
		Reloaded := false
		ReloadError := Err.Message
	}
	if !(Reloaded is Integer) || Reloaded != 1 {
		if (ReloadError != "") {
			try LoggerError("TapHoldMenu",
				"Tap-hold defaults were reset, but Reload failed: {1}.",
				ReloadError)
		} else {
			try LoggerError("TapHoldMenu",
				"Tap-hold defaults were reset, but Reload was refused.")
		}
		return false
	}
	return 1
}

; Clear every configured key so all physical keys revert to their native OS
; behaviour (no tap remapping, no hold remapping).
_TH_DisableAll(*) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_DisableAll()
		finally Critical(InheritedCritical)
	}
	try LoggerInfo("TapHoldMenu", "Disabling all tap-hold mappings (script='{1}', pid={2}).", A_ScriptName, DriverPid)
	if !IsSet(_TH_WriteTapHoldDisabled) {
		try LoggerError("TapHoldMenu", "Disable-all unavailable: tap-hold writer is not loaded.")
		return false
	}
	if !_TH_WriteTapHoldDisabled()
		return false
	return _TH_ReloadTapHoldMenu("disable_all", "")
}

; ---- Callback classes ---------------------------------------------------------
; AHK v2 fat-arrow closures cannot contain multiple statements. These classes
; capture (KeyId, HoldOpt) by value and expose a Call() method bound via
; ObjBindMethod so AHK's Menu.Add() receives a valid callable.

class _TH_DisableFnObj {
	KeyId := ""
	Call(Args*) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
			Critical("Off")
			try return this.Call(Args*)
			finally Critical(InheritedCritical)
		}
		try LoggerInfo("TapHoldMenu", "Menu disable action requested for key '{1}' (pid={2}).", this.KeyId, DriverPid)
		if !WriteTapHoldNative(this.KeyId)
			return false
		return _TH_ReloadTapHoldMenu("key_disable", this.KeyId)
	}
}

class _TH_TapPickerFnObj {
	KeyId     := ""
	KeyLabel  := ""
	Call(*) {
		global TapHold
		; Current tap action at call time (not at menu-build time).
		; "" means native (unconfigured) — pass as-is; ShowNative:=true adds the entry.
		Current := IsSet(TapHold) ? TapHoldTapAction(TapHold, this.KeyId) : ""
		try LoggerDebug("TapHoldMenu", "Opening tap picker for '{1}' (current='{2}').", this.KeyId, (Current == "" ? "<native>" : Current))
		Title := t("tap_hold.picker.title_prefix") . this.KeyLabel
		_KeyId := this.KeyId
		ShowActionPicker(Title, Current, (Id) => _TH_ApplyTap(_KeyId, Id), true)
	}
}

class _TH_HoldFnObj {
	KeyId   := ""
	HoldOpt := ""
	Call(Args*) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
			Critical("Off")
			try return this.Call(Args*)
			finally Critical(InheritedCritical)
		}
		Kind := this.HoldOpt["kind"]
		OptId := this.HoldOpt["id"]
		try LoggerInfo("TapHoldMenu", "Hold picker selection for '{1}': kind='{2}', id='{3}' (pid={4}).", this.KeyId, Kind, OptId, DriverPid)
		if !WriteTapHoldHold(this.KeyId, this.HoldOpt)
			return false
		return _TH_ReloadTapHoldMenu("hold_set", this.KeyId)
	}
}

; Build a bound callback that clears both tap and hold for a key.
_TH_MakeDisableFn(KeyId) {
	obj := _TH_DisableFnObj()
	obj.KeyId := KeyId
	return ObjBindMethod(obj, "Call")
}

; Build a bound callback that opens the action picker modal for the tap slot.
_TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl) {
	obj := _TH_TapPickerFnObj()
	obj.KeyId    := KeyId
	obj.KeyLabel := KeyLabel
	return ObjBindMethod(obj, "Call")
}

; Apply a tap action chosen from the modal picker.
; ActionId="" (from the "Natif" sentinel) clears the slot so the key passes through natively.
; ActionId="none" sets the absorb no-op action.
_TH_ApplyTap(KeyId, ActionId) {
	global TapHold
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ApplyTap(KeyId, ActionId)
		finally Critical(InheritedCritical)
	}
	Current := IsSet(TapHold) ? TapHoldTapAction(TapHold, KeyId) : "<not_ready>"
	try LoggerInfo("TapHoldMenu", "ApplyTap key='{1}' current='{2}' -> '{3}' (pid={4}).", KeyId,
		(Current == "" ? "<native>" : Current), (ActionId == "" ? "<native>" : ActionId), DriverPid)
	if !GestureEnsureActionParameter(GestureBindingId("tap_hold", KeyId), ActionId)
		return false
	if !WriteTapHoldTap(KeyId, ActionId)
		return false
	return _TH_ReloadTapHoldMenu("tap_set", KeyId)
}

; Build the hold picker submenu for a given key. Shows the fixed hold options
; from _TH_HoldOptions; current selection is checked.
_TH_HoldPickerRows(KeyId) {
	global _TH_HoldOptions
	Rows := []
	for _, HoldOpt in _TH_HoldOptions {
		Label    := ""
		if (HoldOpt["kind"] == "modifier" && HoldOpt["i18n"] == "") {
			Label := _TH_HoldOptionLabel(HoldOpt["id"])
		} else {
			Label := t(HoldOpt["i18n"])
		}
		Rows.Push(Map(
			"label",   Label,
			"checked", IsTapHoldHoldActive(KeyId, HoldOpt),
			"action",  _TH_MakeHoldFn(KeyId, HoldOpt)))
	}
	return Rows
}

; Build a bound callback that writes a hold option for a key, then reloads.
_TH_MakeHoldFn(KeyId, HoldOpt) {
	obj := _TH_HoldFnObj()
	obj.KeyId   := KeyId
	obj.HoldOpt := HoldOpt
	return ObjBindMethod(obj, "Call")
}

; Shared reload helper — keeps menu-triggered updates observable in debug logs.
; We use it everywhere to avoid silent hot-reload with no trace when
; diagnosing "second-instance" reports from users.
_TH_ReloadTapHoldMenu(Reason, KeyId := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _TH_ReloadTapHoldMenu(Reason, KeyId)
		finally Critical(InheritedCritical)
	}
	try LoggerInfo("TapHoldMenu", "Reloading script after '{1}' on key '{2}' (pid={3}, script={4}).",
		Reason, KeyId, DriverPid, A_ScriptName)
	Reloaded := false
	ReloadError := ""
	try Reloaded := ReloadPreservingSuspend()
	catch as Err {
		Reloaded := false
		ReloadError := Err.Message
	}
	if !(Reloaded is Integer) || Reloaded != 1 {
		if (ReloadError != "") {
			try LoggerError("TapHoldMenu",
				"Reload after tap-hold action '{1}' failed: {2}.",
				Reason, ReloadError)
		} else {
			try LoggerError("TapHoldMenu",
				"Reload after tap-hold action '{1}' was refused.", Reason)
		}
		return false
	}
	return 1
}
