--- infra/config_paths.lua

--- ==============================================================================
--- MODULE: Linux User-Directory Resolver
--- DESCRIPTION:
--- Single source of truth for the user's home, config and data directories,
--- mirroring the macOS infra/paths.lua config helpers.
---
--- WHY THIS EXISTS:
--- Fifteen files derived `$HOME` themselves, across nineteen call sites, with
--- SIX different answers for what to do when it is unset:
---
---     os.getenv("HOME") or "/tmp"          -- crash reporter, updater
---     os.getenv("HOME") or "~"             -- hotstrings, kanata, keylogger…
---     os.getenv("HOME") or ""              -- gestures
---     os.getenv("HOME") or "."             -- logger sink
---     os.getenv("HOME") or "/home/user"    -- five webview bridges
---     os.getenv("HOME") .. "/…"            -- menu_builder: no fallback at all
---
--- Two of those are actively wrong rather than merely inconsistent. The bare
--- concatenation THROWS on a nil HOME, taking the menu build down. And `"~"` is
--- not expanded by io.open — Lua does no tilde expansion — so every path built
--- on that fallback silently addresses a literal directory named `~` in the
--- current folder, creating it on write and reading nothing on load.
---
--- `"/home/user"` deserves its own mention: it is a plausible-looking path that
--- belongs to nobody. Writing a user's personal hotstrings there is worse than
--- failing, because it looks like it worked.
---
--- FEATURES & RATIONALE:
--- 1. ONE policy for a missing HOME, applied everywhere: fall back to TMPDIR (or
---    /tmp). A temp path is honest — it is obviously not the user's home, it is
---    writable, and nothing there is mistaken for durable state.
--- 2. XDG-aware: XDG_CONFIG_HOME, XDG_DATA_HOME and XDG_STATE_HOME (the logs)
---    are honoured where the spec says they should be, so containerised and
---    sandboxed installs work.
--- 3. No tilde, ever. Every path returned is absolute.
--- ==============================================================================

local M = {}

local AppDirs = require("app_dirs")

local CONFIG_DIR_STORAGE_KEY = "paths.config_dir"
-- Bootstrap storage key of the LogsDirPath override, from the shared registry.
local LOGS_DIR_STORAGE_KEY = AppDirs.linux_storage_key




-- =========================================
-- =========================================
-- ======= 1/ Base directories =============
-- =========================================
-- =========================================

--- Returns the configured account home without a temporary-directory fallback.
--- Privacy identity needs the real account root, while file placement can use
--- home()'s existing temporary-directory policy when HOME is absent.
--- @return string|nil Account home, or nil when unavailable.
function M.account_home()
	local home = os.getenv("HOME")
	if type(home) ~= "string" or home == "" then return nil end
	return (home:gsub("/+$", ""))
end

--- The user's home directory.
---
--- When HOME is unset — a bare systemd unit, a container without a passwd entry
--- — the answer is a temp directory rather than a guess. `"~"` would be taken
--- literally by io.open, and `"/home/user"` is somebody else's path.
--- @return string Absolute path, no trailing slash.
function M.home()
	local home = M.account_home()
	if home ~= nil then return home end
	local tmp = os.getenv("TMPDIR")
	if type(tmp) == "string" and tmp ~= "" then
		return (tmp:gsub("/+$", ""))
	end
	return "/tmp"
end

--- The XDG config root ($XDG_CONFIG_HOME, or ~/.config).
--- @return string Absolute path, no trailing slash.
function M.config_home()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if type(xdg) == "string" and xdg ~= "" then
		return (xdg:gsub("/+$", ""))
	end
	return M.home() .. "/.config"
end

--- The XDG data root ($XDG_DATA_HOME, or ~/.local/share).
--- @return string Absolute path, no trailing slash.
function M.data_home()
	local xdg = os.getenv("XDG_DATA_HOME")
	if type(xdg) == "string" and xdg ~= "" then
		return (xdg:gsub("/+$", ""))
	end
	return M.home() .. "/.local/share"
end

--- The default driver configuration directory, without a user override.
--- @return string Absolute path, no trailing slash.
function M.default_config_dir()
	return M.config_home() .. "/ergopti"
end

--- The effective driver configuration directory.
---
--- The override lives in the bootstrap storage, whose own location depends only
--- on config_home(). It therefore remains discoverable after the directory it
--- points at changes and cannot recurse through M.config().
--- @return string Absolute path, no trailing slash.
function M.get_config_dir()
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or type(Storage) ~= "table" or type(Storage.get) ~= "function" then
		return M.default_config_dir()
	end
	local configured = Storage.get(CONFIG_DIR_STORAGE_KEY, nil)
	if type(configured) ~= "string" or configured:sub(1, 1) ~= "/" then
		return M.default_config_dir()
	end
	configured = configured:gsub("/+$", "")
	return configured ~= "" and configured or M.default_config_dir()
end

--- Persists a configuration-directory override.
--- @param path string Empty/default resets the override; custom paths must be absolute.
--- @return boolean True only when bootstrap storage confirms the mutation.
function M.set_config_dir(path)
	if type(path) ~= "string" then return false end
	local normalized = path:gsub("/+$", "")
	if normalized ~= "" and normalized:sub(1, 1) ~= "/" then return false end

	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or type(Storage) ~= "table" then return false end
	if normalized == "" or normalized == M.default_config_dir() then
		return type(Storage.delete) == "function"
			and Storage.delete(CONFIG_DIR_STORAGE_KEY) == true
	end
	return type(Storage.set) == "function"
		and Storage.set(CONFIG_DIR_STORAGE_KEY, normalized) == true
end




-- =========================================
-- =========================================
-- ======= 2/ Driver directories ===========
-- =========================================
-- =========================================

--- The driver's config directory, optionally with a path appended.
--- @param rel string|nil Path relative to the driver config dir.
--- @return string Absolute path, no trailing slash.
function M.config(rel)
	local base = M.get_config_dir()
	if type(rel) ~= "string" or rel == "" then return base end
	return (base .. "/" .. (rel:gsub("^/+", "")))
end

--- The driver's data directory, optionally with a path appended.
--- @param rel string|nil Path relative to the driver data dir.
--- @return string Absolute path, no trailing slash.
function M.data(rel)
	local base = M.data_home() .. "/ergopti"
	if type(rel) ~= "string" or rel == "" then return base end
	return (base .. "/" .. (rel:gsub("^/+", "")))
end

--- The keylogger's metrics store. It lives in the data directory, so it does not
--- move with the configuration directory; the onboarding consent text and the
--- keylogger both read it here so they cannot name different files.
--- @return string Absolute path of metrics.sqlite.
function M.metrics_path()
	return M.data("metrics.sqlite")
end




-- =========================================
-- =========================================
-- ======= 3/ Logs directory ===============
-- =========================================
-- =========================================

--- The XDG state root ($XDG_STATE_HOME, or ~/.local/state): logs are state.
--- @return string Absolute path, no trailing slash.
function M.state_home()
	local xdg = os.getenv(AppDirs.linux.base_env)
	if type(xdg) == "string" and xdg ~= "" then
		return (xdg:gsub("/+$", ""))
	end
	return M.home() .. "/" .. AppDirs.linux.base_fallback
end

--- The default logs folder, ${XDG_STATE_HOME:-~/.local/state}/ergopti_plus/logs.
--- @return string Absolute path, no trailing slash.
function M.default_logs_dir()
	return M.state_home() .. "/" .. AppDirs.linux.relative
end

--- Validates a logs-folder override and makes it a folder the application
--- owns: the default folder, or one whose last component is the application
--- folder name. Anything else gets that subfolder appended, so retention never
--- deletes in a folder the user merely picked.
--- @param path any Candidate override.
--- @return string|nil normalized Absolute path without trailing slash, or "".
--- @return string|nil error_message
function M.normalize_logs_dir(path)
	if type(path) ~= "string" then return nil, "the logs folder must be a string" end
	local normalized = path:gsub("/+$", "")
	if normalized == "" then return "" end
	if normalized:sub(1, 1) ~= "/" then
		return nil, "the logs folder must be an absolute path"
	end
	if normalized ~= M.default_logs_dir() and normalized:match("([^/]+)$") ~= AppDirs.folder_name then
		normalized = normalized .. "/" .. AppDirs.folder_name
	end
	return normalized
end

--- The effective logs folder: the LogsDirPath override from bootstrap storage,
--- or the default. Resolved per call, like the configuration folder, so a
--- reload after the path editor saved a new folder needs no other hand-off.
--- @return string Absolute path, no trailing slash.
function M.get_logs_dir()
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or type(Storage) ~= "table" or type(Storage.get) ~= "function" then
		return M.default_logs_dir()
	end
	local configured = Storage.get(LOGS_DIR_STORAGE_KEY, nil)
	local normalized = type(configured) == "string" and M.normalize_logs_dir(configured) or nil
	if type(normalized) ~= "string" or normalized == "" then return M.default_logs_dir() end
	return normalized
end

--- Persists a logs-folder override.
--- @param path string Empty/default resets the override; a custom folder must be absolute.
--- @return boolean True only when bootstrap storage confirms the mutation.
--- @return string|nil error_message Why a folder was refused.
function M.set_logs_dir(path)
	local normalized, err = M.normalize_logs_dir(path)
	if normalized == nil then return false, err end
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or type(Storage) ~= "table" then return false, "bootstrap storage is unavailable" end
	if normalized == "" or normalized == M.default_logs_dir() then
		return type(Storage.delete) == "function"
			and Storage.delete(LOGS_DIR_STORAGE_KEY) == true
	end
	return type(Storage.set) == "function"
		and Storage.set(LOGS_DIR_STORAGE_KEY, normalized) == true
end

return M
