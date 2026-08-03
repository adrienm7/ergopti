; infra/config_io.ahk

; ==============================================================================
; MODULE: Config I/O — feature toggles, persistence & shortcut config
; DESCRIPTION:
; Reading/writing the user config: the bulk feature/hotstring/category toggles,
; SaveFullConfig + _CollectFeatureUpdates, ReloadWithDefaultConfig, and the
; script/keyboard shortcut slot configuration (read/run/set/menu). Extracted
; verbatim from ErgoptiPlus.ahk (the entry-point decomposition) and #Include'd in
; place; functions are hoisted so their boot-time call sites (SaveFullConfig
; SetTimer, ReadScript/KeyboardShortcutsConfig) are unaffected.
; ==============================================================================

ToggleAllFeaturesOn(*) {
		MsgBox(t("dialog.enable_all.warning"))
		ToggleAllFeatures(1)
}
ToggleAllFeaturesOff(*) {
		ToggleAllFeatures(0)
}


; Clear every gesture, keyboard and script-control binding, appending the
; matching TOML writes to the shared ``Updates`` accumulator.
;
; ``Updates`` is taken BY VALUE on purpose. It is an Array, so it already
; mutates by reference, and the sibling walker _CollectFeatureFlipUpdates takes
; the same accumulator the same way. Declaring it ByRef here made the one call
; site (which passes the bare variable) raise a TypeError on every invocation of
; "tout desactiver" — AHK v2 requires & at the call site for a ByRef parameter.
_GlobalClearAllBindings(Updates) {
		global GestureAssignments, GESTURE_SLOTS, KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, SCRIPT_SHORTCUT_SLOTS, ScriptShortcutAssignments, _IniCache
		for Slot in GESTURE_SLOTS {
				GestureAssignments[Slot] := "none"
				Updates.Push({ Section: "gestures", Key: Slot, Value: "none" })
		}
		KbWritten := Map()
		for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
				KeyboardShortcutAssignments[Slot] := "none"
				Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: "none" })
				KbWritten[Slot] := true
		}
		if IsSet(_IniCache) and _IniCache.Has("shortcuts.keyboard") {
				for Slot, _ in _IniCache["shortcuts.keyboard"] {
						if !KbWritten.Has(Slot) {
								KeyboardShortcutAssignments[Slot] := "none"
								Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: "none" })
						}
				}
		}
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				ScriptShortcutAssignments[Slot] := "none"
				Updates.Push({ Section: "shortcuts.script_control", Key: Slot, Value: "none" })
		}
		if IsSet(_TH_WriteTapHoldDisabled) {
				; A bare try here meant "tout desactiver" reported success while the
				; tap-hold config could still say enabled on disk — the one write that
				; turns them off, discarded without a word.
				try {
						_TH_WriteTapHoldDisabled()
				} catch as Err {
						try LoggerError("Config", "Could not persist the tap-hold disable: {1}", Err.Message)
				}
		}
}

; Recursively force every leaf under Node to Bool ("tout activer"/"tout
; desactiver"), mutating Features in place and appending the required
; {Section, Key, Value} TOML writes to Updates. Extracted out of ToggleAllFeatures
; as a standalone module function (rather than a nested closure) so the flip
; logic is directly testable without triggering ToggleAllFeatures's trailing
; Reload(). The walked nesting IS the TOML section: ManifestBuildFeaturesMap
; files each feature under its manifest section verbatim, so descending the tree
; reconstructs that section exactly. It used to need a per-leaf manifest lookup
; (ManifestResolveFeatureSection) because the tree was built with the ahk. driver
; prefix stripped, which merged a shared section and an AHK-only one under the
; same top-level key and made the walked path ambiguous. Lot 4 removed the silos
; and with them the ambiguity.
_CollectFeatureFlipUpdates(Bool, SectionPath, Node, Updates) {
		if (Type(Node) != "Map")
				return
		if Node.Has("enabled") and (Type(Node["enabled"]) != "Map") {
				Node["enabled"] := Bool
				Updates.Push({ Section: SectionPath, Key: "enabled", Value: Bool })
				return
		}
		for K, V in Node {
				if (Type(V) == "Map")
						_CollectFeatureFlipUpdates(Bool, SectionPath . "." . K, V, Updates)
				else {
						Node[K] := Bool
						Updates.Push({ Section: SectionPath, Key: K, Value: Bool })
				}
		}
}

ToggleAllFeatures(Value) {
		global Features, CategoryEnabled, ConfigurationFile
		if !IsSet(Features)
				return
		Bool := (Value = true or Value = 1)
		Updates := []
		for TopKey, TopVal in Features {
				if (Type(TopVal) == "Map")
						_CollectFeatureFlipUpdates(Bool, TopKey, TopVal, Updates)
		}
		for Category, _ in CategoryEnabled {
				CategoryEnabled[Category] := Bool
				Updates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(Category), Value: Bool })
		}
		WPMWidget.visible := Bool
		WPMWidget.use_colors := Bool
		WPMWidget.show_graph := Bool
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: Bool ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: Bool ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: Bool ? "1" : "0" })
		if !Bool
				_GlobalClearAllBindings(Updates)
		; Everything above mutated MEMORY. If the write fails, memory and disk
		; disagree and the Reload below never runs, so the tray keeps rendering a
		; state that was never saved. Reload anyway on failure: it re-reads the
		; config from disk, which discards the unpersisted flip and puts the driver
		; back in a state that matches what the user can see on disk.
		try {
				TOML_BatchWrite(ConfigurationFile, Updates)
		} catch as Err {
				try LoggerError("Config", "Bulk feature toggle could not be saved: {1}", Err.Message)
				try MsgBox(t("dialog.bulk_toggle.save_failed"), t("dialog.reset_defaults.failed_title"), "Iconx")
				ReloadPreservingSuspend()
				return
		}
		if Bool {
				HsBatch := []
				for V2Path in _CollectAllHotstringsV2Paths()
						HsBatch.Push(Map("path", V2Path, "value", true))
				if (HsBatch.Length > 0)
						WriteFeatureBatchV2(Features, HsBatch)
		}
		ReloadPreservingSuspend()
}

ToggleAllHotstringsOn(*) {
		ToggleAllHotstrings(1)
}
ToggleAllHotstringsOff(*) {
		ToggleAllHotstrings(0)
}
ToggleAllHotstrings(Value) {
		global CategoryEnabled, ConfigurationFile, Features
		Bool := (Value = true or Value = 1)
		; Force every individual section to Bool — "tout activer" turns them all on,
		; "tout désactiver" turns them all off (a real bulk action, not just the
		; category gate). The Hotstrings master gate follows so the change is
		; immediately effective (on) or the whole tree is off (off).
		CategoryEnabled["Hotstrings"] := Bool
		TOML_Write(Bool, ConfigurationFile, "category_enabled", "hotstrings")
		Batch := []
		for V2Path in _CollectAllHotstringsV2Paths()
				Batch.Push(Map("path", V2Path, "value", Bool))
		if (Batch.Length > 0)
				WriteFeatureBatchV2(Features, Batch)
		ReloadPreservingSuspend()
}

IsCategoryAllEnabled(Categories) {
	if (Categories.Length == 0)
		return true
	for Cat in Categories {
		if !IsCategoryGated(Cat)
			return false
	}
	return true
}

; Deep-clone a (possibly nested) Map. Used to snapshot per-section hotstring
; Features so a live category toggle can restore them independently of later
; mutations. Non-Map values are returned as-is (leaf bool / number / string).
_HSDeepCloneMap(M) {
		if (Type(M) != "Map") {
				return M
		}
		Out := Map()
		for K, V in M {
				Out[K] := _HSDeepCloneMap(V)
		}
		return Out
}

; Snapshot one category's current (un-gated) section states into _HSCategorySnapshot.
_HSSnapshotCategory(V2Cat) {
		global Features, _HSCategorySnapshot
		if (IsSet(Features) and Features.Has("hotstrings") and Features["hotstrings"].Has(V2Cat)) {
				_HSCategorySnapshot[V2Cat] := _HSDeepCloneMap(Features["hotstrings"][V2Cat])
		}
}

; Snapshot every hotstring category. Called once at boot, before gating.
_HSSnapshotAllCategories() {
		global Features
		if (IsSet(Features) and Features.Has("hotstrings")) {
				for V2Cat, _ in Features["hotstrings"] {
						_HSSnapshotCategory(V2Cat)
				}
		}
}

; Restore a category's section states from the snapshot, in place (the category Map
; keeps its identity; each section entry is replaced with a fresh clone).
_HSRestoreCategory(V2Cat) {
		global Features, _HSCategorySnapshot
		; IsSet on BOTH globals. _HSCategorySnapshot is declared in ErgoptiPlus.ahk,
		; which the headless test harness does not load, so reading it first threw an
		; unset error before the IsSet(Features) guard beside it could apply.
		if !(IsSet(_HSCategorySnapshot) and _HSCategorySnapshot.Has(V2Cat) and IsSet(Features)
				and Features.Has("hotstrings") and Features["hotstrings"].Has(V2Cat)) {
				return
		}
		Target := Features["hotstrings"][V2Cat]
		for Section, SecMap in _HSCategorySnapshot[V2Cat] {
				Target[Section] := _HSDeepCloneMap(SecMap)
		}
}

; Hotstring sub-categories whose entire content the live rebuild can apply, so
; flipping their master gate rebuilds in-process instead of Reloading. Only Rolls
; and SFBsReduction qualify: every other gated hotstring category holds a feature
; the rebuild can't apply (DistancesReduction -> the E-circumflex deadkey,
; Autocorrection -> the multiple-punctuation rule, MagicKey -> the J-to-star layout
; remap) or is the Hotstrings master that gates those too.
_IsLiveHotstringCategory(Category) {
		static Live := Map("Rolls", true, "SFBsReduction", true)
		return Live.Has(Category)
}

ToggleCategoryAllFeatures(Category, Value) {
		global CategoryEnabled, ConfigurationFile, Features, TapHold
		Bool := (Value = true or Value = 1)
		if _IsLiveHotstringCategory(Category) {
				; In-process: restore (ON) or snapshot (OFF) the category's sections, flip the
				; gate, re-apply all master gates, then rebuild the engine — no Reload. The
				; snapshot-on-OFF preserves any live section toggles made while it was on.
				V2Cat := _CategoryEnabledKey(Category)
				try LoggerDebug("Menu", "Live category toggle: {1} -> {2}.", Category, Bool ? "ON" : "OFF")
				; Critical covers ONLY the in-memory mutation window (snapshot/restore ->
				; gate flip -> master gates), so a keystroke can never observe a torn
				; Features/TapHold state through a concurrent #HotIf/InputHook evaluation.
				; It is released BEFORE persistence and the engine rebuild: both do
				; unbounded file I/O, and holding Critical across that starves the
				; low-level keyboard hook past LowLevelHooksTimeout, which makes Windows
				; silently drop physical keystrokes. RebuildHotstringsLive() is
				; deliberately Critical-free for exactly this reason and fences the
				; matcher with HSE_RebuildInProgress instead.
				_TcafCrit := Critical("On")
				try {
						if Bool {
								_HSRestoreCategory(V2Cat)
						} else {
								_HSSnapshotCategory(V2Cat)
						}
						CategoryEnabled[Category] := Bool
						ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated, LoggerDebug)
				} finally {
						Critical(_TcafCrit)
				}
				; The in-memory flip above is already done. A failed write here would
				; otherwise skip the rebuild below too, leaving memory, disk and the live
				; engine in three different states.
				try {
						TOML_Write(Bool, ConfigurationFile, "category_enabled", _CategoryEnabledKey(Category))
				} catch as Err {
						try LoggerError("Config", "Category toggle for '{1}' could not be saved: {2}", Category, Err.Message)
						try MsgBox(t("dialog.bulk_toggle.save_failed"), t("dialog.reset_defaults.failed_title"), "Iconx")
						ReloadPreservingSuspend()
						return
				}
				LoggerStart("Menu", "Applying live category toggle for {1}…", Category)
				RebuildHotstringsLive()
				LoggerSuccess("Menu", "Live category toggle applied for {1}.", Category)
				return
		}
		CategoryEnabled[Category] := Bool
		; Reload runs on both paths here, so a failed write self-corrects by
		; re-reading disk — but it must still be reported, or the toggle silently
		; reverts on the next start with no explanation.
		try {
				TOML_Write(Bool, ConfigurationFile, "category_enabled", _CategoryEnabledKey(Category))
		} catch as Err {
				try LoggerError("Config", "Category toggle for '{1}' could not be saved: {2}", Category, Err.Message)
				try MsgBox(t("dialog.bulk_toggle.save_failed"), t("dialog.reset_defaults.failed_title"), "Iconx")
		}
		ReloadPreservingSuspend()
}

; Force every section of one hotstring category on/off (bulk action), scoped to
; a single manifest section. Mirrors ToggleAllHotstrings but per-category:
; enabling also lifts the Hotstrings master gate and (when the category has one)
; the category gate, so the activation is immediately effective; disabling just
; clears the sections. ``V1Cat`` is the PascalCase category id (e.g. "Rolls",
; "DynamicHotstrings").
ToggleCategoryAllSections(V1Cat, Enable) {
		global CategoryEnabled, ConfigurationFile, _LegacyTopCategoryMap, Features
		Bool := (Enable = true or Enable = 1)
		V2Section := _LegacyTopCategoryMap.Has(V1Cat) ? _LegacyTopCategoryMap[V1Cat] : ""
		if (V2Section == "") {
				try LoggerWarn("Menu", "ToggleCategoryAllSections: no v2 section for '{1}' — skipped.", V1Cat)
				return
		}
		GateUpdates := []
		if Bool {
				; Master gate must be on for any hotstring to fire.
				if !CategoryEnabled.Has("Hotstrings") or !CategoryEnabled["Hotstrings"] {
						CategoryEnabled["Hotstrings"] := true
						GateUpdates.Push({ Section: "category_enabled", Key: "hotstrings", Value: true })
				}
				; Lift this category's own gate too, when it has one (flat categories do;
				; DynamicHotstrings / Personal follow the master directly).
				if (CategoryEnabled.Has(V1Cat) and !CategoryEnabled[V1Cat]) {
						CategoryEnabled[V1Cat] := true
						GateUpdates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(V1Cat), Value: true })
				}
		}
		if (GateUpdates.Length > 0)
				TOML_BatchWrite(ConfigurationFile, GateUpdates)
		Batch := []
		for _, Entry in ManifestFeaturesForSection(V2Section)
				Batch.Push(Map("path", Entry["path"], "value", Bool))
		if (Batch.Length > 0)
				WriteFeatureBatchV2(Features, Batch)
		ReloadPreservingSuspend()
}

; Force every personal hotstring section (from personal_hotstrings.toml) on/off.
; Personal sections are runtime-discovered, so their v2 paths are built from the
; TOML section names (hotstrings.personal.<lower(section)>). Enabling lifts the
; Hotstrings master gate so the sections fire immediately.
HS_TogglePersonalAllSections(Enable) {
		global CategoryEnabled, ConfigurationFile, ScriptInformation, Features
		Bool := (Enable = true or Enable = 1)
		PersonalSectionsPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
		if (PersonalSectionsPath == "" or !FileExist(PersonalSectionsPath)) {
				; Reachable on a fresh install (no personal_hotstrings.toml yet) or after
				; relocating the config dir: the menu item does nothing and says nothing.
				; The sibling ToggleCategoryAllSections logs on the equivalent bail.
				try LoggerWarn("Hotstrings", "Personal sections toggle ignored — no personal hotstrings file at '{1}'.", PersonalSectionsPath)
				return
		}
		if (Bool and (!CategoryEnabled.Has("Hotstrings") or !CategoryEnabled["Hotstrings"])) {
				CategoryEnabled["Hotstrings"] := true
				TOML_Write(true, ConfigurationFile, "category_enabled", "hotstrings")
		}
		Data := ReadPersonalToml()
		Batch := []
		for _, SecName in Data["sections_order"] {
				if (SecName != "-") {
						EnsurePersonalHotstringFeature(SecName)
						Batch.Push(Map("path", "hotstrings.personal." . StrLower(SecName), "value", Bool))
				}
		}
		if (Batch.Length > 0)
				WriteFeatureBatchV2(Features, Batch)
		ReloadPreservingSuspend()
}

_CategoryEnabledKey(Category) {
		switch Category {
				case "Layout":     return "layout"
				case "Shortcuts":  return "shortcuts"
				case "Hotstrings": return "hotstrings"
				case "TapHolds":   return "tap_holds"
				; Hotstring sub-category gates — snake_case to match the v2 schema.
				case "DistancesReduction": return "distances_reduction"
				case "SFBsReduction":      return "sfbs_reduction"
				case "MagicKey":           return "magic_key"
				default: return StrLower(Category)
		}
}

SaveFullConfig() {
		global Features, ScriptInformation, ScriptShortcutAssignments, GestureAssignments, KeyboardShortcutAssignments, ConfigurationFile, _TOML_STRICT_CANON_IN_PROGRESS
		; Guard: the driver must be fully initialised before writing config — prevents
		; a partial config flush triggered by the -500 ms boot timer from clobbering the
		; user's file with uninitialised defaults (e.g. before Features or GestureAssignments
		; have been populated by ApplyConfigToml and the deferred tray-menu build).
		global _DriverReady
		if !_DriverReady {
				SetTimer(SaveFullConfig, -100)
				return
		}
		; Guard: refuse to serialize the feature tree when boot could not READ an
		; existing config.toml. In that case ApplyConfigToml applied nothing and the
		; tree below is ManifestBuildFeaturesMap() DEFAULTS — writing it out replaces
		; the user's whole configuration with factory values. TOML_BatchWrite's own
		; TOML_ReadFailed guard cannot catch this: it re-parses at write time, and a
		; transient lock (sync client, AV scan, backup) has usually cleared by then,
		; so the write looks perfectly safe while the payload is already wrong.
		; Returns false — not a bare return — so a caller (and the regression test)
		; can tell "refused" from "deferred until ready" and from a completed save.
		global _ConfigBootReadFailed
		if (IsSet(_ConfigBootReadFailed) && _ConfigBootReadFailed) {
				try LoggerError("ConfigIO", "Refusing to save: config.toml could not be read at boot, so the in-memory feature tree holds defaults rather than the user's settings. Restart the driver once the file is readable.")
				return false
		}
		Updates := []
		; Only sync LLM state into Features if LLM_Menu_Init() has already run and
		; populated _LLM_Menu with the user's persisted values. Calling it before
		; init would push module-level defaults (e.g. enabled=false) over the user's
		; saved settings, corrupting the config file.
		global _LLM_Menu_Loaded
		if IsSet(_LLM_Menu_SyncToFeatures) && (IsSet(_LLM_Menu_Loaded) && _LLM_Menu_Loaded)
				_LLM_Menu_SyncToFeatures()
		if IsSet(Features) {
				_CollectFeatureUpdates(Updates, "", _PruneMasterGatedFeatures(Features))
				Updates.Push({ Section: "_meta", Key: "schema_version", Value: 2 })
		}
		Updates.Push({ Section: "script", Key: "locale", Value: I18nGetLocale() })
		global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
		Updates.Push({ Section: "script", Key: "log_level", Value: IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : LOGGER_DEFAULT_LEVEL })
		Updates.Push({ Section: "hotstrings", Key: "trigger_char", Value: ScriptInformation["MagicKey"] })
		if IsSet(ScriptShortcutAssignments) {
				for Slot, Action in ScriptShortcutAssignments
						Updates.Push({ Section: "shortcuts.script_control", Key: Slot, Value: Action })
		}
		if IsSet(KeyboardShortcutAssignments) {
				for Slot, Action in KeyboardShortcutAssignments
						Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: Action })
		}
		if IsSet(GestureAssignments) {
				for Slot, Action in GestureAssignments
						Updates.Push({ Section: "gestures", Key: Slot, Value: Action })
		}
		apps := []
		for proc, _ in MetricsFilters.disabled_apps
				apps.Push(proc)
		Updates.Push({ Section: "metrics", Key: "metrics_enabled", Value: TOML_Bool(MetricsShortcuts.enabled) })
		Updates.Push({ Section: "metrics", Key: "metrics_shortcut_typing", Value: MetricsShortcuts.typing_str })
		Updates.Push({ Section: "metrics", Key: "metrics_shortcut_apps", Value: MetricsShortcuts.apps_str })
		Updates.Push({ Section: "metrics", Key: "metrics_wpm_menubar_colors", Value: MetricsShortcuts.wpm_menubar_colors })
		Updates.Push({ Section: "metrics", Key: "private_filter_enabled", Value: TOML_Bool(MetricsFilters.private_browsing) })
		Updates.Push({ Section: "metrics", Key: "secure_filter_enabled", Value: TOML_Bool(MetricsFilters.secure_field) })
		Updates.Push({ Section: "metrics", Key: "system_auth_filter_enabled", Value: TOML_Bool(MetricsFilters.system_auth) })
		Updates.Push({ Section: "metrics", Key: "encrypt", Value: TOML_Bool(MetricsFilters.encrypt) })
		Updates.Push({ Section: "metrics", Key: "metrics_disabled_apps", Value: apps })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_X,       Value: String(WPMWidget.pos_x) })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_Y,       Value: String(WPMWidget.pos_y) })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: WPMWidget.use_colors ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: WPMWidget.show_graph  ? "1" : "0" })
		; The flat [llm] keys below round-trip through _LLM_Menu DIRECTLY (not via
		; Features), so the _LLM_Menu_SyncToFeatures gate above does not cover them. The
		; boot-armed SaveFullConfig timer fires ~0-100 ms after _DriverReady, while
		; LLM_Menu_Init runs seconds later at the end of the deferred menu build — so
		; without this dedicated gate the first flush writes module defaults
		; (onboarding_seen=0, empty overrides, default trigger_shortcut/ollama_port/…)
		; over the user's saved values. Skipping is safe: TOML_BatchWrite preserves keys
		; it does not re-collect, so the on-disk values survive until the menu has loaded.
		if (IsSet(_LLM_Menu_Loaded) && _LLM_Menu_Loaded) {
				Updates.Push({ Section: "llm", Key: "onboarding_seen", Value: _LLM_Menu["onboarding_seen"] ? "1" : "0" })
				_AppOverridesStr := ""
				for _AppName, _AppProfileId in _LLM_Menu["app_profile_overrides"] {
						if (_AppOverridesStr != "")
								_AppOverridesStr .= ";"
						_AppOverridesStr .= _AppName . "=" . _AppProfileId
				}
				Updates.Push({ Section: "llm", Key: "app_profile_overrides", Value: _AppOverridesStr })
				if IsSet(_LLM_Menu_AppendPersistedUpdates)
						_LLM_Menu_AppendPersistedUpdates(Updates)
		}
		global CategoryEnabled
		if IsSet(CategoryEnabled) {
				for _CatName, _CatBool in CategoryEnabled
						Updates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(_CatName), Value: TOML_Bool(_CatBool) })
		}
		global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INI_SECTION, UPDATER_INI_KEY, UPDATER_INI_INTERVAL_KEY
		if IsSet(UPDATER_CHECK_INTERVAL)
				Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_INTERVAL_KEY, Value: UPDATER_CHECK_INTERVAL })
		if IsSet(UPDATER_CHANNEL)
				Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_KEY, Value: UPDATER_CHANNEL })
		; Do NOT FileDelete before writing — TOML_BatchWrite already performs an
		; atomic write (temp file + rename). A FileDelete here creates a data-loss
		; window: if a Reload() or thread interrupt fires between the delete and the
		; write, the user's config is permanently gone with no replacement.
		PrevCanonState := _TOML_STRICT_CANON_IN_PROGRESS
		_TOML_STRICT_CANON_IN_PROGRESS := true
		try {
				; RETURNED, not discarded. TOML_BatchWrite fails without throwing when
				; the staging file cannot be opened or the atomic replace is refused, and
				; every caller that dropped this boolean turned that into a silent no-op:
				; the live toggles mutate memory, re-init the engine and rebuild the menu
				; with no Reload, so memory, engine and menu all showed a state that never
				; reached disk — and the next restart silently undid it.
				Written := TOML_BatchWrite(ConfigurationFile, Updates)
		} finally {
				_TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState
		}
		return Written
}

; Resolve the CategoryEnabled master-gate label that owns a Features node key
; ("layout" -> "Layout", "distances_reduction" -> "DistancesReduction"), or ""
; when that key has no dedicated gate. Derived from CategoryEnabled through
; _CategoryEnabledKey rather than a second table, so a new master gate is picked
; up here automatically instead of being silently unprotected.
_MasterGateLabelFor(NodeKey) {
		global CategoryEnabled
		if !IsSet(CategoryEnabled)
				return ""
		for Category, _Bool in CategoryEnabled {
				if (_CategoryEnabledKey(Category) == NodeKey)
						return Category
		}
		return ""
}

; True when the Features node named NodeKey may be serialized right now. A node
; with no gate is always persistable; a gated one only while its master is on.
_MasterGateAllowsPersist(NodeKey) {
		Label := _MasterGateLabelFor(NodeKey)
		if (Label == "")
				return true
		return IsCategoryGated(Label)
}

; Return a shallow view of Features with every master-gated-OFF branch removed,
; for the walker below to flatten.
;
; ApplyMasterGatesToFeatures (infra/master_gates.ahk) zeroes those branches IN
; PLACE as a RUNTIME gate, and its own contract states the per-feature state on
; disk is NOT touched and is restored at the next Reload once the master flips
; back on. SaveFullConfig had no notion of that distinction: it walked the same
; live map, so the boot-armed save wrote the runtime zeroes back as if they were
; the user's intent, and re-enabling the category later revealed every child
; unticked with nothing logged. TOML_BatchWrite preserves keys it does not
; re-collect, so omitting the branch is exactly what "leave the disk alone"
; means — the same mechanism the [llm] block already relies on.
_PruneMasterGatedFeatures(FeaturesMap) {
		Pruned := Map()
		if (Type(FeaturesMap) != "Map")
				return Pruned
		for TopKey, TopVal in FeaturesMap {
				; Non-Map top-level entries are skipped by the walker anyway.
				if (Type(TopVal) != "Map")
						continue
				if !_MasterGateAllowsPersist(TopKey) {
						try LoggerDebug("ConfigIO", "Not serializing '{1}': its master gate is off, so the in-memory tree holds runtime zeroes rather than the user's settings.", TopKey)
						continue
				}
				if (TopKey != "hotstrings") {
						Pruned[TopKey] := TopVal
						continue
				}
				; Hotstring sub-categories own gates independent of the Hotstrings
				; master and are zeroed the same way when theirs is off.
				SubTree := Map()
				for SubKey, SubVal in TopVal {
						if (Type(SubVal) == "Map" and !_MasterGateAllowsPersist(SubKey)) {
								try LoggerDebug("ConfigIO", "Not serializing 'hotstrings.{1}': its sub-category gate is off.", SubKey)
								continue
						}
						SubTree[SubKey] := SubVal
				}
				Pruned[TopKey] := SubTree
		}
		return Pruned
}

_CollectFeatureUpdates(Updates, SectionPath, Node) {
		if (Type(Node) != "Map")
				return
		for Key, Value in Node {
				if (SectionPath == "" and Type(Value) != "Map")
						continue
				Sub := (SectionPath == "") ? Key : SectionPath "." Key
				if (Type(Value) == "Map")
						_CollectFeatureUpdates(Updates, Sub, Value)
				else
						Updates.Push({ Section: SectionPath, Key: Key, Value: Value })
		}
}

ReloadWithDefaultConfig(*) {
		global _ConfigDir, _AhkSubDir
		AhkDir := _ConfigDir . _AhkSubDir
		; A bare try around the delete turned a locked or read-only config into a
		; silent no-op — and worse than a no-op: the FSAppend below then APPENDS a
		; second [_meta] section to the surviving file. The user asked for a reset
		; and got neither a reset nor an error. Editors, cloud-sync clients and the
		; read-only attribute all reach this.
		Undeleted := ""
		for FileName in ["config.toml", "tap_hold.toml", "api_entries.json"] {
				Path := AhkDir . FileName
				try {
						if FileExist(Path)
								FileDelete(Path)
				} catch as Err {
						Undeleted .= (Undeleted == "" ? "" : ", ") . FileName
						try LoggerError("Config", "Reset to defaults: could not delete '{1}': {2}", Path, Err.Message)
				}
		}
		if (Undeleted != "") {
				try MsgBox(Format(t("dialog.reset_defaults.failed"), Undeleted),
						t("dialog.reset_defaults.failed_title"), "Iconx")
				return
		}
		; Write a minimal config so Onboarding_Run() skips the wizard on reload.
		; The user chose "reset defaults" — there is a separate "Setup wizard"
		; menu item for re-running the first-run flow. Without this placeholder
		; the deleted config.toml triggers Onboarding_Run unconditionally.
		; FSAppend REPORTS failure rather than throwing, so an ignored return is a
		; silent one. Without this placeholder the reload runs Onboarding_Run
		; unconditionally, which is not what "reset defaults" means.
		if !FSAppend(AhkDir . "config.toml", "[_meta]`nschema_version = 2`n") {
				try LoggerError("Config", "Reset to defaults: could not write the placeholder config; the setup wizard will run on reload.")
				try MsgBox(t("dialog.reset_defaults.placeholder_failed"),
						t("dialog.reset_defaults.failed_title"), "Icon!")
		}
		ReloadPreservingSuspend()
}

ReadScriptShortcutsConfig() {
		global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				Value := IniCacheGet(_IniCache, "shortcuts.script_control", Slot)
				if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
						ScriptShortcutAssignments[Slot] := Value
				else if (Value != "_")
						; Mirrors ReadKeyboardShortcutsConfig. An action retired by an
						; upgrade, or a hand-edited config, leaves the slot on its
						; compiled-in default — so AltGr+Enter fires a DIFFERENT action than
						; the one configured, with nothing in the log to explain it.
						try LoggerWarn("Shortcuts", "Script slot '{1}' has unknown action '{2}' — falling back to '{3}'.", Slot, Value,
								ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "(none)")
		}
}

ResetScriptComboKeys(SuffixSC) {
		global _ALTGR_KANA_FIXUP
		if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
				return
		KeyWait(SuffixSC, "T2")
		if !GetKeyState(SuffixSC, "P")
				SendEvent("{SC138 Up}")
}

; The ONLY actions allowed to run while the driver is suspended. The script AltGr
; chords keep a dedicated suspend-exempt hotkey set purely so script management stays
; keyboard-reachable while paused (otherwise a user who paused from the tray has no
; keyboard way back). Anything else the user assigns to those slots must obey
; "pause = tout éteint" — single source of truth for that allowlist.
global SCRIPT_SHORTCUT_SUSPEND_ALLOWED := Map(
		"script_pause_toggle", true,
		"script_reload", true,
		"script_quit", true,
		"open_personal_shortcuts", true,
)

RunScriptShortcutAction(Slot) {
		global ScriptShortcutAssignments, GESTURE_ACTIONS, SCRIPT_SHORTCUT_FALLBACKS
		global SCRIPT_SHORTCUT_SUSPEND_ALLOWED
		Action := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
		if (Action == "none") {
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		if !GESTURE_ACTIONS.Has(Action) {
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		; While suspended these chords stay armed ONLY for script management. Without this
		; scope check the exemption silently widened to whatever the user assigned, so a
		; paused driver still fired arbitrary gesture actions. Fall back to the slot's
		; native key instead, exactly like an unassigned slot.
		if (A_IsSuspended and !SCRIPT_SHORTCUT_SUSPEND_ALLOWED.Has(Action)) {
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		GestureInvokeAction(Action, GestureBindingId("script", Slot))
}

SetScriptShortcutAction(Slot, ActionName) {
		global ScriptShortcutAssignments, ConfigurationFile
		if !GestureEnsureActionParameter(GestureBindingId("script", Slot), ActionName)
				return
		ScriptShortcutAssignments[Slot] := ActionName
		TOML_Write(ActionName, ConfigurationFile, "shortcuts.script_control", Slot)
		ReloadPreservingSuspend()
}

BuildScriptShortcutsMenu() {
		global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, GESTURE_ACTIONS
		SMenu := Menu()
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				Current := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
				CurrentLabel := GESTURE_ACTIONS.Has(Current) ? GestureActionDisplayLabel(Current, GestureBindingId("script", Slot)) : t("dialog.action_picker.disabled")
				SlotLabel := t(SCRIPT_SHORTCUT_LABELS[Slot])
				RegisterMenuItem(SMenu, SlotLabel . " : " . CurrentLabel, ((_s, _l) => (*) => ShowActionPicker(_l, ScriptShortcutAssignments.Has(_s) ? ScriptShortcutAssignments[_s] : "none", (Id) => SetScriptShortcutAction(_s, Id)))(Slot, SlotLabel))
		}
		return SMenu
}

/**
 * Resolves a keyboard-shortcut slot id to a canonical chord string.
 *
 * The slot id is our own vocabulary ("ctrl_shift_v", "win_sc029"); the chord is
 * the cross-driver one. Everything AutoHotkey-specific — that Ctrl is "^", that
 * Space is "{Space}" — now lives in the HotkeyRegistrar adapter, which is the
 * only layer allowed to know it. This function previously emitted a native
 * AutoHotkey spec directly, which is why the macOS driver had to reimplement the
 * same slot grammar from scratch.
 * @param {String} SlotId e.g. "ctrl_shift_v", "win_e", "alt_space".
 * @returns {String} The canonical chord, or "" when the slot names no modifier.
 */
_KeyboardSlotChord(SlotId) {
		if SubStr(SlotId, 1, 10) = "ctrl_shift"
				Mods := ["ctrl", "shift"]
		else if SubStr(SlotId, 1, 4) = "ctrl"
				Mods := ["ctrl"]
		else if SubStr(SlotId, 1, 3) = "win"
				Mods := ["cmd"]
		else if SubStr(SlotId, 1, 3) = "alt"
				Mods := ["alt"]
		else
				return ""
		if SubStr(SlotId, 1, 10) = "ctrl_shift"
				Suffix := SubStr(SlotId, 12)
		else
				Suffix := SubStr(SlotId, InStr(SlotId, "_") + 1)
		; Slot-id spellings for keys whose canonical name is a character. The
		; brace-wrapped AutoHotkey forms that used to live here moved to the adapter
		static _SlotKeyNames := Map("period", ".", "comma", ",", "enter", "return")
		Key := _SlotKeyNames.Has(Suffix) ? _SlotKeyNames[Suffix] : Suffix
		Formatted := ChordFormat(Mods, Key)
		return Formatted["ok"] ? Formatted["label"] : ""
}

ReadKeyboardShortcutsConfig() {
		global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache, GESTURE_ACTIONS
		for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
				KeyboardShortcutAssignments[Slot] := Action
		; Read EVERY persisted slot, not just the shipped defaults.
		;
		; The slot picker offers every modifier chord in GESTURE_ACTIONS — roughly
		; 600 of them — while KEYBOARD_SHORTCUT_DEFAULTS holds 15. Iterating only
		; the defaults meant a slot the user added (say win_b) was written to
		; config.toml by SetKeyboardShortcutAction, and then never read back on the
		; Reload that same function triggers: absent from KeyboardShortcutAssignments,
		; so no hotkey is registered and the entry vanishes from the menu too. The
		; value stays on disk, so nothing looks lost — the addition just appears not
		; to have taken.
		;
		; _GlobalClearAllBindings already walks _IniCache for exactly these
		; non-default slots, which is what shows this to be a drift between the
		; clear path and the read path rather than a deliberate restriction.
		SlotsToRead := Map()
		for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS
				SlotsToRead[Slot] := true
		if IsSet(_IniCache) and _IniCache.Has("shortcuts.keyboard") {
				for Slot, _ in _IniCache["shortcuts.keyboard"]
						SlotsToRead[Slot] := true
		}

		for Slot, _ in SlotsToRead {
				Value := IniCacheGet(_IniCache, "shortcuts.keyboard", Slot)
				if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
						KeyboardShortcutAssignments[Slot] := Value
				else if (Value != "_")
						; Falling back to the shipped default is the right behaviour; doing
						; it silently is not. The key then fires a DIFFERENT action than the
						; one the user configured, and nothing anywhere says why. A slot with
						; no default resolves to "" here, which reads as "unassigned".
						try LoggerWarn("Shortcuts", "Keyboard slot '{1}' has unknown action '{2}' — falling back to '{3}'.", Slot, Value,
								KeyboardShortcutAssignments.Has(Slot) ? KeyboardShortcutAssignments[Slot] : "(none)")
		}
}

RunKeyboardShortcutAction(SlotId) {
		global KeyboardShortcutAssignments, GESTURE_ACTIONS
		Action := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
		if (Action == "none" or !GESTURE_ACTIONS.Has(Action))
				return
		GestureInvokeAction(Action, GestureBindingId("keyboard", SlotId))
}

SetKeyboardShortcutAction(SlotId, ActionName) {
		global KeyboardShortcutAssignments, ConfigurationFile
		if !GestureEnsureActionParameter(GestureBindingId("keyboard", SlotId), ActionName)
				return
		KeyboardShortcutAssignments[SlotId] := ActionName
		TOML_Write(ActionName, ConfigurationFile, "shortcuts.keyboard", SlotId)
		ReloadPreservingSuspend()
}

_MakeKeyboardShortcutHandler(SlotId, ActionName) {
		return (*) => SetKeyboardShortcutAction(SlotId, ActionName)
}

_FormatSlotLabel(SlotId) {
		static _ModLabels := Map("ctrl_shift_", "Ctrl + Shift + ", "ctrl_", "Ctrl + ", "win_", "Win + ", "alt_", "Alt + ")
		; Only the two NAMED keys are translatable — ".", "," and "²" are the glyphs
		; themselves. The map holds i18n KEYS, never labels: a static initialised with
		; t() would freeze the language at first call, and the menu is rebuilt on a
		; language switch expecting the new one.
		static _KeyNameKeys := Map("space", "common.key_space", "enter", "common.key_enter")
		static _KeyGlyphs := Map("period", ".", "comma", ",", "sc029", "²")
		for Prefix, ModLabel in _ModLabels {
				if (SubStr(SlotId, 1, StrLen(Prefix)) = Prefix) {
						Suffix := SubStr(SlotId, StrLen(Prefix) + 1)
						if _KeyNameKeys.Has(Suffix)
								Key := t(_KeyNameKeys[Suffix])
						else if _KeyGlyphs.Has(Suffix)
								Key := _KeyGlyphs[Suffix]
						else
								Key := StrUpper(Suffix)
						return ModLabel . Key
				}
		}
		return SlotId
}

; The keyboard-shortcut groups, in display order. The i18n KEYS are stored, never
; the translated labels: a static initialised with t() would freeze the language
; at first call, and the menu is rebuilt on a language switch expecting the new one
global KEYBOARD_SLOT_GROUPS := [
		Map("prefix", "alt_", "group_key", "menu.shortcuts.alt_group", "add_key", "menu.shortcuts.alt_add"),
		Map("prefix", "ctrl_", "group_key", "menu.shortcuts.ctrl_group", "add_key", "menu.shortcuts.ctrl_add"),
		Map("prefix", "ctrl_shift_", "group_key", "menu.shortcuts.ctrl_shift_group", "add_key", "menu.shortcuts.ctrl_shift_add"),
		Map("prefix", "win_", "group_key", "menu.shortcuts.win_group", "add_key", "menu.shortcuts.win_add"),
]

/**
 * The list provider for the manifest's "keyboard_slots" entry.
 *
 * Returns row DATA, never a Menu: the renderer owns the menu shape, which is
 * what removed the whole class of bug this used to be. It was a Menu.Insert
 * splice with no idempotence check, and AHK v2's Insert APPENDS on an existing
 * label rather than merging, so every updater-driven tray refresh grew the
 * submenu by five more rows. A provider cannot splice anything.
 * @returns {Array} Rows of Map("label", …, "items", …) for the renderer.
 */
KeyboardSlotRows() {
		global KeyboardShortcutAssignments, GESTURE_ACTIONS, KEYBOARD_SLOT_GROUPS

		Rows := []
		for GroupInfo in KEYBOARD_SLOT_GROUPS {
				Prefix := GroupInfo["prefix"]
				Items := []
				for Slot, Action in KeyboardShortcutAssignments {
						if (SubStr(Slot, 1, StrLen(Prefix)) != Prefix)
								continue
						; A slot only belongs to the LONGEST prefix that matches it, or
						; "ctrl_shift_v" would appear in the Ctrl group as well
						IsExactPrefix := true
						for OtherGroup in KEYBOARD_SLOT_GROUPS {
								OtherPrefix := OtherGroup["prefix"]
								if (OtherPrefix != Prefix and StrLen(OtherPrefix) > StrLen(Prefix) and SubStr(Slot, 1, StrLen(OtherPrefix)) == OtherPrefix) {
										IsExactPrefix := false
										break
								}
						}
						if !IsExactPrefix or (Action == "none")
								continue
						ActionLabel := GESTURE_ACTIONS.Has(Action) ? GestureActionDisplayLabel(Action, GestureBindingId("keyboard", Slot)) : Action
						Items.Push(Map(
								"label", _FormatSlotLabel(Slot) . " : " . ActionLabel,
								"action", ((_s) => (*) => ShowKeyboardShortcutPicker(_s))(Slot)
						))
				}
				Items.Push(Map(
						"label", t(GroupInfo["add_key"]),
						"action", ((_p) => (*) => ShowKeyboardSlotPicker(_p))(Prefix)
				))
				Rows.Push(Map("label", t(GroupInfo["group_key"]), "items", Items))
		}
		return Rows
}
