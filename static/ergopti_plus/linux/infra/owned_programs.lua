--- infra/owned_programs.lua

--- ==============================================================================
--- MODULE: Owned Programs (Linux)
--- DESCRIPTION:
--- The one answer to « which curl, sqlite3, openssl or zstd does the driver
--- run? ». Every package format carries a private runtime prefix (the AppImage
--- stages it; the .deb, the .rpm and the Flatpak carry the same set) and its
--- launcher exports ERGOPTI_RUNTIME_PREFIX through network-runtime-env.sh. The
--- owned-runtimes registry decides these programs PIN: run only that copy.
---
--- FEATURES & RATIONALE:
--- 1. With a prefix, a program is its absolute path inside it: a host copy
---    earlier on PATH, or a user's alias, can never answer instead.
--- 2. Without one, the run is a source checkout or a source install, which
---    uses the developer's programs on PATH; that mode is logged once, never
---    taken silently.
--- 3. Only the programs the prefix carries are resolved here, the same list
---    tools/build/stage-linux-network-runtime.py stages (OWNED_PROGRAMS).
--- ==============================================================================

local M = {}

local LOG = "infra.owned_programs"

--- The environment variable network-runtime-env.sh exports.
M.PREFIX_ENV = "ERGOPTI_RUNTIME_PREFIX"

--- The programs the private runtime prefix carries.
M.PROGRAMS = { luajit = true, curl = true, sqlite3 = true, openssl = true, zstd = true }

-- Whether the PATH mode was logged already.
local _path_mode_reported = false




-- =====================================
-- =====================================
-- ======= 1/ Resolution ===============
-- =====================================
-- =====================================

--- The private runtime prefix, or nil for a source run.
--- @param getenv function|nil os.getenv by default; a test seam.
--- @return string|nil
function M.prefix(getenv)
	local value = (getenv or os.getenv)(M.PREFIX_ENV)
	if value == nil or value == "" then return nil end
	assert(value:sub(1, 1) == "/" and not value:find("\0", 1, true), "invalid " .. M.PREFIX_ENV)
	return value
end

--- The program to run for one owned program, without logging.
--- For a helper process that has only the driver tree on package.path
--- (adapters/sqlite_process_worker.lua, platform/network/system_proxy_probe.lua):
--- the daemon already logged the mode, and a helper's stdout may be its protocol.
--- @param name string One of M.PROGRAMS.
--- @param getenv function|nil os.getenv by default; a test seam.
--- @return string An absolute path inside the prefix, or the bare name for a source run.
function M.resolve(name, getenv)
	assert(M.PROGRAMS[name], "not an owned program: " .. tostring(name))
	local prefix = M.prefix(getenv)
	if prefix then return prefix .. "/bin/" .. name end
	return name
end

--- The program to run for one owned program.
--- @param name string One of M.PROGRAMS.
--- @param getenv function|nil os.getenv by default; a test seam.
--- @return string An absolute path inside the prefix, or the bare name for a source run.
function M.path(name, getenv)
	local program = M.resolve(name, getenv)
	if program:sub(1, 1) == "/" then return program end
	if not _path_mode_reported then
		_path_mode_reported = true
		require("core.logger.engine.shim").info(LOG, "No private runtime prefix (%s unset): a source run uses curl, sqlite3, "
			.. "openssl and zstd from PATH.", M.PREFIX_ENV)
	end
	return program
end

--- Whether one owned program can run.
--- @param name string One of M.PROGRAMS.
--- @param getenv function|nil os.getenv by default; a test seam.
--- @return boolean
function M.available(name, getenv)
	local program = M.path(name, getenv)
	local Shell = require("adapters.shell_runner")
	if program:sub(1, 1) == "/" then
		local ok = os.execute("test -x " .. Shell.quote(program))
		return ok == true or ok == 0
	end
	return Shell.has_command(program)
end

--- The tar option that decompresses through the private runtime's zstd.
---
--- `tar --zstd` used whatever zstd support the host tar was built with, and no
--- package required it: the Ollama archive then failed after a 1.4 GB download
--- (owned runtimes: PIN a zstd decoder). Any GNU tar runs a named program.
--- @param getenv function|nil os.getenv by default; a test seam.
--- @return string|nil option, string|nil reason
function M.zstd_tar_option(getenv)
	local program = M.path("zstd", getenv)
	-- GNU tar splits the program on blanks into a command and its arguments.
	if program:find("%s") then return nil, "owned_zstd_path_has_blank" end
	return "--use-compress-program=" .. program
end

--- Test seam: forgets that the PATH mode was logged.
function M._reset_for_test()
	_path_mode_reported = false
end

return M
