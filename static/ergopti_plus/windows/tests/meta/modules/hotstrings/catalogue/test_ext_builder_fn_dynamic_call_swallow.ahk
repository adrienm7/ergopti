; tests/meta/modules/hotstrings/catalogue/test_ext_builder_fn_dynamic_call_swallow.ahk

; ==============================================================================
; MODULE: Extension Builder Fail-Loud Meta Test
; DESCRIPTION:
; Static source guard for finding ext-builder-fn-dynamic-call-swallow.
;
; _SC_ExtensionRows() invokes each extension's BuildExtMenu_<id> via dynamic
; %BuilderFn% during menu build. The old code caught a thrown builder with a
; LoggerWarn only, so a broken extension produced a present-but-empty submenu
; indistinguishable from an absent one -- the only trace was a WARNING line the
; user never reads. That violates the project's fail-loud convention for
; user-actionable surfaces.
;
; The fix: on catch, log an ERROR (not a Warn) and add a visible disabled error
; row to the extension submenu; additionally, after a non-throwing call, count
; the items the builder actually added (via _ExtMenuItemCount) and show the same
; marker when it populated nothing. This test receives the caller, observer and declared construction owner as
; one physical control-flow closure; refactoring cannot detach their proof.
;
; Meta-static because ui/tray_menu.ahk registers top-level menu hooks and is not
; part of the headless run_all include graph; it cannot be #Included by the
; runner without side effects.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================




; ==================================================
; ==================================================
; ======= 2/ Fail-loud guard assertions ============
; ==================================================
; ==================================================

; Match a physical executable line, retaining literal identity but rejecting
; quoted/comment copies and foreign receiver prefixes via the canonical mask.
_EBFD_CodeLinePosition(Seg, Text) {
	Code := _DriverMaskNonCode(&Seg)
	Expected := _DriverMaskNonCode(&Text)
	Pos := 1
	while Pos := InStr(Seg, Text, true, Pos) {
		LineStart := InStr(SubStr(Seg, 1, Pos - 1), "`n", true, -1) + 1
		Prefix := SubStr(Seg, LineStart, Pos - LineStart)
		if RegExMatch(Prefix, "^[ `t]*$") && SubStr(Code, Pos, StrLen(Text)) == Expected
			return Pos
		Pos += StrLen(Text)
	}
	return 0
}

_EBFD_HasCodeLine(Seg, Text) {
	return _EBFD_CodeLinePosition(Seg, Text) > 0
}

; Receive the physical caller, observation port and construction owner together.
; A marker token in a detached helper cannot prove the native handoff.
_EBFD_SourceClosure() {
	Parts := []
	for Name in ["_SC_ExtensionRows", "_SC_ObserveExtensionMenu", "MenuRenderer_ConstructObservedMenu"] {
		Part := _DriverFuncBody(Name)
		Assert(Part != "", Name . " must exist in the physical extension construction closure")
		Parts.Push(Part)
	}
	return Parts[1] . "`n" . Parts[2] . "`n" . Parts[3]
}

; The real owner supplies observed facts; shared includes select its native marker.
_EBFD_ErrorFramePublication(Seg) {
	return _EBFD_ActiveBuilderErrorBranch(Seg)
		&& _EBFD_HasCodeLine(Seg, 'ConstructorOwner := MenuRenderer_ConstructObservedMenu, ObserverOwner := _SC_ObserveExtensionMenu')
		&& _EBFD_HasCodeLine(Seg, 'ExtMenu := ConstructorOwner.Call("shortcut_extension_construction_ahk", ExtId, ExtName, ObserverOwner, OwnedMenus)')
		&& _EBFD_HasCodeLine(Seg, 'static NativeObserver := _SC_ObserveExtensionMenu')
		&& _EBFD_HasCodeLine(Seg, 'static Admission := _MR_AppendTemplateRowsAdmitted, Append := MenuRenderer_AppendTemplate')
		&& _EBFD_HasCodeLine(Seg, 'BuilderFn := "BuildExtMenu_" . StrReplace(ExtId, "-", "_")')
		&& _EBFD_HasCodeLine(Seg, 'MarkerOutcome := "populated"')
		&& _EBFD_HasCodeLine(Seg, 'State := Map("shortcut_extension_name", (*) => ExtId,')
		&& _EBFD_HasCodeLine(Seg, '"shortcut_extension_builder_failed", (*) => Observed == "failed",')
		&& _EBFD_HasCodeLine(Seg, '"shortcut_extension_builder_empty", (*) => Observed == "empty",')
		&& _EBFD_HasCodeLine(Seg, '"shortcut_extension_builder_missing", (*) => Observed == "missing")')
		&& _EBFD_HasCodeLine(Seg, 'ErrorRows := TemplateOwner.Call("shortcut_extension_error_frame", Map(), State, Map())')
		&& _EBFD_HasCodeLine(Seg, 'MarkerOutcome := BuildFailed ? "failed" : "empty"')
		&& _EBFD_HasCodeLine(Seg, 'MarkerOutcome := "missing"')
		&& _EBFD_HasCodeLine(Seg, 'if Eligible.Has(Observed) {')
		&& _EBFD_HasCodeLine(Seg, "if (BuildFailed or _ExtMenuItemCount(ExtMenu) == 0) {")
		&& _EBFD_HasCodeLine(Seg, 'if Append.Call(Native, Recipe["result_frame"], Map(), State, Map()) == 0')
}

; Conservative physical receipt of the genuine published native provider.
; Keep line and identifier boundaries: dormant ancestors, extra guards and
; merged identifiers cannot impersonate the supported error publication route.
_EBFD_ActiveBuilderErrorBranch(Seg) {
	Code := _DriverMaskNonCode(&Seg)
	Actual := []
	for Line in StrSplit(Code, "`n", "`r") {
		Line := RegExReplace(Trim(Line, " `t"), "[ `t]+", " ")
		if Line != ""
			Actual.Push(Line)
	}
	Expected := ['_SC_ExtensionRows() {',
		'global _ExtensionsDir',
		'ExtShortcutsBaseDir := _ExtensionsDir .',
		'HasExtShortcuts := false',
		'if DirExist(ExtShortcutsBaseDir) {',
		'Loop Files ExtShortcutsBaseDir . , {',
		'MenuAhkPath := A_LoopFileFullPath .',
		'if FileExist(MenuAhkPath) {',
		'HasExtShortcuts := true',
		'break',
		'}',
		'}',
		'}',
		'Rows := []',
		'if !HasExtShortcuts {',
		'return Rows',
		'}',
		'BoundaryRows := MenuRenderer_TemplateRows( , Map(), Map(), Map())',
		'if !(BoundaryRows is Array)',
		'return []',
		'for Row in BoundaryRows',
		'Rows.Push(Row)',
		'OwnedMenus := [], Completed := false',
		'try {',
		'Loop Files ExtShortcutsBaseDir . , {',
		'ExtId := A_LoopFileName',
		'ExtDir := A_LoopFileFullPath',
		'MenuAhkPath := ExtDir .',
		'if !FileExist(MenuAhkPath)',
		'continue',
		'ExtName := ExtId',
		'ManifestPath := ExtDir .',
		'if FileExist(ManifestPath) {',
		'try {',
		'MC := FileRead(ManifestPath, )',
		'if RegExMatch(MC, , &NM)',
		'ExtName := NM[1]',
		'}',
		'}',
		'ConstructorOwner := MenuRenderer_ConstructObservedMenu, ObserverOwner := _SC_ObserveExtensionMenu',
		'if !(ConstructorOwner is Func) || !(ObserverOwner is Func)',
		'|| Object.Prototype.HasOwnProp.Call(ConstructorOwner, )',
		'|| Object.Prototype.HasOwnProp.Call(ObserverOwner, )',
		'return []',
		'ExtMenu := ConstructorOwner.Call( , ExtId, ExtName, ObserverOwner, OwnedMenus)',
		'if !(ExtMenu is Menu)',
		'return []',
		'Rows.Push(Map( , ExtName, , ExtMenu))',
		'}',
		'Completed := true',
		'} finally {',
		'if !Completed',
		'_SC_ExtensionDisposeOwnedMenus(OwnedMenus)',
		'}',
		'return Rows',
		'}',
		'_SC_ObserveExtensionMenu(ExtId, ExtName, ExtMenu) {',
		'MarkerOutcome :=',
		'BuilderFn := . StrReplace(ExtId, , )',
		'if IsSet(%BuilderFn%) and HasMethod(%BuilderFn%) {',
		'BuildFailed := false',
		'try {',
		'%BuilderFn%(ExtMenu, ExtName)',
		'} catch as Err {',
		'LoggerError( , , ExtId, Err.Message)',
		'BuildFailed := true',
		'}',
		'if (BuildFailed or _ExtMenuItemCount(ExtMenu) == 0) {',
		'if !BuildFailed',
		'LoggerError( , , ExtId)',
		'MarkerOutcome := BuildFailed ? :',
		'}',
		'} else {',
		'LoggerWarn( , , StrReplace(ExtId, , ))',
		'MarkerOutcome :=',
		'}',
		'return MarkerOutcome',
		'}',
		'MenuRenderer_ConstructObservedMenu(RecipeKey, ExtId, ExtName, ObserveNative, OwnedMenus) {',
		'static Entry := MenuRenderer_ConstructObservedMenu, Guard := _MR_DeclaredParentCallable',
		'static RootReader := _MR_GetManifestRoot, Loader := _MM_GetManifestRoot, Snapshot := _MR_ReasonedGroupSnapshot',
		'static SourceCurrent := _MR_ReasonedGroupCurrent, TemplateOwner := MenuRenderer_TemplateRows',
		'static Admission := _MR_AppendTemplateRowsAdmitted, Append := MenuRenderer_AppendTemplate',
		'static Constructor := Menu, ConstructorOwner := _MR_FrameNativeConstructorCurrent',
		'static NativeObserver := _SC_ObserveExtensionMenu',
		'if RecipeKey != || !(OwnedMenus is Array)',
		'|| ObserveNative != NativeObserver || NativeObserver != _SC_ObserveExtensionMenu',
		'|| Object.Prototype.HasOwnProp.Call(Guard, ) || !_MR_DeclaredParentCallable(ObserveNative)',
		'return false',
		'OwnersLive() {',
		'if Guard != _MR_DeclaredParentCallable || Object.Prototype.HasOwnProp.Call(Guard, )',
		'return false',
		'for Pair in [[Entry, MenuRenderer_ConstructObservedMenu], [RootReader, _MR_GetManifestRoot], [Loader, _MM_GetManifestRoot],',
		'[Snapshot, _MR_ReasonedGroupSnapshot], [SourceCurrent, _MR_ReasonedGroupCurrent],',
		'[ConstructorOwner, _MR_FrameNativeConstructorCurrent]]',
		'if Pair[1] != Pair[2] || !Guard.Call(Pair[1])',
		'return false',
		'return ObserveNative == NativeObserver && NativeObserver == _SC_ObserveExtensionMenu && Guard.Call(ObserveNative)',
		'}',
		'if !OwnersLive()',
		'return false',
		'Root := RootReader.Call()',
		'if !(Root is Map) || ObjGetBase(Root) != Map.Prototype',
		'return false',
		'for Name in ObjOwnProps(Root)',
		'return false',
		'if !Root.Has(RecipeKey)',
		'return false',
		'Recipe := Root[RecipeKey]',
		'if !(Recipe is Map) || ObjGetBase(Recipe) != Map.Prototype',
		'return false',
		'for Name in ObjOwnProps(Recipe)',
		'return false',
		'if Recipe.Count != 5 || Recipe.Get( , ) !=',
		'|| Recipe.Get( , ) != || !(Recipe.Get( , false) is Array)',
		'|| Type(Recipe.Get( , false)) != || Recipe[ ] ==',
		'|| !(Recipe.Get( , false) is Array)',
		'return false',
		'Program := Recipe[ ], Outcomes := Recipe[ ]',
		'if ObjGetBase(Program) != Array.Prototype || ObjGetBase(Outcomes) != Array.Prototype',
		'|| ObjGetBase(OwnedMenus) != Array.Prototype',
		'return false',
		'for Container in [Program, Outcomes, OwnedMenus]',
		'for Name in ObjOwnProps(Container)',
		'return false',
		'if Program.Length != 4',
		'return false',
		'Fields := Map( , true, , true, , true, , true, , true)',
		'for Field in Recipe',
		'if !Fields.Has(Field)',
		'return false',
		'Steps := Map( , true, , true, , true, , true)',
		'Results := Map( , true, , true, , true, , true)',
		'Positions := Map()',
		'for Index, Step in Program {',
		'if Type(Step) != || !Steps.Has(Step) || Positions.Has(Step)',
		'return false',
		'Positions[Step] := Index',
		'}',
		'if Positions.Count != 4 || Positions[ ] > Positions[ ]',
		'|| Positions[ ] > Positions[ ]',
		'|| Positions[ ] > Positions[ ]',
		'return false',
		'Eligible := Map()',
		'for Outcome in Outcomes {',
		'if Type(Outcome) != || !Results.Has(Outcome) || Outcome == || Eligible.Has(Outcome)',
		'return false',
		'Eligible[Outcome] := true',
		'}',
		'RecipeSource := Snapshot.Call(Recipe)',
		'if !RecipeSource || !OwnersLive()',
		'return false',
		'Current() {',
		'if !OwnersLive() || RootReader.Call() != Root || ObjGetBase(Root) != Map.Prototype',
		'return false',
		'for Name in ObjOwnProps(Root)',
		'return false',
		'return Root.Has(RecipeKey) && Root[RecipeKey] == Recipe && SourceCurrent.Call(RecipeSource)',
		'}',
		'Observed := , Native := false',
		'State := Map( , (*) => ExtId,',
		', (*) => Observed == ,',
		', (*) => Observed == ,',
		', (*) => Observed == )',
		'for Step in Program {',
		'if !Current()',
		'throw Error( )',
		'switch Step {',
		'case :',
		'if TemplateOwner != MenuRenderer_TemplateRows || Admission != _MR_AppendTemplateRowsAdmitted',
		'|| !Guard.Call(TemplateOwner) || !Guard.Call(Admission)',
		'return false',
		'ErrorRows := TemplateOwner.Call( , Map(), State, Map())',
		'if !Current() || !Guard.Call(TemplateOwner) || !Guard.Call(Admission)',
		'return false',
		'EmptyRows := TemplateOwner.Call( , Map(), Map(), Map())',
		'if !Current() || TemplateOwner != MenuRenderer_TemplateRows || Admission != _MR_AppendTemplateRowsAdmitted',
		'|| !Guard.Call(TemplateOwner) || !Guard.Call(Admission)',
		'return false',
		'if !(ErrorRows is Array) || ErrorRows.Length == 0 || !Admission.Call(ErrorRows, 1, Map())',
		'|| !(EmptyRows is Array) || EmptyRows.Length == 0 || !Admission.Call(EmptyRows, 1, Map())',
		'return false',
		'if !Current() || TemplateOwner != MenuRenderer_TemplateRows || !Guard.Call(TemplateOwner)',
		'return false',
		'ResultRows := TemplateOwner.Call(Recipe[ ], Map(), State, Map())',
		'if !(ResultRows is Array) || ResultRows.Length != 0 || !Current()',
		'return false',
		'case :',
		'if !ConstructorOwner.Call(Constructor)',
		'return false',
		'Native := Constructor.Call()',
		'OwnedMenus.Push(Native)',
		'case :',
		'Observed := ObserveNative.Call(ExtId, ExtName, Native)',
		'if Type(Observed) != || !Results.Has(Observed)',
		'throw Error( )',
		'case :',
		'if Eligible.Has(Observed) {',
		'if Append != MenuRenderer_AppendTemplate || !Guard.Call(Append)',
		'throw Error( )',
		'if Append.Call(Native, Recipe[ ], Map(), State, Map()) == 0',
		'throw Error(Observed ==',
		'?',
		': )',
		'}',
		'}',
		'}',
		'return Native',
		'}']
	if Actual.Length != Expected.Length
		return false
	for Index, Line in Expected
		if Actual[Index] != Line
			return false
	return true
}

_EBFD_CatchFailsLoud() {
	Seg := _EBFD_SourceClosure()
	Assert(Seg != "", "_SC_ExtensionRows declaration must exist in the driver source")
	; The thrown-builder branch must log an ERROR, not merely a Warn the user
	; never reads.
	Assert(InStr(Seg, "LoggerError(" . Chr(34) . "Extensions") > 0,
		"_SC_ExtensionRows must LoggerError (not just Warn) when a BuildExtMenu_<id> throws -- a broken extension is user-actionable")
}
Test("tray_menu: extension builder failure logs an ERROR (ext-builder-fn-dynamic-call-swallow)", _EBFD_CatchFailsLoud)

_EBFD_RendersVisibleErrorRow() {
	Seg := _EBFD_SourceClosure()
	Assert(Seg != "", "_SC_ExtensionRows declaration must exist in the driver source")
	; A failed/empty builder must produce a visible disabled marker built from a
	; localised error prefix plus the ExtId, so it is not mistaken for an absent
	; extension.
	Assert(_EBFD_ErrorFramePublication(Seg),
		"_SC_ExtensionRows must add a visible disabled error row (localised common.error_prefix + ExtId) when an extension builder fails or adds nothing")
}
Test("tray_menu: extension builder failure shows a visible disabled row (ext-builder-fn-dynamic-call-swallow)", _EBFD_RendersVisibleErrorRow)

_EBFD_ValidatesItemsPopulated() {
	Src := _DriverSourceConcat()
	Seg := _EBFD_SourceClosure()
	Assert(Seg != "", "_SC_ExtensionRows declaration must exist in the driver source")
	; A builder may return without throwing yet populate nothing; the fix counts
	; the items added and treats zero as a failure.
	Assert(InStr(Seg, "_ExtMenuItemCount(") > 0,
		"_SC_ExtensionRows must validate the builder populated at least one item (via _ExtMenuItemCount) so a silently-empty submenu also surfaces the error marker")
	; And the counting helper itself must exist.
	Assert(InStr(Src, "_ExtMenuItemCount(MenuObj) {") > 0,
		"the driver source must define the _ExtMenuItemCount helper used to detect an empty extension submenu")
}
Test("tray_menu: extension builder result is validated for emptiness (ext-builder-fn-dynamic-call-swallow)", _EBFD_ValidatesItemsPopulated)


; The physical declaration supplies the original disabled prefix+ExtId marker.
; This calls the genuine renderer and callback, without allocating any Menu.
_EBFD_DeclaredErrorMarker() {
	ExtId := "fixture-extension", Calls := 0
	Rows := MenuRenderer_TemplateRows("shortcut_extension_error_frame", Map(),
		Map("shortcut_extension_name", (*) => (Calls += 1, ExtId)), Map())
	Assert(Rows is Array, "the genuine shared error declaration must be admitted")
	AssertEqual(1, Rows.Length, "exactly the Windows marker is projected")
	AssertEqual(t("common.error_prefix") . ExtId, Rows[1]["label"])
	AssertEqual(true, Rows[1]["disabled"])
	AssertFalse(Rows[1].Has("action"), "an error marker must remain inert")
	AssertEqual(1, Calls, "the genuine native extension identity getter is evaluated once")
}
Test("tray_menu: declared extension error marker preserves caption and inertness", _EBFD_DeclaredErrorMarker)

_EBFD_ErrorPublicationSourceControls() {
	Seg := _EBFD_SourceClosure()
	AssertTrue(_EBFD_ErrorFramePublication(Seg))
	Call := 'if Append.Call(Native, Recipe["result_frame"], Map(), State, Map()) == 0'
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, Call, "; " . Call)),
		"a commented publication cannot keep the error marker guard green")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, Call, 'Text := ' . Chr(34) . Call . Chr(34))),
		"quoted publication text is not a renderer call")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, "Append.Call(Native", "Foreign.Append.Call(Native")),
		"a foreign renderer cannot publish the native owner marker")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, '"shortcut_extension_error_frame"', '"shortcut_extension_empty_frame"')),
		"the empty marker cannot substitute for the failure marker")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, "(*) => ExtId", "(*) => ExtName")),
		"the genuine failure marker retains the original extension identity")
}
Test("tray_menu: error marker guard rejects withdrawn and decorative source calls", _EBFD_ErrorPublicationSourceControls)


_EBFD_DormantErrorBranchRefused() {
	Seg := _EBFD_SourceClosure()
	Branch := "if (BuildFailed or _ExtMenuItemCount(ExtMenu) == 0) {"
	Code := _DriverMaskNonCode(&Seg)
	Start := InStr(Seg, Branch, true), Open := Start + StrLen(Branch) - 1
	Depth := 0, Close := 0
	Loop StrLen(Code) - Open + 1 {
		At := Open + A_Index - 1
		if SubStr(Code, At, 1) == "{"
			Depth += 1
		else if SubStr(Code, At, 1) == "}" {
			Depth -= 1
			if Depth == 0 {
				Close := At
				break
			}
		}
	}
	Assert(Start > 0 && Close > Open, "the genuine complete native failure branch must exist")
	Dormant := SubStr(Seg, 1, Start - 1) . "if (false) {`n"
		. SubStr(Seg, Start, Close - Start + 1) . "`n}" . SubStr(Seg, Close + 1)
	AssertFalse(_EBFD_ErrorFramePublication(Dormant), "a balanced dormant wrapper must not prove actual error publication")
	Guarded := StrReplace(Seg, Branch, "if false`n" . Branch)
	AssertFalse(_EBFD_ErrorFramePublication(Guarded), "a disabled single-statement guard must also refuse")
	Header := "if IsSet(%BuilderFn%) and HasMethod(%BuilderFn%) {"
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, Header, "if false`n" . Header)),
		"a disabled guard before the native builder branch cannot publish the marker")
	AssertTrue(_EBFD_ErrorFramePublication(Seg), "the original authentic builder branch repairs admission")
}
Test("tray_menu: dormant native error branches cannot satisfy the publication proof", _EBFD_DormantErrorBranchRefused)


_EBFD_StatementAndOwnerBoundaries() {
	Seg := _EBFD_SourceClosure()
	JoinedNeedle := "if !BuildFailed`n`t`t`t`tLoggerError("
	Assert(InStr(Seg, JoinedNeedle, true) > 0, "the original distinct condition and logger statements must exist before withdrawal")
	Joined := StrReplace(Seg, JoinedNeedle, "if !BuildFailedLoggerError(")
	AssertFalse(_EBFD_ErrorFramePublication(Joined), "joining a distinct native condition and logger statement must refuse")
	LoopLine := 'Loop Files ExtShortcutsBaseDir . "*", "D" {'
	DormantOwner := StrReplace(Seg, LoopLine, "if false {")
	AssertFalse(_EBFD_ErrorFramePublication(DormantOwner), "a dormant same-depth ancestor cannot substitute for the native directory loop")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, '"BuildExtMenu_"', '"ForeignExtMenu_"')),
		"a foreign dynamic builder namespace cannot substitute for the native extension callback")
	AssertTrue(_EBFD_ErrorFramePublication(Seg), "genuine original physical statement boundaries restore admission")
}
Test("tray_menu: error publication retains native statement and loop boundaries", _EBFD_StatementAndOwnerBoundaries)

; Removing any actual handoff must fail even when the detached observer still logs.
_EBFD_ConstructionCustodyControls() {
	Seg := _EBFD_SourceClosure()
	for Call in [
		'ConstructorOwner := MenuRenderer_ConstructObservedMenu, ObserverOwner := _SC_ObserveExtensionMenu',
		'ExtMenu := ConstructorOwner.Call("shortcut_extension_construction_ahk", ExtId, ExtName, ObserverOwner, OwnedMenus)',
		'static NativeObserver := _SC_ObserveExtensionMenu',
		'static Admission := _MR_AppendTemplateRowsAdmitted, Append := MenuRenderer_AppendTemplate',
		'Observed := ObserveNative.Call(ExtId, ExtName, Native)'] {
		Assert(_EBFD_HasCodeLine(Seg, Call), "each original handoff is physically present before withdrawal")
		AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, Call, "; " . Call)),
			"a detached construction owner cannot publish the actual extension marker")
	}
	AssertTrue(_EBFD_ErrorFramePublication(Seg), "restoring all three physical owners repairs admission")
}
Test("tray_menu: extension construction custody cannot detach native error publication", _EBFD_ConstructionCustodyControls)
