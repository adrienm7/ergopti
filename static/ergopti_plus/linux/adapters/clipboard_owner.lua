--- adapters/clipboard_owner.lua

--- ==============================================================================
--- MODULE: Multi-Format Clipboard Restore (Linux)
--- DESCRIPTION:
--- Puts a saved clipboard back with every format it held, through the native
--- owner child (adapters/clipboard_owner_worker.lua), so a borrower can run on
--- a clipboard holding HTML, an image or copied files next to its text, as
--- Windows (ClipboardAll) and macOS (readAllData) do.
---
--- FEATURES & RATIONALE:
--- 1. Probe before borrowing: the clipboard adapter asks available() before its
---    first write, so a session where the owner cannot run (no LuaJIT FFI, no
---    data-control on GNOME's Wayland) keeps the refusal instead of losing
---    formats on restore.
--- 2. The snapshot goes through a private mktemp file, never a heredoc: images
---    hold NUL bytes the shell cannot carry. The child removes it once read.
--- 3. The child's exit status is the receipt: 0 means the selection is taken.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Shell = require("adapters.shell_runner")
local DisplayServer = require("infra.display_server")

local LOG = "adapters.clipboard_owner"

-- Seconds the owner may take to read the snapshot and take the selection
-- before it forks; a stalled display must not hold a borrower longer.
local OWNER_TIMEOUT_S = 3




-- ===============================================
-- ===============================================
-- ======= 1/ Command ============================
-- ===============================================
-- ===============================================

--- The owner backend of this session.
--- @return string|nil kind "x11" or "wayland".
--- @return string|nil soname The library the child loads.
local function session_backend()
	local Runtime = require("_generated.native_runtime")
	if DisplayServer.is_wayland() then return "wayland", Runtime.optional.wayland_client end
	if DisplayServer.is_x11() then return "x11", Runtime.x11 end
	return nil, nil
end

--- Composes the owner command line.
--- @param mode string "probe" or "own".
--- @param path string|nil Snapshot file for "own".
--- @return string|nil command nil when the owner cannot run here.
local function owner_command(mode, path)
	local kind, soname = session_backend()
	if not kind then return nil end
	-- The child needs LuaJIT's FFI, which only the daemon's own interpreter is
	-- known to have.
	if not pcall(require, "ffi") then return nil end
	local loaded, uv = pcall(require, "luv")
	if not loaded or type(uv.exepath) ~= "function" then return nil end
	local executable = uv.exepath()
	if type(executable) ~= "string" or executable:sub(1, 1) ~= "/" then return nil end
	local worker = require("infra.paths").driver_root() .. "/adapters/clipboard_owner_worker.lua"
	local parts = { "timeout", tostring(OWNER_TIMEOUT_S), Shell.quote(executable), Shell.quote(worker), mode, kind,
		Shell.quote(soname) }
	if path then parts[#parts + 1] = Shell.quote(path) end
	return table.concat(parts, " ") .. " </dev/null >/dev/null 2>&1"
end




-- ===============================================
-- ===============================================
-- ======= 2/ Public API =========================
-- ===============================================
-- ===============================================

--- Whether this session can restore a multi-format clipboard.
--- @return boolean
function M.available()
	local command = owner_command("probe")
	if not command then return false end
	return Shell.run(command) == true
end

--- Takes the clipboard with every saved target.
--- @param targets table Ordered { { name, data } }.
--- @return boolean taken
function M.write(targets)
	assert(type(targets) == "table" and #targets > 0, "clipboard owner needs at least one target")
	local Worker = require("adapters.clipboard_owner_worker")
	local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
	local made, path = Shell.exec_checked(runtime_dir and runtime_dir ~= ""
		and "mktemp -p " .. Shell.quote(runtime_dir) .. " ergopti-clipboard.XXXXXX" or "mktemp")
	path = made and path:match("^(/[^\n]+)\n?$") or nil
	if not path then
		Logger.error(LOG, "No private file for the clipboard snapshot.")
		return false
	end
	local file = io.open(path, "wb")
	local written = file ~= nil and file:write(Worker.encode(targets)) ~= nil
	if file then written = file:close() and written end
	local command = written and owner_command("own", path) or nil
	local taken = command ~= nil and Shell.run(command) == true
	-- The child removes the file once read; one that never started leaves it.
	os.remove(path)
	if not taken then Logger.error(LOG, "The clipboard owner did not take the selection back.") end
	return taken
end

return M
