; tests/meta/test_ext_builder_fn_dynamic_call_swallow.ahk

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
; marker when it populated nothing. This test asserts those guards are present.
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

; The real failure branch appends the declared marker to its native ExtMenu.
_EBFD_ErrorFramePublication(Seg) {
	return _EBFD_ActiveBuilderErrorBranch(Seg)
		&& _EBFD_HasCodeLine(Seg, 'BuilderFn := "BuildExtMenu_" . StrReplace(ExtId, "-", "_")')
		&& _EBFD_HasCodeLine(Seg, 'MarkerState := Map("shortcut_extension_name", (*) => ExtId)')
		&& _EBFD_HasCodeLine(Seg, "if (BuildFailed or _ExtMenuItemCount(ExtMenu) == 0) {")
		&& _EBFD_HasCodeLine(Seg, 'if MenuRenderer_AppendTemplate(ExtMenu, "shortcut_extension_error_frame", Map(), MarkerState, Map()) == 0')
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
		'MarkerState := Map( , (*) => ExtId)',
		'ErrorRows := MenuRenderer_TemplateRows( , Map(), MarkerState, Map())',
		'EmptyRows := MenuRenderer_TemplateRows( , Map(), Map(), Map())',
		'if !(ErrorRows is Array) || ErrorRows.Length == 0',
		'|| !_MR_AppendTemplateRowsAdmitted(ErrorRows, 1, Map())',
		'|| !(EmptyRows is Array) || EmptyRows.Length == 0',
		'|| !_MR_AppendTemplateRowsAdmitted(EmptyRows, 1, Map())',
		'return []',
		'ExtMenu := Menu()',
		'OwnedMenus.Push(ExtMenu)',
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
		'if MenuRenderer_AppendTemplate(ExtMenu, , Map(), MarkerState, Map()) == 0',
		'throw Error( )',
		'}',
		'} else {',
		'LoggerWarn( , , StrReplace(ExtId, , ))',
		'if MenuRenderer_AppendTemplate(ExtMenu, , Map(), Map(), Map()) == 0',
		'throw Error( )',
		'}',
		'Rows.Push(Map( , ExtName, , ExtMenu))',
		'}',
		'Completed := true',
		'} finally {',
		'if !Completed',
		'_SC_ExtensionDisposeOwnedMenus(OwnedMenus)',
		'}',
		'return Rows',
		'}']
	if Actual.Length != Expected.Length
		return false
	for Index, Line in Expected
		if Actual[Index] != Line
			return false
	return true
}

_EBFD_CatchFailsLoud() {
	Seg := _DriverFuncBody("_SC_ExtensionRows")
	Assert(Seg != "", "_SC_ExtensionRows declaration must exist in the driver source")
	; The thrown-builder branch must log an ERROR, not merely a Warn the user
	; never reads.
	Assert(InStr(Seg, "LoggerError(" . Chr(34) . "Extensions") > 0,
		"_SC_ExtensionRows must LoggerError (not just Warn) when a BuildExtMenu_<id> throws -- a broken extension is user-actionable")
}
Test("tray_menu: extension builder failure logs an ERROR (ext-builder-fn-dynamic-call-swallow)", _EBFD_CatchFailsLoud)

_EBFD_RendersVisibleErrorRow() {
	Seg := _DriverFuncBody("_SC_ExtensionRows")
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
	Seg := _DriverFuncBody("_SC_ExtensionRows")
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
	Seg := _DriverFuncBody("_SC_ExtensionRows")
	AssertTrue(_EBFD_ErrorFramePublication(Seg))
	Call := 'if MenuRenderer_AppendTemplate(ExtMenu, "shortcut_extension_error_frame", Map(), MarkerState, Map()) == 0'
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, Call, "; " . Call)),
		"a commented publication cannot keep the error marker guard green")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, Call, 'Text := ' . Chr(34) . Call . Chr(34))),
		"quoted publication text is not a renderer call")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, "MenuRenderer_AppendTemplate(ExtMenu", "Foreign.MenuRenderer_AppendTemplate(ExtMenu")),
		"a foreign renderer cannot publish the native owner marker")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, '"shortcut_extension_error_frame"', '"shortcut_extension_empty_frame"')),
		"the empty marker cannot substitute for the failure marker")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, "(*) => ExtId", "(*) => ExtName")),
		"the genuine failure marker retains the original extension identity")
}
Test("tray_menu: error marker guard rejects withdrawn and decorative source calls", _EBFD_ErrorPublicationSourceControls)


_EBFD_DormantErrorBranchRefused() {
	Seg := _DriverFuncBody("_SC_ExtensionRows")
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
	Seg := _DriverFuncBody("_SC_ExtensionRows")
	Joined := StrReplace(Seg, "if !BuildFailed`n`t`t`t`t`t`tLoggerError(", "if !BuildFailedLoggerError(")
	AssertFalse(_EBFD_ErrorFramePublication(Joined), "joining a distinct native condition and logger statement must refuse")
	LoopLine := 'Loop Files ExtShortcutsBaseDir . "*", "D" {'
	DormantOwner := StrReplace(Seg, LoopLine, "if false {")
	AssertFalse(_EBFD_ErrorFramePublication(DormantOwner), "a dormant same-depth ancestor cannot substitute for the native directory loop")
	AssertFalse(_EBFD_ErrorFramePublication(StrReplace(Seg, '"BuildExtMenu_"', '"ForeignExtMenu_"')),
		"a foreign dynamic builder namespace cannot substitute for the native extension callback")
	AssertTrue(_EBFD_ErrorFramePublication(Seg), "genuine original physical statement boundaries restore admission")
}
Test("tray_menu: error publication retains native statement and loop boundaries", _EBFD_StatementAndOwnerBoundaries)
