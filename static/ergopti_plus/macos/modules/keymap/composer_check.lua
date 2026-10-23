--- modules/keymap/composer_check.lua

--- ==============================================================================
--- MODULE: Layout Composer Check (macOS)
--- DESCRIPTION:
--- The macOS side of the Debug menu's « Test the composed layout »: wires the
--- shared steps (_shared/lua/layouts/composer_check.lua) to this driver's layout
--- registry, the shipped check composition and the system's enabled input
--- sources. The composed layout is installed as a real input source and removed
--- again; a user's own composition is only read.
---
--- FEATURES & RATIONALE:
--- 1. "Ready" means the system lists the layout among its enabled keyboard
---    layouts: right after an install, the install's own enable result; for a
---    composition that already exists, the enabled-source list. macOS may read
---    a rewritten file only after the input source is toggled or the user logs
---    in again (docs/layout-composer.md); this check says only what the system
---    reports.
--- 2. Every collaborator is injectable (the registry, its deps, the reads and
---    the source list), so the portable suite replays the wiring without
---    Hammerspoon or a home folder.
--- ==============================================================================

local Paths       = require("infra.paths")
local FileSystem  = require("adapters.file_system")
local Report      = require("field_check_report")

local M = {}

-- Where the shipped check composition lives, under the shared tree.
local FIXTURE_DIR = "modules/layouts/composer_check/"

--- Whether the system lists a keyboard layout as enabled.
--- @param sources table Records from list_active_keyboard_layouts.
--- @param keyboard_name string The layout's keyboard name.
--- @return boolean
local function lists(sources, keyboard_name)
	local InputSources = require("modules.keymap.input_sources")
	local display = InputSources.format_ergopti_display(keyboard_name)
	for _, source in ipairs(sources) do
		if source.id == keyboard_name or source.name == keyboard_name or source.name == display then
			return true
		end
	end
	return false
end

--- Builds the shared check's env over this driver.
--- @param overrides table|nil Replacements for tests: registry, deps, read, exists,
---   active_sources, settings, config_dir, read_fixture.
--- @return table|nil env
--- @return string|nil error
function M.env(overrides)
	overrides = overrides or {}
	local Registry = overrides.registry or require("modules.keymap.layout_registry")
	local settings, settings_err = overrides.settings, nil
	if settings == nil then settings, settings_err = Registry.composer_settings() end
	if not settings then return nil, settings_err end
	local deps = overrides.deps
	local read = overrides.read or FileSystem.read
	local exists = overrides.exists or FileSystem.exists
	local config_dir = overrides.config_dir or require("infra.config_paths").get_config_dir()
	local Logger = require("infra.logger")
	local env = {
		composer_id = settings.id,
		declaration_path = config_dir .. settings.folder .. "/" .. settings.declaration_file,
		registry = Registry,
		deps = deps,
		exists = exists,
		log = function(level, message, ...) Logger[level]("composer_check", message, ...) end,
	}

	function env.snapshot() return Registry.snapshot(deps) end

	function env.read_fixture()
		if overrides.read_fixture then return overrides.read_fixture() end
		local declaration_path = Paths.shared(FIXTURE_DIR .. "composition.json")
		local keylayout_path = Paths.shared(FIXTURE_DIR .. "composed.keylayout")
		if type(declaration_path) ~= "string" or type(keylayout_path) ~= "string" then
			return nil, "the shared tree is unreachable"
		end
		local declaration, keylayout = read(declaration_path), read(keylayout_path)
		if type(declaration) ~= "string" or type(keylayout) ~= "string" then
			return nil, "the shipped check composition is unreadable"
		end
		return { declaration = declaration, keylayout = keylayout }
	end

	function env.read_copy() return (Registry.read_local_copy(settings.id, deps)) end

	function env.sha256(text, callback) Registry.sha256_text(text, callback, deps) end

	--- @param info table|nil The install's result ({ enabled }), nil for an existing composition.
	--- @param entry table The installed record entry.
	function env.host_ready(info, entry)
		if type(info) == "table" and info.enabled ~= nil then
			return info.enabled == true and Report.STATE_PASS or Report.STATE_FAIL,
				info.enabled == true and "enabled" or "not_enabled"
		end
		local sources = (overrides.active_sources or require("modules.keymap.input_sources").list_active_keyboard_layouts)()
		if lists(type(sources) == "table" and sources or {}, entry.keyboard_name) then
			return Report.STATE_PASS, "enabled"
		end
		return Report.STATE_FAIL, "not_enabled"
	end

	return env, nil
end

return M
