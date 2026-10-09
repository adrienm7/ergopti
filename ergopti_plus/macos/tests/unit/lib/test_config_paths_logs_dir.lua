--- tests/unit/lib/test_config_paths_logs_dir.lua

--- ==============================================================================
--- MODULE: Config Paths — Logs Folder Override
--- DESCRIPTION:
--- paths.toml may move the logs folder through LogsDirPath. An empty value is
--- the OS default, ~/Library/Logs/ergopti_plus.
---
--- WHAT IS PINNED (config-paths-logs-dir):
--- 1. The default, and the override read back from paths.toml.
--- 2. A folder that is not named after the application gets that subfolder
---    appended. The native worker restricts the logs folder to its owner and
---    deletes old logs in it: a user picking ~/Documents must not have either
---    applied to ~/Documents itself.
--- 3. A relative override is refused, on load and on save.
--- 4. The one writer stores both keys in one publication, keeps the other key
---    untouched, and clears an override equal to the default.
--- 5. A logs folder that cannot be created is refused before anything is
---    published: the native worker would refuse it at the next start, which
---    then stops.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a resolver over an in-memory paths.toml.
--- @param bootstrap_content string|nil Existing paths.toml bytes.
--- @return table config_paths
--- @return table observations `writes` holds every published content.
--- @return boolean initialized
local function fresh_resolver(bootstrap_content)
	local observations = { writes = {} }
	local previous_file_system = package.loaded["adapters.file_system"]
	package.loaded["adapters.file_system"] = {
		read_with_status = function()
			if bootstrap_content ~= nil then return bootstrap_content, "ok" end
			return nil, "absent"
		end,
		create_if_absent = function(_, content)
			observations.writes[#observations.writes + 1] = content
			return true, "created"
		end,
		write_if_unchanged = function(_, content)
			observations.writes[#observations.writes + 1] = content
			return true
		end,
	}
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "HOME" then return "/fixture/home" end
		if name == "ERGOPTI_PATHS_FILE" then return nil end
		return real_getenv(name)
	end
	local previous_hs = _G.hs
	local ok, ConfigPaths = pcall(helpers.load_with_stubs, "infra.config_paths", {
		fs = {
			attributes = function(path)
				if type(path) == "string" and path:sub(1, 9) == "/fixture/" then
					return { mode = "directory" }
				end
				return nil
			end,
			mkdir = function() return true end,
		},
	})
	_G.hs = previous_hs
	os.getenv = real_getenv
	package.loaded["adapters.file_system"] = previous_file_system
	if not ok then error(ConfigPaths, 0) end
	local initialized = ConfigPaths.init("/fixture/driver/")
	return ConfigPaths, observations, initialized
end

local DEFAULT_LOGS = "/fixture/home/Library/Logs/ergopti_plus/"

helpers.describe("config_paths: logs folder override (config-paths-logs-dir)", function()
	helpers.it("defaults to ~/Library/Logs/ergopti_plus", function()
		local ConfigPaths, _, initialized = fresh_resolver(nil)
		helpers.assert_true(initialized, "an absent paths.toml must initialise")
		helpers.assert_eq(ConfigPaths.get_default_logs_dir(), DEFAULT_LOGS)
		helpers.assert_eq(ConfigPaths.get_logs_dir(), DEFAULT_LOGS)
	end)

	helpers.it("reads an override named after the application as is", function()
		local ConfigPaths = fresh_resolver('LogsDirPath = "/fixture/sync/ergopti_plus"\n')
		helpers.assert_eq(ConfigPaths.get_logs_dir(), "/fixture/sync/ergopti_plus/")
	end)

	helpers.it("appends the application folder to a foreign folder", function()
		local ConfigPaths = fresh_resolver('LogsDirPath = "/fixture/Documents/"\n')
		helpers.assert_eq(ConfigPaths.get_logs_dir(), "/fixture/Documents/ergopti_plus/")
	end)

	helpers.it("refuses a relative override at load", function()
		local _, _, initialized = fresh_resolver('LogsDirPath = "logs"\n')
		helpers.assert_true(initialized == false, "a relative logs folder must fail initialisation")
	end)

	helpers.it("stores both folders in one publication and keeps the other key", function()
		local ConfigPaths, observations = fresh_resolver('ConfigDirPath = "/fixture/cfg/"\n')
		local changed, err = ConfigPaths.set_paths(nil, "/fixture/Documents")
		helpers.assert_nil(err)
		helpers.assert_true(changed == true, "a new logs folder is a change")
		local written = observations.writes[#observations.writes]
		helpers.assert_contains(written, 'LogsDirPath = "/fixture/Documents/ergopti_plus/"')
		helpers.assert_contains(written, 'ConfigDirPath = "/fixture/cfg/"')
		helpers.assert_eq(ConfigPaths.get_logs_dir(), "/fixture/Documents/ergopti_plus/")
		helpers.assert_eq(ConfigPaths.get_config_dir(), "/fixture/cfg/")
	end)

	helpers.it("keeps the logs override when only the configuration folder moves", function()
		local ConfigPaths, observations = fresh_resolver('LogsDirPath = "/fixture/sync/ergopti_plus/"\n')
		helpers.assert_true(ConfigPaths.set_config_dir("/fixture/cfg2/") == true)
		local written = observations.writes[#observations.writes]
		helpers.assert_contains(written, 'LogsDirPath = "/fixture/sync/ergopti_plus/"')
		helpers.assert_contains(written, 'ConfigDirPath = "/fixture/cfg2/"')
	end)

	helpers.it("clears an override equal to the default", function()
		local ConfigPaths, observations = fresh_resolver('LogsDirPath = "/fixture/sync/ergopti_plus/"\n')
		local changed = ConfigPaths.set_paths(nil, DEFAULT_LOGS)
		helpers.assert_true(changed == true)
		local written = observations.writes[#observations.writes]
		helpers.assert_contains(written, '# LogsDirPath = "' .. DEFAULT_LOGS .. '"')
		helpers.assert_nil(written:find('\nLogsDirPath', 1, true), "the default is never stored as an override")
		helpers.assert_eq(ConfigPaths.get_logs_dir(), DEFAULT_LOGS)
	end)

	-- The native worker refuses a logs folder it cannot open and the start then
	-- stops: a folder saved without being created would leave the application
	-- unable to boot until paths.toml is edited by hand.
	helpers.it("refuses a logs folder it cannot create and publishes nothing", function()
		local ConfigPaths, observations = fresh_resolver('ConfigDirPath = "/fixture/cfg/"\n')
		local writes_before = #observations.writes
		local changed, err = ConfigPaths.set_paths("/fixture/cfg2/", "/unwritable/place")
		helpers.assert_true(changed == false, "an uncreatable logs folder must be refused")
		helpers.assert_not_nil(err)
		helpers.assert_eq(#observations.writes, writes_before, "a refusal publishes nothing")
		helpers.assert_eq(ConfigPaths.get_logs_dir(), DEFAULT_LOGS)
		helpers.assert_eq(ConfigPaths.get_config_dir(), "/fixture/cfg/",
			"a refused save keeps the configuration folder too")
	end)

	helpers.it("refuses a relative override at save and keeps the stored one", function()
		local ConfigPaths, observations = fresh_resolver('LogsDirPath = "/fixture/sync/ergopti_plus/"\n')
		local writes_before = #observations.writes
		local changed, err = ConfigPaths.set_paths(nil, "relative/logs")
		helpers.assert_true(changed == false, "a relative folder must be refused")
		helpers.assert_not_nil(err)
		helpers.assert_eq(#observations.writes, writes_before, "a refusal publishes nothing")
		helpers.assert_eq(ConfigPaths.get_logs_dir(), "/fixture/sync/ergopti_plus/")
	end)
end)
