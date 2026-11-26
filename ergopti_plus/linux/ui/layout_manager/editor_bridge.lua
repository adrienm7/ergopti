--- ui/layout_manager/editor_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Layout Editor Window
--- DESCRIPTION:
--- The handler of the layout editor's own window
--- (_shared/ui/layout_editor_window, bridge "layout_editor_window_bridge").
--- ui/layout_manager/bridge.lua builds it with the layout manager's handler, so
--- both windows apply the same rules (_shared/layouts/engine/manager_bridge.lua).
--- ==============================================================================

return require("ui.layout_manager.bridge").editor
