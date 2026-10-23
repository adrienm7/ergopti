--- tests/hardware/run_window_list_receipt.lua

--- ==============================================================================
--- MODULE: X11 Window List Receipt
--- DESCRIPTION:
--- Runs the real `window_info.getAll()` against the display and window manager
--- of the calling fixture (Xvfb and Openbox), one line per listed window:
--- `<title><TAB><application id>`. The caller asserts the windows it owns. The
--- unit tests cover the parser; only a real window manager proves that
--- `wmctrl -lp` answers and that `/proc/<pid>/comm` names the owner.
--- ==============================================================================

require("compat.utf8").install()
local DisplayServer = require("infra.display_server")
assert(DisplayServer.is_x11(), "the window list receipt needs an X11 display")
local WindowInfo = require("adapters.window_info")

local windows = WindowInfo.getAll()
assert(type(windows) == "table" and #windows > 0, "getAll() listed no window on a managed display")
for _, window in ipairs(windows) do
	io.write(window.windowTitle, "\t", window.appId, "\n")
end
