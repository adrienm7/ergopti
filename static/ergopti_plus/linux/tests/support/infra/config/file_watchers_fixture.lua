--- tests/support/infra/config/file_watchers_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_file_watchers
--- DESCRIPTION:
--- Prelude shared by the test_file_watchers_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local reload_gate = require("reload_gate")

local native_ok, native_luv = pcall(require, "luv")

-- ------------------------------------------------------------------
-- Temp-directory helpers.  A sequence counter guarantees uniqueness
-- even when os.clock() does not advance between tests.
-- ------------------------------------------------------------------
local _dir_seq = 0

local function make_temp_dir()
	local base = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	_dir_seq = _dir_seq + 1
	local suffix = string.format("ergopti_fw_%d_%d", os.time(), _dir_seq)
	local dir = base .. "/" .. suffix
	os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	return dir
end

--- lib.file_watchers._is_watched_lua() deliberately excludes any path under
--- "/tmp/" (real .lua projects never live there; it is treated as OS noise).
--- make_temp_dir() resolves to "/tmp/..." on CI (no TEMP/TMPDIR env var), so
--- the base_dir-in-pump-mode test needs a directory OUTSIDE that prefix to
--- exercise the per-file .lua watcher at all (file-watcher-tmp-prefix-filter-
--- excludes-own-test-fixture).
---
--- It is a private mktemp directory under the platform temp root, never the
--- working directory: the runner's working directory is the driver root, so a
--- "./" fixture with an init.lua inside became production source for a
--- parallel group's walk of that tree, which then read it after removal
--- (fw-nontmp-outside-source-tree).
--- @return string dir Absolute path whose spelling does not start with /tmp/.
local function make_non_tmp_dir()
	local base = os.getenv("TMPDIR") or os.getenv("TEMP")
	if not base or base:find("^/tmp") then base = "/var/tmp" end
	local template = base .. "/ergopti_fw_nontmp_XXXXXX"
	local pipe = assert(io.popen("mktemp -d '" .. template:gsub("'", "'\\''") .. "'", "r"))
	local dir = pipe:read("*l")
	pipe:close()
	assert(dir and dir ~= "", "mktemp -d refused " .. template)
	assert(not dir:find("^/tmp/"), "the non-/tmp fixture resolved under /tmp/: " .. dir)
	local root = helpers.driver_root()
	assert(dir:sub(1, #root + 1) ~= root .. "/", "the non-/tmp fixture is inside the driver tree: " .. dir)
	return dir
end

local function write_file(path, content)
	local fh = io.open(path, "w")
	if fh then
		fh:write(content or "[test]\ntrigger = \"abc\"\n")
		fh:close()
		return true
	end
	return false
end

local function touch_file(path)
	os.execute("touch '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
end

local function rm_dir(dir)
	os.execute("rm -rf '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
end

local function sleep_sec(n)
	os.execute("sleep " .. tostring(n) .. " 2>/dev/null")
end

--- Probe: can we stat a file's mtime on this system?
--- @return boolean true when stat(1) works and returns an integer epoch timestamp.
local function _can_stat()
	local tmp = os.tmpname and os.tmpname() or "/tmp/__ergopti_stat_probe__"
	local fh = io.open(tmp, "w")
	if fh then fh:close() end
	local fh2 = io.popen("stat -c %Y '" .. tmp:gsub("'", "'\\''") .. "' 2>/dev/null", "r")
	if fh2 then
		local out = fh2:read("*l")
		fh2:close()
		os.remove(tmp)
		if out and tonumber(out) then return true end
	end
	pcall(os.remove, tmp)
	return false
end

local CAN_STAT = _can_stat()

--- Isolates the real libuv return-value interface, not a physical watch.
local function activation_fixture(receipt)
	local state = { handles = {}, starts = 0, stops = 0, closes = 0, warnings = {}, summaries = {} }
	local backend = { constants = {} }
	function backend.new_fs_event()
		local handle = {}
		state.handles[#state.handles + 1] = handle
		return handle
	end
	function backend.fs_event_start(handle, path, flags, callback)
		state.starts = state.starts + 1
		handle.callback = callback
		if receipt.throws then error(receipt.reason) end
		return receipt.value, receipt.reason, receipt.code
	end
	function backend.fs_event_stop() state.stops = state.stops + 1; return 0 end
	function backend.close(handle)
		state.closes = state.closes + 1
		handle.closed = true
	end
	local logger = {}
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "error" }) do
		logger[level] = function() end
	end
	function logger.warn(_, format, ...)
		state.warnings[#state.warnings + 1] = string.format(format, ...)
	end
	function logger.success(_, format, ...)
		state.summaries[#state.summaries + 1] = string.format(format, ...)
	end
	local replacements = {
		{ "luv", backend }, { "posix", { stat = function() return { type = "directory" } end } },
		{ "logger.shim", logger }, { "infra.file_watchers", nil },
	}
	local saved = {}
	for _, entry in ipairs(replacements) do
		saved[#saved + 1] = { entry[1], package.loaded[entry[1]] }
		package.loaded[entry[1]] = entry[2]
	end
	local ok, watcher = pcall(require, "infra.file_watchers")
	for _, entry in ipairs(saved) do package.loaded[entry[1]] = entry[2] end
	if not ok then error(watcher, 0) end
	return watcher, state
end

return {
	helpers = helpers,
	reload_gate = reload_gate,
	native_ok = native_ok,
	native_luv = native_luv,
	_dir_seq = _dir_seq,
	make_temp_dir = make_temp_dir,
	make_non_tmp_dir = make_non_tmp_dir,
	write_file = write_file,
	touch_file = touch_file,
	rm_dir = rm_dir,
	sleep_sec = sleep_sec,
	_can_stat = _can_stat,
	CAN_STAT = CAN_STAT,
	activation_fixture = activation_fixture,
}
