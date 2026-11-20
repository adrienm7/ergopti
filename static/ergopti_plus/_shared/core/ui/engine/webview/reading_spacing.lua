--- _shared/core/ui/engine/webview/reading_spacing.lua

--- ==============================================================================
--- MODULE: Reading Spacing Owner (Shared)
--- DESCRIPTION:
--- The native owner of `script.reading_spacing`, the WCAG 1.4.12 text spacing
--- of the app's windows, which the script scope binds on macOS and Linux.
--- Built by reading_preferences.lua, which documents it.
--- ==============================================================================

return require("core.ui.engine.webview.reading_preferences").new_owner(
	"script.reading_spacing", "core.ui.engine.webview.reading_spacing")
