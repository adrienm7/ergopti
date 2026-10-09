; tests/meta/test_llm_model_menu_no_model_row_actionable.ahk

; ==============================================================================
; MODULE: LLM Model Menu "no model" Row Guard Meta Test
; DESCRIPTION:
; Static source guard for llm-no-model-row-clobbered.
;
; LLM_Menu_BuildModelMenu registers an actionable "Aucun modele (Desactive)"
; selector as the first row of the model submenu - it is how a user clears a
; configured model. Its catalogue fallback then built a DISABLED placeholder
; from the SAME i18n key, t("menu.llm.no_model"), with a raw Menu.Add followed by
; Menu.Disable.
;
; AHK v2's Menu.Add with an already-present label modifies that item in place
; rather than appending, so the placeholder did not add a row: it overwrote the
; selector's callback with a no-op, and the Disable that followed greyed out the
; one row the user needed. Reproduced with AutoHotkey64.exe: re-adding an
; existing label leaves GetMenuItemCount unchanged and GetMenuItemInfoW then
; reports MFS_DISABLED|MFS_GRAYED on the ORIGINAL row.
;
; The branch is reachable, not theoretical: it needs the curated catalogue to
; produce nothing (models.json missing, unreadable, or advertising no Ollama
; url) AND Ollama not ready, which is exactly the state of a fresh install with
; the feature off.
;
; Nothing reports it. The in-place update is not an error, RegisterMenuItem had
; already returned success for the real row, and a degradation path's output is
; never compared against the nominal one.
;
; THE FIX (the contract this test pins): no i18n key may label two different rows
; of this menu. The redundant placeholder is gone - the selector above it already
; says "no model" and, unlike the placeholder, stays clickable.
;
; Source-level: ui/menu/menu_llm/menu_models.ahk needs the whole LLM tray module
; graph, so run_all cannot #Include it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ One i18n key labels at most one row =======
; ======================================================
; ======================================================

; Class-level: any repeated key in this builder is the same defect, whichever
; two rows collide. Pinning only "menu.llm.no_model" would let the next pair
; through.
_LMNM_NoI18nKeyLabelsTwoRows() {
	Body := _DriverFuncBody("LLM_Menu_BuildModelMenu")
	Assert(Body != "", "LLM_Menu_BuildModelMenu must be defined in menu_models.ahk")

	Counts := _LMNM_ModelCaptionCounts(Body)
	Assert(Counts.Count > 0,
		"LLM_Menu_BuildModelMenu must build its row labels from i18n keys - finding none means this "
		. "scan is looking at the wrong body and asserts nothing")
	for Key, N in Counts {
		Assert(N == 1,
			"i18n key '" . Key . "' labels " . N . " rows of the model menu. AHK v2's Menu.Add with an "
			. "existing label modifies that item IN PLACE, so the later row silently steals the "
			. "earlier one's callback - and when the later one is a disabled placeholder it greys out "
			. "the actionable row the user needs (llm-no-model-row-clobbered)")
	}
}
Test("menu_models: no i18n key labels two rows of the model menu (llm-no-model-row-clobbered)",
	_LMNM_NoI18nKeyLabelsTwoRows)





; ======================================================
; ======================================================
; ======= 2/ Both rows that mattered still exist =======
; ======================================================
; ======================================================

; Guards the lazy way out: deleting the actionable selector, or the whole
; installed-tags fallback, would also satisfy section 1.
_LMNM_SelectorAndFallbackSurvive() {
	Body := _DriverFuncBody("LLM_Menu_BuildModelMenu")
	Assert(Body != "", "LLM_Menu_BuildModelMenu must be defined in menu_models.ahk")

	Assert(InStr(Body, '_LLM_Menu_MakeSetModelHandler("")') > 0,
		"the actionable 'no model' selector must stay registered - it is the only way to clear a "
		. "configured model from the tray")
	Assert(InStr(Body, "_LLM_GetInstalledTagsCached(") > 0,
		"the installed-Ollama-tags fallback must stay - it is what gives the user a picker when the "
		. "curated catalogue produces nothing")
}
Test("menu_models: the 'no model' selector and the tag fallback both survive (llm-no-model-row-clobbered)",
	_LMNM_SelectorAndFallbackSurvive)

; Authenticate raw argument literals only at their actual executable statement.
; The canonical offset-preserving mask excludes strings, comments and continuation data.
_LMNM_ExecutableStatement(Source, Pattern, Depth) {
	Masked := _DriverMaskNonCode(&Source)
	if !RegExMatch(Source, Pattern, &Found)
		return 0
	Position := Found.Pos(1), Token := Found[1]
	if SubStr(Masked, Position, StrLen(Token)) != Token
		return 0
	Prefix := SubStr(Masked, 1, Position - 1), CurrentDepth := 0
	if RegExMatch(RTrim(Prefix, " `t`r`n"), 'i)(?:^|\n)[ \t]*(?:if|else|for|while|loop|catch|try|finally)\b[^\r\n{]*$')
		return 0
	Loop Parse Prefix {
		if A_LoopField == "{"
			CurrentDepth++
		else if A_LoopField == "}"
			CurrentDepth--
	}
	return CurrentDepth == Depth ? Position : 0
}

; Count only physical caption records selected by a consumed template include.
; A selected include is not permission to count all of its sibling records.
_LMNM_DeclaredCaptions(Section, SelectedId := "", Visiting := unset) {
	if !IsSet(Visiting)
		Visiting := Map()
	if Visiting.Has(Section)
		throw Error("A model caption include cannot be cyclic.")
	Rows := _MR_GetMenuDef(Section)
	if !Rows.Length
		throw Error("The consumed model caption declaration must exist: " . Section)
	if SelectedId != "" {
		Matches := 0
		for Row in Rows
			if Row is Map && Row.Get("id", "") == SelectedId
				Matches++
		if Matches != 1
			throw Error("A consumed model caption must select exactly one physical row.")
	}
	Visiting[Section] := true
	Captions := []
	try {
		for Row in Rows {
			if !(Row is Map)
				throw Error("A model caption declaration must be a typed record.")
			if SelectedId != "" && Row.Get("id", "") != SelectedId
				continue
			if !_MR_IsForAhk(Row)
				continue
			Kind := Row.Get("type", "")
			if Kind == "include" {
				Target := Row.Get("section", "")
				if Type(Target) != "String" || Target == ""
					throw Error("A model caption include must name its physical section.")
				for Key in _LMNM_DeclaredCaptions(Target, Row.Get("row_id", ""), Visiting)
					Captions.Push(Key)
			} else if Kind == "separator" {
				continue
			} else if Kind == "check" || Kind == "command" || Kind == "label" || Kind == "section_header" {
				Key := Row.Get("i18n", "")
				if Type(Key) != "String" || Key == ""
					throw Error("A model caption row must retain its real i18n key.")
				Captions.Push(Key)
			} else {
				throw Error("Unsupported record in the consumed model caption frame.")
			}
		}
	} finally Visiting.Delete(Section)
	return Captions
}

_LMNM_DefaultBranchContains(Body, GuardPosition, CapturePosition, JoinPosition) {
	Masked := _DriverMaskNonCode(&Body)
	Open := InStr(Masked, "{", true, GuardPosition), BranchDepth := 1
	if !Open
		return false
	Loop Parse SubStr(Masked, Open + 1) {
		if A_LoopField == "{"
			BranchDepth++
		else if A_LoopField == "}" {
			BranchDepth--
			if BranchDepth == 0
				return Open < CapturePosition && CapturePosition < JoinPosition && JoinPosition < Open + A_Index
		}
	}
	return false
}

_LMNM_ModelCaptionCounts(Body) {
	Counts := Map()
	Masked := _DriverMaskNonCode(&Body)
	; Keep native literals in this invariant: a duplicate raw Menu.Add placeholder
	; must collide with the declared selector instead of disappearing from the scan.
	Pos := 1
	while (Found := RegExMatch(Body, '\bt\("([^"]+)"\)', &M, Pos)) {
		if SubStr(Masked, Found, 2) == "t(" {
			Key := M[1]
			Counts[Key] := (Counts.Has(Key) ? Counts[Key] : 0) + 1
		}
		Pos := Found + StrLen(M[0])
	}
	Head := _LMNM_ExecutableStatement(Body,
		'm)^[ \t]*(HeadRows) := MenuRenderer_TemplateRows\("llm_model_picker_head",[ \t]*\n[ \t]*Map\("llm_model_none", _LLM_Menu_MakeSetModelHandler\(""\)\),[ \t]*\n[ \t]*Map\("model_none_selected", \(\*\) => active == "", "model_picker_ready", \(\*\) => true\), Map\(\)\)', 1)
	DefaultSeed := _LMNM_ExecutableStatement(Body,
		'm)^[ \t]*(default_name) := _LLM_DefaultFor\("llm_model", ""\)[ \t]*\n[ \t]*if \(default_name != ""\) \{[ \t]*$', 1)
	DefaultGuard := _LMNM_ExecutableStatement(Body,
		'm)^[ \t]*(if) \(default_name != ""\) \{[ \t]*$', 1)
	DefaultPosition := _LMNM_ExecutableStatement(Body,
		'm)^[ \t]*(DefaultRows) := MenuRenderer_TemplateRows\("llm_model_picker_default",[ \t]*\n[ \t]*Map\("llm_model_backend_default", _LLM_Menu_MakeSetModelHandler\(default_name\)\),[ \t]*\n[ \t]*Map\("model_backend_default_caption", \(\*\) => default_name, "model_default_selected", \(\*\) => active == default_name,[ \t]*\n[ \t]*"model_picker_ready", \(\*\) => true\), Map\(\)\)', 2)
	Join := _LMNM_ExecutableStatement(Body,
		'm)^[ \t]*(for) Row in DefaultRows[ \t]*\n[ \t]*HeadRows\.Push\(Row\)[ \t]*$', 2)
	Draw := _LMNM_ExecutableStatement(Body,
		'm)^[ \t]*(MenuRenderer_AppendRows)\(m, "llm_menu", "llm_model", HeadRows\)[ \t]*$', 1)
	if !(Head && DefaultSeed && DefaultGuard && DefaultPosition && Join && Draw
		&& Head < DefaultSeed && DefaultSeed < DefaultGuard && DefaultGuard < DefaultPosition
		&& DefaultPosition < Join && Join < Draw && _LMNM_DefaultBranchContains(Body, DefaultGuard, DefaultPosition, Join))
		return Counts
	global _LLM_Menu
	Active := _LLM_Menu["model"], DefaultName := _LLM_DefaultFor("llm_model", "")
	HeadRows := MenuRenderer_TemplateRows("llm_model_picker_head",
		Map("llm_model_none", _LLM_Menu_MakeSetModelHandler("")),
		Map("model_none_selected", (*) => Active == "", "model_picker_ready", (*) => true), Map())
	DefaultRows := MenuRenderer_TemplateRows("llm_model_picker_default",
		Map("llm_model_backend_default", _LLM_Menu_MakeSetModelHandler(DefaultName)),
		Map("model_backend_default_caption", (*) => DefaultName, "model_default_selected", (*) => Active == DefaultName,
			"model_picker_ready", (*) => true), Map())
	if !(HeadRows is Array) || !(DefaultRows is Array)
		throw Error("Consumed model caption declarations must be admitted by the genuine typed renderer.")
	for Section in ["llm_model_picker_head", "llm_model_picker_default"] {
		for Key in _LMNM_DeclaredCaptions(Section)
			Counts[Key] := (Counts.Has(Key) ? Counts[Key] : 0) + 1
	}
	return Counts
}

; These are actual-body edits, not standalone decoy call snippets.
_LMNM_DeclaredCaptionRouteControls() {
	Body := _DriverFuncBody("LLM_Menu_BuildModelMenu")
	Assert(Body != "", "the real caption consumer must be source-visible")
	Counts := _LMNM_ModelCaptionCounts(Body)
	AssertEqual(1, Counts["menu.llm.no_model"])
	AssertEqual(1, Counts["menu.llm.backend_default_model"])
	AssertEqual(0, _LMNM_ModelCaptionCounts("").Count)
	for Needle in ['HeadRows := MenuRenderer_TemplateRows', 'DefaultRows := MenuRenderer_TemplateRows',
		'default_name := _LLM_DefaultFor', 'if (default_name != "") {',
		'MenuRenderer_AppendRows(m, "llm_menu", "llm_model", HeadRows)', 'HeadRows.Push(Row)'] {
		Assert(InStr(Body, Needle) > 0, "the actual-body mutation must change its real subject")
		AssertEqual(0, _LMNM_ModelCaptionCounts(StrReplace(Body, Needle, "WithdrawnCaptionRoute")).Count,
			"a declaration disconnected from its real consumer gets no source credit")
	}
	AssertEqual(0, _LMNM_ModelCaptionCounts(StrReplace(Body, 'if (default_name != "") {', 'if (false) {')).Count,
		"an unreachable default caption branch cannot receive declared-row credit")
	ClearedDefault := StrReplace(Body, 'default_name := _LLM_DefaultFor("llm_model", "")',
		'default_name := _LLM_DefaultFor("llm_model", "")' . '`n	default_name := ""')
	AssertEqual(0, _LMNM_ModelCaptionCounts(ClearedDefault).Count,
		"interposing a native default reset cannot credit a permanently disabled caption branch")
	for Prefix in ["; ", '"'] {
		Mutant := StrReplace(Body, 'HeadRows := MenuRenderer_TemplateRows', Prefix . 'HeadRows := MenuRenderer_TemplateRows')
		AssertEqual(0, _LMNM_ModelCaptionCounts(Mutant).Count, "commented/quoted call data is not an executable caption owner")
	}
	Duplicate := Body . '`nm.Add(t("menu.llm.no_model"), (*) => 0)'
	AssertEqual(2, _LMNM_ModelCaptionCounts(Duplicate)["menu.llm.no_model"],
		"the old raw disabled-placeholder defect still violates the original N == 1 invariant")
	Root := _MM_GetManifestRoot()
	for Section in ["llm_model_picker_head", "llm_model_picker_default", "llm_model_picker_commands"] {
		Original := Root[Section]
		try {
			Root.Delete(Section)
			AssertThrows(_LMNM_ModelCaptionCounts.Bind(Body), "a withdrawn consumed caption declaration refuses source credit")
			Root[Section] := [Map("type", "check", "id", "foreign_model_caption", "i18n", "button.cancel")]
			AssertThrows(_LMNM_ModelCaptionCounts.Bind(Body), "a selected caption with no physical owner refuses source credit")
		} finally Root[Section] := Original
	}
	AssertEqual(1, _LMNM_ModelCaptionCounts(Body)["menu.llm.no_model"], "exact declaration repair restores the original collision invariant")
}
Test("menu_models: authentic template captions and native duplicate placeholders share the collision invariant",
	_LMNM_DeclaredCaptionRouteControls)

_LMNM_AddRoute(Tail) {
	Capture := _LMNM_ExecutableStatement(Tail,
		'm)^[ \t]*(AddRows) := MenuRenderer_TemplateRows\("llm_model_add_command",[ \t]*\n[ \t]*Map\("llm_add_model_entry", \(\*\) => LLM_Menu_PromptAddModel\(\)\), Map\("model_picker_ready", \(\*\) => true\), Map\(\)\)', 1)
	Join := _LMNM_ExecutableStatement(Tail,
		'm)^[ \t]*(for) Row in AddRows[ \t]*\n[ \t]*TailRows\.Push\(Row\)[ \t]*$', 1)
	ReturnPosition := _LMNM_ExecutableStatement(Tail, 'm)^[ \t]*(return) TailRows[ \t]*$', 1)
	return Capture && Join && ReturnPosition && Capture < Join && Join < ReturnPosition
}

_LMNM_GenerationRoute(Emit) {
	CasePosition := _LMNM_ExecutableStatement(Emit, 'm)^[ \t]*(case) "llm_generation_settings":[ \t]*$', 2)
	Draw := _LMNM_ExecutableStatement(Emit,
		'm)^[ \t]*(if) !MenuRenderer_AppendGroup\(_LLM_Menu_Handle, "llm_menu", "llm_generation_settings",[ \t]*\n[ \t]*Map\("llm_generation_settings", LLM_Menu_BuildGenerationMenu\), disabled\)', 2)
	NextCase := _LMNM_ExecutableStatement(Emit, 'm)^[ \t]*(case) "llm_display":[ \t]*$', 2)
	return CasePosition && Draw && NextCase && CasePosition < Draw && Draw < NextCase
}

_LMNM_NativeBindingRouteControls() {
	Tail := _DriverFuncBody("_LLM_Menu_ModelTailRows"), Emit := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Tail != "" && Emit != "", "both genuine native binding owners must exist")
	AssertTrue(_LMNM_AddRoute(Tail))
	AssertTrue(_LMNM_GenerationRoute(Emit))
	AssertFalse(_LMNM_AddRoute(""))
	AssertFalse(_LMNM_GenerationRoute(""))
	for Needle in ['AddRows := MenuRenderer_TemplateRows', '"llm_add_model_entry", (*) => LLM_Menu_PromptAddModel()',
		'TailRows.Push(Row)', 'return TailRows'] {
		Assert(InStr(Tail, Needle) > 0, "the Add mutation must alter its real native owner")
		AssertFalse(_LMNM_AddRoute(StrReplace(Tail, Needle, "WithdrawnAddRoute")))
	}
	for Needle in ['if !MenuRenderer_AppendGroup(_LLM_Menu_Handle, "llm_menu", "llm_generation_settings",',
		'Map("llm_generation_settings", LLM_Menu_BuildGenerationMenu)', 'case "llm_generation_settings":'] {
		Assert(InStr(Emit, Needle) > 0, "the generation mutation must alter its real native owner")
		AssertFalse(_LMNM_GenerationRoute(StrReplace(Emit, Needle, "WithdrawnGenerationRoute")))
	}
	for Prefix in ["; ", '"'] {
		AssertFalse(_LMNM_AddRoute(StrReplace(Tail, 'AddRows := MenuRenderer_TemplateRows', Prefix . 'AddRows := MenuRenderer_TemplateRows')))
		AssertFalse(_LMNM_GenerationRoute(StrReplace(Emit, 'if !MenuRenderer_AppendGroup', Prefix . 'if !MenuRenderer_AppendGroup')))
	}
	AssertTrue(_LMNM_AddRoute(Tail), "exact native Add repair restores source credit")
	AssertTrue(_LMNM_GenerationRoute(Emit), "exact native generation-group repair restores source credit")
}
Test("menu_llm: named Add/generation bindings are executable consumed routes, not source data", _LMNM_NativeBindingRouteControls)
