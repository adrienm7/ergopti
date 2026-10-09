; tests/meta/test_menu_metrics_disabled_when.ahk

; ==============================================================================
; MODULE: Metrics Menu disabled_when Contract Test (MG-1/MG-2)
; DESCRIPTION:
; Pins the declarative disabled_when predicate the shared manifest now carries
; for every metrics_menu item, and asserts the AHK driver actually delegates
; to the shared resolver (MenuRenderer_ResolveDisabledWhen) instead of
; re-deriving the dependency graph by hand — the drift MG-1 closes — and that
; the previously dead depends_on on menubar_colors is now a load-bearing
; disabled_when, rendered through a "dynamic" (not "feature") entry (MG-2).
;
; The macOS half lives in macos/tests/meta/test_menu_metrics_disabled_when.lua.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ Canonical contract (the truth) =======
; =================================================
; =================================================

; id -> array of canonical disabled_when state keys. AHK-relevant subset only
; — metrics_menu items restricted to platforms=["hs"] (wpm_menubar,
; menubar_colors, encryption) are never rendered on AHK and are covered by
; the manifest-only assertions in 2/ instead.
_MMDW_Canonical() {
	return Map(
		"show_typing",        ["keylogger_enabled"],
		"show_apps",          ["keylogger_enabled"],
		"wpm_widget",         ["keylogger_enabled"],
		"widget_colors",      ["keylogger_enabled", "wpm_widget_visible"],
		"include_realtime",   ["keylogger_enabled", "wpm_widget_visible"],
		"reset_wpm_position", ["keylogger_enabled", "wpm_widget_visible"],
		"filter_private",     ["keylogger_enabled"],
		"filter_secure",      ["keylogger_enabled"],
		"filter_sysauth",     ["keylogger_enabled"],
		"exclude_apps",       ["keylogger_enabled"],
	)
}

_MMDW_ManifestPath() {
	SplitPath(A_ScriptDir, , &WinDir)
	SplitPath(WinDir, , &EpDir)
	return EpDir . "\_shared\modules\menu\menu_manifest.json"
}

_MMDW_LoadMetricsMenu() {
	Raw := ""
	try Raw := FileRead(_MMDW_ManifestPath(), "UTF-8")
	Assert(Raw != "", "menu_manifest.json must be readable")
	Root := JsonParse(Raw)
	Assert(Root is Map && Root.Has("metrics_menu"), "menu_manifest.json must have a metrics_menu array")
	return Root["metrics_menu"]
}





; ===============================================
; ===============================================
; ======= 2/ Manifest contract assertions =======
; ===============================================
; ===============================================

; Every canonical id must carry the exact disabled_when array in the shared
; manifest — this is the data MenuRenderer_ResolveDisabledWhen actually reads.
_MMDW_ManifestMatchesCanonical() {
	ById := Map()
	for Entry in _MMDW_LoadMetricsMenu() {
		if (Entry is Map) && Entry.Has("id")
			ById[Entry["id"]] := Entry
	}

	for Id, Canon in _MMDW_Canonical() {
		Assert(ById.Has(Id), "metrics_menu must declare an item with id '" . Id . "'")
		Entry := ById[Id]
		Assert(Entry.Has("disabled_when"), "metrics_menu item '" . Id . "' must declare disabled_when")
		Keys := Entry["disabled_when"]
		Assert(Keys is Array && Keys.Length == Canon.Length,
			"metrics_menu item '" . Id . "' disabled_when must have " . Canon.Length . " key(s)")
		I := 1
		while I <= Canon.Length {
			Assert(Keys[I] == Canon[I],
				"metrics_menu item '" . Id . "' disabled_when[" . I . "] must be '" . Canon[I] . "' — found '" . Keys[I] . "'")
			I++
		}
	}
}
Test("menu-metrics-disabled-when: manifest disabled_when matches the canonical dependency graph", _MMDW_ManifestMatchesCanonical)

; MG-2 — menubar_colors' depends_on is now a load-bearing disabled_when. It also
; used to be type="feature", which the macOS renderer silently skips (the item
; never rendered at all); pinning type="dynamic" here guards against that
; regression reappearing alongside the dead-data one.
_MMDW_MenubarColorsLoadBearing() {
	for Entry in _MMDW_LoadMetricsMenu() {
		if !(Entry is Map) || !Entry.Has("id") || Entry["id"] != "menubar_colors"
			continue
		; The failure this guards is a type the renderer SKIPS: a `feature` row is
		; left to the caller, so declaring one made the item never render at all.
		; It was `dynamic` until 2026-08-07 and is `check` now — the renderer
		; builds the checkbox from the declaration rather than the driver building
		; one it already knows how to draw. Both are rendered; `feature` is not,
		; which is what this states instead of naming the single type that happened
		; to satisfy it.
		RenderedTypes := Map("dynamic", true, "check", true, "command", true, "list", true, "action", true)
		Assert(RenderedTypes.Has(Entry["type"]),
			"menubar_colors is type=" . Entry["type"] . ", which the renderer does not materialise — "
			. "`feature` is left to the caller, so the row disappears with nothing "
			. "reporting it (MG-2)")
		Assert(!Entry.Has("depends_on"),
			"menubar_colors must no longer carry the dead depends_on key — superseded by disabled_when")
		Assert(Entry.Has("disabled_when"), "menubar_colors must declare disabled_when")
		Keys := Entry["disabled_when"]
		Assert(Keys.Length == 2 && Keys[1] == "keylogger_enabled" && Keys[2] == "wpm_menubar_visible",
			"menubar_colors disabled_when must be [keylogger_enabled, wpm_menubar_visible]")
		return
	}
	Assert(false, "metrics_menu must declare a menubar_colors item")
}
Test("menu-metrics-disabled-when: menubar_colors depends_on is now load-bearing disabled_when (MG-2)", _MMDW_MenubarColorsLoadBearing)





; ===================================================
; ===================================================
; ======= 3/ AHK driver delegates to resolver =======
; ===================================================
; ===================================================

; Every remaining AHK provider must call the shared resolver with its own id
; instead of re-deriving the dependency graph inline — the drift MG-1 closes.
_MMDW_HandlersCallResolver() {
	; The handlers this driver still writes. The three privacy filters left this
	; list on 2026-08-06: their manifest rows became `type = "check"`, so the
	; SHARED renderer builds them and calls the same resolver while doing it.
	;
	; The invariant is unchanged — greying comes from the manifest through the
	; shared resolver, never from a condition re-derived here — and section 4
	; below asserts it for the migrated rows. Keeping them in this list would
	; have made a row built by MORE shared code look like a regression.
	; show_typing, show_apps and reset_wpm_position left this list on 2026-08-07: their manifest rows
	; are `command`, so the RENDERER applies the greying from the declaration and
	; there is no handler left to delegate. That is the case the paragraph above
	; describes — a row built by more shared code, not less.
	; The app-exclusion row became a `list` provider on 2026-08-07 — the renderer
	; draws the row, the provider only says what it says. It stays in this list
	; under its new name: a provider resolves its own greying exactly as the
	; handler did, because the label is computed and the renderer has nothing
	; else to apply the declaration to. The two shortcut pickers left the menu on
	; 2026-10-01 (the last test of this file).
	Handlers := Map(
		"_MET_ExcludeAppsRows",    "exclude_apps",
	)
	for FuncName, Id in Handlers {
		Seg := _DriverFuncBody(FuncName)
		Assert(Seg != "", FuncName . "() must exist in menu_metrics.ahk")
		Needle := 'MenuRenderer_ResolveDisabledWhen("metrics_menu", "' . Id . '", Getters)'
		Assert(InStr(Seg, Needle) > 0,
			FuncName . " must delegate greying to MenuRenderer_ResolveDisabledWhen('metrics_menu', '" . Id . "', Getters) — not a hardcoded condition")
	}
}
Test("menu-metrics-disabled-when: AHK handlers delegate to the shared resolver (MG-1)", _MMDW_HandlersCallResolver)

; The shared getters map itself must map each canonical key to the correct
; state read — this is the only place MetricsShortcuts.enabled / WPMWidget.visible
; should still be referenced for disabling purposes.
; Matched with a tolerant gap between the key and its arrow rather than the exact
; two spaces the map happened to use. The mapping is the contract; the column the
; arrow lands in is not, and pinning it made adding a LONGER key to the map fail
; this test — the alignment shifts, the assertion breaks, and nothing about the
; state read has changed.
_MMDW_GettersMapCorrect() {
	Src := _DriverSourceConcat()
	Assert(RegExMatch(Src, '"keylogger_enabled",\s+\(\) => MetricsShortcuts\.enabled,') > 0,
		"_MET_STATE_GETTERS must map keylogger_enabled to MetricsShortcuts.enabled")
	Assert(RegExMatch(Src, '"wpm_widget_visible",\s+\(\) => WPMWidget\.visible,') > 0,
		"_MET_STATE_GETTERS must map wpm_widget_visible to WPMWidget.visible")
}
Test("menu-metrics-disabled-when: shared getters map reads the correct AHK state", _MMDW_GettersMapCorrect)





; =======================================================
; =======================================================
; ======= 4/ Master toggle wiring (F2 regression) =======
; =======================================================
; =======================================================

; ToggleMetricsEnabled() holds the real MetricsShortcuts.enabled flip plus the
; confirm/security-warning dialogs. The master row is the manifest's
; `metrics_toggle`, so the command BuildMetricsMenu registers under that id is
; the one wire that reaches it. Without it the renderer reports the switch and
; draws nothing; with the generic ToggleCategoryAllFeatures instead, it would
; write a key ApplyMasterGatesToFeatures never reads — see F2 in
; AUDIT_AHK_2026-07-01.md.
_MMDW_ToggleMetricsEnabledIsWired() {
	Body := _StripFullLineComments(_DriverFuncBody("BuildMetricsMenu"))
	Assert(Body != "", "BuildMetricsMenu must be present in the driver source")
	Assert(RegExMatch(Body, '"metrics_toggle",\s*\(\*\)\s*=>\s*ToggleMetricsEnabled\(\)') > 0,
		"BuildMetricsMenu must register ToggleMetricsEnabled() as the metrics_toggle command (F2)")
}
Test("menu-metrics-disabled-when: the metrics switch runs ToggleMetricsEnabled (F2)", _MMDW_ToggleMetricsEnabledIsWired)

; The manifest's toggle entry is the ONLY metrics switch on AHK now, so it must
; be visible there. It used to exclude "ahk" because BuildMetricsMenu inserted a
; second, hand-built master row; that row is gone, and an exclusion would leave
; the submenu with no switch at all.
_MMDW_ManifestToggleReachesAhk() {
	for Entry in _MMDW_LoadMetricsMenu() {
		if !(Entry is Map)
			continue
		if !Entry.Has("type") || Entry["type"] != "toggle"
			continue
		if Entry.Has("platforms") {
			Plats := Entry["platforms"]
			Assert(Plats is Array, "metrics_menu toggle entry's platforms must be an array")
			Found := false
			for P in Plats
				Found := Found || (P == "ahk")
			Assert(Found, "metrics_menu toggle entry must reach ahk — it is the only metrics switch there (F2)")
		}
		return
	}
	Assert(false, "metrics_menu must declare a type=toggle entry")
}
Test("menu-metrics-disabled-when: the manifest metrics switch reaches Windows (F2)", _MMDW_ManifestToggleReachesAhk)

; The prior assertion reads the GENERATED menu_manifest.json, which can drift
; from its own source: an earlier fix pass hand-edited the generated JSON
; instead of manifest.toml, and regenerating undid it. This reads the TRUE
; source so a regeneration cannot silently take the switch away from Windows.
_MMDW_ManifestTomlSourceReachesAhk() {
	SplitPath(A_ScriptDir, , &WinDir)
	SplitPath(WinDir, , &EpDir)
	TomlPath := EpDir . "\_shared\modules\features\manifest.toml"
	Toml := ""
	try Toml := FileRead(TomlPath, "UTF-8")
	Assert(Toml != "", "manifest.toml must be readable")

	HeaderPos := InStr(Toml, "[[menu.metrics_menu]]")
	Assert(HeaderPos > 0, "manifest.toml must declare a [[menu.metrics_menu]] table")
	NextTablePos := InStr(Toml, "[[", , HeaderPos + StrLen("[[menu.metrics_menu]]"))
	Body := (NextTablePos > 0) ? SubStr(Toml, HeaderPos, NextTablePos - HeaderPos) : SubStr(Toml, HeaderPos)
	Assert(InStr(Body, 'type = "toggle"') > 0,
		'the first [[menu.metrics_menu]] table must be the type="toggle" master entry')
	PlatPos := InStr(Body, "platforms = [")
	if (PlatPos > 0) {
		PlatList := SubStr(Body, PlatPos, InStr(Body, "]", , PlatPos) - PlatPos + 1)
		Assert(RegExMatch(PlatList, 'i)"ahk"'),
			'manifest.toml`'s [[menu.metrics_menu]] toggle entry must reach "ahk" — it is the only metrics switch there (F2). Found: ' . PlatList)
	}
}
Test("menu-metrics-disabled-when: manifest.toml SOURCE keeps the metrics switch on Windows, not just the generated JSON (F2)", _MMDW_ManifestTomlSourceReachesAhk)




; ==============================================================================
; ==============================================================================
; ======= 4/ The rows the shared renderer builds now ===========================
; ==============================================================================
; ==============================================================================

; The three privacy filters are declared `type = "check"`, which means the row —
; label, checkmark and greying — is materialised by MenuRenderer_Build from the
; manifest, on all three drivers, from one declaration.
;
; WHAT THIS FORBIDS. Two things, and the second is the one that bites: a row that
; loses its declaration silently returns to being hand-built and drifts again;
; and a row that is declared AND still has a handler here is drawn TWICE, which
; looks like a duplicate menu entry and nothing else reports it.
_MMDW_MigratedRowsAreDeclarative() {
	; id -> the handler this driver used to build it with. Spelled out rather
	; than derived from the id, because a derivation that stops matching would
	; assert the absence of a function that never existed under that name.
	Migrated := Map(
		"include_realtime", "_MET_WpmWidgetGraph",
		"widget_colors", "_MET_WpmWidgetColors",
		"wpm_widget", "_MET_WpmWidget",
		"filter_private", "_MET_FilterPrivate",
		"filter_secure",  "_MET_FilterSecure",
		"filter_sysauth", "_MET_FilterSysauth",
	)

	Rows := _MMDW_LoadMetricsMenu()
	for Id, OldHandler in Migrated {
		Found := false
		for Entry in Rows {
			if (Entry is Map) and Entry.Has("id") and Entry["id"] == Id {
				Found := true
				Assert(Entry.Has("type") and Entry["type"] == "check",
					"'" . Id . "' must be declared type=check so the shared renderer builds its row — a row that loses the declaration goes back to being hand-built on three drivers and drifts again")
				Assert(Entry.Has("i18n") and Entry["i18n"] != "",
					"'" . Id . "' must carry its i18n key: the renderer has no other source for the label")
			}
		}
		Assert(Found, "metrics_menu must still declare '" . Id . "'")

		; And no handler may remain: the renderer draws the row, so a second
		; builder here draws it twice — which looks like a duplicate menu entry
		; and nothing else reports it.
		Assert(_DriverFuncBodyOrEmpty(OldHandler) == "",
			OldHandler . "() still exists — the shared renderer builds '" . Id . "' now, so this handler would draw it a second time")
	}
}
Test("menu-metrics-disabled-when: the migrated check rows are built by the shared renderer, not twice", _MMDW_MigratedRowsAreDeclarative)

; The Metrics menu sets no shortcut of its own (the maintainer's rule of
; 2026-10-01, metrics-no-shortcut-rows): a shortcut that opens a metrics window
; is assigned to its opening action in the Gestures or the Shortcuts menu. The
; two rows, their providers and their refresh wrapper are gone, and the two
; rows that open a window follow each other with no separator between them.
_MMDW_NoShortcutRows() {
	Rows := _MMDW_LoadMetricsMenu()
	Ids := []
	for Entry in Rows {
		if !(Entry is Map)
			continue
		Id := Entry.Has("id") ? Entry["id"] : ""
		Assert(Id != "shortcut_typing" and Id != "shortcut_apps",
			"the Metrics menu must declare no shortcut row, found '" . Id . "'")
		Assert(!Entry.Has("i18n_dynamic"), "no Metrics row carries a shortcut label prefix any more")
		Ids.Push(Entry.Has("type") and Entry["type"] == "---" ? "---" : Id)
	}
	At := 0
	for Index, Id in Ids {
		if (Id == "show_typing")
			At := Index
	}
	Assert(At > 0 and At + 2 <= Ids.Length, "the Metrics menu must still declare the row that opens the typing metrics")
	AssertEqual("show_apps", Ids[At + 1], "the two rows that open a window form one group, with nothing between them")
	AssertEqual("---", Ids[At + 2], "a separator closes that group")
	for Name in ["_MET_ShortcutTypingRows", "_MET_ShortcutAppsRows", "_MET_PromptShortcutAndRefresh"]
		Assert(_DriverFuncBodyOrEmpty(Name) == "", Name . "() still exists: the Metrics menu sets no shortcut")
}
Test("menu-metrics-disabled-when: the menu sets no shortcut and its two opening rows form one group (metrics-no-shortcut-rows)",
	_MMDW_NoShortcutRows)
