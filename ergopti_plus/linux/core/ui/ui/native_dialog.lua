--- core/ui/ui/native_dialog.lua

--- ==============================================================================
--- MODULE: Native Dialog Command (Linux)
--- DESCRIPTION:
--- The one answer to « which program shows a native dialog? »: Ergopti's own
--- GTK 3 host (core/ui/ui/dialog_host.lua), run by the interpreter running the daemon.
--- The host's command line is the zenity subset the call sites always wrote,
--- so a site prefixes its arguments with M.command() and keeps reading the
--- answer on stdout and the exit status (0 accepted, 1 cancelled).
---
--- FEATURES & RATIONALE:
--- 1. Never the host's zenity or kdialog (owned runtimes registry): the dialog
---    exists on every desktop that can show the tray, which already needs GTK 3.
--- 2. The interpreter is the daemon's own executable (luv exepath), so the
---    private runtime's LuaJIT runs the host in every package format.
--- 3. Blocking runs still go through core/ui/ui/modal.lua, which hands the grabbed
---    keyboard to the desktop while the dialog is open.
--- ==============================================================================

local M = {}

--- The host script, relative to the driver root.
M.HOST = "core/ui/ui/dialog_host.lua"

--- Exit status of the host when the user cancels or closes the dialog.
M.EXIT_CANCELLED = 1

--- Exit status of the host when GTK 3 or a display is missing.
M.EXIT_UNAVAILABLE = 69

local DEFAULT_DEPS = {
	exepath = function() return require("luv").exepath() end,
	-- The path owner's root, absolute even under a relative package.path
	-- (`luajit ergopti_hotstrings.lua` from the driver folder, or a child the
	-- tray starts with that path): this file's own source path is then
	-- "./ui/native_dialog.lua", and every dialog refused to open.
	driver_root = function() return require("core.fs.engine.paths").driver_root() end,
	quote = function(value) return require("core.text.engine.utils_core").shell_quote(value) end,
}




-- ================================
-- ================================
-- ======= 1/ Command =============
-- ================================
-- ================================

--- The shell words that start the owned dialog host; append its arguments.
--- @param deps table|nil { exepath, driver_root, quote }; a test seam.
--- @return string command Two quoted words: the interpreter and the host script.
function M.command(deps)
	deps = deps or DEFAULT_DEPS
	local interpreter = deps.exepath()
	assert(type(interpreter) == "string" and interpreter:sub(1, 1) == "/",
		"the native dialog needs the daemon's interpreter path")
	local root = deps.driver_root()
	assert(type(root) == "string" and root:sub(1, 1) == "/", "the native dialog needs the driver root")
	return deps.quote(interpreter) .. " " .. deps.quote(root .. "/" .. M.HOST)
end

--- The exit code of an os.execute result on either interpreter: LuaJIT returns
--- the raw wait status (the code times 256), Lua 5.2+ returns true or nil,
--- "exit", code.
--- @param status any os.execute's first result.
--- @param how any os.execute's second result.
--- @param code any os.execute's third result.
--- @return number|nil code Nil when the child did not exit normally.
function M.exit_code(status, how, code)
	if status == true then return 0 end
	if how == "exit" and type(code) == "number" then return code end
	if type(status) ~= "number" then return nil end
	-- Numeric results are POSIX wait statuses, including a signal in the low
	-- byte. In particular, SIGHUP (1) is not the dialog's cancellation exit.
	if status < 0 or status % 1 ~= 0 then return nil end
	if status % 256 ~= 0 then return nil end
	return math.floor(status / 256)
end

--- Escapes text for a dialog read as Pango markup (a site that omits
--- --no-markup): a value holding "<" or "&" would otherwise blank the dialog.
--- @param text any
--- @return string
function M.plain_markup(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

return M
