--- tests/hardware/desktop/run_wayland_focus_lswt.lua

--- ==============================================================================
--- MODULE: Wayland Focus Through The Foreign-Toplevel Listing
--- DESCRIPTION:
--- Run by run_wayland_sessions.sh inside a live headless compositor session,
--- with `lswt` on the PATH (the private foreign_toplevel_probe standing in for
--- lswt 2.x, which Ubuntu 24.04 does not package).
---   - labwc: two real windows; the compositor's activated toplevel is the one
---     adapters/window_info.lua reports, and process_lifecycle's focus callback
---     (the per-application rules' input) follows each activation.
---   - gnome / kde: no wlr-foreign-toplevel interface, so the adapter answers
---     unknown and logs the single "No focused-window query" line however often
---     it is asked.
---
--- USAGE: luajit run_wayland_focus_lswt.lua <driver root> <labwc|gnome|kde>
---   [first app-id] [second app-id]
--- Exit 0 = verified; any assertion failure exits non-zero.
--- ==============================================================================

local root, mode = assert(arg[1], "driver root"), assert(arg[2], "session mode")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/?.lua;" .. root .. "/../_shared/?/init.lua;" .. package.path
require("core.lifecycle.engine.compat.utf8").install()
local Logger = require("core.logger.engine.shim")
local Display = require("core.ui.engine.display_server")
local Shell = require("core.process.adapters.shell_runner")

local NO_QUERY_LINE = "No focused-window query on this compositor"
local QUERIES = 5

-- Count the adapter's warnings without silencing them.
local unsupported_lines = 0
local real_warn = Logger.warn
Logger.warn = function(tag, fmt, ...)
	if tag == "adapters.window_info" and tostring(fmt):find(NO_QUERY_LINE, 1, true) then
		unsupported_lines = unsupported_lines + 1
	end
	return real_warn(tag, fmt, ...)
end

assert(Display.refresh() == Display.WAYLAND, "the session must be a Wayland one")
assert(Shell.has_command("lswt"), "the lswt listing must be on the PATH")
local WindowInfo = require("adapters.window_info")
local Lifecycle = require("core.process.adapters.lifecycle")
print(string.format("SESSION mode=%s desktop=%s", mode, Display.desktop()))

if mode == "gnome" or mode == "kde" then
	for _ = 1, QUERIES do
		local info, identity = WindowInfo.focused_snapshot()
		assert(info.appId == "" and info.windowTitle == "" and identity == nil,
			"no focused-window query answers unknown, never a guess")
	end
	assert(unsupported_lines == 1, "the limitation is logged once, got " .. unsupported_lines)
	print(string.format("PASS %s %d queries unknown, %d \"%s\" line", mode, QUERIES, unsupported_lines, NO_QUERY_LINE))
	return
end

assert(mode == "labwc", "unknown mode " .. mode)
local first, second = assert(arg[3], "first app-id"), assert(arg[4], "second app-id")
local seen = {}
Lifecycle.onFocusChange(function(app_id, title) seen[#seen + 1] = { app = app_id, title = title } end)
local function activate(app_id)
	assert(Shell.exec_checked("lswt activate " .. Shell.quote(app_id)), "the compositor refused to activate " .. app_id)
end

activate(first)
Lifecycle.start()
local info = WindowInfo.getFocused()
assert(info.appId == first, "the activated toplevel is the focus, got '" .. info.appId .. "'")
print(string.format("PASS focus %s title=%q", info.appId, info.windowTitle))
for tick, target in ipairs({ second, first, second }) do
	activate(target)
	Lifecycle.tick(tick)
	local event = seen[#seen]
	assert(#seen == tick and event.app == target,
		"the focus callback must follow the activation to " .. target)
	print(string.format("PASS focus change %d -> %s title=%q", tick, event.app, event.title))
end
Lifecycle.tick(#seen + 1)
assert(#seen == 3, "an unchanged focus fires no callback")
Lifecycle.stop()
assert(unsupported_lines == 0, "a compositor with the listing never logs the unsupported line")
print("PASS labwc per-application focus followed 3 activations")
