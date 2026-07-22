; tests/meta/test_download_window_i18n_fallback.ahk
#Requires AutoHotkey v2.0

Test_DownloadWindowNeverFallsBackToFrenchCancel() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := FileRead(WindowsDir . "\..\_shared\ui\download_window\script.js")
	Assert(!InStr(Src, "Annuler"),
		"download_window must not contain a hard-coded French cancel fallback")
	Assert(InStr(Src, "const cancelLabel = _t('download_window.btn_cancel')") > 0,
		"download_window cancel label must come exclusively from i18n")
	Assert(InStr(Src, "cancelBtn.style.display = 'none'") > 0,
		"a missing cancel translation must hide the unavailable action rather than show a foreign fallback")
}

Test("download window: missing cancel translation has no French fallback", Test_DownloadWindowNeverFallsBackToFrenchCancel)
