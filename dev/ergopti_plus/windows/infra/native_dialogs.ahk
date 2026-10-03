; infra/native_dialogs.ahk
;
; ==============================================================================
; MODULE: Native Dialog Captions
; DESCRIPTION:
; Owns native Windows dialog captions through the shared window-title policy.
; Message bodies, options, defaults and native return values pass through intact.
; Both this owner and the generated composer consist of hoisted functions only:
; bootstrap failures can call them before their #Include lines execute, without
; requiring configuration, translations, bundle extraction or logger state.
; ==============================================================================

/**
 * Shows a native message box with an already-translated, brandless caption.
 * @param {string} Text - Native message body.
 * @param {string} Title - Brandless caption, or empty for the product alone.
 * @param {string|integer} Options - Native buttons, icon, owner and timeout.
 * @returns {string} The native selected-button name or timeout receipt.
 */
Ui_MsgBox(Text := "", Title := "", Options := "") {
	return MsgBox(Text, WindowTitle(Title), Options)
}

/**
 * Opens the native input dialog without changing cancellation or entered text.
 * @param {string} Prompt - Native prompt body.
 * @param {string} Title - Already-translated, brandless caption.
 * @param {string} Options - Native size, password and timeout options.
 * @param {string} Default - Exact initial text, including surrounding spaces.
 * @returns {object} The native Result and Value receipt.
 */
Ui_InputBox(Prompt := "", Title := "", Options := "", Default := "") {
	return InputBox(Prompt, WindowTitle(Title), Options, Default)
}

/**
 * Opens the native file picker with the shared caption and untouched selection policy.
 * The pinned native owner passes this third argument to IFileDialog.SetTitle;
 * it is window chrome rather than body text, unlike DirSelect's prompt.
 * @param {string|integer} Options - Native open/save, existence and multiselect flags.
 * @param {string} RootDir - Exact initial directory and optional default file name.
 * @param {string} Title - Already-translated, brandless caption.
 * @param {string} Filter - Native display labels and file patterns, unchanged.
 * @returns {string|Array} The native selected path, paths, or cancellation receipt.
 */
Ui_FileSelect(Options := "", RootDir := "", Title := "", Filter := "") {
	return FileSelect(Options, RootDir, WindowTitle(Title), Filter)
}

#Include %A_LineFile%\..\native_folder_picker.ahk

/**
 * Opens the native folder modal with separate caption and explanatory prompt.
 * @param {string} RootDir - Native root and initial-folder notation.
 * @param {integer} Options - Native creation, edit-box and old-dialog flags.
 * @param {string} Prompt - Original explanatory body text, preserved exactly.
 * @param {string} Title - Already-translated, brandless native caption.
 * @param {integer} OwnerHwnd - Explicit parent HWND, or zero for current callers.
 * @returns {string} Native filesystem path, or empty on cancellation.
 */
Ui_DirSelect(RootDir, Options, Prompt, Title, OwnerHwnd) {
	return _Ui_FolderSelect(RootDir, Options, Prompt, WindowTitle(Title), OwnerHwnd)
}
