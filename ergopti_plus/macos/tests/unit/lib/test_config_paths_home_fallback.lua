--- tests/unit/lib/test_config_paths_home_fallback.lua

--- ==============================================================================
--- MODULE: Config Paths HOME Fallback Regression
--- DESCRIPTION:
--- Proves that a missing or empty HOME never collapses the configuration root
--- to an empty string, with and without a paths.toml override.
---
--- ROOT CAUSE ENCODED:
--- Lua treats the empty string as truthy. Caching an unavailable HOME as ""
--- therefore made `_default_config_dir or _base_dir` select "" and rendered the
--- base-directory fallback unreachable. Every derived path then became relative
--- to Hammerspoon's working directory or rooted at `/`.
---
--- The module computes the HOME-derived default at require time, so every case
--- replaces os.getenv before loading a fresh production module. Both unavailable
--- values are tested explicitly: nil and the empty string.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Public resolver keys intentionally covered by this regression
local EXPECTED_PATH_COUNT = 7

local PATH_SUFFIXES = {
	PersonalTomlPath         = "hotstrings/personal_hotstrings.toml",
	PersonalInfoTomlPath     = "personal_info.toml",
	HotstringsDirPath        = "",
	PersonalHotstringsDir    = "hotstrings/",
	ConfigTomlPath           = "hammerspoon/config.toml",
	KarabinerConfigPath      = "hammerspoon/config_karabiner.toml",
	PersonalShortcutsLuaPath = "hammerspoon/personal_shortcuts.lua",
}

local UNAVAILABLE_HOME_CASES = {
	{
		label = "nil HOME",
		value = function() return nil end,
	},
	{
		label = "empty HOME",
		value = function() return "" end,
	},
}





-- ====================================
-- ====================================
-- ======= 1/ Fixture lifecycle =======
-- ====================================
-- ====================================

--- Creates an isolated directory with a trailing slash.
--- @return string path Absolute temporary path.
local function make_tmp_dir()
	local path = os.tmpname()
	os.remove(path)
	local result = os.execute('mkdir "' .. path .. '"')
	helpers.assert_true(result and true or result == 0,
		"could not create config-path fixture directory: " .. tostring(path))
	return path .. "/"
end

--- Writes or removes the bootstrap file for one matrix case.
--- @param base_dir string Driver base directory.
--- @param override_dir string|nil Config directory override.
local function prepare_paths_toml(base_dir, override_dir)
	local path = base_dir .. "paths.toml"
	if override_dir == nil then
		os.remove(path)
		return
	end

	local fh = io.open(path, "w")
	helpers.assert_true(fh ~= nil, "could not create paths.toml fixture")
	fh:write(string.format('ConfigDirPath = "%s"\n', override_dir))
	fh:close()
end

--- Reloads the production resolver after replacing HOME.
--- @param home_value_fn fun(): string|nil HOME value supplier.
--- @return table config_paths Fresh production module.
local function load_with_home(home_value_fn)
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "HOME" then return home_value_fn() end
		return real_getenv(name)
	end

	local ok, loaded = pcall(helpers.load_with_stubs, "infra.config_paths")
	os.getenv = real_getenv
	if not ok then error(loaded, 0) end
	return loaded
end

--- Asserts every public derived path resolves under the selected root.
--- @param config_paths table Fresh resolver module.
--- @param root string Expected configuration root with trailing slash.
--- @param label string Matrix case label.
local function assert_derived_paths(config_paths, root, label)
	local checked = 0
	for key, suffix in pairs(PATH_SUFFIXES) do
		helpers.assert_eq(config_paths.get(key), root .. suffix,
			label .. ": " .. key .. " escaped the selected configuration root")
		checked = checked + 1
	end
	helpers.assert_eq(checked, EXPECTED_PATH_COUNT,
		label .. ": every public path key must be covered")
end





-- ===================================================
-- ===================================================
-- ======= 2/ Unavailable HOME fallback matrix =======
-- ===================================================
-- ===================================================

helpers.describe("config_paths falls back safely when HOME is unavailable", function()
	for _, home_case in ipairs(UNAVAILABLE_HOME_CASES) do
		for _, with_override in ipairs({ false, true }) do
			local override_label = with_override and "with override" or "without override"
			helpers.it("(config-paths-home-fallback) " .. home_case.label .. " " .. override_label,
				function()
					local base_dir = make_tmp_dir()
					local override_dir = with_override and make_tmp_dir() or nil
					prepare_paths_toml(base_dir, override_dir)

					local config_paths = load_with_home(home_case.value)
					helpers.assert_true(config_paths.get_config_dir() ~= "",
						home_case.label .. ": pre-init resolution must not return an empty root")

					config_paths.init(base_dir)
					local expected_root = override_dir or base_dir
					helpers.assert_eq(config_paths.get_default_config_dir(), base_dir,
						home_case.label .. ": unavailable HOME must expose the driver base fallback")
					helpers.assert_eq(config_paths.get_config_dir(), expected_root,
						home_case.label .. ": paths.toml must be the only value that overrides the fallback")
					assert_derived_paths(config_paths, expected_root,
						home_case.label .. " " .. override_label)
				end)
		end
	end
end)





-- ==========================================
-- ==========================================
-- ======= 3/ Valid HOME sanity check =======
-- ==========================================
-- ==========================================

helpers.describe("config_paths preserves the normal HOME-derived default", function()
	helpers.it("(config-paths-home-fallback) valid HOME still selects ~/.config", function()
		local base_dir = make_tmp_dir()
		local home_dir = make_tmp_dir():gsub("[/\\]$", "")
		prepare_paths_toml(base_dir, nil)

		local config_paths = load_with_home(function() return home_dir end)
		config_paths.init(base_dir)

		local expected_root = home_dir .. "/.config/ergopti_plus/"
		helpers.assert_eq(config_paths.get_default_config_dir(), expected_root,
			"a valid HOME must remain the canonical OS default")
		helpers.assert_eq(config_paths.get_config_dir(), expected_root,
			"no bootstrap override must keep the HOME-derived default")
		assert_derived_paths(config_paths, expected_root, "valid HOME")
	end)
end)
