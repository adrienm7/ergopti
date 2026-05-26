; static/drivers/autohotkey/tests/_run_shortcuts_only.ahk
#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off
#Include test_framework.ahk
#Include test_stubs.ahk
#Include ../lib/ui_style.ahk
#Include ../lib/logger.ahk
#Include ../lib/toml/toml_helpers.ahk
#Include ../lib/active_app_cache.ahk
#Include ../lib/window_utils.ahk
#Include ../lib/string_utils.ahk
#Include ../lib/nav_layer_helpers.ahk
#Include ../lib/hotstrings/hotstring_engine.ahk
#Include ../lib/hotstrings/hotstring_engine_main.ahk
#Include ../lib/toml/toml_loader.ahk
#Include ../lib/toml/toml_config_loader.ahk
#Include ../lib/tap_hold/tap_hold_loader.ahk
#Include ../_generated/features_manifest.ahk
#Include ../lib/manifest_reader.ahk
#Include ../lib/hotstrings/hotstrings_config.ahk
#Include ../lib/hotstrings/personal_toml_editor.ahk
#Include ../lib/layout/layout_altgr.ahk
#Include ../lib/layout/layout_shift_caps.ahk
#Include ../lib/tooltip.ahk
#Include ../lib/registry.ahk
#Include ../lib/json.ahk
#Include ../lib/i18n.ahk
InstallHotstringHooks()
#Include test_shortcuts.ahk
RunTests()
