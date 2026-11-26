; core/ui/engine/font_scale.ahk

; ==============================================================================
; MODULE: Native Window Font Scale
; DESCRIPTION:
; The one place a native window of the driver turns a font size into the size
; it asks Windows for: « Make text bigger » (Settings > Accessibility > Text
; size) applies to the system fonts, never to a font a window requests by
; size, so every explicit « sN » goes through Gui_SetFont.
;
; FEATURES & RATIONALE:
; 1. Pure on purpose: Gui_FontOptions takes the scale as an argument, so a
;    test pins the arithmetic without changing the user's setting.
; 2. Read at window creation: a window opened after the setting changes
;    follows it; one already open keeps its layout until it is reopened.
; 3. Each window file that sets a font includes this file, which includes
;    platform/system/accessibility.ahk: the driver, the bundled apps' own
;    process and a test child that loads one window file all get both.
; ==============================================================================

#Requires AutoHotkey v2.0+
#Include %A_LineFile%\..\..\..\..\platform\system\accessibility.ahk

/**
 * Scales every point size of a SetFont option string by the « Make text
 * bigger » scale (Settings > Accessibility > Text size). Windows does not
 * apply that scale to a font a window asks for by size, so a fixed « s10 »
 * stayed 10 pt at 200 %. The screen DPI needs nothing here: AutoHotkey turns
 * points into pixels with the screen's DPI already.
 * @param {string} Options - SetFont options, such as "s10 bold cFFFFFF".
 * @param {Integer} TextScalePercent - 100 to 225; read from the system when omitted.
 * @returns {string} The options with each « sN » scaled and rounded.
 */
Gui_FontOptions(Options, TextScalePercent := unset) {
	Scale := IsSet(TextScalePercent) ? TextScalePercent : A11ySystem_TextScalePercent()
	if !(Scale is Integer) || Scale < 100
		throw ValueError("Gui_FontOptions: the text scale is a percentage of at least 100", -1, Scale)
	Result := "", Pos := 1
	while RegExMatch(Options, "i)(?:^|\s)s(\d+(?:\.\d+)?)(?=\s|$)", &Size, Pos) {
		Result .= SubStr(Options, Pos, Size.Pos[1] - Pos) . Max(1, Round(Size[1] * Scale / 100))
		Pos := Size.Pos[1] + Size.Len[1]
	}
	return Result . SubStr(Options, Pos)
}

/**
 * Sets a native window's or control's font at a size that follows the
 * system text scale. Every native window of the driver sets its font sizes
 * through here; the tooltips scale theirs through the style globals of
 * core/ui/engine/style.ahk and the WPM pill keeps the canon's fixed geometry.
 * @param {Gui|Gui.Control} Target - The window or the control.
 * @param {string} Options - SetFont options; sizes are in points at 100 %.
 * @param {string} FontName - Optional font face.
 */
Gui_SetFont(Target, Options, FontName := "") {
	Scaled := Gui_FontOptions(Options)
	if (FontName == "")
		Target.SetFont(Scaled)
	else
		Target.SetFont(Scaled, FontName)
}
