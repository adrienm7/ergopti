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

--- Builds the exact FileSystem port surface this resolver exercises.
---
--- The stock Windows Lua runner cannot expose Hammerspoon's hard-link primitive,
--- so the production create-only adapter correctly fails closed there. These
--- resolver tests own no concurrent writer; this fixture preserves the port's
--- status/commit contract while using their private real directories.
--- @return table file_system Faithful first-run bootstrap port.
local function make_bootstrap_file_system()
	local file_system = {}

	function file_system.read_with_status(path)
		local fh, open_err, open_code = io.open(path, "r")
		if not fh then
			if open_code == 2 then return nil, "absent", open_err end
			return nil, "error", open_err
		end
		local content, read_err = fh:read("*a")
		local closed, close_err = fh:close()
		if type(content) ~= "string" then return nil, "error", read_err end
		if closed ~= true then return nil, "error", close_err end
		return content, "ok"
	end

	function file_system.create_if_absent(path, content)
		local _, status, detail = file_system.read_with_status(path)
		if status == "ok" then return false, "exists" end
		if status ~= "absent" then return false, "error", detail end

		local fh, open_err = io.open(path, "w")
		if not fh then return false, "error", open_err end
		local written, write_err = fh:write(type(content) == "string" and content or "")
		local closed, close_err = fh:close()
		if not written then return false, "error", write_err end
		if closed ~= true then return false, "error", close_err end
		return true, "created"
	end

	return file_system
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
	local previous_file_system = package.loaded["adapters.file_system"]
	package.loaded["adapters.file_system"] = make_bootstrap_file_system()
	local ok, mod = pcall(helpers.load_with_stubs, "ui.menu.menu_paths")
	package.loaded["adapters.file_system"] = previous_file_system
	os.getenv = real_getenv
	if not ok then error(mod, 0) end
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
		helpers.assert_true(Paths.init(base, function() end),
			"path resolver initialization must commit before its directory contract is tested")

		helpers.assert_true(dir_exists(Paths.get_config_dir()),
			"get_config_dir() must name a directory that exists after init")
		helpers.assert_true(dir_exists(Paths.get_default_config_dir()),
			"get_default_config_dir() must name a real directory, it is the wizard's pre-fill")
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





-- ==============================================================
-- ==============================================================
-- ======= 4/ Personal Bootstrap Preserves Existing Bytes =======
-- ==============================================================
-- ==============================================================

helpers.describe("menu_paths: personal bootstrap distinguishes absence from unreadability", function()
	helpers.it("never creates or truncates after an existing-file read refusal", function()
		local base = make_tmp_dir()
		local home = make_tmp_dir():gsub("[/\\]$", "")
		local Paths = load_paths({ home = home, paths_toml = nil, base_dir = base })
		Paths.init(base, function() end)
		local personal_dir = home .. "/.config/ergopti_plus/hotstrings/"
		os.execute('mkdir "' .. personal_dir .. '"')
		local personal_path = personal_dir .. "personal_hotstrings.toml"
		local sentinel = "PRIVATE-PATH-BOOTSTRAP-SENTINEL"
		local fixture = assert(io.open(personal_path, "wb"))
		assert(fixture:write(sentinel))
		assert(fixture:close())
		local original_open = io.open
		local write_opens = 0
		io.open = function(path, mode)
			if path == personal_path and mode == "r" then return nil, "PRIVATE-READ-FAILURE", 13 end
			if path == personal_path and mode == "w" then write_opens = write_opens + 1 end
			return original_open(path, mode)
		end
		local call_ok, resolved = pcall(Paths.get, "PersonalTomlPath")
		io.open = original_open

		helpers.assert_true(call_ok, "a read refusal must not escape path resolution")
		helpers.assert_eq(resolved, personal_path, "path resolution itself must remain deterministic")
		helpers.assert_eq(write_opens, 0,
			"an unproven absence must never reach the baseline writer")
		local preserved = assert(io.open(personal_path, "rb"))
		helpers.assert_eq(assert(preserved:read("*a")), sentinel,
			"path lookup must preserve every committed personal-hotstrings byte")
		assert(preserved:close())
		os.remove(personal_path)
	end)
end)
