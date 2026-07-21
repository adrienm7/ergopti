; lib/config_io.ahk

; ==============================================================================
; MODULE: Config I/O — feature toggles, persistence & shortcut config
; DESCRIPTION:
; Reading/writing the user config: the bulk feature/hotstring/category toggles,
; SaveFullConfig + _CollectFeatureUpdates, ReloadWithDefaultConfig, and the
; script/keyboard shortcut slot configuration (read/run/set/menu). Extracted
; verbatim from ErgoptiPlus.ahk (P4 entrypoint decomposition) and #Include'd in
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
        Updates.Push({ Section: "ahk.gestures", Key: Slot, Value: "none" })
    }
    KbWritten := Map()
    for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
        KeyboardShortcutAssignments[Slot] := "none"
        Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: "none" })
        KbWritten[Slot] := true
    }
    if IsSet(_IniCache) and _IniCache.Has("ahk.shortcuts.keyboard") {
        for Slot, _ in _IniCache["ahk.shortcuts.keyboard"] {
            if !KbWritten.Has(Slot) {
                KeyboardShortcutAssignments[Slot] := "none"
                Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: "none" })
            }
        }
    }
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        ScriptShortcutAssignments[Slot] := "none"
        Updates.Push({ Section: "ahk.shortcuts.script_control", Key: Slot, Value: "none" })
    }
    if IsSet(_TH_WriteTapHoldDisabled)
        try _TH_WriteTapHoldDisabled()
}

; Recursively force every leaf under Node to Bool ("tout activer"/"tout
; desactiver"), mutating Features in place and appending the required
; {Section, Key, Value} TOML writes to Updates. Extracted out of ToggleAllFeatures
; as a standalone module function (rather than a nested closure) so the flip
; logic is directly testable without triggering ToggleAllFeatures's trailing
; Reload(). Reuses ManifestResolveFeatureSection (lib/manifest_reader.ahk) --
; the single source of truth introduced for _CollectFeatureUpdates -- to
; re-derive the ahk.-prefixed TOML section per leaf instead of the raw
; (already ahk.-stripped) Features nesting.
_CollectFeatureFlipUpdates(Bool, SectionPath, Node, Updates) {
    if (Type(Node) != "Map")
        return
    if Node.Has("enabled") and (Type(Node["enabled"]) != "Map") {
        Node["enabled"] := Bool
        Updates.Push({ Section: ManifestResolveFeatureSection(SectionPath . ".enabled", SectionPath), Key: "enabled", Value: Bool })
        return
    }
    for K, V in Node {
        if (Type(V) == "Map")
            _CollectFeatureFlipUpdates(Bool, SectionPath . "." . K, V, Updates)
        else {
            Node[K] := Bool
            Updates.Push({ Section: ManifestResolveFeatureSection(SectionPath . "." . K, SectionPath), Key: K, Value: Bool })
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
        Updates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(Category), Value: Bool })
    }
    WPMWidget.visible := Bool
    WPMWidget.use_colors := Bool
    WPMWidget.show_graph := Bool
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: Bool ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: Bool ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: Bool ? "1" : "0" })
    if !Bool
        _GlobalClearAllBindings(Updates)
    TOML_BatchWrite(ConfigurationFile, Updates)
    if Bool {
        HsBatch := []
        for V2Path in _CollectAllHotstringsV2Paths()
            HsBatch.Push(Map("path", V2Path, "value", true))
        if (HsBatch.Length > 0)
            WriteFeatureBatchV2(Features, HsBatch)
    }
    Reload
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
    TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", "hotstrings")
    Batch := []
    for V2Path in _CollectAllHotstringsV2Paths()
        Batch.Push(Map("path", V2Path, "value", Bool))
    if (Batch.Length > 0)
        WriteFeatureBatchV2(Features, Batch)
    Reload
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
    if !(_HSCategorySnapshot.Has(V2Cat) and IsSet(Features)
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
        TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", _CategoryEnabledKey(Category))
        LoggerStart("Menu", "Applying live category toggle for {1}…", Category)
        RebuildHotstringsLive()
        LoggerSuccess("Menu", "Live category toggle applied for {1}.", Category)
        return
    }
    CategoryEnabled[Category] := Bool
    TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", _CategoryEnabledKey(Category))
    Reload
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
            GateUpdates.Push({ Section: "ahk.category_enabled", Key: "hotstrings", Value: true })
        }
        ; Lift this category's own gate too, when it has one (flat categories do;
        ; DynamicHotstrings / Personal follow the master directly).
        if (CategoryEnabled.Has(V1Cat) and !CategoryEnabled[V1Cat]) {
            CategoryEnabled[V1Cat] := true
            GateUpdates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(V1Cat), Value: true })
        }
    }
    if (GateUpdates.Length > 0)
        TOML_BatchWrite(ConfigurationFile, GateUpdates)
    Batch := []
    for _, Entry in ManifestFeaturesForSection(V2Section)
        Batch.Push(Map("path", Entry["path"], "value", Bool))
    if (Batch.Length > 0)
        WriteFeatureBatchV2(Features, Batch)
    Reload
}

; Force every personal hotstring section (from personal_hotstrings.toml) on/off.
; Personal sections are runtime-discovered, so their v2 paths are built from the
; TOML section names (hotstrings.personal.<lower(section)>). Enabling lifts the
; Hotstrings master gate so the sections fire immediately.
HS_TogglePersonalAllSections(Enable) {
    global CategoryEnabled, ConfigurationFile, ScriptInformation, Features
    Bool := (Enable = true or Enable = 1)
    PersonalSectionsPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
    if (PersonalSectionsPath == "" or !FileExist(PersonalSectionsPath))
        return
    if (Bool and (!CategoryEnabled.Has("Hotstrings") or !CategoryEnabled["Hotstrings"])) {
        CategoryEnabled["Hotstrings"] := true
        TOML_Write(true, ConfigurationFile, "ahk.category_enabled", "hotstrings")
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
    Reload
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
    Updates := []
    ; Only sync LLM state into Features if LLM_Menu_Init() has already run and
    ; populated _LLM_Menu with the user's persisted values. Calling it before
    ; init would push module-level defaults (e.g. enabled=false) over the user's
    ; saved settings, corrupting the config file.
    global _LLM_Menu_Loaded
    if IsSet(_LLM_Menu_SyncToFeatures) && (IsSet(_LLM_Menu_Loaded) && _LLM_Menu_Loaded)
        _LLM_Menu_SyncToFeatures()
    if IsSet(Features) {
        _CollectFeatureUpdates(Updates, "", Features)
        Updates.Push({ Section: "_meta", Key: "schema_version", Value: 2 })
    }
    Updates.Push({ Section: "script", Key: "locale", Value: I18nGetLocale() })
    global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
    Updates.Push({ Section: "script", Key: "log_level", Value: IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : LOGGER_DEFAULT_LEVEL })
    Updates.Push({ Section: "hotstrings", Key: "trigger_char", Value: ScriptInformation["MagicKey"] })
    if IsSet(ScriptShortcutAssignments) {
        for Slot, Action in ScriptShortcutAssignments
            Updates.Push({ Section: "ahk.shortcuts.script_control", Key: Slot, Value: Action })
    }
    if IsSet(KeyboardShortcutAssignments) {
        for Slot, Action in KeyboardShortcutAssignments
            Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: Action })
    }
    if IsSet(GestureAssignments) {
        for Slot, Action in GestureAssignments
            Updates.Push({ Section: "ahk.gestures", Key: Slot, Value: Action })
    }
    apps := []
    for proc, _ in MetricsFilters.disabled_apps
        apps.Push(proc)
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_enabled", Value: TOML_Bool(MetricsShortcuts.enabled) })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_shortcut_typing", Value: MetricsShortcuts.typing_str })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_shortcut_apps", Value: MetricsShortcuts.apps_str })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_wpm_menubar_colors", Value: MetricsShortcuts.wpm_menubar_colors })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_filter_private_browsing", Value: TOML_Bool(MetricsFilters.private_browsing) })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_filter_secure_field", Value: TOML_Bool(MetricsFilters.secure_field) })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_filter_system_auth", Value: TOML_Bool(MetricsFilters.system_auth) })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_disabled_apps", Value: apps })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_X,       Value: String(WPMWidget.pos_x) })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_Y,       Value: String(WPMWidget.pos_y) })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: WPMWidget.use_colors ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: WPMWidget.show_graph  ? "1" : "0" })
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
            Updates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(_CatName), Value: TOML_Bool(_CatBool) })
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
        TOML_BatchWrite(ConfigurationFile, Updates)
    } finally {
        _TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState
    }
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
            Updates.Push({ Section: ManifestResolveFeatureSection(Sub, SectionPath), Key: Key, Value: Value })
    }
}

ReloadWithDefaultConfig(*) {
    global _ConfigDir, _AhkSubDir
    AhkDir := _ConfigDir . _AhkSubDir
    for FileName in ["config.toml", "tap_hold.toml", "api_entries.json"] {
        Path := AhkDir . FileName
        try {
            if FileExist(Path)
                FileDelete(Path)
        }
    }
    ; Write a minimal config so Onboarding_Run() skips the wizard on reload.
    ; The user chose "reset defaults" — there is a separate "Setup wizard"
    ; menu item for re-running the first-run flow. Without this placeholder
    ; the deleted config.toml triggers Onboarding_Run unconditionally.
    FSAppend(AhkDir . "config.toml", "[_meta]`nschema_version = 2`n")
    Reload
}

ReadScriptShortcutsConfig() {
    global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Value := IniCacheGet(_IniCache, "ahk.shortcuts.script_control", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
            ScriptShortcutAssignments[Slot] := Value
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
    TOML_Write(ActionName, ConfigurationFile, "ahk.shortcuts.script_control", Slot)
    Reload
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

_KeyboardSlotSendCode(SlotId) {
    global KEYBOARD_SHORTCUT_SEND_CODES
    if KEYBOARD_SHORTCUT_SEND_CODES.Has(SlotId)
        return KEYBOARD_SHORTCUT_SEND_CODES[SlotId]
    if SubStr(SlotId, 1, 10) = "ctrl_shift"
        ModifierPrefix := "^+"
    else if SubStr(SlotId, 1, 4) = "ctrl"
        ModifierPrefix := "^"
    else if SubStr(SlotId, 1, 3) = "win"
        ModifierPrefix := "#"
    else if SubStr(SlotId, 1, 3) = "alt"
        ModifierPrefix := "!"
    else
        return ""
    if SubStr(SlotId, 1, 10) = "ctrl_shift"
        Suffix := SubStr(SlotId, 12)
    else
        Suffix := SubStr(SlotId, InStr(SlotId, "_") + 1)
    static _SpecialMap := Map("space", "{Space}", "enter", "{Enter}", "period", ".", "comma", ",", "sc029", "SC029")
    return _SpecialMap.Has(Suffix) ? ModifierPrefix . _SpecialMap[Suffix] : ModifierPrefix . Suffix
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
    if IsSet(_IniCache) and _IniCache.Has("ahk.shortcuts.keyboard") {
        for Slot, _ in _IniCache["ahk.shortcuts.keyboard"]
            SlotsToRead[Slot] := true
    }

    for Slot, _ in SlotsToRead {
        Value := IniCacheGet(_IniCache, "ahk.shortcuts.keyboard", Slot)
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
    TOML_Write(ActionName, ConfigurationFile, "ahk.shortcuts.keyboard", SlotId)
    Reload
}

_MakeKeyboardShortcutHandler(SlotId, ActionName) {
    return (*) => SetKeyboardShortcutAction(SlotId, ActionName)
}

_FormatSlotLabel(SlotId) {
    static _ModLabels := Map("ctrl_shift_", "Ctrl + Shift + ", "ctrl_", "Ctrl + ", "win_", "Win + ", "alt_", "Alt + ")
    static _KeyNames := Map("space", "Espace", "enter", "Entrée", "period", ".", "comma", ",", "sc029", "²")
    for Prefix, ModLabel in _ModLabels {
        if (SubStr(SlotId, 1, StrLen(Prefix)) = Prefix) {
            Suffix := SubStr(SlotId, StrLen(Prefix) + 1)
            Key := _KeyNames.Has(Suffix) ? _KeyNames[Suffix] : StrUpper(Suffix)
            return ModLabel . Key
        }
    }
    return SlotId
}

InsertKeyboardShortcutGroups(TargetMenu, InsertBefore) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    _Groups := [
        Map("prefix", "alt_", "label", t("menu.shortcuts.alt_group"), "add_label", t("menu.shortcuts.alt_add")),
        Map("prefix", "ctrl_", "label", t("menu.shortcuts.ctrl_group"), "add_label", t("menu.shortcuts.ctrl_add")),
        Map("prefix", "ctrl_shift_", "label", t("menu.shortcuts.ctrl_shift_group"), "add_label", t("menu.shortcuts.ctrl_shift_add")),
        Map("prefix", "win_", "label", t("menu.shortcuts.win_group"), "add_label", t("menu.shortcuts.win_add")),
    ]
    GroupMenus := []
    for GroupInfo in _Groups {
        Prefix := GroupInfo["prefix"]
        GLabel := GroupInfo["label"]
        AddLabel := GroupInfo["add_label"]
        GMenu := Menu()
        for Slot, Action in KeyboardShortcutAssignments {
            if (SubStr(Slot, 1, StrLen(Prefix)) != Prefix)
                continue
            IsExactPrefix := true
            for OtherGroup in _Groups {
                OtherPrefix := OtherGroup["prefix"]
                if (OtherPrefix != Prefix and StrLen(OtherPrefix) > StrLen(Prefix) and SubStr(Slot, 1, StrLen(OtherPrefix)) == OtherPrefix) {
                    IsExactPrefix := false
                    break
                }
            }
            if !IsExactPrefix or (Action == "none")
                continue
            ActionLabel := GESTURE_ACTIONS.Has(Action) ? GestureActionDisplayLabel(Action, GestureBindingId("keyboard", Slot)) : Action
            RegisterMenuItem(GMenu, _FormatSlotLabel(Slot) . " : " . ActionLabel, ((_s) => (*) => ShowKeyboardShortcutPicker(_s))(Slot))
        }
        RegisterMenuItem(GMenu, AddLabel, ((_p) => (*) => ShowKeyboardSlotPicker(_p))(Prefix))
        GroupMenus.Push(Map("label", GLabel, "menu", GMenu))
    }
    TargetMenu.Insert(InsertBefore)
    loop GroupMenus.Length {
        Idx := GroupMenus.Length - A_Index + 1
        TargetMenu.Insert(InsertBefore, GroupMenus[Idx]["label"], GroupMenus[Idx]["menu"])
    }
}
