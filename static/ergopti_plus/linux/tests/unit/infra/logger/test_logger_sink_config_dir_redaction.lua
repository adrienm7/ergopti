--- tests/unit/infra/logger/test_logger_sink_config_dir_redaction.lua

--- ==============================================================================
--- MODULE: Logger sink — configuration directory names masked at write time
--- DESCRIPTION:
--- The configuration directory is chosen by the user ("/srv/Sync/Jean Dupont"),
--- and every pack, backup and profile under it carries a name of their choosing.
--- The export collector masked those names, but the log file itself held them in
--- clear: a log attached by hand, or copied before the export, still told who the
--- user was (item 139 of the TODO).
---
--- WHAT IS PINNED (linux-logger-config-dir-redaction):
--- 1. A line the sink writes shows the directory as the placeholder
---    redaction.json declares and each name below it as the name placeholder,
---    except the names the product ships.
--- 2. The sink starts from the directory infra.config_paths resolves when it
---    installs.
--- 3. infra.config_paths hands over the directory it commits when the user moves
---    it, so lines written after the move hide the new folder's names.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

--- Reads the shared redaction rules, the single source of the placeholders.
--- @return table rules
local function rules()
	local Paths = require("infra.paths")
	local path = Paths.shared_root_from(Paths.driver_root()) .. "/diagnostics/data/redaction.json"
	local file = assert(io.open(path, "r"))
	local raw = file:read("*a")
	file:close()
	return Json.decode(raw)
end

local RULES = rules()
local CONFIG = RULES.config_placeholder
local NAME = RULES.config_name_placeholder

--- Installs a real sink into a private log directory with a fixture identity.
--- @param options table|nil { config_dir = string } folder the resolver reports.
--- @param body function Receives (Sink, Logger, log_path).
local function with_sink(options, body)
	options = options or {}
	local real_paths = helpers.fresh_module("infra.config_paths")
	local previous_paths = package.loaded["infra.config_paths"]
	package.loaded["infra.config_paths"] = setmetatable({
		get_config_dir = function() return options.config_dir or real_paths.default_config_dir() end,
	}, { __index = real_paths })
	local Sink = helpers.load_module("infra.logger_sink")
	local Logger = helpers.load_module("core.logger.engine")
	local base = os.getenv("TMPDIR") or "/tmp"
	local dir = base:gsub("/+$", "") .. "/ergopti_config_dir_redaction_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
	os.execute("mkdir -p '" .. dir .. "'")
	local ok, err = xpcall(function()
		helpers.assert_true(Sink.install(Logger, {
			log_dir = dir, redaction_context = { home = "/home/fixture-user", user = "fixture-user" },
		}), "the sink must install over a writable folder")
		body(Sink, Logger, dir .. "/ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log")
	end, debug.traceback)
	Sink.uninstall(Logger)
	package.loaded["infra.config_paths"] = previous_paths
	os.execute("rm -rf '" .. dir .. "'")
	if not ok then error(err, 0) end
end

--- Reads a whole file.
--- @param path string
--- @return string content
local function read(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end




-- ==============================================
-- ==============================================
-- ======= 1/ Lines Written by the Sink =========
-- ==============================================
-- ==============================================

helpers.describe("logger sink: configuration directory names (linux-logger-config-dir-redaction)", function()
	helpers.it("writes the directory and the names below it as their placeholders", function()
		helpers.assert_true(type(CONFIG) == "string" and CONFIG ~= "", "redaction.json must declare the directory placeholder")
		helpers.assert_true(type(NAME) == "string" and NAME ~= "", "redaction.json must declare the name placeholder")
		with_sink({ config_dir = "/srv/Sync/Jean Dupont" }, function(_, Logger, log_path)
			Logger.info("config_dir_test", "Loaded /srv/Sync/Jean Dupont/famille Dupont.toml")
			Logger.info("config_dir_test", "Read /srv/Sync/Jean Dupont/config.toml")
			local content = read(log_path)
			helpers.assert_true(content:find("Jean Dupont", 1, true) == nil,
				"the user's folder name must not reach the log file:\n" .. content)
			helpers.assert_true(content:find("Loaded " .. CONFIG .. "/" .. NAME, 1, true) ~= nil,
				"a pack under the folder is written as the placeholders:\n" .. content)
			helpers.assert_true(content:find("Read " .. CONFIG .. "/config.toml", 1, true) ~= nil,
				"a file the product ships keeps its name:\n" .. content)
		end)
	end)

	helpers.it("follows the folder handed over after a move", function()
		with_sink({ config_dir = "/srv/Sync/Jean Dupont" }, function(Sink)
			Sink.follow_config_dir("/srv/Documents/Réglages Jean")
			local redact = assert(Sink.capture_redactor(), "an installed sink exposes its redactor")
			helpers.assert_eq(redact("Loaded /srv/Documents/Réglages Jean/perso.toml"), "Loaded " .. CONFIG .. "/" .. NAME,
				"the folder followed last is the one masked")
		end)
	end)

	helpers.it("refuses a directory that is not a path", function()
		local Sink = helpers.load_module("infra.logger_sink")
		local accepted, refusal = pcall(Sink.follow_config_dir, { "/srv/Sync" })
		helpers.assert_eq(accepted, false, "a table is not a directory")
		helpers.assert_true(tostring(refusal):find("configuration directory", 1, true) ~= nil, tostring(refusal))
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ The Path Owner Hands It Over =======
-- ===============================================
-- ===============================================

helpers.describe("config_paths: hands its folder to the log sink (linux-logger-config-dir-redaction)", function()
	helpers.it("hands over the folder the user moves to", function()
		with_sink(nil, function(Sink)
			local stored = {}
			local saved_storage, saved_shell = package.loaded["adapters.storage"], package.loaded["adapters.shell_runner"]
			package.loaded["adapters.storage"] = {
				get = function(key, default) if stored[key] ~= nil then return stored[key] end return default end,
				set = function(key, value) stored[key] = value; return true end,
				delete = function(key) stored[key] = nil; return true end,
			}
			package.loaded["adapters.shell_runner"] = {
				run = function() return true end,
				quote = function(value) return "'" .. value .. "'" end,
			}
			local ok, err = pcall(function()
				local ConfigPaths = helpers.fresh_module("infra.config_paths")
				helpers.assert_true(ConfigPaths.set_config_dir("/srv/Moved/Jean Dupont"), "the move must commit")
				local redact = assert(Sink.capture_redactor())
				helpers.assert_eq(redact("Loaded /srv/Moved/Jean Dupont/famille.toml"), "Loaded " .. CONFIG .. "/" .. NAME,
					"the committed folder must reach the sink, or lines after the move show its names")
			end)
			package.loaded["adapters.storage"], package.loaded["adapters.shell_runner"] = saved_storage, saved_shell
			if not ok then error(err, 0) end
		end)
	end)
end)
