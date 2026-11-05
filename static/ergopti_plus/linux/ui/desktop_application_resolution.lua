-- linux/ui/desktop_application_resolution.lua

--- Resolves a desktop-file ID in a fresh, bounded Gio process.
local M = {}
local Shell = require("adapters.shell_runner")
local Modal = require("ui.modal")

-- Gio may read arbitrary XDG desktop entries. A blocked native read must not
-- keep the keyboard grab or the daemon indefinitely.
local LOOKUP_SECONDS = 2
local KILL_GRACE_SECONDS = 1
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(/.*)/ui/desktop_application_resolution%.lua$")

--- Resolves the ID with a fresh Gio cache, as the later gtk-launch process will.
--- @param id string Desktop-file ID without the .desktop suffix.
--- @return string|nil path Effective native file path, if verified.
--- @return string status `found` or `unavailable`.
function M.resolve(id)
	if type(id) ~= "string" or id == "" or id:find("[%z\r\n]") or not root then return nil, "unavailable" end
	local ok, luv = pcall(require, "luv")
	if not ok or type(luv.exepath) ~= "function" then return nil, "unavailable" end
	local got, executable = pcall(luv.exepath)
	if not got or type(executable) ~= "string" or executable:sub(1, 1) ~= "/" then return nil, "unavailable" end
	-- Foreground mode signals only the worker: group-wide SIGKILL would also
	-- kill timeout itself before it can wait for and reap that worker.
	local command = "timeout --foreground --kill-after=" .. KILL_GRACE_SECONDS .. "s " .. LOOKUP_SECONDS .. "s "
		.. Shell.quote(executable) .. " " .. Shell.quote(root .. "/ui/desktop_application_resolution_worker.lua")
		.. " " .. Shell.quote(id) .. " 2>/dev/null"
	-- exec_checked waits for timeout and the worker to retire before returning;
	-- while it waits, the native modal owner releases the keyboard to the desktop.
	local ran, output = Modal.run(function() return Shell.exec_checked(command) end)
	if ran ~= true or type(output) ~= "string" or output:sub(-1) ~= "\n" then return nil, "unavailable" end
	local path = output:sub(1, -2)
	if path:sub(1, 1) ~= "/" or path:find("[%z\r\n]") then return nil, "unavailable" end
	return path, "found"
end

return M
