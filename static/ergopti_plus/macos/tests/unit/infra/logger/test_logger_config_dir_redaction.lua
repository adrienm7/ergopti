--- tests/unit/infra/logger/test_logger_config_dir_redaction.lua

--- ==============================================================================
--- MODULE: Logger — configuration directory names masked at write time
--- DESCRIPTION:
--- The configuration directory is chosen by the user ("~/Sync/Jean Dupont"), and
--- every pack, backup and profile under it carries a name of their choosing. The
--- export collector masked those names, but the log file itself held them in
--- clear: a log attached by hand, or copied before the export, still told who
--- the user was (item 139 of the TODO).
---
--- WHAT IS PINNED (logger-config-dir-redaction):
--- 1. A line written through the logger's redactor shows the directory as the
---    placeholder redaction.json declares and each name below it as the name
---    placeholder, except the names the product ships.
--- 2. The redactor follows the directory the path owner hands it: after a move,
---    the new directory is masked.
--- 3. The path owner hands over the directory it resolves at initialization and
---    the one it commits when the user moves it, so the two halves are joined.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local SourceFile = require("tests.support.source_file")

local POLICY = SourceFile.read(helpers.shared("diagnostics/data/redaction.json"))
local RULES = Json.decode(POLICY)
local CONFIG = RULES.config_placeholder
local NAME = RULES.config_name_placeholder

-- The suite's logger: each case runs a fresh one in a stub scope, then hands
-- the shared core hooks back to this instance, as the file sink tests do.
local SuiteLogger = helpers.load_with_stubs("infra.logger")

--- Runs a callback over a fresh logger whose privacy is admitted.
--- @param callback function Receives the fresh logger.
local function with_logger(callback)
	helpers.with_stub_scope({ "infra.logger", "core.logger.engine", "adapters.log_transport" }, function()
		local Logger = require("infra.logger")
		Logger.initialize_privacy(POLICY, { home = "/Users/PrivateUser", user = "PrivateUser" })
		callback(Logger)
	end)
	SuiteLogger.claim_core_hooks()
end





-- ==================================================
-- ==================================================
-- ======= 1/ The Redactor Follows the Folder =======
-- ==================================================
-- ==================================================

helpers.describe("logger: configuration directory names (logger-config-dir-redaction)", function()
	helpers.it("masks the directory and the names the user chose below it", function()
		helpers.assert_true(type(CONFIG) == "string" and CONFIG ~= "", "redaction.json must declare the directory placeholder")
		helpers.assert_true(type(NAME) == "string" and NAME ~= "", "redaction.json must declare the name placeholder")
		with_logger(function(Logger)
			Logger.follow_config_dir("/Volumes/Sync/Jean Dupont")
			helpers.assert_eq(Logger.redact_message("Loaded /Volumes/Sync/Jean Dupont/famille Dupont.toml"),
				"Loaded " .. CONFIG .. "/" .. NAME, "a pack name under the folder must not reach the log")
			helpers.assert_eq(Logger.redact_message("Saved '/Volumes/Sync/Jean Dupont/hotstrings/Mes packs/a.toml'"),
				"Saved '" .. CONFIG .. "/hotstrings/" .. NAME .. "/" .. NAME .. "'",
				"a shipped folder keeps its name; the user's own names below it do not")
			helpers.assert_eq(Logger.redact_message("Read /Volumes/Sync/Jean Dupont/config.toml"),
				"Read " .. CONFIG .. "/config.toml", "a file the product ships keeps its name")
		end)
	end)

	helpers.it("follows the folder the user moves to at runtime", function()
		with_logger(function(Logger)
			Logger.follow_config_dir("/Volumes/Sync/Jean Dupont/")
			Logger.follow_config_dir("/Users/PrivateUser/Documents/Réglages Jean")
			helpers.assert_eq(Logger.redact_message("Loaded /Users/PrivateUser/Documents/Réglages Jean/perso.toml"),
				"Loaded " .. CONFIG .. "/" .. NAME, "the folder followed last is the one masked")
			Logger.follow_config_dir(nil)
			helpers.assert_eq(Logger.redact_message("Loaded /Volumes/Data/perso.toml"), "Loaded /Volumes/Data/perso.toml",
				"with no folder followed, an unrelated path is left as written")
		end)
	end)

	helpers.it("refuses a directory that is not a path", function()
		with_logger(function(Logger)
			local accepted, refusal = pcall(Logger.follow_config_dir, { "/Volumes/Sync" })
			helpers.assert_eq(accepted, false, "a table is not a directory")
			helpers.assert_contains(refusal, "configuration directory")
		end)
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ The Path Owner Hands It Over =======
-- ===============================================
-- ===============================================

--- Loads a resolver over an in-memory paths.toml and records what it hands the
--- logger's redactor.
--- @param bootstrap_content string|nil Existing paths.toml bytes.
--- @return table config_paths
--- @return table followed Every directory handed to follow_config_dir.
local function fresh_resolver(bootstrap_content)
	local followed = {}
	local logger = helpers.make_logger_stub()
	logger.follow_config_dir = function(dir) followed[#followed + 1] = dir end
	local previous_logger = package.loaded["infra.logger"]
	local previous_file_system = package.loaded["adapters.file_system"]
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.file_system"] = {
		read_with_status = function()
			if bootstrap_content ~= nil then return bootstrap_content, "ok" end
			return nil, "absent"
		end,
		create_if_absent = function() return true, "created" end,
		write_if_unchanged = function() return true end,
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
				if type(path) == "string" and path:sub(1, 9) == "/fixture/" then return { mode = "directory" } end
				return nil
			end,
			mkdir = function() return true end,
		},
	})
	_G.hs = previous_hs
	os.getenv = real_getenv
	package.loaded["adapters.file_system"] = previous_file_system
	package.loaded["infra.logger"] = previous_logger
	package.loaded["infra.config_paths"] = nil
	if not ok then error(ConfigPaths, 0) end
	helpers.assert_true(ConfigPaths.init("/fixture/driver/"), "the resolver must initialise over the fixture")
	return ConfigPaths, followed
end

helpers.describe("config_paths: hands its folder to the log redactor (logger-config-dir-redaction)", function()
	helpers.it("hands over the folder resolved at initialization", function()
		local ConfigPaths, followed = fresh_resolver('ConfigDirPath = "/fixture/Sync/Jean Dupont"\n')
		helpers.assert_true(#followed >= 1, "initialization must hand its folder to the redactor")
		helpers.assert_eq(followed[#followed], ConfigPaths.get_config_dir())
		helpers.assert_true(followed[#followed]:find("Jean Dupont", 1, true) ~= nil,
			"the override from paths.toml is the folder handed over: " .. tostring(followed[#followed]))
	end)

	helpers.it("hands over the folder the user moves to", function()
		local ConfigPaths, followed = fresh_resolver(nil)
		local changed = ConfigPaths.set_config_dir("/fixture/Documents/Réglages Jean")
		helpers.assert_eq(changed, true, "the move must commit")
		helpers.assert_eq(followed[#followed], ConfigPaths.get_config_dir(),
			"the committed folder must reach the redactor, or lines after the move show its names")
		helpers.assert_true(followed[#followed]:find("Réglages Jean", 1, true) ~= nil,
			"the new folder is the one handed over: " .. tostring(followed[#followed]))
	end)
end)
