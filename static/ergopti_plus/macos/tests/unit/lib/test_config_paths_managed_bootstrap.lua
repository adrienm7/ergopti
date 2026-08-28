--- tests/unit/lib/test_config_paths_managed_bootstrap.lua

--- ==============================================================================
--- MODULE: Config Paths — Managed-App Bootstrap Persistence
--- DESCRIPTION:
--- Proves that the packaged launcher can place paths.toml in a stable,
--- user-writable location instead of beside the signed Lua resources.
---
--- ROOT CAUSE ENCODED:
--- The packaged launcher points MJConfigFile at
--- ErgoptiPlus.app/Contents/Resources/.../init.lua. ConfigPaths historically
--- derived paths.toml from that source directory, so first boot and every path
--- editor save attempted to write inside the installed application bundle.
--- io.open then failed under a normal /Applications install, while the in-memory
--- override still moved and the UI reloaded as if persistence had succeeded.
---
--- These tests drive the production resolver with the launcher's managed path
--- environment contract. The load-bearing assertion is where the bytes land;
--- merely scanning for the environment-variable name would stay green if the
--- writer continued using the bundle path.
--- ==============================================================================

local helpers = require("tests.helpers")

local MANAGED_FILE = "/Users/test/Library/Application Support/ErgoptiPlus/paths.toml"
local BUNDLE_DIR = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos/"
local CUSTOM_DIR = "/Volumes/User Config/"

--- Loads ConfigPaths with the exact environment exported by the packaged
--- launcher, then restores process-global getenv even when require raises.
--- @return table config_paths Fresh production module.
local function load_managed()
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "ERGOPTI_PATHS_FILE" then return MANAGED_FILE end
		if name == "HOME" then return "/Users/test" end
		return real_getenv(name)
	end

	local ok, loaded = pcall(helpers.load_with_stubs, "infra.config_paths", {
		fs = {
			xattr = {
				list = function() return {} end,
				get = function() return nil end,
			},
			attributes = function(path)
				local file = io.open(path, "r")
				if file then file:close(); return { mode = "file" } end
				if path:match("paths%.toml$") or path:find("stage%-lock")
					or path:find("write%-lock%-v1") then return nil end
				return { mode = "directory" }
			end,
			symlinkAttributes = function(path)
				local file = io.open(path, "r")
				if file then file:close(); return { mode = "file" } end
				if path:match("paths%.toml$") or path:find("stage%-lock")
					or path:find("write%-lock%-v1") then return nil, "missing" end
				return { mode = "directory" }
			end,
			mkdir = function() return true end,
			rmdir = function() return true end,
			link = function(source, destination)
				local source_file = io.open(source, "r")
				if not source_file then return nil, "missing source" end
				local content = source_file:read("*a"); source_file:close()
				local target_file = io.open(destination, "w")
				if not target_file then return nil, "cannot create destination" end
				target_file:write(content); target_file:close()
				return true
			end,
			dir = function(parent)
				local entries = {}
				if parent == BUNDLE_DIR:gsub("/$", "") and io.open(BUNDLE_DIR .. "paths.toml", "r") then
					entries[#entries + 1] = "paths.toml"
				end
				local index = 0
				return function() index = index + 1; return entries[index] end
			end,
			lock = function() return true end,
			unlock = function() return true end,
		},
	})
	os.getenv = real_getenv
	if not ok then error(loaded, 0) end
	return loaded
end

--- Runs a body with an in-memory filesystem for paths.toml reads and writes.
--- @param initial table<string,string>|nil Initial file contents.
--- @param fn fun(files: table<string,string>, writes: string[])
local function with_memory_files(initial, fn)
	local files = {}
	for path, content in pairs(initial or {}) do files[path] = content end
	local writes = {}
	local real_open = io.open
	local real_remove = os.remove
	local real_rename = os.rename

	io.open = function(path, mode)
		if mode == "r" then
			local content = files[path]
			if content == nil then return nil, "not found" end
			return {
				read = function() return content end,
				close = function() return true end,
			}
		end
		if mode == "w" then
			local pending = ""
			return {
				write = function(_, content)
					pending = pending .. tostring(content)
					return true
				end,
				close = function()
					files[path] = pending
					writes[#writes + 1] = path
					return true
				end,
			}
		end
		if mode == "a+" then
			files[path] = files[path] or ""
			return { close = function() return true end }
		end
		return real_open(path, mode)
	end
	os.remove = function(path)
		if files[path] ~= nil or path:find("paths.toml", 1, true) ~= nil then
			files[path] = nil
			return true
		end
		return real_remove(path)
	end
	os.rename = function(from, to)
		if files[from] ~= nil then
			files[to] = files[from]
			files[from] = nil
			return true
		end
		return nil, "not found"
	end

	local ok, err = xpcall(function() fn(files, writes) end, debug.traceback)
	io.open = real_open
	os.remove = real_remove
	os.rename = real_rename
	if not ok then error(err, 0) end
end

helpers.describe("managed ConfigPaths bootstrap lives outside the app bundle", function()
	helpers.it("managed bootstrap: writes first-boot and user overrides outside the bundle", function()
		with_memory_files({}, function(files, writes)
			local ConfigPaths = load_managed()
			helpers.assert_true(ConfigPaths.init(BUNDLE_DIR))
			helpers.assert_true(ConfigPaths.set_config_dir(CUSTOM_DIR))

			helpers.assert_not_nil(files[MANAGED_FILE],
				"the managed bootstrap must be persisted in the user-writable location")
			helpers.assert_true(files[MANAGED_FILE]:find(CUSTOM_DIR, 1, true) ~= nil,
				"the persisted bootstrap must contain the directory selected by the user")
		for _, path in ipairs(writes) do
			helpers.assert_true(path:sub(1, #BUNDLE_DIR) ~= BUNDLE_DIR,
				"paths.toml must never be written inside the signed app resources: " .. path)
		end
		end)
	end)

	helpers.it("managed bootstrap: migrates a legacy adjacent override", function()
		local legacy = BUNDLE_DIR .. "paths.toml"
		with_memory_files({
			[legacy] = 'ConfigDirPath = "' .. CUSTOM_DIR .. '"\n',
		}, function(files)
			local ConfigPaths = load_managed()
			helpers.assert_true(ConfigPaths.init(BUNDLE_DIR))

			helpers.assert_eq(ConfigPaths.get_config_dir(), CUSTOM_DIR,
				"migration must preserve the user's existing override")
			helpers.assert_not_nil(files[MANAGED_FILE],
				"the legacy override must be copied to the stable managed location")
			helpers.assert_true(files[MANAGED_FILE]:find(CUSTOM_DIR, 1, true) ~= nil)
		end)
	end)
end)
