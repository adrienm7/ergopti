--- adapters/reload_breadcrumb.lua

--- ==============================================================================
--- MODULE: Reload Breadcrumb
--- DESCRIPTION:
--- Synchronous trail of the controlled reload's stages, written outside the
--- Logger pipeline so a reload that loses the app still names its last stage.
---
--- FEATURES & RATIONALE:
--- 1. The field run's timed reload of 2026-10-30 21:06 lost the app: the
---    coordinator accepted it, the Karabiner lease revocation was requested,
---    then the day log stopped, no boot followed and no crash report was
---    written. Logger lines are queued in memory and a lost process discards
---    them, so each line here is appended, flushed and closed before the stage
---    continues: the last line is the stage the app was lost in.
--- 2. Stage names and monotonic times only (hs.timer.absoluteTime, which counts
---    from the Mac's boot, so a line of the next process compares with them):
---    never a path, a reason or user text.
--- 3. One reload per file: an accepted reload truncates it, its stages append,
---    an exit that supersedes it keeps appending, and the next boot appends
---    `boot`, which proves one followed. An exit alone writes nothing.
---    tools/dev/collect-macos-field-report.sh copies the file.
--- 4. The default logs folder, whatever LogsDirPath says, like launcher.log:
---    the next boot writes there before any configuration is read.
--- 5. Never in the way: a refused write returns false and logs nothing, since
---    the logger may already be drained when a late stage is written.
--- ==============================================================================

local M = {}

local AppDirs = require("app_dirs")
local LogFolders = require("infra.log_folders")

-- The stage that opens a new trail; every other stage appends to it
M.ACCEPTED = "accepted"

-- The line the next boot appends
M.BOOT = "boot"

-- A boot appends only to a trail at most this long: boots with no reload in
-- between must not grow it without bound
M.TRAIL_MAX_BYTES = 8192

-- Stage names: a closed vocabulary of lower-case words, digits, "_" and "-"
local STAGE_PATTERN = "^[a-z][a-z0-9_%-]*$"
local STAGE_MAX_LENGTH = 64

-- Test seams; production keeps the real file, io.open and the native clock
local _deps = {}

-- Whether this process opened a trail; stages before or without one are not written
local _active = false

--- The trail's absolute path, in the default logs folder the launcher creates.
--- @return string|nil path Nil without a home folder.
function M.path()
	if _deps.path then return _deps.path end
	local folder = LogFolders.default_logs_dir(os.getenv(AppDirs.macos.base_env))
	return folder and (folder .. AppDirs.macos.reload_breadcrumb) or nil
end

--- Nanoseconds since the Mac's boot, as milliseconds with three decimals.
--- @return string stamp
local function stamp()
	local clock = _deps.clock or function() return hs.timer.absoluteTime() end
	local ok, ns = pcall(clock)
	if not ok or type(ns) ~= "number" then return "unknown" end
	return string.format("%.3f", ns / 1e6)
end

--- Writes one line and closes the handle before returning.
--- @param mode string "wb" opens a new trail, "ab" appends.
--- @param stage string Validated stage name.
--- @return boolean written
local function write_line(mode, stage)
	local open = _deps.open or io.open
	local path = M.path()
	if not path then return false end
	local ok, handle = pcall(open, path, mode)
	if not ok or not handle then return false end
	local write_ok = pcall(function()
		assert(handle:write(stage, " ", stamp(), "\n"))
		assert(handle:flush())
	end)
	local close_ok, closed = pcall(function() return handle:close() end)
	return write_ok and close_ok and closed == true
end

--- Rejects a stage name outside the closed vocabulary: a caller bug, never data.
--- @param stage any
local function check_stage(stage)
	if type(stage) ~= "string" or #stage > STAGE_MAX_LENGTH or not stage:match(STAGE_PATTERN) then
		error("reload breadcrumb: invalid stage name " .. tostring(stage), 3)
	end
end

--- Records one stage of a controlled terminal transition. A reload's
--- acceptance opens a new trail; any other stage appends only while one is open.
--- @param kind string|nil The transition's current kind ("reload" or "exit").
--- @param stage string Stage name.
--- @return boolean written
function M.record(kind, stage)
	check_stage(stage)
	if kind == "reload" and stage == M.ACCEPTED then
		_active = write_line("wb", stage)
		return _active
	end
	if not _active then return false end
	return write_line("ab", stage)
end

--- Appends the boot line when a trail exists and is still short.
--- @return boolean written
function M.record_boot()
	local open = _deps.open or io.open
	local path = M.path()
	if not path then return false end
	local ok, handle = pcall(open, path, "rb")
	if not ok or not handle then return false end
	local size_ok, size = pcall(function() return handle:seek("end") end)
	pcall(function() handle:close() end)
	if not size_ok or type(size) ~= "number" or size > M.TRAIL_MAX_BYTES then return false end
	return write_line("ab", M.BOOT)
end

--- Replaces the test seams: path, open and clock.
--- @param deps table|nil Nil restores production behaviour.
function M.configure_for_tests(deps)
	_deps = type(deps) == "table" and deps or {}
	_active = false
end

return M
