--- tests/hardware/desktop/take_note_action.lua

--- ==============================================================================
--- MODULE: Daily Note Action Runner
--- DESCRIPTION:
--- Runs the catalogue action `take_note` once through the gesture manager's own
--- executor (the path a gesture, a shortcut or the tray takes), with the real
--- background-command owner, xdg-mime, gtk-launch and notify-send, then pumps the
--- event loop until the owner has collected the launch. Prints the action's
--- log lines. Exit 0 = the action ran; 1 = it raised.
--- ==============================================================================

require("core.lifecycle.engine.compat.utf8").install()
local uv = require("luv")
local Logger = require("core.logger.engine.shim")
Logger.set_level("info")
-- The driver routes its lines to a file sink; this runner prints them for the proof.
Logger.set_sink(function(line) io.stdout:write(line, "\n"); io.stdout:flush() end)
local i18n = require("infra.i18n")
i18n.init()

local Manager = require("modules.gestures.manager")
local Background = require("modules.gestures.background_commands")
local ran = Manager.execute_action("take_note", "desktop_proof")
local deadline = uv.hrtime() + 10e9
while Background.pending_count() > 0 and uv.hrtime() < deadline do
	uv.run("nowait")
	-- The daemon's loop runs the collector timer; this runner has no such loop.
	Background._collect_now()
	uv.sleep(20)
end
print("RESULT ran=" .. tostring(ran) .. " pending=" .. tostring(Background.pending_count()))
os.exit(ran and 0 or 1)
