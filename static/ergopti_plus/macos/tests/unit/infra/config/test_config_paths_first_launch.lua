--- tests/unit/infra/config/test_config_paths_first_launch.lua

--- ==============================================================================
--- MODULE: Config Paths — First Launch Without the Managed Folder
--- DESCRIPTION:
--- The packaged launcher exports ERGOPTI_PATHS_FILE inside the Ergopti support
--- folder (app_dirs config.macos_paths_file), a folder the first save creates.
---
--- ROOT CAUSE ENCODED:
--- On the first launch of a fresh install that folder does not exist yet. The
--- bootstrap read went through the file adapter, which reports a missing path
--- prefix as an error, so every first launch logged an ERROR and the packaged
--- app's launch gate failed. A missing folder proves the file absent.
--- ==============================================================================

local helpers = require("tests.helpers")
local AppDirs = require("app_dirs")

local MANAGED_FILE = "/Users/test/" .. AppDirs.config.macos_paths_file
local MANAGED_DIR = MANAGED_FILE:match("^(.*)/[^/]+$")

--- Answers an lstat-style query: the managed folder and everything in it are
--- missing, every other folder exists.
--- @param path string Inspected path.
--- @return table|nil attributes
local function attributes(path)
	if path == MANAGED_DIR or path:sub(1, #MANAGED_DIR + 1) == MANAGED_DIR .. "/" then return nil end
	if path:match("paths%.toml$") then return nil end
	return { mode = "directory" }
end

--- Loads ConfigPaths with the packaged launcher's environment and a recording logger.
--- @return table config_paths, table errors
local function load_first_launch()
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "ERGOPTI_PATHS_FILE" then return MANAGED_FILE end
		if name == "HOME" then return "/Users/test" end
		return real_getenv(name)
	end
	package.loaded["infra.logger"] = nil
	local Logger = helpers.load_with_stubs("infra.logger")
	local errors = {}
	Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
	local ok, loaded = pcall(helpers.load_with_stubs, "infra.config_paths", {
		fs = {
			attributes = attributes,
			symlinkAttributes = attributes,
			xattr = { list = function() return {} end, get = function() return nil end },
			-- Absence is proven by listing the parent: the missing folder is not in it.
			dir = function() return function() return nil end end,
		},
	})
	os.getenv = real_getenv
	if not ok then error(loaded, 0) end
	return loaded, errors
end




-- ==========================================
-- ==========================================
-- ======= 1/ Absent managed folder =========
-- ==========================================
-- ==========================================

helpers.describe("ConfigPaths on the first launch of a packaged app", function()
	helpers.it("refuses initialization when the default configuration directory cannot be created", function()
		local previous_hs, previous_getenv = _G.hs, os.getenv
		local previous_file_system = package.loaded["adapters.file_system"]
		local ok, err = xpcall(function()
			local available = false
			os.getenv = function(name)
				if name == "HOME" then return "/fixture/home" end
				if name == "ERGOPTI_PATHS_FILE" then return nil end
				return previous_getenv(name)
			end
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return "", "ok" end,
			}
			local paths = helpers.load_with_stubs("infra.config_paths", {
				fs = {
					attributes = function(path)
						if path:find("/.config/ergopti_plus", 1, true) and not available then return nil end
						return { mode = "directory" }
					end,
					mkdir = function() return nil, "permission denied" end,
				},
				execute = function() return "", false end,
			})
			helpers.assert_eq(paths.init("/fixture/driver/"), false)
			helpers.assert_eq(paths.is_initialized(), false)
			available = true
			helpers.assert_true(paths.init("/fixture/driver/"), "initialization can retry after access is restored")
			helpers.assert_true(paths.is_initialized())
		end, debug.traceback)
		_G.hs, os.getenv = previous_hs, previous_getenv
		package.loaded["adapters.file_system"] = previous_file_system
		if not ok then error(err, 0) end
	end)
	helpers.it("reads a missing managed folder as an absent bootstrap, without an error", function()
		local ConfigPaths, errors = load_first_launch()
		local dir = ConfigPaths.get_config_dir()
		helpers.assert_true(type(dir) == "string" and dir ~= "",
			"the default configuration folder is used")
		helpers.assert_eq(#errors, 0,
			"a first launch is no error: " .. table.concat(errors, " | "))
	end)
end)
