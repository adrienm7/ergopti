; tests/meta/test_app_picker_sort_safe_selection.ahk

; ==============================================================================
; MODULE: App Picker Sort-Safe Selection Meta Test
; DESCRIPTION:
; Static source guard for the app-picker-listview-sort-index finding.
;
; AppPicker_OnOK collected the ticked applications by indexing the
; construction-time `rows` array with the ListView DISPLAY row number
; (`rows[row_idx].process`). An AHK v2 ListView created without the `NoSort`
; option sorts its items in place the moment the user clicks a column header,
; and the checkbox state travels with the item while `rows` keeps its original
; order. After one header click the picker therefore saved a DIFFERENT
; application than the one the user ticked, and it did so silently: the display
; index always stays within 1..rows.Length, so nothing ever threw and neither
; consumer (metrics exclusions, LLM exclusions) validates the array it is
; handed. The user only sees metrics quietly stop working in an app they never
; excluded.
;
; The fix reads the process name back OUT of the control (column 2), which is
; the only object the sort reorders. This guard pins both halves so the parallel
; index cannot be reintroduced.
;
; Meta-static rather than behavioural: app_picker.ahk builds a Gui, so the
; headless harness cannot instantiate the control. The source-level guarantee
; (no display-index-into-model lookup) is what we pin, via the move-resilient
; _DriverFuncBody helper so the file can be relocated freely.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Sort-safe selection assertion =======
; ================================================
; ================================================

_APSS_SelectionReadsTheControl() {
	Body := _DriverFuncBody("AppPicker_OnOK")
	Assert(Body != "", "AppPicker_OnOK() must exist in the driver source")

	Assert(InStr(Body, "lv.GetNext(") > 0,
		"prerequisite: AppPicker_OnOK still enumerates the ticked rows with lv.GetNext(), whose return value is a DISPLAY row number")

	Assert(RegExMatch(Body, "rows\s*\[") == 0,
		"AppPicker_OnOK must not index the construction-time rows array with a ListView row number: an AHK v2 ListView without NoSort reorders its items on a column-header click, so the display index stops matching the model and the picker saves an application the user never ticked (app-picker-listview-sort-index)")

	Assert(InStr(Body, "lv.GetText(") > 0,
		"AppPicker_OnOK must read the process name out of the ListView itself (column 2) " . Chr(0x2014) . " the control is the only object the header-click sort reorders, so it is the only object allowed to answer 'which app is on row N'")
}
Test("app_picker: OK reads the process name from the control, not a display-indexed model (app-picker-listview-sort-index)", _APSS_SelectionReadsTheControl)
