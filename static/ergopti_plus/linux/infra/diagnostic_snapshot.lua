--- infra/diagnostic_snapshot.lua

--- ==============================================================================
--- MODULE: Diagnostic Snapshot Collector (Linux)
--- DESCRIPTION:
--- Gathers the environment facts of the cross-driver diagnostic snapshot
--- (_shared/modules/logger/diagnostic_snapshot.json) and logs them as one INFO
--- line once the daemon is ready. Formatting is shared with macOS through
--- _shared/lua/diagnostics/snapshot.lua; only the probes live here.
---
--- FEATURES & RATIONALE:
--- 1. No subprocess on the boot path: every fact comes from /proc, /etc and the
---    already-initialised modules, so the snapshot costs a few file reads.
--- 2. Injectable reads: the tests drive the real collector against fixture
---    files instead of asserting on its source.
--- 3. Unknown is an answer: monitors and DPI have no probe that does not need a
---    display client, so they report "unknown" rather than a guessed number.
--- ==============================================================================

local M = {}

local Logger        = require("logger.shim")
local Snapshot      = require("diagnostics.snapshot")
local Version       = require("infra.version")
local ConfigPaths   = require("infra.config_paths")
local Paths         = require("infra.paths")
local DisplayServer = require("infra.display_server")

M.DRIVER = "linux"

-- Log tag of the unknown-commit warning. Not Snapshot.MODULE: that tag is the
-- cross-driver grep key for the single snapshot line.
local COMMIT_LOG = "BuildCommit"




-- =================================
-- =================================
-- ======= 1/ System probes ========
-- =================================
-- =================================

--- Reads a whole file quietly: a missing file is an expected answer here, not
--- an event worth a debug line per probe.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Default probe environment.
--- @return table
local function default_env()
	return {
		read = read_file,
		exists = function(path)
			local fh = io.open(path, "r")
			if fh then fh:close() return true end
			return false
		end,
	}
end

--- Extracts one KEY=value entry from /etc/os-release, unquoting it.
--- @param text string|nil
--- @param key string
--- @return string|nil
local function os_release_value(text, key)
	if type(text) ~= "string" then return nil end
	for line in text:gmatch("[^\n]+") do
		local k, v = line:match("^([%u_]+)=(.*)$")
		if k == key then return (v:gsub('^"(.*)"$', "%1")) end
	end
	return nil
end

--- Reports whether the process runs with an effective uid of 0.
--- @param status string|nil Content of /proc/self/status.
--- @return string|nil "true", "false" or nil when unknown.
local function elevated_from_status(status)
	if type(status) ~= "string" then return nil end
	local _, effective = status:match("\nUid:%s+(%d+)%s+(%d+)")
	if not effective then return nil end
	return tostring(effective == "0")
end




-- ====================================
-- ====================================
-- ======= 2/ Collect and emit ========
-- ====================================
-- ====================================

--- Resolves the commit this daemon was built from: the package build stamp in
--- the shared tree (.deb, .rpm, AppImage, Flatpak, tarball), else the git
--- checkout a source run lives in, else "unknown" with the reason logged. The
--- single resolver behind the snapshot, the healthcheck and the crash dump.
--- @param opts table|nil { env, shared_root, source_dir } overrides for tests.
--- @return string commit Abbreviated commit id or Snapshot.UNKNOWN.
--- @return string source One of the Snapshot.COMMIT_SOURCE_* values.
function M.resolve_commit(opts)
	opts = opts or {}
	local shared_root = opts.shared_root
	if shared_root == nil then shared_root = Paths.shared_root() end
	local commit, source, detail = Snapshot.resolve_commit(opts.env or default_env(), shared_root,
		opts.source_dir or Paths.driver_root())
	if source == Snapshot.COMMIT_SOURCE_UNKNOWN then
		Logger.warn(COMMIT_LOG, "Build commit unknown: %s.", tostring(detail))
	end
	return commit, source
end

--- The daemon's process id, read from /proc so no subprocess is needed.
--- @param env table|nil Probe override.
--- @return string|nil
function M.pid(env)
	local stat = (env or default_env()).read("/proc/self/stat")
	return type(stat) == "string" and stat:match("^(%d+)") or nil
end

--- Builds the snapshot values.
--- @param ctx table { script_dir, shared_root, boot_ms, locale, keyboard_layout,
---   log_level, features_enabled, features_total }
--- @param env table|nil { read = fn(path), exists = fn(path) } probe override.
--- @return table Field name to raw value.
function M.collect(ctx, env)
	ctx = ctx or {}
	env = env or default_env()
	local os_release = env.read("/etc/os-release")
	local kernel = env.read("/proc/sys/kernel/osrelease")
	kernel = type(kernel) == "string" and kernel:match("^%s*(.-)%s*$") or nil
	local version_id = os_release_value(os_release, "VERSION_ID")
	local os_version = version_id
	if kernel and kernel ~= "" then
		os_version = (version_id and (version_id .. " ") or "") .. "kernel " .. kernel
	end
	local arch = (jit and jit.arch) or nil
	if not arch then
		local probed = env.read("/proc/sys/kernel/arch")
		arch = type(probed) == "string" and probed:match("^%s*(.-)%s*$") or nil
	end
	local desktop = DisplayServer.desktop()
	local display = DisplayServer.kind() .. ((desktop ~= "") and (" " .. desktop) or "")
	return {
		driver           = M.DRIVER,
		version          = Version.VERSION,
		commit           = (M.resolve_commit({
			env = env, shared_root = ctx.shared_root, source_dir = ctx.script_dir,
		})),
		os               = os_release_value(os_release, "NAME"),
		os_version       = os_version,
		arch             = arch,
		runtime          = (jit and jit.version) or _VERSION,
		elevated         = elevated_from_status(env.read("/proc/self/status")),
		locale           = ctx.locale,
		keyboard_layout  = ctx.keyboard_layout,
		monitors         = nil,
		dpi              = nil,
		display          = display,
		config_dir       = Snapshot.redact_home(ConfigPaths.get_config_dir(), ConfigPaths.home()),
		log_level        = ctx.log_level,
		features_enabled = Snapshot.features_ratio(ctx.features_enabled, ctx.features_total),
		boot_ms          = ctx.boot_ms and string.format("%.0f", ctx.boot_ms) or nil,
	}
end

--- Collects and logs the snapshot line.
--- @param ctx table See M.collect.
--- @param env table|nil Probe override.
--- @return string The logged message.
function M.emit(ctx, env)
	local message = Snapshot.format(M.collect(ctx, env))
	Logger.info(Snapshot.MODULE, "%s", message)
	return message
end

return M
