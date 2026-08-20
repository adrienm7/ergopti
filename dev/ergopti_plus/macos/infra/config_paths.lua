--- infra/config_paths.lua

--- ==============================================================================
--- MODULE: Config Path Resolution
--- DESCRIPTION:
--- Resolves the single machine-specific configuration directory and every
--- personal file derived from it, and owns the paths.toml bootstrap that stores
--- the user's override.
---
--- FEATURES & RATIONALE:
--- 1. It lives in infra/ because infra/ depends on it. personal_hotstrings.lua
---    and personal_shortcuts.lua both resolve their file through get(key), and
---    while this code sat in ui/menu/ that made the infrastructure layer import
---    the menu — a dependency pointing exactly the wrong way, and one that made
---    the resolver unreachable from anything that must not draw a UI.
--- 2. ONE writer of paths.toml. Two lived here before, in two files: the
---    onboarding wizard's persist_config_dir_for_wizard and the path editor's
---    apply_and_reload, near-duplicates that differed in whether they reloaded
---    and in how they treated a value equal to the default. set_config_dir is
---    the single writer; whether to reload afterwards is the caller's business,
---    which is the actual difference between those two.
--- 3. Resolution works BEFORE init(). Modules requiring this during their own
---    load — keylogger's init IIFE among them — must still get the
---    user-configured directory, so the default is computed at module load and
---    paths.toml is lazy-read on first use. A packaged launch exports its stable
---    user-writable bootstrap path; source-tree launches retain the adjacent
---    development file. init() only overrides the base directory and creates
---    what is missing.
--- 4. The failure mode this file exists to avoid is not a crash. A wrong-depth
---    path resolves to a directory that EXISTS and holds nothing, the write
---    succeeds against the wrong place, and nothing is logged. Five separate
---    bugs of that shape are recorded in this repo, which is why
---    tests/unit/ui/test_menu_paths_resolution_matrix.lua stats every answer
---    rather than comparing strings.
--- ==============================================================================

local M = {}
local hs         = hs
local Logger     = require("infra.logger")
local text_utils = require("infra.text_utils")
local FileSystem = require("adapters.file_system")
local LOG        = "config_paths"





-- ====================================
-- ====================================
-- ======= 1/ Constants + state =======
-- ====================================
-- ====================================






-- Bootstrap filename. In source-tree mode it remains next to init.lua
-- (gitignored); the packaged launcher exports a stable user-writable path because
-- its init.lua lives inside the signed application resources.
local PATHS_FILENAME = "paths.toml"

-- Exact path exported by the native packaged launcher. Ignore a missing,
-- relative, or empty inherited value so standalone Hammerspoon development keeps
-- using the source-adjacent bootstrap and never writes through an ambiguous cwd.
local MANAGED_PATHS_ENV = "ERGOPTI_PATHS_FILE"
local _managed_paths_file = os.getenv(MANAGED_PATHS_ENV)
if type(_managed_paths_file) ~= "string"
		or _managed_paths_file == ""
		or _managed_paths_file:sub(1, 1) ~= "/" then
	_managed_paths_file = nil
end

-- The single key stored in paths.toml.
local CONFIG_DIR_KEY = "ConfigDirPath"

-- Driver root — derived at module-load time so standalone source-tree launches
-- can read their adjacent paths.toml before M.init(). M.init() may override it.
local _src      = debug.getinfo(1, "S").source:sub(2)
local _base_dir = (_src:match("^(.*[/\\])") or "./"):gsub("infra[/\\]$", "")

-- Computed at module load, not in init(), for the same reason: anything written
-- under the config dir must land outside the source tree by construction, even
-- for a consumer that required this module before init() ran.
local _default_config_dir = (function()
	local home = os.getenv("HOME")
	if type(home) == "string" and home ~= "" then
		return home .. "/.config/ergopti_plus/"
	end
	return nil
end)()

-- In-memory cache: { ConfigDirPath = "..." } or {}; nil = not yet loaded.
local _bootstrap = nil
local _bootstrap_status = nil
local _bootstrap_snapshot = nil

-- Module-load path discovery lets early consumers resolve read-only paths, but
-- it is not lifecycle initialization. Only M.init() may publish this sentinel.
local _initialized = false

-- Directories already ensured this session. get("ConfigTomlPath") runs through
-- file_in_driver_subdir on EVERY save_prefs() — i.e. on every menu toggle, on
-- the run loop that services the typing event tap — and used to fork /bin/sh for
-- a directory that exists from the first boot onwards.
local _ensured_dirs = {}





-- ====================================
-- ====================================
-- ======= 2/ Bootstrap helpers =======
-- ====================================
-- ====================================






--- Returns the absolute path to paths.toml.
--- @return string
local function paths_file()
	return _managed_paths_file or ((_base_dir or "") .. PATHS_FILENAME)
end

--- Returns the legacy source-adjacent bootstrap path. Packaged builds prior to
--- the managed-path contract could leave an override here when run from a
--- writable location; it is read once for migration, never preferred for writes.
--- @return string
local function legacy_paths_file()
	return (_base_dir or "") .. PATHS_FILENAME
end

--- Parses a simple flat TOML file (key = "value" pairs, ignoring comments).
--- @param content string Raw file content.
--- @return table Parsed key-value map.
local function parse_toml(content)
	local result = {}
	for line in content:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
			local key, val = trimmed:match('^(%S+)%s*=%s*"(.*)"$')
			if key then result[key] = val end
		end
	end
	return result
end

--- Reads and parses one bootstrap file.
--- @param path string Absolute paths.toml path.
--- @return table|nil bootstrap Parsed table.
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail
--- @return string|nil raw Exact source bytes when status is `ok`.
local function read_bootstrap(path)
	local raw, status, detail = FileSystem.read_with_status(path)
	if status ~= "ok" then return nil, status, detail end
	return parse_toml(raw), "ok", nil, raw
end

--- Loads the primary bootstrap, falling back to the adjacent legacy file only
--- when a packaged launcher selected a different stable path.
--- @return table|nil bootstrap
--- @return string|nil source_path
--- @return string status
--- @return string|nil detail
--- @return table|nil target_snapshot Exact state of the primary write target.
local function load_bootstrap()
	local primary = paths_file()
	local parsed, status, detail, raw = read_bootstrap(primary)
	if status == "ok" then
		return parsed, primary, "ok", nil, { status = "ok", content = raw }
	end
	if status == "error" then return nil, primary, "error", detail end

	local legacy = legacy_paths_file()
	if _managed_paths_file and legacy ~= primary then
		parsed, status, detail = read_bootstrap(legacy)
		if status == "ok" then
			return parsed, legacy, "ok", nil, { status = "absent" }
		end
		if status == "error" then return nil, legacy, "error", detail end
	end
	return nil, nil, "absent", nil, { status = "absent" }
end

--- Returns the resolved config directory (with trailing slash).
--- Falls back to ~/.config/ergopti_plus/ when no override is set. Lazy-loads
--- paths.toml on first call so that modules requiring this before init() still
--- get the user-configured path.
--- @return string
local function config_dir()
	if _bootstrap == nil then
		local loaded, _, status, _, snapshot = load_bootstrap()
		_bootstrap = loaded or {}
		_bootstrap_status = status
		_bootstrap_snapshot = snapshot
	end
	local v = _bootstrap[CONFIG_DIR_KEY]
	if type(v) == "string" and v ~= "" then return v end
	return _default_config_dir or _base_dir or ""
end

--- Ensures a directory exists (idempotent), creating parents as needed.
--- Memoised per session; prefers the in-process hs.fs API over a shell fork.
--- @param path string Absolute path with trailing slash.
--- @return boolean ensured True only when the directory exists after the call.
local function ensure_dir(path)
	if not path or path == "" then return false end
	if _ensured_dirs[path] then return true end

	-- hs.fs.mkdir creates a single level only, so walk the ancestors first to
	-- reproduce "mkdir -p" without leaving the process.
	local made = false
	if hs.fs and type(hs.fs.mkdir) == "function" then
		made = true
		local prefix = path:match("^[/\\]") and path:sub(1, 1) or ""
		local rest   = path:sub(#prefix + 1)
		local current = prefix
		for segment in rest:gmatch("[^/\\]+") do
			current = current .. segment .. "/"
			local ok_attr, attr = pcall(hs.fs.attributes, current)
			if not (ok_attr and attr) then
				-- hs.fs.mkdir follows LuaFileSystem semantics: it RETURNS nil plus an
				-- error and does not raise, so the pcall status alone reports success
				-- for a create that never happened.
				local ok_mk, created = pcall(hs.fs.mkdir, current)
				if not ok_mk or not created then
					made = false
					break
				end
			end
		end
	end

	-- Only fall back to the subprocess when the filesystem API is unavailable or
	-- refused the create; the shell path stays correct but is no longer the norm.
	if not made then
		pcall(hs.execute, "mkdir -p " .. text_utils.shell_quote(path))
	end

	-- Memoise only a directory that now genuinely exists. A refused create is
	-- usually transient (volume still mounting, TCC access not yet granted), and
	-- remembering the failure would skip every later attempt — leaving the config
	-- directory missing for the whole session while every save silently no-ops.
	local ok_final, final_attr = pcall(hs.fs.attributes, path)
	if ok_final and final_attr then
		_ensured_dirs[path] = true
		return true
	else
		Logger.warn(LOG, "Could not create '%s' — not memoised, will retry on next use.", path)
		return false
	end
end

--- Serializes the bootstrap table to TOML.
--- The header mirrors the AutoHotkey driver's paths.toml so the two driver
--- bootstrap files stay visually identical, and is intentionally English — this
--- file is developer-facing (gitignored, manually edited when relocating the
--- config dir), not user-facing.
--- @return string
local function serialize_toml()
	local default_dir = _default_config_dir ~= "" and _default_config_dir
		or "~/.config/ergopti_plus/"
	local lines = { "# Custom paths — auto-generated by ErgoptiPlus." }
	lines[#lines + 1] = "# Edit this file to point to your personal configuration folder."
	lines[#lines + 1] = string.format(
		"# If absent or commented out, files are looked up in: %s",
		default_dir
	)
	lines[#lines + 1] = ""
	local v = _bootstrap[CONFIG_DIR_KEY]
	if type(v) == "string" and v ~= "" then
		lines[#lines + 1] = string.format('%s = "%s"', CONFIG_DIR_KEY, v)
	else
		lines[#lines + 1] = string.format('# %s = "%s"', CONFIG_DIR_KEY, default_dir)
	end
	lines[#lines + 1] = ""
	return table.concat(lines, "\n")
end

--- Replaces one file atomically on macOS. The Windows branch exists solely for
--- the portable Lua suite, whose CRT cannot rename over an existing target; it
--- keeps a rollback copy so even that fallback preserves the old file on error.
--- @param temporary string Complete sibling temporary file.
--- @param target string Final paths.toml file.
--- @return boolean replaced
--- @return string|nil err
local function replace_file(temporary, target)
	local ok_rename, renamed, rename_err = pcall(os.rename, temporary, target)
	if ok_rename and renamed then return true end
	local first_err = ok_rename and rename_err or renamed

	if package.config:sub(1, 1) ~= "\\" then
		return false, tostring(first_err or "rename failed")
	end

	local backup = target .. ".bak"
	pcall(os.remove, backup)
	local old_moved = os.rename(target, backup)
	local new_moved, new_err = os.rename(temporary, target)
	if new_moved then
		if old_moved then pcall(os.remove, backup) end
		return true
	end
	if old_moved then pcall(os.rename, backup, target) end
	return false, tostring(new_err or first_err or "rename failed")
end

--- Persists the current _bootstrap table to disk as TOML.
--- @return boolean saved True only after write, close, and atomic publish.
--- @return string|nil err Concrete I/O reason on failure.
local function save_bootstrap()
	local content = serialize_toml()
	local target = paths_file()
	local replaced = false
	local write_error = nil
	if type(_bootstrap_snapshot) ~= "table" then
		return false, "paths.toml source snapshot is unavailable"
	end
	if _bootstrap_snapshot.status == "absent" then
		local created, create_status, create_detail = FileSystem.create_if_absent(target, content)
		replaced = created == true
		if create_status == "exists" then
			return false, "paths.toml appeared concurrently"
		end
		write_error = create_detail or "create-only publication failed"
	else
		replaced, write_error = FileSystem.write_if_unchanged(
			target,
			content,
			_bootstrap_snapshot
		)
	end
	if not replaced then
		Logger.error(LOG, "Cannot publish paths file '%s'.", target)
		return false, write_error or "atomic write failed"
	end

	_bootstrap_status = "ok"
	_bootstrap_snapshot = { status = "ok", content = content }
	Logger.info(LOG, "Paths saved to '%s'.", target)
	return true
end

--- Adopts a target that demonstrably diverged from the snapshot used by the
--- refused transaction. An ordinary I/O failure against unchanged bytes keeps
--- the caller's in-memory rollback instead of fabricating a concurrent edit.
--- @return boolean adopted
local function adopt_changed_bootstrap_target()
	local expected = _bootstrap_snapshot
	if type(expected) ~= "table" then return false end
	local parsed, status, _, raw = read_bootstrap(paths_file())
	if status ~= "ok" and status ~= "absent" then return false end
	local changed = status ~= expected.status
		or (status == "ok" and raw ~= expected.content)
	if not changed then return false end
	if status == "ok" then
		_bootstrap = parsed
		_bootstrap_status = "ok"
		_bootstrap_snapshot = { status = "ok", content = raw }
	else
		_bootstrap = {}
		_bootstrap_status = "absent"
		_bootstrap_snapshot = { status = "absent" }
	end
	return true
end





-- ==================================
-- ==================================
-- ======= 3/ Derived paths =========






--- Absolute path for a SHARED personal file at the root of config_dir(), readable
--- by either driver (hotstrings TOML, personal info).
--- @param filename string Bare filename (e.g. "personal_hotstrings.toml").
--- @return string
local function file_in_config(filename)
	local d = config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	return d .. filename
end

--- Absolute path for a HS-specific file under the ``hammerspoon/`` subfolder of
--- config_dir(). Used for files whose semantics differ from the AHK side
--- (config.toml with macOS bundle IDs, the Mac-only remap config…). The subfolder
--- is auto-created on first call so callers need not guard ENOENT.
--- @param filename string Bare filename inside the hammerspoon/ folder.
--- @return string
local function file_in_driver_subdir(filename)
	local d = config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	local sub = d .. "hammerspoon/"
	ensure_dir(sub)
	return sub .. filename
end

--- Absolute path to the user's personal hotstrings folder, auto-created on first
--- access so callers need not guard ENOENT.
--- @return string Absolute path with trailing slash.
local function personal_hotstrings_dir()
	local d = config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	local p = d .. "hotstrings/"
	ensure_dir(p)
	-- Bootstrap an empty personal_hotstrings.toml on first use so the user always
	-- has a file to open rather than a confusing ENOENT.
	local toml_path = p .. "personal_hotstrings.toml"
	local _, read_status = FileSystem.read_with_status(toml_path)
	if read_status == "absent" then
		local _, create_status = FileSystem.create_if_absent(toml_path, "")
		if create_status ~= "created" and create_status ~= "exists" then
			Logger.error(LOG, "Personal hotstrings baseline did not commit.")
		end
	elseif read_status ~= "ok" then
		Logger.error(LOG, "Personal hotstrings path could not be read; baseline creation refused "
			.. "(failure content withheld).")
	end
	return p
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================






--- Initializes the module with the driver base directory.
--- @param base_dir string Absolute path to the driver directory (trailing slash).
function M.init(base_dir)
	Logger.start(LOG, "Initializing config paths…")
	if type(base_dir) ~= "string" or base_dir == "" then
		Logger.error(LOG, "M.init(): base_dir must be a non-empty string — module non-functional.")
		return false
	end
	if _initialized then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return false
	end
	_base_dir = base_dir
	ensure_dir(_base_dir)
	if _managed_paths_file then
		ensure_dir(paths_file():match("^(.*[/\\])") or "")
	end

	-- Read paths.toml, migrating an adjacent legacy override when present, or
	-- creating a commented template when neither location exists.
	local loaded, source_path, load_status, load_detail, source_snapshot = load_bootstrap()
	if load_status == "error" then
		_bootstrap = {}
		_bootstrap_status = "error"
		_bootstrap_snapshot = nil
		Logger.error(LOG, "paths.toml is unreadable or malformed; default publication refused (%s).",
			tostring(load_detail))
		return false
	elseif load_status == "absent" then
		Logger.info(LOG, "paths.toml not found — generating with defaults at '%s'.", paths_file())
		_bootstrap = {}
		local initial_content = serialize_toml()
		local _, create_status, create_detail = FileSystem.create_if_absent(paths_file(), initial_content)
		if create_status == "exists" then
			loaded, _, load_status, load_detail, source_snapshot = load_bootstrap()
			if load_status ~= "ok" then
				Logger.error(LOG, "Concurrent paths.toml publication could not be loaded (%s).",
					tostring(load_detail))
				return false
			end
			_bootstrap = loaded
			_bootstrap_snapshot = source_snapshot
		elseif create_status ~= "created" then
			Logger.error(LOG, "paths.toml default publication failed (%s).", tostring(create_detail))
			return false
		else
			_bootstrap_snapshot = { status = "ok", content = initial_content }
		end
		_bootstrap_status = "ok"
	else
		_bootstrap = loaded
		_bootstrap_status = "ok"
		_bootstrap_snapshot = source_snapshot
		if source_path ~= paths_file() then
			Logger.info(LOG, "Migrating paths from '%s' to '%s'.", source_path, paths_file())
			local migrated_content = serialize_toml()
			local _, create_status, create_detail = FileSystem.create_if_absent(
				paths_file(),
				migrated_content
			)
			if create_status == "exists" then
				local concurrent, concurrent_source, concurrent_status, concurrent_detail,
					concurrent_snapshot = load_bootstrap()
				if concurrent_status ~= "ok" then
					Logger.error(LOG, "Concurrent paths.toml migration target could not be loaded (%s).",
						tostring(concurrent_detail))
					return false
				end
				_bootstrap = concurrent
				_bootstrap_snapshot = concurrent_snapshot
			elseif create_status ~= "created" then
				Logger.error(LOG, "paths.toml migration failed (%s).", tostring(create_detail))
				return false
			else
				_bootstrap_snapshot = { status = "ok", content = migrated_content }
			end
		else
			Logger.debug(LOG, "Paths loaded from '%s'.", source_path)
		end
	end

	-- Only create the default fallback directory when no custom path is
	-- configured; otherwise the user ends up with an unwanted
	-- ~/.config/ergopti_plus/ on every reload.
	local resolved = config_dir()
	if resolved == _default_config_dir then ensure_dir(_default_config_dir) end
	_initialized = true
	Logger.success(LOG, "Config paths initialized (base: '%s', config: '%s').", base_dir, resolved)
	return true
end

--- True when M.init() has already run.
--- @return boolean
function M.is_initialized()
	return _initialized
end

--- Resolves a well-known personal file by name.
--- @param key string One of: "PersonalTomlPath", "PersonalInfoTomlPath",
---   "HotstringsDirPath", "PersonalHotstringsDir", "ConfigTomlPath",
---   "KarabinerConfigPath", "PersonalShortcutsLuaPath".
--- @return string The resolved absolute path, or "" for an unknown key.
function M.get(key)
	-- Shared at the root of config_dir (both drivers may read these):
	if key == "PersonalTomlPath"      then return personal_hotstrings_dir() .. "personal_hotstrings.toml" end
	if key == "PersonalInfoTomlPath"  then return file_in_config("personal_info.toml")                    end
	if key == "HotstringsDirPath"     then return config_dir()                                            end
	if key == "PersonalHotstringsDir" then return personal_hotstrings_dir()                               end
	-- Hammerspoon-specific (under <config_dir>/hammerspoon/):
	if key == "ConfigTomlPath"           then return file_in_driver_subdir("config.toml")               end
	if key == "KarabinerConfigPath"      then return file_in_driver_subdir("config_karabiner.toml")     end
	if key == "PersonalShortcutsLuaPath" then return file_in_driver_subdir("personal_shortcuts.lua")   end
	return ""
end

--- Current config directory (with trailing slash).
--- @return string
function M.get_config_dir()
	return config_dir()
end

--- The OS-default config directory (with trailing slash). Used by the onboarding
--- wizard to pre-fill the form and to detect "user kept the default", so a
--- redundant override is not written to paths.toml.
--- @return string
function M.get_default_config_dir()
	return _default_config_dir or _base_dir or ""
end

--- Persists a new config directory to paths.toml. THE single writer.
---
--- Whether to reload afterwards is the caller's decision and the only real
--- difference between the two writers this replaces: the path editor reloads so
--- every module picks up the new location, while the onboarding wizard must NOT
--- — it writes config.toml right after and reloads once at the end, and a reload
--- here would restart the script mid-wizard and lose the remaining answers.
--- @param new_dir string|nil Absolute path (trailing slash optional), or "" / nil
---                           to mean "use the OS default".
--- @return boolean changed True when the stored value actually moved.
function M.set_config_dir(new_dir)
	if _bootstrap_status == "error" then
		return false, "paths.toml is unreadable or malformed"
	end
	if type(new_dir) ~= "string" then new_dir = "" end
	if new_dir ~= "" and not new_dir:match("[/\\]$") then new_dir = new_dir .. "/" end

	local old_dir = config_dir()
	local old_override = _bootstrap[CONFIG_DIR_KEY]
	-- An empty path or one equal to the default → clear the override so
	-- paths.toml stays a commented-out template and a future reload follows the
	-- OS default.
	if new_dir == "" or new_dir == (_default_config_dir or "") then
		_bootstrap[CONFIG_DIR_KEY] = nil
	else
		if not ensure_dir(new_dir) then
			return false, string.format("could not create config directory '%s'", new_dir)
		end
		_bootstrap[CONFIG_DIR_KEY] = new_dir
	end
	local saved, save_err = save_bootstrap()
	if not saved then
		_bootstrap[CONFIG_DIR_KEY] = old_override
		adopt_changed_bootstrap_target()
		return false, save_err
	end
	return config_dir() ~= old_dir
end

--- Ensures a directory exists. Exposed because the path editor creates the
--- directory the user typed before it is stored.
--- @param path string Absolute path with trailing slash.
function M.ensure_dir(path)
	return ensure_dir(path)
end

return M
