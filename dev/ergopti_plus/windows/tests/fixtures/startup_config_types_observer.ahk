; tests/fixtures/startup_config_types_observer.ahk

; ==============================================================================
; MODULE: Startup Configuration Type Observer
; DESCRIPTION:
; Receives the actual manifest load and editor preference after the boot full
; save. Both cold and independent warm launches must retain exact string types.
; ==============================================================================

_StartupSmokeConfigTypesReceipt() {
	global Features, DriverPid
	if EnvGet("ERGOPTI_STARTUP_SMOKE_EXPECT_CONFIG_TYPES") != "1"
		return
	Locale := Features["script"]["locale"]
	Level := Features["script"]["log_level"]
	Section := _EditorPrefGet("default_section", "")
	if !(Locale is String) || Locale != "en" || !(Level is String) || Level != "DEBUG"
		throw Error("Literal configuration strings did not reach the live manifest settings.")
	if !(Section is String) || StrCompare(Section, "001", true) != 0
		throw Error("The personal editor lost the exact numeric section name.")
	Receipt := '{"nonce":' . JsonStringLiteral(EnvGet("ERGOPTI_STARTUP_SMOKE_NONCE"))
		. ',"pid":' . DriverPid . ',"locale":' . JsonStringLiteral(Locale)
		. ',"level":' . JsonStringLiteral(Level) . ',"section":' . JsonStringLiteral(Section) . '}'
	if !FSWriteCreateDurable(EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\config-types.json", Receipt)
		throw Error("The startup configuration type receipt could not be created.")
}
