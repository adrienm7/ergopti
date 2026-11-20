--- _shared/core/ui/engine/webview/reading_font.lua

--- ==============================================================================
--- MODULE: Reading Font Owner (Shared)
--- DESCRIPTION:
--- The native owner of `script.reading_font`, the font of the app's windows,
--- which the script scope binds on macOS and Linux. Built by
--- reading_preferences.lua, which documents it.
--- ==============================================================================

local ConfigKeys = require("settings.engine.keys")

return require("core.ui.engine.webview.reading_preferences").new_owner(
	ConfigKeys.KEY.SCRIPT_READING_FONT, "core.ui.engine.webview.reading_font")
