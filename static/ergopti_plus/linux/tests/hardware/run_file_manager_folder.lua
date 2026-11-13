--- tests/hardware/run_file_manager_folder.lua

--- ==============================================================================
--- MODULE: Active File Manager Folder Receipt
--- DESCRIPTION:
--- Runs the real adapters/file_manager_folder.lua and the real
--- open_terminal_here / new_text_file_here handlers against the display, the
--- window manager and the file managers of the calling fixture
--- (tests/hardware/run_file_manager_folder.sh). One line per call:
---   read      -> "folder<TAB><path>" or "refused<TAB><reason><TAB><detail>"
---   terminal  -> "terminal<TAB>started" or "terminal<TAB>refused"
---   new_file  -> "created<TAB><path>" or "created<TAB>none"
--- The unit tests cover the parsing and the refusals with recorded answers;
--- only real file managers prove which windows publish their folder.
--- ==============================================================================

require("core.lifecycle.engine.compat.utf8").install()
local DisplayServer = require("infra.display_server")
assert(DisplayServer.is_x11(), "the file manager folder receipt needs an X11 display")

local Folder = require("adapters.file_manager_folder")
local SystemActions = require("modules.gestures.system_actions")

local mode = arg[1]

if mode == "read" then
	local folder, reason, detail = Folder.read_active_folder()
	if folder then
		io.write("folder\t", folder.path, "\n")
	else
		io.write("refused\t", tostring(reason), "\t", tostring(detail or ""), "\n")
	end
elseif mode == "terminal" then
	local before = Folder.read_active_folder()
	SystemActions.HANDLERS.open_terminal_here()
	io.write("terminal\t", before and "started" or "refused", "\n")
elseif mode == "new_file" then
	local before = Folder.read_active_folder()
	local revealed = {}
	SystemActions.HANDLERS.new_text_file_here({
		run_background = function(command)
			revealed[#revealed + 1] = command
			local ok = os.execute(command .. " >/dev/null")
			return ok == true or ok == 0
		end,
	})
	if before and #revealed == 1 then
		local base = require("infra.i18n").get("system_actions.new_text_file_name")
		local path = revealed[1]:match("file://([^']+)'")
		io.write("created\t", tostring(path and path:gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)), "\t", base, "\n")
	else
		io.write("created\tnone\n")
	end
else
	error("usage: run_file_manager_folder.lua read|terminal|new_file")
end
