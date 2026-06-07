; static/ergopti_plus/windows/tests/test_log_level_ui.ahk
;
; DESCRIPTION:
; Verifies that the log level menu labels include emojis.

#Include %A_LineFile%\..\test_framework.ahk
#Include %A_LineFile%\..\..\ui\tray_menu.ahk

TestLogLevel_Emojis() {
    ; Mock global state
    global LOGGER_MIN_LEVEL := "DEBUG"
    
    ; Test the emoji helper
    AssertEqual("🐛", _LogLevelEmoji("DEBUG"), "DEBUG should have bug emoji")
    AssertEqual("ℹ️", _LogLevelEmoji("INFO"), "INFO should have info emoji")
    AssertEqual("⚠️", _LogLevelEmoji("WARNING"), "WARNING should have warning emoji")
    AssertEqual("❌", _LogLevelEmoji("ERROR"), "ERROR should have cross emoji")
    
    ; Test the parent label
    Label := _LogLevelMenuLabel()
    ; t() might return key or value, but we check if it contains the emoji
    AssertTrue(InStr(Label, "🐛") > 0, "parent label should contain emoji for DEBUG")
    
    ; Switch level and check again
    global LOGGER_MIN_LEVEL := "ERROR"
    Label := _LogLevelMenuLabel()
    AssertTrue(InStr(Label, "❌") > 0, "parent label should contain emoji for ERROR")
}
Test("UI: Log level menu labels include emojis", TestLogLevel_Emojis)
