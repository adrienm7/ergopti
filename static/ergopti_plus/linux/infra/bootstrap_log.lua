--- infra/bootstrap_log.lua

--- ==============================================================================
--- MODULE: Pre-sink Fatal Record (Linux)
--- DESCRIPTION:
--- Appends one line to bootstrap.log in the DEFAULT logs folder for the fatal
--- outcomes that happen before the logger sink can exist: a refused session lock
--- and a refused privacy admission. Windows keeps the same file for the same
--- purpose (a yielding second instance, a refused configuration transition) and
--- macOS keeps launcher.log and a fatal report in the native launcher; the name is
--- declared once in _shared/modules/paths/app_dirs.toml.
---
--- FEATURES & RATIONALE:
--- 1. Closed vocabulary. The privacy policy is not loaded yet, so a free-text
---    message could carry a path or an exception with the account name. Only the
---    codes below are accepted; anything else is refused instead of written.
--- 2. Default folder. LogsDirPath lives in bootstrap storage that has not been
---    read, so the file is always in ${XDG_STATE_HOME:-~/.local/state}/
---    ergopti_plus/logs, like the Windows file.
--- 3. Never fatal itself. The record is best effort: a folder that cannot be
---    created leaves the stderr line (journald under systemd) as the only
---    evidence, and the caller still exits with its own code.
--- 4. Dependency-free. Only infra.config_paths (already needed by the sink) is
---    loaded, so this works before any adapter can.
--- ==============================================================================

local M = {}




-- ===============================
-- ===============================
-- ======= 1/ Vocabulary =========
-- ===============================
-- ===============================

--- The fatal outcomes this record can name.
M.CODES = {
	session_lock_refused = "Session lock refused; daemon not started.",
	privacy_admission_refused = "Privacy initialization refused; daemon not started.",
	second_instance_yielded = "Another daemon owns the session lock; this start yielded.",
}

local AppDirs = require("app_dirs")
local TextUtils = require("text_utils")




-- ===============================
-- ===============================
-- ======= 2/ Writing ============
-- ===============================
-- ===============================

--- Absolute path of the pre-configuration log.
--- @return string
function M.path()
	return require("infra.config_paths").default_logs_dir() .. "/" .. AppDirs.files.bootstrap_log
end

--- Appends one record, creating the default logs folder if needed.
--- @param code string A key of M.CODES.
--- @param opts table|nil { dir = string } explicit folder, for fixtures.
--- @return boolean written
--- @return string|nil reason
function M.append(code, opts)
	local message = M.CODES[code]
	if message == nil then return false, "unknown bootstrap code" end
	local ok, path = pcall(function()
		if opts and opts.dir then return opts.dir .. "/" .. AppDirs.files.bootstrap_log end
		return M.path()
	end)
	if not ok then return false, "default logs folder unresolved" end
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. TextUtils.shell_quote(dir) .. " 2>/dev/null")
	local handle = io.open(path, "a")
	if not handle then return false, "bootstrap log not writable" end
	local wrote = handle:write(os.date("%Y-%m-%d %H:%M:%S"), " [ERROR] [bootstrap] ", message, "\n")
	local closed = handle:close()
	if not wrote or not closed then return false, "bootstrap log write refused" end
	return true
end

return M
