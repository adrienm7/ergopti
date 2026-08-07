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
		"shortcut_typing",    ["keylogger_enabled"],
		"show_apps",          ["keylogger_enabled"],
		"shortcut_apps",      ["keylogger_enabled"],
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
		; one it already knows how to draw. Both are rendered; `feature` and
		; `toggle` are not, which is what this states instead of naming the single
		; type that happened to satisfy it.
		RenderedTypes := Map("dynamic", true, "check", true, "command", true, "list", true, "action", true)
		Assert(RenderedTypes.Has(Entry["type"]),
			"menubar_colors is type=" . Entry["type"] . ", which the renderer does not materialise — "
			. "`feature` and `toggle` are left to the caller, so the row disappears with nothing "
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

; Every AHK dynamic handler must call the shared resolver with its own id
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
	; The two shortcut pickers and the app-exclusion row became `list` providers on
	; 2026-08-07 — the renderer draws the row, the provider only says what it says.
	; They stay in this list under their new names: a provider resolves its own
	; greying exactly as the handler did, because the label is computed and the
	; renderer has nothing else to apply the declaration to.
	Handlers := Map(
		"_MET_ShortcutTypingRows", "shortcut_typing",
		"_MET_ShortcutAppsRows",   "shortcut_apps",
		"_MET_ExcludeAppsRows",    "exclude_apps",
		"_MET_WpmWidget",          "wpm_widget",
		"_MET_WpmWidgetColors",    "widget_colors",
		"_MET_WpmWidgetGraph",     "include_realtime",
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
; confirm/security-warning dialogs. If it has zero call sites, the master
; toggle row either doesn't exist or silently falls through to the generic
; manifest renderer (which writes a key ApplyMasterGatesToFeatures never
; reads) — see F2 in AUDIT_AHK_2026-07-01.md.
_MMDW_ToggleMetricsEnabledIsWired() {
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "ToggleMetricsEnabled())") > 0,
		"BuildMetricsMenu must wire the master row to ToggleMetricsEnabled() via AddCategoryToggleItem — found no call site")
}
Test("menu-metrics-disabled-when: ToggleMetricsEnabled has a real call site (F2)", _MMDW_ToggleMetricsEnabledIsWired)

; The manifest's own generic toggle entry must be excluded on AHK — otherwise
; _MR_RenderToggle auto-renders a second, non-functional master row that
; writes a dead ToggleCategoryAllFeatures("Metrics", ...) key. Mirrors the
; gestures_menu toggle entry, which already carries platforms:["hs"].
_MMDW_ManifestToggleExcludesAhk() {
	; NOTE: this file's tests are static-source-scan only — infra/manifest_menu.ahk
	; (which defines _MR_Get/MenuRenderer_Build) is deliberately NOT #Included by
	; run_all.ahk, so this reads the parsed JSON directly via Map access rather
	; than calling into manifest_menu.ahk's helpers.
	for Entry in _MMDW_LoadMetricsMenu() {
		if !(Entry is Map)
			continue
		if !Entry.Has("type") || Entry["type"] != "toggle"
			continue
		Assert(Entry.Has("platforms"), "metrics_menu toggle entry must declare a platforms filter excluding ahk (F2)")
		Plats := Entry["platforms"]
		Assert(Plats is Array, "metrics_menu toggle entry's platforms must be an array")
		for P in Plats
			Assert(P != "ahk", "metrics_menu toggle entry must NOT include 'ahk' in platforms — the real toggle is BuildMetricsMenu's AddCategoryToggleItem (F2)")
		return
	}
	Assert(false, "metrics_menu must declare a type=toggle entry")
}
Test("menu-metrics-disabled-when: manifest toggle entry excludes ahk so the bespoke toggle isn't shadowed (F2)", _MMDW_ManifestToggleExcludesAhk)

; The two prior assertions only read the GENERATED menu_manifest.json, which
; can silently drift from its own source: an earlier fix pass hand-edited the
; generated JSON directly instead of manifest.toml, so regenerating via
; `node tools/build/build-menu-manifest.js` reintroduced the F2 bug (the
; regenerated JSON lost platforms:["hs"] because manifest.toml never had it).
; This guards the TRUE source of truth so a future regeneration can never
; silently resurrect the dead duplicate toggle.
_MMDW_ManifestTomlSourceExcludesAhk() {
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
	Assert(InStr(Body, 'platforms = ["hs"]') > 0,
		'manifest.toml`'s [[menu.metrics_menu]] toggle entry must declare platforms = ["hs"] — without it, regenerating menu_manifest.json from source silently resurrects the dead duplicate toggle (F2)')
}
Test("menu-metrics-disabled-when: manifest.toml SOURCE excludes ahk from the metrics toggle, not just the generated JSON (F2)", _MMDW_ManifestTomlSourceExcludesAhk)




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
Test("menu-metrics-disabled-when: the migrated privacy rows are built by the shared renderer, not twice", _MMDW_MigratedRowsAreDeclarative)
