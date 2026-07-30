; ui/menu/menu_taphold.ahk

; ==============================================================================
; MODULE: Tray Menu / Tap-Hold Submenu
; DESCRIPTION:
; Builds the Tap-Hold category: per-key tap and hold pickers, reset/disable-all actions and the closure factory classes that bind a key id to a menu callback.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
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
	DynHandlers := Map(
		"reset_defaults", (M, C) => _TH_DynResetDefaults(M, C),
		"disable_all",    (M, C) => _TH_DynDisableAll(M, C),
		"tap_hold_keys",  _TH_DynKeys,
	)
	return MenuRenderer_Build("tap_holds_menu", "TapHolds", DynHandlers)
}

; Dynamic handler: reset-defaults action button.
_TH_DynResetDefaults(M, _Cat) {
	try LoggerInfo("TapHoldMenu", "Resetting all tap-hold overrides from defaults (script='{1}', pid={2}).", A_ScriptName, DriverPid)
	RegisterMenuItem(M, t("tap_hold.reset_defaults"), _TH_ResetAllToDefaults)
}

; Dynamic handler: disable-all action button.
_TH_DynDisableAll(M, _Cat) {
	try LoggerInfo("TapHoldMenu", "Disabling all tap-hold mappings (script='{1}', pid={2}).", A_ScriptName, DriverPid)
	RegisterMenuItem(M, t("tap_hold.disable_all"), _TH_DisableAll)
}

; Dynamic handler: per-key tap/hold entries.
_TH_DynKeys(M, _Cat) {
	global TapHold
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

		KeyMenu := Menu()

		DisableLabel := t("tap_hold.action.disable")
		RegisterMenuItem(KeyMenu, DisableLabel, _TH_MakeDisableFn(KeyId))
		if !IsConfigured
			KeyMenu.Disable(DisableLabel)

		KeyMenu.Add()

		TapPickerLabel := StrReplace(t("tap_hold.picker.tap"), "%s", TapLbl)
		RegisterMenuItem(KeyMenu, TapPickerLabel, _TH_MakeTapPickerFn(KeyId, KeyLabel, TapLbl))

		HoldPickerLabel := StrReplace(t("tap_hold.picker.hold"), "%s", HoldLbl)
		; Indirection avoids a call-site occurrence of the function name before
		; its definition, which would cause the meta test's body-extractor to
		; resolve the wrong function body (see HIGH-07 regression guard).
		_HoldSubmenuBuilder := _BuildHoldPickerSubmenu
		HoldPickerMenu      := _HoldSubmenuBuilder(KeyId)
		KeyMenu.Add(HoldPickerLabel, HoldPickerMenu)

		M.Add(ParentLabel, KeyMenu)
		if IsConfigured
			M.Check(ParentLabel)
	}
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
	global _ConfigDir, _AhkSubDir
	Path := _ConfigDir . _AhkSubDir . "tap_hold.toml"
	try {
		if FileExist(Path) {
			FileDelete(Path)
		}
	} catch as Err {
		try LoggerError("TapHoldMenu", "Could not delete tap_hold.toml: {1}.", Err.Message)
	}
	_TH_ReloadTapHoldMenu("reset_defaults", "")
}

; Clear every configured key so all physical keys revert to their native OS
; behaviour (no tap remapping, no hold remapping).
_TH_DisableAll(*) {
	if !IsSet(_TH_WriteTapHoldDisabled) {
		try LoggerError("TapHoldMenu", "Disable-all unavailable: tap-hold writer is not loaded.")
		return
	}
	if !_TH_WriteTapHoldDisabled()
		return
	_TH_ReloadTapHoldMenu("disable_all", "")
}

; ---- Callback classes ---------------------------------------------------------
; AHK v2 fat-arrow closures cannot contain multiple statements. These classes
; capture (KeyId, HoldOpt) by value and expose a Call() method bound via
; ObjBindMethod so AHK's Menu.Add() receives a valid callable.

class _TH_DisableFnObj {
	KeyId := ""
	Call(*) {
		try LoggerInfo("TapHoldMenu", "Menu disable action requested for key '{1}' (pid={2}).", this.KeyId, DriverPid)
                if WriteTapHoldNative(this.KeyId)
                        _TH_ReloadTapHoldMenu("key_disable", this.KeyId)
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
	Call(*) {
		Kind := this.HoldOpt["kind"]
		OptId := this.HoldOpt["id"]
		try LoggerInfo("TapHoldMenu", "Hold picker selection for '{1}': kind='{2}', id='{3}' (pid={4}).", this.KeyId, Kind, OptId, DriverPid)
                if WriteTapHoldHold(this.KeyId, this.HoldOpt)
                        _TH_ReloadTapHoldMenu("hold_set", this.KeyId)
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
	Current := IsSet(TapHold) ? TapHoldTapAction(TapHold, KeyId) : "<not_ready>"
	try LoggerInfo("TapHoldMenu", "ApplyTap key='{1}' current='{2}' -> '{3}' (pid={4}).", KeyId,
		(Current == "" ? "<native>" : Current), (ActionId == "" ? "<native>" : ActionId), DriverPid)
	if !GestureEnsureActionParameter(GestureBindingId("tap_hold", KeyId), ActionId)
		return
        if WriteTapHoldTap(KeyId, ActionId)
                _TH_ReloadTapHoldMenu("tap_set", KeyId)
}

; Build the hold picker submenu for a given key. Shows the fixed hold options
; from _TH_HoldOptions; current selection is checked.
_BuildHoldPickerSubmenu(KeyId) {
	global _TH_HoldOptions
	PickerMenu := Menu()
	for _, HoldOpt in _TH_HoldOptions {
		Label    := ""
		if (HoldOpt["kind"] == "modifier" && HoldOpt["i18n"] == "") {
			Label := _TH_HoldOptionLabel(HoldOpt["id"])
		} else {
			Label := t(HoldOpt["i18n"])
		}
		IsActive := IsTapHoldHoldActive(KeyId, HoldOpt)
		RegisterMenuItem(PickerMenu, Label, _TH_MakeHoldFn(KeyId, HoldOpt))
		if IsActive {
			PickerMenu.Check(Label)
		}
	}
	return PickerMenu
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
	try LoggerInfo("TapHoldMenu", "Reloading script after '{1}' on key '{2}' (pid={3}, script={4}).",
		Reason, KeyId, DriverPid, A_ScriptName)
	ReloadPreservingSuspend()
}
