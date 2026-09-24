--- modules/keymap/layout_registry.lua

--- ==============================================================================
--- MODULE: Layout Registry (Linux client)
--- DESCRIPTION:
--- Prepares a layout of the keyboard-layout registry for Linux: downloads
--- index.json and the layout's .keylayout from the repository folder, verifies
--- the file against the index (_shared/lua/layouts/registry.lua), keeps the
--- verified copy in the configuration folder and converts it on this machine
--- to an XKB symbols file, an XCompose file and the XKB types, with the one
--- .keylayout converter the package ships (keylayout_to_xkb.py).
---
--- FEATURES & RATIONALE:
--- 1. Nothing derived from a layout is downloaded: the .keylayout is the only
---    source and the XKB files are produced here, by the same converter that
---    regenerates the repository's own Ergopti files.
--- 2. Python 3.8 or newer runs the converter. It is the interpreter every Linux
---    layout installer of this project already requires, and a second
---    converter in Lua would be a second source of truth for every layout.
---    A missing or older python3 fails with a translated explanation.
--- 3. The conversion runs in an asynchronous child (adapters/process_runner):
---    the daemon owns the keyboard and must never wait on it.
--- 4. Every collaborator is injectable, so tests replay a download and a
---    conversion without network, luv or python3.
--- ==============================================================================

local Logger        = require("logger.shim")
local Paths         = require("infra.paths")
local ConfigPaths   = require("infra.config_paths")
local I18n          = require("infra.i18n")
local FileSystem    = require("adapters.file_system")
local HttpClient    = require("adapters.http_client")
local FileDigest    = require("adapters.file_digest")
local ShellRunner   = require("adapters.shell_runner")
local ProcessRunner = require("adapters.process_runner")
local Json          = require("json")
local Registry      = require("layouts.registry")

local M = {}

local LOG = "layout_registry"





-- ================================
-- ================================
-- ======= 1/ Constants ===========
-- ================================
-- ================================

-- Interpreter of the converter, looked up in PATH like the installers do.
local PYTHON = "python3"

-- Oldest Python the converter supports (the installers' floor).
local MIN_PYTHON = { 3, 8 }

-- Exit code of the version probe when the interpreter is too old.
local PYTHON_TOO_OLD_EXIT = 3

-- The converter, relative to the driver root: where the package ships it,
-- then where it lives in a source checkout.
local CONVERTER_CANDIDATES = {
	"xkb_generation/keylayout_to_xkb.py",
	"../../ergopti/linux/xkb_generation/keylayout_to_xkb.py",
}

-- The converter reads a whole layout; a second of work is typical, a minute
-- means it is stuck.
local CONVERSION_TIMEOUT_MS = 60000





-- ================================
-- ================================
-- ======= 2/ Settings ============
-- ================================
-- ================================

--- Reads and decodes one shared JSON file.
--- @param rel string Path under _shared/.
--- @return table|nil value
--- @return string|nil error
local function read_shared_json(rel)
	local path = Paths.shared(rel)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then return nil, "_shared/" .. rel .. " is unreadable" end
	-- The shared json.lua answers nil to invalid JSON rather than raising.
	local ok, decoded = pcall(Json.decode, raw)
	if not ok or type(decoded) ~= "table" then return nil, "_shared/" .. rel .. " is not valid JSON" end
	return decoded, nil
end

--- The registry settings, resolved from the shared defaults.
--- @return table|nil settings
--- @return string|nil error
function M.settings()
	local layouts, layouts_err = read_shared_json("modules/layouts/defaults.json")
	if not layouts then return nil, layouts_err end
	local updater, updater_err = read_shared_json("modules/updater/defaults.json")
	if not updater then return nil, updater_err end
	return Registry.resolve(layouts, updater)
end

--- The converter shipped with this driver.
--- @param driver_root string Driver root, without a trailing slash.
--- @param exists function exists(path) -> boolean
--- @return string|nil path
function M.converter_path(driver_root, exists)
	for _, relative in ipairs(CONVERTER_CANDIDATES) do
		local candidate = driver_root .. "/" .. relative
		if exists(candidate) then return candidate end
	end
	return nil
end

--- Creates a folder and its parents.
--- @param dir string
--- @return boolean
local function ensure_dir(dir)
	return ShellRunner.run("mkdir -p " .. ShellRunner.quote(dir) .. " 2>/dev/null")
end

--- Digests text through a temporary file (the digest runs in a child).
--- @param dir string Folder of the temporary file, created when missing.
--- @param timeout_ms number
--- @return function sha256(text, callback)
local function file_sha256(dir, timeout_ms)
	local path = dir .. ".digest.tmp"
	return function(text, callback)
		if not ensure_dir(dir) or not FileSystem.write(path, text) then
			callback(nil, "cannot stage " .. path)
			return
		end
		FileDigest.sha256(path, { timeout_ms = timeout_ms }, function(digest, err)
			FileSystem.delete(path)
			callback(digest, err)
		end)
	end
end

--- The production collaborators of M.install().
--- @param settings table Result of M.settings().
--- @return table
local function default_deps(settings)
	local local_dir = ConfigPaths.config(settings.local_folder) .. "/"
	return {
		settings = settings,
		transport = {
			get = function(url, headers, timeout_ms, callback)
				HttpClient.get(url, headers, {
					timeout_ms = timeout_ms,
					max_body_bytes = settings.max_file_bytes,
					owner = "layout_registry",
					https_only = true,
					follow_redirects = true,
				}, function(result)
					callback(result.status, result.body, result.error)
				end)
			end,
			decode_json = Json.decode,
			sha256 = file_sha256(local_dir, settings.timeout_ms),
		},
		ensure_dir = ensure_dir,
		write = FileSystem.write,
		run = ProcessRunner.run,
		local_dir = local_dir,
		converter = M.converter_path(Paths.driver_root(), FileSystem.exists),
		keycodes = Paths.shared("modules/layouts/mac_keycodes.json"),
		translate = I18n.get,
	}
end





-- ================================
-- ================================
-- ======= 3/ Conversion ==========
-- ================================
-- ================================

--- Writes the verified download: the layout first, then the index it matches.
--- @param deps table
--- @param id string
--- @param detail table { entry, index_text, layout_text }
--- @return string|nil layout_path
--- @return string|nil error
local function publish(deps, id, detail)
	if not deps.ensure_dir(deps.local_dir) then return nil, "cannot create " .. deps.local_dir end
	local layout_path = deps.local_dir .. id .. ".keylayout"
	local index_path = deps.local_dir .. deps.settings.index_file
	local written, write_err = deps.write(layout_path, detail.layout_text)
	if not written then return nil, "cannot write " .. layout_path .. ": " .. tostring(write_err) end
	written, write_err = deps.write(index_path, detail.index_text)
	if not written then return nil, "cannot write " .. index_path .. ": " .. tostring(write_err) end
	return layout_path, nil
end

--- The converter's argument vector for one verified layout.
--- @param deps table
--- @param id string
--- @param entry table Registry index entry.
--- @param layout_path string
--- @return table
local function converter_args(deps, id, entry, layout_path)
	return {
		deps.converter,
		"--keylayout", layout_path,
		"--keycodes", deps.keycodes,
		"--convention", entry.keycode_convention,
		"--layout-id", id,
		"--display-name", entry.name,
		"--index", deps.local_dir .. deps.settings.index_file,
		"--out", deps.local_dir .. id,
	}
end

--- The version probe's argument vector.
--- @return table
local function version_probe_args()
	return {
		"-c",
		string.format("import sys; sys.exit(0 if sys.version_info >= (%d, %d) else %d)",
			MIN_PYTHON[1], MIN_PYTHON[2], PYTHON_TOO_OLD_EXIT),
	}
end

--- Converts a verified layout to XKB, after checking the interpreter.
--- @param deps table
--- @param id string
--- @param entry table
--- @param layout_path string
--- @param finish function finish(ok, detail, user_message)
local function convert(deps, id, entry, layout_path, finish)
	local python_message = deps.translate("layouts.linux_needs_python")
	if not deps.converter then
		finish(false, "the .keylayout converter is not shipped with this driver", nil)
		return
	end
	deps.run(PYTHON, version_probe_args(), { timeout_ms = CONVERSION_TIMEOUT_MS }, function(probe)
		if probe.not_found or probe.exit_code == PYTHON_TOO_OLD_EXIT then
			finish(false, "python3 3.8 or newer is required to convert the layout", python_message)
			return
		end
		if probe.error then
			finish(false, "python3 does not run: " .. tostring(probe.error), python_message)
			return
		end
		deps.run(PYTHON, converter_args(deps, id, entry, layout_path),
			{ timeout_ms = CONVERSION_TIMEOUT_MS }, function(result)
				if result.error then
					local detail = result.stderr ~= "" and result.stderr or result.error
					finish(false, "the conversion failed: " .. tostring(detail), nil)
					return
				end
				finish(true, { entry = entry, xkb_dir = deps.local_dir .. id }, nil)
			end)
	end)
end





-- ================================
-- ================================
-- ======= 4/ Public API ==========
-- ================================
-- ================================

--- Downloads, verifies and converts one registry layout to XKB files in
--- <configuration folder>/<local folder>/<id>/.
--- on_done(true, { entry, xkb_dir }) or on_done(false, reason, user_message)
--- is called exactly once; user_message is a translated explanation when the
--- user can act on the cause (python3 missing or too old), nil otherwise.
--- @param id string Registry id.
--- @param on_done function Terminal callback.
--- @param deps table|nil Collaborators; the production ones by default.
--- @return boolean dispatched False when nothing could be started (on_done was called).
function M.install(id, on_done, deps)
	if deps == nil then
		local settings, settings_err = M.settings()
		if not settings then
			Logger.error(LOG, "The layout registry is unusable: %s.", tostring(settings_err))
			on_done(false, settings_err, nil)
			return false
		end
		deps = default_deps(settings)
	end
	local function finish(ok, detail, user_message)
		if ok then
			Logger.success(LOG, "Converted the '%s' layout, version %s, to XKB in %s.", id,
				tostring(detail.entry.version), detail.xkb_dir)
		else
			Logger.error(LOG, "The '%s' layout was not converted: %s.", tostring(id), tostring(detail))
		end
		on_done(ok, detail, user_message)
	end
	Logger.start(LOG, "Preparing the '%s' layout from the registry…", tostring(id))
	Registry.fetch(deps.settings, id, deps.transport, function(ok, detail)
		if not ok then
			finish(false, detail, nil)
			return
		end
		local layout_path, publish_err = publish(deps, id, detail)
		if not layout_path then
			finish(false, publish_err, nil)
			return
		end
		convert(deps, id, detail.entry, layout_path, finish)
	end)
	return true
end

return M
