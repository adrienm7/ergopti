; tests/fixtures/menu/tray_rows_walker.ahk

; ==============================================================================
; MODULE: Tray Rows Walker
; DESCRIPTION:
; Appended to a startup wrapper by tools/test/test-ahk-tray-rows-read-as-text.cjs.
; At ready it walks the tray the real boot published, native menu by native
; menu, and writes every caption with its parent trail, for the Node side to
; judge. It reads what Windows would paint, not the rows handed to the renderer.
; ==============================================================================

_TrayRowsWalkerInspect(*) {
	global _MenuPopulationPublished
	Lines := []
	Seen := Map()
	_TrayRowsWalkerVisit(A_TrayMenu.Handle, "", Lines, Seen)
	Text := ""
	for Line in Lines
		Text .= Line . "`n"
	FileAppend(Text, EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\tray-rows.txt", "UTF-8-RAW")
}

; Completes a deferred picker the way opening it does, then reads each row.
_TrayRowsWalkerVisit(Handle, Trail, Lines, Seen) {
	if Seen.Has(Handle)
		return
	Seen[Handle] := true
	MenuPopulation_OnInitPopup(Handle)
	Count := TrayMenuHandleItemCount(Handle)
	loop Count {
		Position := A_Index - 1
		Caption := StrReplace(TrayMenuHandleItemCaption(Handle, Position), "`t", " ")
		Submenu := TrayMenuSubmenuHandle(Handle, Position)
		if (Caption != "")
			Lines.Push(Trail . "`t" . Caption)
		if Submenu
			_TrayRowsWalkerVisit(Submenu, Trail . " > " . Caption, Lines, Seen)
	}
}
