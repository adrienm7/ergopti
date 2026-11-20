--- _shared/core/ui/engine/webview/reading_font.lua

--- ==============================================================================
--- MODULE: Reading Font Owner (Shared)
--- DESCRIPTION:
--- The native owner of `script.reading_font`, the font of the app's windows,
--- which the script scope binds on macOS and Linux. Built by
--- reading_preferences.lua, which documents it.
--- ==============================================================================

return require("core.ui.engine.webview.reading_preferences").new_owner(
	"script.reading_font", "core.ui.engine.webview.reading_font")
