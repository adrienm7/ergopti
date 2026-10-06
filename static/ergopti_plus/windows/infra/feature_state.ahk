; infra/feature_state.ahk

; ==============================================================================
; MODULE: Feature & Shortcut State Tables
; DESCRIPTION:
; The driver's runtime state tables — ScriptInformation, the script/keyboard
; shortcut slot tables (SLOTS/LABELS/DEFAULTS/FALLBACKS/SEND_CODES + assignment
; maps) and CategoryEnabled — plus the readers that populate them from config
; (ReadCategoryEnabled, IsCategoryGated, ReadScriptConfig). Extracted verbatim
; from ErgoptiPlus.ahk (the entry-point decomposition) and #Include'd in place, so
; the global assignments still run at the same point in the boot sequence and the
; reader functions (hoisted) stay available to their boot call sites.
; ==============================================================================

; feature_state.ahk is syntax-validated on its own as well as included after
; boot.ahk.  Do not dereference boot-owned path globals while constructing the
; declaration: their empty standalone values are harmless and the real driver
; has assigned both before this file executes.
global _FeatureStateConfigDir := IsSet(_ConfigDir) ? _ConfigDir : ""
global _FeatureStateAhkSubDir := IsSet(_AhkSubDir) ? _AhkSubDir : ""

global ScriptInformation := Map(
		"MagicKey", _FeatureStateRequireManifestDefault("hotstrings.trigger_char"),
		; The physical key remapped to ★, as the shared [hotstrings]
		; magic_key_source names it on every driver: a KeyboardEvent.code, or the
		; manifest default "auto" that leaves the key to the layout.
		"MagicKeySource", _FeatureStateRequireManifestDefault(
			"hotstrings.magic_key_source"),
		; Its scan code, resolved once at boot by LayoutRegistry_MagicKeySource
		; (ErgoptiPlus.ahk) before any hotkey registers on it.
		"MagicKeySourceScan", "",
		; The character whose key the boot looks for on the OS layout when no key
		; is chosen and no emulated layout declares one.
		"MagicKeySourceChar", _FeatureStateRequireManifestDefault(
			"hotstrings.magic_key_source_char"),
		; Whether config.toml names the source key: the user's choice then wins
		; over the active layout's declared key and over any detection.
		"MagicKeySourceChosen", false,
		; Whether the boot took the source key from the OS layout, so a switch of
		; OS layout can move it (LayoutRemapSignature); decided at boot.
		"MagicKeySourceFollowsOsLayout", false,
		; Whether an emulated layout yields the magic key's unshifted level to it:
		; only for a key the user chose or the active layout declares, so an
		; emulated layout declaring none keeps its own character; decided at boot.
		"MagicKeySourceOverridesEmulation", false,
		; Manual override for the AltGr-as-Kana / custom-remap detection. The
		; manifest default is "auto": HotstringEngineInit() detects the family via
		; a reverse VK_RMENU→SC probe. The TOML value (under [script]) wins when
		; explicitly set to true or false; "auto" (or absent) defers to the
		; probe. Kept as an escape hatch in case the probe ever misfires on an
		; exotic layout.
		"AltGrIsKanaRemap", _FeatureStateRequireManifestDefault("script.alt_gr_is_kana_remap"),
		; Configurable file paths — all derived from _ConfigDir set above.
		; AHK-specific files (.ahk, AHK config.toml) go under ``autohotkey/`` so
		; the folder can be safely shared with the Hammerspoon driver via cloud
		; sync. Shared neutral files (hotstrings TOML, personal info) stay
		; at the root of _ConfigDir.
		"PersonalAhkPath", _FeatureStateConfigDir . _FeatureStateAhkSubDir . "personal_shortcuts.ahk",
		"PersonalTomlPath", _FeatureStateConfigDir . "hotstrings\personal_hotstrings.toml",
		"PersonalHotstringsDir", _FeatureStateConfigDir . "hotstrings\",
		"PersonalInfoTomlPath", _FeatureStateConfigDir . "personal_info.toml",
)

_FeatureStateRequireManifestDefault(Path) {
	Entry := ManifestFindEntryByPath(Path)
	if !(Entry is Map) || !Entry.Has("default")
		throw Error("Missing required feature manifest default: " . Path)
	return Entry["default"]
}

; Builds detached assignments from the canonical platform section.
_FeatureStateDefaultsForSection(Section) {
	Values := Map()
	for Entry in ManifestFeaturesForSection(Section)
		Values[Entry["id"]] := ManifestDefaultFor(Entry["path"])
	return Values
}

; Script-management hotkey slots. Each AltGr+key combo dispatches to an action
; from GESTURE_ACTIONS (see modules/gestures.ahk) so the user can re-purpose
; them via the tray menu the same way they configure trackpad gestures.
; ``DEFAULTS`` come from the manifest; ``FALLBACKS`` is the key a chord sends
; when its AltGr turns out not to be physical (a latched prefix) or a pause
; began between the press and its thread; ``SCAN_CODES`` is the key AltGr
; modifies, which names the chord hotkeys and the GetKeyState double-check
; guarding against AltGr+Enter pause-bug-style misfires.
#Include ../../_shared/ahk/config_binding_identity.ahk
global SCRIPT_SHORTCUT_SLOTS := [
		"script_altgr_enter",
		"script_altgr_backspace",
		"script_altgr_delete",
		"script_altgr_escape",
]
; Only this compiled complete declaration publishes the script binding domain.
; Readers do not infer it from active assignments or reread a catalogue.
global _ScriptShortcutBindingPublication := ConfigBindingIdentityScriptPublication(SCRIPT_SHORTCUT_SLOTS)
global SCRIPT_SHORTCUT_LABELS := Map(
		"script_altgr_enter",     "sg_labels.script_altgr_enter",
		"script_altgr_backspace", "sg_labels.script_altgr_backspace",
		"script_altgr_delete",    "sg_labels.script_altgr_delete",
		"script_altgr_escape",    "sg_labels.script_altgr_escape",
)
global SCRIPT_SHORTCUT_DEFAULTS := _FeatureStateDefaultsForSection("shortcuts.script_control")
global SCRIPT_SHORTCUT_FALLBACKS := Map(
		"script_altgr_enter", "{Enter}",
		"script_altgr_backspace", "{BackSpace}",
		"script_altgr_delete", "{Delete}",
		"script_altgr_escape", "{Escape}",
)
global SCRIPT_SHORTCUT_SCAN_CODES := Map(
		"script_altgr_enter", "SC01C",
		"script_altgr_backspace", "SC00E",
		"script_altgr_delete", "SC153",
		"script_altgr_escape", "SC001",
)
; The switch at the head of « Raccourcis de gestion du script »: off leaves
; every chord to the system and keeps the slots' actions.
global ScriptShortcutChordsOn := _FeatureStateRequireManifestDefault("shortcuts.script_control.chords_enabled")
global ScriptShortcutAssignments := Map()
for _FeatureStateIndex, _FeatureStateSlot in SCRIPT_SHORTCUT_SLOTS {
		ScriptShortcutAssignments[_FeatureStateSlot] := SCRIPT_SHORTCUT_DEFAULTS[_FeatureStateSlot]
}

; Configurable keyboard shortcuts — Ctrl/Win/Alt × a-z, 0-9 and special keys.
; Each slot id matches a GESTURE_ACTIONS key (e.g. "win_a", "ctrl_b").
; Defaults below mirror the legacy hard-coded shortcuts so a fresh install
; behaves identically to before while giving the user full control via the menu.
global KEYBOARD_SHORTCUT_DEFAULTS := _FeatureStateDefaultsForSection("shortcuts.keyboard")
global KeyboardShortcutAssignments := Map()

; ParseTomlFile / IniCacheGet / ResolveConfigPath are defined in
; infra/toml/toml_helpers.ahk
; (included above) so the test runner can exercise them in isolation.

; Category-level gating state (master-toggle refactor).
;
; The master toggle at the top of every category submenu ("Activer la
; disposition" / "Désactiver les raccourcis" / ...) used to flip every
; individual feature in the category to the same value, destroying the
; user's per-feature choices on every master click. The new design
; separates the master gate (this Map) from the per-feature .Enabled
; flags: toggling the master flips ``CategoryEnabled[Category]`` only,
; and ``ApplyMasterGatesToFeatures`` in infra/master_gates.ahk forces
; the corresponding Features entries to false at boot — a disabled
; category propagates as all Features entries reading false at the HotIf
; level, but the underlying per-feature choices persisted on disk are
; preserved for when the user re-enables the master.
;
; Missing gates inherit the manifest's neutral defaults. Explicit user choices
; are loaded from [category_enabled] without importing recommendations.
global CategoryEnabled := Map(
		"Layout", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("Layout")),
		"Shortcuts", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("Shortcuts")),
		"Hotstrings", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("Hotstrings")),
		"TapHolds", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("TapHolds")),
		; « Combinaisons de touches », the only gate of the AltGr / LAlt / CapsLock
		; combination families, whatever Shortcuts says (ApplyMasterGatesToFeatures).
		"KeyCombinations", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("KeyCombinations")),
		; Per-TOML-file hotstring sub-category gates. Independent of the top
		; Hotstrings master above: a category file can be switched off while the
		; rest of the hotstrings stay live. The parent menu checkmark for each
		; category follows ITS gate (not whether every section is checked), and
		; ApplyMasterGatesToFeatures zeroes only that category's features when off.
		; Absent subordinate gates remain neutral too.
		"Autocorrection", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("Autocorrection")),
		"DistancesReduction", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("DistancesReduction")),
		"SFBsReduction", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("SFBsReduction")),
		"Rolls", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("Rolls")),
		"MagicKey", _FeatureStateRequireManifestDefault("category_enabled." . _FeatureStateCategoryKey("MagicKey")),
)

; Hotstring categories that deliberately have NO dedicated gate above: they follow the
; Hotstrings master. The tray menu still queries them per category, so IsCategoryGated
; answers with the master's state rather than logging schema drift. Single source of
; truth for that pass-through — menu_engine.ahk previously open-coded the exclusion.
global CATEGORY_FOLLOWS_HOTSTRINGS_MASTER := Map(
		"DynamicHotstrings", true,
		"Personal",          true,
)

ReadCategoryEnabled(Cache) {
		global CategoryEnabled
		for Category, _Default in CategoryEnabled {
				Raw := _FeatureStateIniGet(Cache, "category_enabled", _FeatureStateCategoryKey(Category))
				if (Raw == "_") {
						continue
				}
				CategoryEnabled[Category] := _FeatureStateValidateBoolean(
					Raw, "category_enabled." . _FeatureStateCategoryKey(Category))
		}
}

; Returns true when the master gate for ``Category`` is on. Used by
; the mirrors (to apply gating when populating Features) and by the
; tray-menu rendering (to label the master toggle and parent menu).
IsCategoryGated(Category) {
		global CategoryEnabled, CATEGORY_FOLLOWS_HOTSTRINGS_MASTER
		; Categories that deliberately own NO gate and follow the Hotstrings master.
		; The tray menu legitimately asks about them per category, so answer with the
		; master's state instead of crying schema drift — that warning fired on every
		; menu build and every boot, drowning the must-investigate WARNING log.
		if CATEGORY_FOLLOWS_HOTSTRINGS_MASTER.Has(Category)
				Category := "Hotstrings"
		if !CategoryEnabled.Has(Category)
				return ManifestDefaultFor("category_enabled." . _FeatureStateCategoryKey(Category))
		return CategoryEnabled[Category]
}

ReadScriptConfig(Cache) {
		; MagicKey lives in [hotstrings] trigger_char in the v2 TOML.
		Raw := _FeatureStateIniGet(Cache, "hotstrings", "trigger_char")
		if Raw != "_"
				ScriptInformation["MagicKey"] := _FeatureStateValidateTriggerChar(Raw)
		; Source key for the J→★ remap, named by its KeyboardEvent.code so the one
		; value means the same physical key on every driver. A value that names
		; no candidate is outdated configuration: the loader reports it and the
		; cleanup offers it, so it reads as the automatic key here, never as a
		; boot failure.
		RawSource := _FeatureStateIniGet(Cache, "hotstrings", "magic_key_source")
		ScriptInformation["MagicKeySource"] := _FeatureStateMagicKeySource(RawSource)
		ScriptInformation["MagicKeySourceChosen"] := ScriptInformation["MagicKeySource"]
			!== _FeatureStateRequireManifestDefault("hotstrings.magic_key_source")
		RawChar := _FeatureStateIniGet(Cache, "hotstrings", "magic_key_source_char")
		if RawChar != "_"
				ScriptInformation["MagicKeySourceChar"] :=
					_FeatureStateValidateCodePoint(RawChar,
						"hotstrings.magic_key_source_char")
		; AltGr-as-Kana manual override. Default "auto" defers to the reverse
		; VK_RMENU→SC probe in HotstringEngineInit(); "true" / "false" force the
		; respective mode. Lives in [script] so the user can lock it once per
		; machine if auto-detection misfires on an exotic layout.
		RawKana := _FeatureStateIniGet(Cache, "script", "alt_gr_is_kana_remap")
		if RawKana != "_"
				ScriptInformation["AltGrIsKanaRemap"] :=
					_FeatureStateValidateKanaOverride(RawKana)
		; Missing repeat-key intent restores the same neutral baseline as first boot.
		global HSE_RepeatEnabled
		RawRepeat := _FeatureStateIniGet(Cache, "hotstrings", "repeat_key_enabled")
		if RawRepeat != "_"
				HSE_RepeatEnabled := _FeatureStateValidateBoolean(
					RawRepeat, "hotstrings.repeat_key_enabled")
		else
				HSE_RepeatEnabled := ManifestDefaultFor("hotstrings.repeat_key_enabled")
		if IsSet(HSE_AdvanceRuntimeDecisionGeneration)
				HSE_AdvanceRuntimeDecisionGeneration()
		; Paths are always derived from _ConfigDir at startup and are never persisted.
}

_FeatureStateValidateBoolean(Value, Path) {
	if !(Value is Integer) || (Value != 0 && Value != 1)
		throw ValueError(Path . " must be a TOML boolean")
	return Value == 1
}

_FeatureStateValidateKanaOverride(Value) {
	if Value is String {
		if Value == "auto"
			return Value
		throw ValueError("script.alt_gr_is_kana_remap must be 'auto' or a TOML boolean")
	}
	return _FeatureStateValidateBoolean(Value,
		"script.alt_gr_is_kana_remap")
}

; The configured magic-key source in its manifest spelling, or the manifest
; default for an absent or outdated value. Membership follows the loader's enum
; rule (TomlConfigValueMatchesManifest compares with AHK's case-insensitive =),
; so a value the loader applies is never read here as another key.
_FeatureStateMagicKeySource(Raw) {
	Default := _FeatureStateRequireManifestDefault("hotstrings.magic_key_source")
	if Raw == "_" || !(Raw is String)
		return Default
	Entry := ManifestFindEntryByPath("hotstrings.magic_key_source")
	if !(Entry is Map) || !Entry.Has("enum_values")
		throw Error("Missing required feature manifest candidates: hotstrings.magic_key_source")
	for Allowed in Entry["enum_values"] {
		if Allowed = Raw
			return Allowed
	}
	return Default
}

_FeatureStateValidateCodePoint(Value, Path) {
	; AHK's Unicode PCRE dot counts code points, so astral characters are not
	; double-counted as their UTF-16 surrogate pair.
	if !(Value is String) || !RegExMatch(Value, "s)^.$")
		throw ValueError(Path . " must contain exactly one Unicode code point")
	return Value
}

_FeatureStateValidateTriggerChar(Value) {
	; Keep the runtime boundary aligned with config.schema.json.
	return _FeatureStateValidateCodePoint(Value, "hotstrings.trigger_char")
}

; IniCacheGet belongs to the configuration-loader boundary.  It is included
; before this module in ErgoptiPlus.ahk, so call it directly.  The former
; function-object indirection can itself throw "Invalid base" at boot,
; which hid a valid config behind a fatal startup error.
_FeatureStateIniGet(Cache, Section, Key) {
		return IniCacheGet(Cache, Section, Key)
}

; Category-key normalization is owned by config_io.ahk.  AHK resolves function
; declarations across the complete #Include graph before executing auto-run
; code, so the direct call remains valid although config_io.ahk appears later
; in the source.  Keep one canonical mapping rather than duplicating it here.
_FeatureStateCategoryKey(Category) {
		return _CategoryEnabledKey(Category)
}
