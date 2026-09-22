--- infra/diagnostic_snapshot.lua

--- ==============================================================================
--- MODULE: Diagnostic Snapshot Collector (macOS)
--- DESCRIPTION:
--- Gathers the environment facts of the cross-driver diagnostic snapshot
--- (_shared/modules/logger/diagnostic_snapshot.json) and logs them as one INFO
--- line once per session, after boot. Formatting is shared with Linux through
--- _shared/lua/diagnostics/snapshot.lua; the OS probes live in
--- adapters/system_info.lua.
---
--- FEATURES & RATIONALE:
--- 1. Emitted once per Lua state. A second emission would make "which snapshot
---    belongs to this boot" ambiguous in a log that spans reloads.
--- 2. Injectable probes: the tests pass a plain table instead of the adapter.
--- 3. Privacy: environment facts only, the home directory rendered as "~".
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local Snapshot    = require("diagnostics.snapshot")
local FileSystem  = require("adapters.file_system")

M.DRIVER = "macos"

-- Whether this Lua state already logged its snapshot.
local _emitted = false

-- Directory of this file, the start of the git HEAD lookup for source installs.
local SOURCE_DIR = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$")) or "."




-- ====================================
-- ====================================
-- ======= 1/ Collect and emit ========
-- ====================================
-- ====================================

--- Filesystem view used by the commit lookup. read_with_status keeps absent
--- git files silent instead of logging one debug line per probe.
local GIT_FS = {
	exists = function(path) return FileSystem.exists(path) == true end,
	read = function(path)
		local content, status = FileSystem.read_with_status(path)
		if status == "ok" then return content end
		return nil
	end,
}

--- Name of the logger's active level.
--- @return string|nil
local function level_name()
	for name, value in pairs(Logger.LEVELS or {}) do
		if value == Logger.current_level then return name end
	end
	return nil
end

--- Counts enabled/known boolean features in the menu state.
--- @param state table|nil
--- @return number|nil enabled, number|nil total
local function count_features(state)
	if type(state) ~= "table" then return nil, nil end
	local enabled, total = 0, 0
	local function visit(tbl)
		for _, value in pairs(tbl) do
			if type(value) == "boolean" then
				total = total + 1
				if value then enabled = enabled + 1 end
			end
		end
	end
	visit(state)
	if type(state.hotstrings) == "table" then visit(state.hotstrings) end
	return enabled, total
end

--- Builds the snapshot values.
--- @param ctx table { boot_ms, locale, config_dir, state }
--- @param system table|nil Probe table (defaults to adapters/system_info).
--- @return table Field name to raw value.
function M.collect(ctx, system)
	ctx = ctx or {}
	system = system or require("adapters.system_info")
	local scale = system.main_screen_scale()
	local enabled, total = count_features(ctx.state)
	return {
		driver           = M.DRIVER,
		version          = ctx.version,
		commit           = Snapshot.git_commit(ctx.git_fs or GIT_FS, ctx.source_dir or SOURCE_DIR),
		os               = "macOS",
		os_version       = system.os_version(),
		arch             = system.arch(),
		runtime          = system.runtime_version() and ("Hammerspoon " .. system.runtime_version()) or nil,
		elevated         = system.elevated(),
		locale           = ctx.locale,
		keyboard_layout  = system.keyboard_layout(),
		monitors         = system.monitor_count(),
		dpi              = scale and string.format("%gx", scale) or nil,
		display          = "quartz",
		config_dir       = Snapshot.redact_home(ctx.config_dir, system.home()),
		log_level        = level_name(),
		features_enabled = Snapshot.features_ratio(enabled, total),
		boot_ms          = ctx.boot_ms and string.format("%.0f", ctx.boot_ms) or nil,
	}
end

--- Collects and logs the snapshot line, once per Lua state.
--- @param ctx table See M.collect.
--- @param system table|nil Probe override.
--- @return string|nil The logged message, nil when already emitted.
function M.emit_once(ctx, system)
	if _emitted then return nil end
	_emitted = true
	local message = Snapshot.format(M.collect(ctx, system))
	Logger.info(Snapshot.MODULE, "%s", message)
	return message
end

--- Clears the once-per-state latch. Tests only.
function M._reset_for_test()
	_emitted = false
end

return M
