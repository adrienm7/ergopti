; infra/personal_features.ahk

; ==============================================================================
; MODULE: Personal Features Registry
; DESCRIPTION:
; Runtime registry for user-defined personal shortcuts.
; RegisterPersonalFeature seeds the Features map and the ordered registry
; that the tray menu renders; PersonalFeatureEnabled queries it. (The
; personal_shortcuts.ahk file bootstrap stays in the entry — it is boot
; orchestration and does raw FileIO best left out of the infra/ purity scope.)
; ==============================================================================




; ==================================
; ==================================
; ======= 1/ Helpers ===============
; ==================================
; ==================================

/**
 * Registers a personal shortcut without implicitly enabling an absent preference.
 * @param {String} Name Personal preference identity.
 * @param {Boolean} DefaultEnabled Retained positional argument; ignored. Absence uses the manifest default.
 * @param {String} Description User-authored menu description.
 */
RegisterPersonalFeature(Name, DefaultEnabled := false, Description := "") {
		global _PersonalShortcutsRegistry, Features
		Name := StrLower(Name)
		if !_PersonalShortcutsRegistry.Has(Name) {
				_PersonalShortcutsRegistry[Name] := Description
				Found := false
				for _, Item in _PersonalShortcutsRegistry["__Order"] {
						if Item == Name {
								Found := true
								break
						}
				}
				if !Found {
						_PersonalShortcutsRegistry["__Order"].Push(Name)
				}
		}
		if !(IsSet(Features) and Features.Has("shortcuts")
				and Features["shortcuts"].Has("personal")
				and IsObject(Features["shortcuts"]["personal"])
				and Features["shortcuts"]["personal"].Has(Name)) {
				if IsSet(Features) and Features.Has("shortcuts") {
						if !Features["shortcuts"].Has("personal") {
								Features["shortcuts"]["personal"] := Map()
						}
						Neutral := ManifestDefaultFor("shortcuts.personal." . Name)
						Features["shortcuts"]["personal"][Name] := Neutral
						if MasterGateState()["initialized"] {
								Desired := MasterGateState()["features"]["shortcuts"]
								if !Desired.Has("personal")
										Desired["personal"] := Map()
								if !Desired["personal"].Has(Name)
										Desired["personal"][Name] := Neutral
								Features["shortcuts"]["personal"][Name] :=
										IsCategoryGated("Shortcuts") && Desired["personal"][Name]
						}
				}
		}
}
PersonalFeatureEnabled(name) {
		global Features
		name := StrLower(name)
		try {
				return Features["shortcuts"]["personal"][name] = true
		} catch {
				return false
		}
}

; Seed a file-discovered personal HOTSTRING section into Features["hotstrings"]["personal"]
; as a default-disabled Map node (mirroring the manifest shape), so custom sections beyond
; the fixed manifest 5 are toggleable + loadable. No-op when already present (manifest seed
; or a prior call). Mirrors RegisterPersonalFeature for shortcuts (personal-hotstring-seed).
EnsurePersonalHotstringFeature(SecName) {
		global Features
		SecName := StrLower(SecName)
		if !(IsSet(Features) and Features.Has("hotstrings"))
				return
		if !Features["hotstrings"].Has("personal")
				Features["hotstrings"]["personal"] := Map()
		if !Features["hotstrings"]["personal"].Has(SecName)
				_ConfigSeedPersonalHotstring(Features, SecName)
		if MasterGateState()["initialized"]
				_ConfigSeedPersonalHotstring(MasterGateState()["features"], SecName)
}

/** Returns only personal shortcut paths registered by the runtime owner. */
PersonalShortcutScopePaths() {
	global _PersonalShortcutsRegistry
	if !IsSet(_PersonalShortcutsRegistry) || !(_PersonalShortcutsRegistry is Map)
		throw Error("Personal shortcut inventory is unavailable.")
	Order := _PersonalShortcutsRegistry.Get("__Order", 0)
	if !(Order is Array)
		throw TypeError("Personal shortcut order is unavailable.")
	Paths := []
	loop Order.Length {
		if !Order.Has(A_Index) || !(Order[A_Index] is String)
			throw TypeError("Personal shortcut inventory must contain dense names.")
		Name := Order[A_Index]
		if Name == "" || !_PersonalShortcutsRegistry.Has(Name)
			throw ValueError("Personal shortcut inventory contains an unregistered name.")
		Paths.Push("shortcuts.personal." . Name)
	}
	return Paths
}
