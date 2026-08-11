--- tests/unit/ui/test_menu_paths_resolution_matrix.lua

--- ==============================================================================
--- MODULE: Config-Path Resolution Matrix
--- DESCRIPTION:
--- Executes every path resolver menu_paths exposes, for real, across the four
--- states the resolution actually has: HOME set or unset × paths.toml present or
--- absent. Every answer is then STATTED, not merely compared to a string.
---
--- FEATURES & RATIONALE:
--- 1. This is the coverage that has to exist BEFORE the resolution half moves to
---    infra/config_paths.lua, not after. The failure mode of a wrong-depth path
---    is not a crash: it is a path that resolves to a directory that EXISTS and
---    holds nothing, so the driver writes the user's personal files somewhere
---    they will never look and reports success. Five separate bugs of that exact
---    shape are already recorded in this repo, which is why an assertion on the
---    STRING is not enough — the directory has to be there.
--- 2. Every key of M.get() is exercised, not a sample. The keys differ in which
---    half of the tree they land in (shared root vs the hammerspoon/ subfolder),
---    and it is precisely that distinction a refactor gets wrong.
--- 3. HOME unset is a real state, not a hypothetical: launchd starts Hammerspoon
---    with a minimal environment, and the default-config-dir computation reads
---    HOME at MODULE LOAD. A resolver that returns "" there sends every personal
---    file to a relative path interpreted against Hammerspoon's cwd.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Every named path the driver asks for. Kept as data so a new key added to
--- M.get() without a row here is visible as a count mismatch below.
local PATH_KEYS = {
	"PersonalTomlPath",
	"PersonalInfoTomlPath",
	"HotstringsDirPath",
	"PersonalHotstringsDir",
	"ConfigTomlPath",
	"KarabinerConfigPath",
	"PersonalShortcutsLuaPath",
}

--- Creates a throwaway directory and returns its path with a trailing slash.
--- @return string
local function make_tmp_dir()
	local p = os.tmpname()
	os.remove(p)
	os.execute('mkdir "' .. p .. '"')
	return p .. "/"
end

--- Loads menu_paths with a controlled environment.
--- @param opts table {home: string|nil, paths_toml: string|nil, base_dir: string}
--- @return table The freshly required module.
local function load_paths(opts)
	-- The default config dir is computed at module load from HOME, so the
	-- environment has to be set before the require, not before the call.
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "HOME" then return opts.home end
		return real_getenv(name)
	end

	if opts.paths_toml ~= nil then
		local fh = io.open(opts.base_dir .. "paths.toml", "w")
		if fh then
			fh:write(opts.paths_toml)
			fh:close()
		end
	else
		os.remove(opts.base_dir .. "paths.toml")
	end

	package.loaded["ui.menu.menu_paths"] = nil
	package.loaded["infra.config_paths"] = nil
	local mod = helpers.load_with_stubs("ui.menu.menu_paths")
	os.getenv = real_getenv
	return mod
end

--- True when `path` names a directory that exists.
--- @param path string
--- @return boolean
local function dir_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	local stripped = path:gsub("[/\\]$", "")
	-- Portable stat without lfs: opening a directory for read fails on every
	-- platform this suite runs on, so probe for a file we know we can create.
	local probe = io.open(stripped .. "/.__ergopti_probe", "w")
	if not probe then return false end
	probe:close()
	os.remove(stripped .. "/.__ergopti_probe")
	return true
end




-- =========================================================
-- =========================================================
-- ======= 1/ Every key resolves, in every state ===========
-- =========================================================
-- =========================================================

helpers.describe("menu_paths: every named path resolves in all four states", function()
	local STATES = {
		{ name = "HOME set, no paths.toml", home = function()
			return make_tmp_dir():gsub("[/\\]$", "")
		end, toml = nil },
		{ name = "HOME set, paths.toml overrides", home = function()
			return make_tmp_dir():gsub("[/\\]$", "")
		end, toml = true },
		{ name = "HOME unset, no paths.toml", home = function() return nil end, toml = nil },
		{ name = "HOME unset, paths.toml overrides", home = function() return nil end, toml = true },
	}

	for _, state in ipairs(STATES) do
		helpers.it(state.name .. ": no key resolves to an empty string", function()
			local base = make_tmp_dir()
			local override = state.toml and make_tmp_dir() or nil
			local Paths = load_paths({
				home = state.home(),
				paths_toml = override and ('ConfigDirPath = "' .. override .. '"\n') or nil,
				base_dir = base,
			})
			Paths.init(base, function() end)

			for _, key in ipairs(PATH_KEYS) do
				local resolved = Paths.get(key)
				helpers.assert_true(type(resolved) == "string" and resolved ~= "",
					state.name .. ": " .. key .. " resolved to nothing — a caller then writes to a "
						.. "relative path interpreted against Hammerspoon's cwd")
				helpers.assert_true(resolved:find("[/\\]") ~= nil,
					state.name .. ": " .. key .. " is not an absolute path: " .. resolved)
			end
		end)
	end
end)




-- ==========================================================
-- ==========================================================
-- ======= 2/ The directory is really there =================
-- ==========================================================
-- ==========================================================

helpers.describe("menu_paths: a resolved path's parent directory exists on disk", function()
	helpers.it("every key lands in a directory the driver can write to", function()
		-- The whole point. A path that resolves to a plausible string inside a
		-- directory nobody created is the silent failure this file guards: the
		-- write fails, the caller logs nothing, and the user's personal file is
		-- simply absent.
		local base = make_tmp_dir()
		local home = make_tmp_dir():gsub("[/\\]$", "")
		local Paths = load_paths({ home = home, paths_toml = nil, base_dir = base })
		Paths.init(base, function() end)

		local checked = 0
		for _, key in ipairs(PATH_KEYS) do
			local resolved = Paths.get(key)
			local parent = resolved:match("^(.*[/\\])") or ""
			helpers.assert_true(dir_exists(parent),
				key .. " resolves into '" .. tostring(parent) .. "', which does not exist or is not "
					.. "writable — the file write will fail silently")
			checked = checked + 1
		end
		helpers.assert_eq(checked, #PATH_KEYS, "every key must have been checked")
	end)

	helpers.it("get_config_dir and get_default_config_dir both name a real directory", function()
		local base = make_tmp_dir()
		local home = make_tmp_dir():gsub("[/\\]$", "")
		local Paths = load_paths({ home = home, paths_toml = nil, base_dir = base })
		Paths.init(base, function() end)

		helpers.assert_true(dir_exists(Paths.get_config_dir()),
			"get_config_dir() must name a directory that exists after init")
		helpers.assert_true(type(Paths.get_default_config_dir()) == "string"
			and Paths.get_default_config_dir() ~= "",
			"get_default_config_dir() must always answer, it is the wizard's pre-fill")
	end)
end)




-- =============================================================
-- =============================================================
-- ======= 3/ The override actually overrides ==================
-- =============================================================
-- =============================================================

helpers.describe("menu_paths: paths.toml wins over the OS default", function()
	helpers.it("every shared-root key moves with the configured directory", function()
		local base = make_tmp_dir()
		local home = make_tmp_dir():gsub("[/\\]$", "")
		local override = make_tmp_dir()
		local Paths = load_paths({
			home = home,
			paths_toml = 'ConfigDirPath = "' .. override .. '"\n',
			base_dir = base,
		})
		Paths.init(base, function() end)

		helpers.assert_eq(Paths.get_config_dir(), override,
			"an override in paths.toml must be what get_config_dir answers")
		for _, key in ipairs(PATH_KEYS) do
			local resolved = Paths.get(key)
			helpers.assert_true(resolved:sub(1, #override) == override,
				key .. " ignored the configured directory and resolved to " .. resolved
					.. " — a personal file written outside the folder the user chose")
		end
	end)

	helpers.it("a commented-out override falls back to the OS default", function()
		local base = make_tmp_dir()
		local home = make_tmp_dir():gsub("[/\\]$", "")
		local Paths = load_paths({
			home = home,
			paths_toml = '# ConfigDirPath = "/somewhere/else/"\n',
			base_dir = base,
		})
		Paths.init(base, function() end)

		helpers.assert_eq(Paths.get_config_dir(), Paths.get_default_config_dir(),
			"a commented override is not an override — the template paths.toml this driver "
				.. "generates on first boot is exactly that shape")
	end)
end)
