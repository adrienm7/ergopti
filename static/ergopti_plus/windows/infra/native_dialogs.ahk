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
