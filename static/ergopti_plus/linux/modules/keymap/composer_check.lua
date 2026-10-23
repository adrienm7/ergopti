--- modules/keymap/composer_check.lua

--- ==============================================================================
--- MODULE: Layout Composer Check (Linux)
--- DESCRIPTION:
--- The Linux side of the Debug menu's « Test the composed layout »: wires the
--- shared steps (_shared/lua/layouts/composer_check.lua) to this driver's layout
--- registry and the shipped check composition. The composed layout goes through
--- the same XKB conversion and installer as any layout, and is removed again; a
--- user's own composition is only read.
---
--- FEATURES & RATIONALE:
--- 1. "Ready" means the installer verified the XKB layout it just installed
---    (it compiles it). A composition that already exists is not installed
---    again, so the installer's verdict is not available for it: the step says
---    "not_reprobed" instead of claiming a result nobody observed.
--- 2. Every collaborator is injectable, so the portable suite replays the
---    wiring without a desktop session or a home folder.
--- ==============================================================================

local Paths       = require("infra.paths")
local FileSystem  = require("adapters.file_system")
local Report      = require("field_check_report")

local M = {}

-- Where the shipped check composition lives, under the shared tree.
local FIXTURE_DIR = "modules/layouts/composer_check/"

--- Builds the shared check's env over this driver.
--- @param overrides table|nil Replacements for tests: registry, deps, read, exists,
---   settings, config_dir, read_fixture.
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
	local config_dir = overrides.config_dir or (require("infra.config_paths").config("") .. "/")
	local Logger = require("logger.shim")
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

	--- @param info table|nil The install's result ({ verified }), nil for an existing composition.
	function env.host_ready(info)
		if type(info) ~= "table" then return Report.STATE_INFO, "not_reprobed" end
		if info.verified == true then return Report.STATE_PASS, "verified" end
		return Report.STATE_FAIL, "unverified"
	end

	return env, nil
end

return M
