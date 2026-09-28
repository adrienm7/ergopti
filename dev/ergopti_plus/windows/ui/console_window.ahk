; ui/console_window.ahk

; ==============================================================================
; MODULE: Native Debug Console Window
; DESCRIPTION:
; Opens either debug view with the shared minimum geometry. Already-large
; windows keep their placement, and growing one dimension never shrinks another.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../adapters/console_window.ahk

; Reads the shared native-window geometry; missing or invalid data is an error.
; @returns {Map} Validated width and height ratios.
ConsoleWindow_ReadRatios() {
	global _SharedDir
	Data := JsonParse(FileRead(_SharedDir . "\ui\apps.manifest.json", "UTF-8"))
	Ratios := Data["native_windows"]["console"]
	for Name in ["width_ratio", "height_ratio"] {
		Value := Ratios[Name]
		if !(Value is Number) || Value <= 0 || Value > 1
			throw ValueError("Invalid console " . Name . ".")
	}
	return Ratios
}

; Opens, sizes and activates the script's own debug window.
; @param {String} Kind The list_vars or key_history view.
; @param {Object} Native Native boundary, replaceable by behavioral tests.
; @returns {Boolean} True only after every requested native operation succeeded.
ConsoleWindow_Open(Kind, Native := ConsoleWindowNative) {
	try {
		if (Kind != "list_vars" && Kind != "key_history")
			throw ValueError("Unknown console view '" . Kind . "'.")
		Ratios := ConsoleWindow_ReadRatios()
		if Native.Open(Kind) != true
			throw Error("Console opening was refused.")
		Current := Native.Frame(A_ScriptHwnd)
		Bounds := Native.Screen()
		Width := Max(Current.w, Round(Bounds.w * Ratios["width_ratio"]))
		Height := Max(Current.h, Round(Bounds.h * Ratios["height_ratio"]))
		if (Width != Current.w || Height != Current.h) {
			Rect := {x: Round(Bounds.x + (Bounds.w - Width) / 2),
				y: Round(Bounds.y + (Bounds.h - Height) / 2), w: Width, h: Height}
			if Native.Move(A_ScriptHwnd, Rect) != true
				throw Error("Console placement was refused.")
		}
		if Native.Activate(A_ScriptHwnd) != true
			throw Error("Console activation was refused.")
		return true
	} catch as Err {
		LoggerError("ConsoleWindow", "Could not open debug view '{1}': {2}.", Kind, Err.Message)
		return false
	}
}
