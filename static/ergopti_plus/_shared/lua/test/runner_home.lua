--- _shared/lua/test/runner_home.lua

--- ==============================================================================
--- MODULE: Lua Runner Home Isolation
--- DESCRIPTION:
--- Keeps the Lua test runners of every driver away from the user's real home.
--- The drivers derive config.toml, the logs and the caches from HOME and the
--- XDG variables, so a suite started with the real HOME rewrote the developer's
--- own config.toml (group switches, metrics flags, schema migrations).
---
--- FEATURES & RATIONALE:
--- 1. A HOME that already lies in a temporary directory is a deliberate scratch
---    home (CI shards, the install sandbox, a developer's `HOME=$(mktemp -d)`)
---    and is kept as given.
--- 2. Any other HOME is replaced, for this process only, by a fresh directory
---    through an os.getenv wrapper installed before any module loads. The
---    wrapper also hides the XDG base directories, which would otherwise
---    point back at the real tree, unless they lie in a temporary directory.
---    LuaJIT also exports the redirect to the process environment through the
---    FFI, so a child started with io.popen inherits it. Lua 5.4 cannot change
---    the environment: a test that spawns a child there passes its own HOME.
--- 3. The scratch directory is removed when the runner exits.
--- ==============================================================================

local M = {}
local NativePath = require("native_path")

local XDG_VARIABLES = {
	XDG_CONFIG_HOME = true, XDG_DATA_HOME = true, XDG_STATE_HOME = true, XDG_CACHE_HOME = true,
}

local TEMPORARY_ROOTS = { "/tmp", "/private/tmp", "/var/folders", "/private/var/folders" }

local function normalised(path)
	local spelling = tostring(path)
	if package.config:sub(1, 1) == "\\" then spelling = spelling:gsub("\\", "/") end
	return NativePath.without_trailing_separators(spelling)
end

local function inside(path, root)
	root = normalised(root)
	return root ~= "" and (path == root or path:sub(1, #root + 1) == root .. "/")
end

--- Whether a home directory is a scratch location rather than a real account.
--- @param home string|nil The HOME value.
--- @param getenv function Environment reader (os.getenv or a fake).
--- @return boolean
function M.is_scratch(home, getenv)
	if type(home) ~= "string" or home == "" then return false end
	local path = normalised(home)
	if path:find("/%.%./") or path:sub(-3) == "/.." then return false end
	local roots = {}
	for _, root in ipairs(TEMPORARY_ROOTS) do roots[#roots + 1] = root end
	for _, name in ipairs({ "TMPDIR", "TEMP", "TMP" }) do
		local value = getenv(name)
		if type(value) == "string" and value ~= "" then roots[#roots + 1] = value end
	end
	for _, root in ipairs(roots) do
		if inside(path, root) then return true end
	end
	return false
end

local function remove_tree(path)
	if package.config:sub(1, 1) == "\\" then
		os.execute('rmdir /s /q "' .. path .. '" >nul 2>nul')
	else
		os.execute("rm -rf '" .. path:gsub("'", "'\\''") .. "'")
	end
end

local function make_scratch(getenv)
	local base = os.tmpname()
	os.remove(base)
	local path = normalised(base) .. "_ergopti_home"
	if package.config:sub(1, 1) == "\\" then
		os.execute('mkdir "' .. path .. '" >nul 2>nul')
	else
		os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
	end
	local probe = io.open(path .. "/.ergopti_home_probe", "w")
	if not probe then error("the runner could not create its scratch home " .. path, 0) end
	probe:close()
	return path
end

--- Mirrors the redirect into the process environment, so a child started with
--- io.popen or os.execute inherits the scratch home. Only LuaJIT can: its FFI
--- reaches setenv; plain Lua has no way to change the environment.
--- @param scratch string The scratch home.
--- @param getenv function The original environment reader.
local function export_to_children(scratch, getenv)
	if type(jit) ~= "table" then return end
	local loaded, ffi = pcall(require, "ffi")
	if not loaded then return end
	ffi.cdef("int setenv(const char *name, const char *value, int overwrite); int unsetenv(const char *name);")
	if ffi.C.setenv("HOME", scratch, 1) ~= 0 then error("the runner could not export its scratch home", 0) end
	for name in pairs(XDG_VARIABLES) do
		if not M.is_scratch(getenv(name), getenv) and ffi.C.unsetenv(name) ~= 0 then
			error("the runner could not hide " .. name, 0)
		end
	end
end

--- Redirects HOME when it is a real home. Call once, before any module loads.
--- @param env table|nil Test seam: { getenv, exit } replacing os.getenv and os.exit.
--- @return string home The HOME the process now resolves.
--- @return boolean redirected Whether a scratch home replaced the real one.
function M.isolate(env)
	local getenv = env and env.getenv or os.getenv
	local home = getenv("HOME")
	if M.is_scratch(home, getenv) then return home, false end
	local scratch = make_scratch(getenv)
	local previous_exit = env and env.exit or os.exit
	local function wrapped_getenv(name)
		if name == "HOME" or name == "USERPROFILE" then return scratch end
		if XDG_VARIABLES[name] then
			local value = getenv(name)
			-- A test may point an XDG directory at its own scratch tree; only a
			-- directory outside the temporary roots leads back to the real account.
			if M.is_scratch(value, getenv) then return value end
			return nil
		end
		return getenv(name)
	end
	if env then
		env.getenv, env.exit = wrapped_getenv, function(...) remove_tree(scratch); return previous_exit(...) end
	else
		-- A POSIX-only call: the Windows test mode emulates its own environment.
		if package.config:sub(1, 1) == "/" then export_to_children(scratch, getenv) end
		os.getenv = wrapped_getenv
		os.exit = function(...) remove_tree(scratch); return previous_exit(...) end
	end
	return scratch, true
end

return M
