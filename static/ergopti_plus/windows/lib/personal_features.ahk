; lib/personal_features.ahk

; ==============================================================================
; MODULE: Personal Features Registry
; DESCRIPTION:
; Runtime registry for user-defined personal shortcuts.
; RegisterPersonalFeature seeds the Features map and the ordered registry
; that the tray menu renders; PersonalFeatureEnabled queries it. (The
; personal_shortcuts.ahk file bootstrap stays in the entry — it is boot
; orchestration and does raw FileIO best left out of the lib/ purity scope.)
; ==============================================================================




; ==================================
; ==================================
; ======= 1/ Helpers ===============
; ==================================
; ==================================

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
						Features["shortcuts"]["personal"][Name] := DefaultEnabled
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
				Features["hotstrings"]["personal"][SecName] := Map("enabled", false, "time_activation_seconds", 0)
}
