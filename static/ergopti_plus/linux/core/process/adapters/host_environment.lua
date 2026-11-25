--- core/process/adapters/host_environment.lua

--- ==============================================================================
--- MODULE: Host Environment Restoration (Linux)
--- DESCRIPTION:
--- Starts host programs with the environment the user's session gave the
--- launcher, not the one the private runtime runs under.
---
--- FEATURES & RATIONALE:
--- 1. network-runtime-env.sh points LUA_PATH, LUA_CPATH and CURL_CA_BUNDLE (and,
---    in a prefix that owns its GIO, the GIO and XDG variables) at the bundle,
---    and every process the daemon starts inherits them. A host program (pkexec,
---    setxkbmap, xkbcomp, kwriteconfig6, qdbus, xdg-open, notify-send,
---    systemctl) then ran with the bundle's search paths: the GIO module
---    directory reached every GTK application xdg-open started. The launcher
---    records each host value (ERGOPTI_HOST_ENV_NAMES, ERGOPTI_HOST_ENV_SET_*)
---    before it changes it, and this module puts them back.
--- 2. One owner for every spawn: install() wraps io.popen, os.execute and
---    luv.spawn once, at daemon start, before any module can keep a reference
---    to the originals. ~150 call sites start processes directly; patching them
---    one by one would leave the next one leaking.
--- 3. A command that names the private runtime prefix or the driver root runs
---    an owned program (the bundled luajit, curl, a driver script) and keeps
---    the bundle environment it needs. Every other command is a host program.
--- 4. Without a launcher record (a source checkout) install() changes nothing.
--- ==============================================================================

local M = {}

local LOG = "core.process.adapters.host_environment"

-- The variables network-runtime-env.sh writes (identifiers.json linux_host_environment).
local Record = require("core.text.engine.identifiers").linux_host_environment
local TableUtil = require("core.text.engine.table_util")
local shell_quote = require("core.text.engine.utils_core").shell_quote

--- The launcher's record: the names it changed, and each one's host value.
M.NAMES_ENV = Record.names_env
M.VALUE_PREFIX = Record.value_prefix
--- The roots whose programs keep the bundle environment.
M.OWNED_ROOT_ENVS = { "ERGOPTI_RUNTIME_PREFIX", Record.driver_root_env }

-- Whether install() already wrapped the spawn functions.
local _installed = false




-- ===============================
-- ===============================
-- ======= 1/ The record =========
-- ===============================
-- ===============================

--- Reads the launcher's record of the host environment.
--- @param getenv function|nil os.getenv by default; a test seam.
--- @return table|nil { names = { ... }, values = { [name] = value }, owned = { root, ... } }
function M.read(getenv)
	getenv = getenv or os.getenv
	local listed = getenv(M.NAMES_ENV)
	if listed == nil then return nil end
	local record = { names = {}, values = {}, owned = {} }
	for name in listed:gmatch("%S+") do
		assert(name:match("^[A-Z_][A-Z0-9_]*$"), "invalid " .. M.NAMES_ENV .. " entry")
		record.names[#record.names + 1] = name
		record.values[name] = getenv(M.VALUE_PREFIX .. name)
	end
	for _, variable in ipairs(M.OWNED_ROOT_ENVS) do
		local root = getenv(variable)
		if root ~= nil and root ~= "" then
			assert(root:sub(1, 1) == "/", "invalid " .. variable)
			record.owned[#record.owned + 1] = root
		end
	end
	return record
end

--- The shell text that restores the host environment before a command.
--- The record's own variables go too: a host program has no use for them.
--- @param record table From M.read().
--- @return string
function M.shell_prefix(record)
	local unset = { M.NAMES_ENV }
	local exports = {}
	for _, name in ipairs(record.names) do
		unset[#unset + 1] = M.VALUE_PREFIX .. name
		local value = record.values[name]
		if value == nil then
			unset[#unset + 1] = name
		else
			exports[#exports + 1] = name .. "=" .. shell_quote(value)
		end
	end
	local text = "unset " .. table.concat(unset, " ") .. "; "
	if #exports > 0 then text = text .. "export " .. table.concat(exports, " ") .. "; " end
	return text
end

--- The environment array for a host program started by luv.spawn.
--- @param record table From M.read().
--- @param environ table The current environment, { [name] = value } (luv.os_environ()).
--- @return table An array of "NAME=value" strings.
function M.spawn_environment(record, environ)
	local dropped = { [M.NAMES_ENV] = true }
	local restored = {}
	for _, name in ipairs(record.names) do
		dropped[M.VALUE_PREFIX .. name] = true
		dropped[name] = true
		if record.values[name] ~= nil then restored[name] = record.values[name] end
	end
	local merged = {}
	for name, value in pairs(environ) do
		if not dropped[name] then merged[name] = value end
	end
	for name, value in pairs(restored) do merged[name] = value end
	local result = {}
	for _, name in ipairs(TableUtil.sorted_keys(merged)) do
		result[#result + 1] = name .. "=" .. merged[name]
	end
	return result
end

--- Whether a command or an executable runs an owned program.
--- @param record table From M.read().
--- @param text string The shell command, or the executable path.
--- @return boolean
function M.is_owned(record, text)
	for _, root in ipairs(record.owned) do
		if text:find(root, 1, true) then return true end
	end
	return false
end




-- ===================================
-- ===================================
-- ======= 2/ The spawn owner ========
-- ===================================
-- ===================================

--- Wraps io.popen, os.execute and luv.spawn so host programs get the host
--- environment. Once per process.
--- @param deps table|nil { getenv, io, os, luv, logger }; test seams.
--- @return boolean installed False when the launcher left no record.
function M.install(deps)
	assert(not _installed, "host environment restoration installed twice")
	deps = deps or {}
	local record = M.read(deps.getenv)
	if record == nil then return false end
	_installed = true
	local io_module = deps.io or io
	local os_module = deps.os or os
	local prefix = M.shell_prefix(record)
	local host = function(command)
		if type(command) ~= "string" or M.is_owned(record, command) then return command end
		return prefix .. command
	end
	local popen, execute = io_module.popen, os_module.execute
	io_module.popen = function(command, ...) return popen(host(command), ...) end
	os_module.execute = function(command, ...)
		if command == nil then return execute() end
		return execute(host(command), ...)
	end
	local luv = deps.luv
	if luv == nil then
		local loaded, module = pcall(require, "luv")
		if loaded then luv = module end
	end
	if type(luv) == "table" and type(luv.spawn) == "function" and type(luv.os_environ) == "function" then
		local spawn = luv.spawn
		-- A shell or an env(1) that starts an owned program names it in its arguments.
		local function owned_arguments(args)
			if type(args) ~= "table" then return false end
			for _, value in ipairs(args) do
				if type(value) == "string" and M.is_owned(record, value) then return true end
			end
			return false
		end
		luv.spawn = function(path, options, ...)
			if type(path) == "string" and type(options) == "table" and options.env == nil
				and not M.is_owned(record, path) and not owned_arguments(options.args) then
				local copy = {}
				for key, value in pairs(options) do copy[key] = value end
				copy.env = M.spawn_environment(record, luv.os_environ())
				options = copy
			end
			return spawn(path, options, ...)
		end
	end
	local logger = deps.logger or require("core.logger.engine.shim")
	logger.info(LOG, "Host programs start with the session's environment (%d variable(s) restored).",
		#record.names)
	return true
end

--- Test seam: forgets a previous install() without restoring the originals,
--- which each test passes in as its own tables.
function M._reset_for_test()
	_installed = false
end

return M
