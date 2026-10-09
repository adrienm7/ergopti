--- tests/unit/infra/test_private_publication_diagnostics.lua

--- Exercises private diagnostics through the actual preferences and batch publisher.
local helpers = require("tests.helpers")
local PRIVATE = "PRIVATE_PUBLICATION_ARGUMENT"

local function with_preferences(body)
	helpers.with_fresh_modules({ "infra.preferences", "infra.logger", "toml_codec.writer", "adapters.file_system" }, function()
		local logs, categories = {}, {}
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "error", "warn", "info", "debug" }) do
			logger[level] = function(_, message, ...) logs[#logs + 1] = string.format(message, ...) end
		end
		package.loaded["infra.logger"] = logger
		local content = '[gestures]\naction_parameters = { retained = "unrelated" }\n'
		local files = {
			read_with_status = function() return content, "ok" end,
			write_if_unchanged = function() error(PRIVATE) end,
		}
		package.loaded["adapters.file_system"] = files
		local preferences = require("infra.preferences")
		preferences.load("config")
		local function reporter(category, ...)
			helpers.assert_eq(select("#", ...), 0, "private diagnostics carry categories only")
			categories[#categories + 1] = category
		end
		body(preferences, logs, categories, reporter, files)
	end)
end

helpers.describe("private publication diagnostic ownership", function()
	for _, domain in ipairs({ "owned", "full" }) do
		helpers.it("private-publication actual " .. domain .. " publisher contains native exception details", function()
			with_preferences(function(preferences, logs, categories, reporter)
				local committed
				if domain == "owned" then
					committed = preferences.publish_owned("config", { { section = "gestures", key = "enabled", value = true } }, preferences.source_snapshot("config"), reporter)
				else
					committed = preferences.save("config", {}, {}, { gestures = {
						get_all_action_parameters = function() return { keyboard__cmd_1__run_program = PRIVATE } end,
					} }, nil, reporter)
				end
				helpers.assert_eq(committed, false)
				for _, line in ipairs(logs) do helpers.assert_eq(line:find(PRIVATE, 1, true), nil) end
				helpers.assert_true(#categories > 0, "the actual failed publisher must report its refusal")
			end)
		end)
	end
	helpers.it("private-publication ordinary diagnostics retain concrete native errors", function()
		with_preferences(function(preferences, logs)
			helpers.assert_eq(preferences.publish_owned("config", { { section = "gestures", key = "enabled", value = true } }, preferences.source_snapshot("config")), false)
			local found = false
			for _, line in ipairs(logs) do if line:find(PRIVATE, 1, true) then found = true end end
			helpers.assert_eq(found, true, "ordinary publication diagnostics must remain concrete")
		end)
	end)
	helpers.it("private-publication callback failure cannot reveal its exception", function()
		with_preferences(function(preferences, logs)
			helpers.assert_eq(preferences.publish_owned("config", { { section = "gestures", key = "enabled", value = true } },
				preferences.source_snapshot("config"), function() error(PRIVATE) end), false)
			for _, line in ipairs(logs) do helpers.assert_eq(line:find(PRIVATE, 1, true), nil) end
		end)
	end)
	helpers.it("private-publication preserves canonical two-argument adapter write arity", function()
		with_preferences(function(preferences, _, _, reporter, files)
			files.write_if_unchanged = nil
			local called = false
			files.write = function(...) helpers.assert_eq(select("#", ...), 2); called = true; return false end
			helpers.assert_eq(preferences.publish_owned("config", { { section = "gestures", key = "enabled", value = true } },
				preferences.source_snapshot("config"), reporter), false)
			helpers.assert_eq(called, true)
		end)
	end)
	helpers.it("private-publication actual native staging exception and retained retry use their original diagnostic owner", function()
		require("tests.support.file_system_transaction_fixture").with_fixture(function(fixture)
			local logs, categories = {}, {}
			local logger = helpers.make_logger_stub()
			for _, level in ipairs({ "error", "warn", "info", "debug" }) do
				logger[level] = function(_, message, ...) logs[#logs + 1] = string.format(message, ...) end
			end
			package.loaded["infra.logger"] = logger
			local path = os.tmpname():gsub("\\", "/")
			assert(os.remove(path))
			local adapter = fixture.make_adapter()
			local original_open, original_remove = io.open, os.remove
			local retained = true
			local ok, failure = xpcall(function()
				io.open = function(target, mode)
					local handle, detail = original_open(target, mode)
					if not handle or mode ~= "w" or not target:match("/payload$") then return handle, detail end
					return { write = function() error(PRIVATE) end, close = function() return handle:close() end }
				end
				os.remove = function(target)
					if retained and target:match("/payload$") then return false, PRIVATE end
					return original_remove(target)
				end
				local function reporter(category, ...)
					helpers.assert_eq(select("#", ...), 0)
					categories[#categories + 1] = category
				end
				helpers.assert_eq(adapter.write_if_unchanged(path, PRIVATE, { status = "absent" }, reporter), false)
				io.open = original_open
				helpers.assert_eq(adapter.write(path, "ordinary successor"), false, "the retained private staging owner still blocks publication")
				for _, line in ipairs(logs) do helpers.assert_eq(line:find(PRIVATE, 1, true), nil) end
				helpers.assert_true(#categories > 1)
				retained = false
				helpers.assert_eq(adapter.write(path, "ordinary successor"), true)
				for _, line in ipairs(logs) do helpers.assert_eq(line:find(PRIVATE, 1, true), nil) end
			end, debug.traceback)
			io.open, os.remove = original_open, original_remove
			retained = false
			pcall(adapter.write, path, "fixture cleanup")
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)
	for _, private in ipairs({ true, false }) do
		helpers.it("private-publication actual keyboard setter exception " .. (private and "is redacted" or "keeps ordinary details"), function()
			helpers.with_fresh_modules({ "modules.shortcuts.keyboard_shortcuts", "modules.gestures.actions", "infra.config_paths",
				"infra.paths", "infra.preferences", "infra.logger", "toml_codec.writer", "adapters.file_system" }, function()
				local logs, categories, unavailable = {}, {}, false
				local logger = helpers.make_logger_stub()
				for _, level in ipairs({ "error", "warn", "info", "debug" }) do
					logger[level] = function(_, message, ...) logs[#logs + 1] = string.format(message, ...) end
				end
				package.loaded["infra.logger"] = logger
				package.loaded["infra.paths"] = { shared = helpers.shared }
				package.loaded["infra.config_paths"] = { get = function() return "config" end }
				package.loaded["modules.gestures.actions"] = { is_assignable = function() return true end }
				package.loaded["adapters.file_system"] = {
					read = function(path) local file = assert(io.open(path, "rb")); local body = file:read("*a"); file:close(); return body end,
					read_with_status = function()
						if unavailable then return nil, "error", PRIVATE end
						return '[shortcuts.keyboard]\ncmd_1 = "none"\n', "ok"
					end,
				}
				local keyboard = require("modules.shortcuts.keyboard_shortcuts")
				helpers.assert_eq(keyboard.get_action("cmd_1"), "none")
				unavailable = true
				local function reporter(category) categories[#categories + 1] = category end
				local called, committed = pcall(keyboard.set_action, "cmd_1", "run_program", private and reporter or nil)
				helpers.assert_eq(called, true, "the native setter must acknowledge a raised preparation refusal")
				helpers.assert_eq(committed, false)
				helpers.assert_eq(keyboard.get_action("cmd_1"), "none")
				local found = false
				for _, line in ipairs(logs) do if line:find(PRIVATE, 1, true) then found = true end end
				helpers.assert_eq(found, not private)
				if private then helpers.assert_eq(categories, { "assignment" }) end
			end)
		end)
	end
end)
