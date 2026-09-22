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

M.DRIVER = "macos"

-- Log tag of the unknown-commit warning. Not Snapshot.MODULE: that tag is the
-- cross-driver grep key for the single snapshot line.
local COMMIT_LOG = "BuildCommit"

-- Whether this Lua state already logged its snapshot.
local _emitted = false

-- Directory of this file, the start of the git HEAD lookup for source installs.
local SOURCE_DIR = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$")) or "."




-- ====================================
-- ====================================
-- ======= 1/ Collect and emit ========
-- ====================================
-- ====================================

--- Filesystem view used by the commit lookup. read_with_status keeps an absent
--- build stamp or git file silent instead of logging one debug line per probe.
--- The adapter is looked up per call: the crash reporter reaches this module
--- late, and a reference bound at first load would outlive the adapter it named.
local GIT_FS = {
	exists = function(path) return require("adapters.file_system").exists(path) == true end,
	read = function(path)
		local content, status = require("adapters.file_system").read_with_status(path)
		if status == "ok" then return content end
		return nil
	end,
}

--- Resolves the commit this driver was built from: the package build stamp in
--- the shared tree, else the git checkout a source run lives in, else "unknown"
--- with the reason logged. The single resolver behind the snapshot, the
--- healthcheck and the crash report, so the three can never disagree.
--- @param opts table|nil { fs, shared_root, source_dir } overrides for tests.
--- @return string commit Abbreviated commit id or Snapshot.UNKNOWN.
--- @return string source One of the Snapshot.COMMIT_SOURCE_* values.
function M.resolve_commit(opts)
	opts = opts or {}
	local shared_root = opts.shared_root
	if shared_root == nil then shared_root = require("infra.paths").shared_root() end
	local commit, source, detail = Snapshot.resolve_commit(opts.fs or GIT_FS, shared_root,
		opts.source_dir or SOURCE_DIR)
	if source == Snapshot.COMMIT_SOURCE_UNKNOWN then
		Logger.warn(COMMIT_LOG, "Build commit unknown: %s.", tostring(detail))
	end
	return commit, source
end

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
--- @param ctx table { boot_ms, locale, config_dir, state, git_fs, shared_root, source_dir }
--- @param system table|nil Probe table (defaults to adapters/system_info).
--- @return table Field name to raw value.
function M.collect(ctx, system)
	ctx = ctx or {}
	system = system or require("adapters.system_info")
	local scale = system.main_screen_scale()
	local enabled, total = count_features(ctx.state)
	local commit = M.resolve_commit({
		fs = ctx.git_fs, shared_root = ctx.shared_root, source_dir = ctx.source_dir,
	})
	return {
		driver           = M.DRIVER,
		version          = ctx.version,
		commit           = commit,
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
