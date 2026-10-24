--- _shared/lua/test/error_dialog_core_contract.lua

--- ==============================================================================
--- MODULE: Error Window Core Contract
--- DESCRIPTION:
--- Pins the host-independent half of the error window (error_dialog/core.lua)
--- on both Lua runners: the once-only initialisation and its lifecycle lines,
--- the Debug switch, the report of one error and the page's first message.
--- register_host() checks that a host does not carry its own copy again.
--- ==============================================================================

local M = {}
local Core = require("error_dialog.core")

--- A logger that records each line as "<level> <tag> <text>".
--- @return table logger
--- @return table lines
local function recording_logger()
	local lines = {}
	local logger = {}
	for _, level in ipairs({ "start", "success", "error", "debug" }) do
		logger[level] = function(tag, template, ...)
			lines[#lines + 1] = level .. " " .. tag .. " " .. string.format(template, ...)
		end
	end
	return logger, lines
end

--- A diagnostics snapshot with the sections the report reads.
--- @return table snapshot
local function snapshot()
	return {
		generated_at = "2026-10-24T08:00:00Z",
		sections = {
			versions = { ergopti_version = "9.9.9", commit = "abc" },
			system = { os = "TestOS 1" },
			issues = { warn_count = 2, err_count = "3", recent = { "first", 42 } },
			paths = { errors_today = "/logs/errors.log", log = "/logs/today.log" },
		},
	}
end

--- Registers the core vectors in a driver suite.
--- @param helpers table Driver test API.
--- @param shared_root string Path of static/ergopti_plus/_shared.
function M.register(helpers, shared_root)
	local policy_path = shared_root .. "/modules/diagnostics/error_policy.json"
	helpers.describe("shared error window core (error-dialog-core)", function()
		helpers.it("loads the shipped policy and refuses a missing one", function()
			helpers.assert_type(Core.load_policy(policy_path), "table")
			local ok, err = pcall(Core.load_policy, shared_root .. "/modules/diagnostics/missing_policy.json")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("the error policy cannot be read", 1, true) ~= nil, tostring(err))
		end)

		helpers.it("initialises once under the host's lifecycle lines", function()
			local logger, lines = recording_logger()
			local adopted
			helpers.assert_eq(Core.init(logger, "host", false, function() return policy_path end, function(policy, decisions)
				adopted = { policy = policy, decisions = decisions }
				return false
			end), true)
			helpers.assert_type(adopted.policy, "table")
			helpers.assert_type(adopted.decisions, "table")
			helpers.assert_eq(lines, { "start host Initialising the error window…", "success host Error window ready (disabled)." })
			lines[1], lines[2] = nil, nil
			helpers.assert_eq(Core.init(logger, "host", true, function() error("never read") end, function()
				error("never adopted")
			end), false)
			helpers.assert_eq(lines, { "error host The error window was initialised twice; the second call is refused." })
		end)

		helpers.it("answers false and logs why when the policy cannot be loaded", function()
			local logger, lines = recording_logger()
			local adopted = false
			helpers.assert_eq(Core.init(logger, "host", false, function() error("no shared root") end, function()
				adopted = true
				return true
			end), false)
			helpers.assert_eq(adopted, false, "nothing is adopted")
			helpers.assert_eq(#lines, 2)
			helpers.assert_eq(lines[1], "start host Initialising the error window…")
			helpers.assert_true(lines[2]:find("^error host The error window cannot start: .*no shared root") ~= nil, lines[2])
		end)

		helpers.it("reads the stored switch first, then the manifest's boolean default", function()
			local defaults = { ["script.show_error_dialog"] = true }
			local function default_for(path) return defaults[path] end
			local stored = {}
			local storage = { get = function(key, default) if stored[key] == nil then return default end return stored[key] end }
			helpers.assert_eq(Core.stored_enabled(storage, default_for, "script.show_error_dialog"), true)
			stored["script.show_error_dialog"] = false
			helpers.assert_eq(Core.stored_enabled(storage, default_for, "script.show_error_dialog"), false)
			stored["script.show_error_dialog"] = "false"
			helpers.assert_eq(Core.stored_enabled(storage, default_for, "script.show_error_dialog"), true,
				"a non-boolean stored value falls to the declared default")
			defaults["script.show_error_dialog"] = "yes"
			helpers.assert_eq(pcall(Core.stored_enabled, storage, default_for, "script.show_error_dialog"), false,
				"no boolean default is an error")
		end)

		helpers.it("persists only a boolean and only reports a saved one", function()
			local logger, lines = recording_logger()
			local writes, answer = {}, true
			local resolved = 0
			local function storage()
				resolved = resolved + 1
				return { set = function(key, value) writes[#writes + 1] = { key, value }; return answer end }
			end
			helpers.assert_eq(Core.save_enabled(logger, "host", storage, "script.show_error_dialog", "true"), false)
			helpers.assert_eq(resolved, 0, "storage is not reached for an invalid value")
			helpers.assert_eq(lines[1], "error host set_enabled() needs a boolean, got string.")
			helpers.assert_eq(Core.save_enabled(logger, "host", storage, "script.show_error_dialog", false), true)
			answer = nil
			helpers.assert_eq(Core.save_enabled(logger, "host", storage, "script.show_error_dialog", true), false)
			helpers.assert_eq(lines[2], "error host The error window setting could not be saved; it is unchanged.")
			helpers.assert_eq(writes, { { "script.show_error_dialog", false }, { "script.show_error_dialog", true } })
		end)

		helpers.it("composes the report and the file an error or a crash is logged in", function()
			local record = Core.error_record(42, "boom\nsecond line")
			helpers.assert_eq(record.kind, "error")
			helpers.assert_eq(record.module, "42")
			helpers.assert_true(record.time:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil, record.time)
			local fields = Core.compose(record, snapshot(), "testdriver")
			helpers.assert_eq(fields.open_id, "errors_today")
			helpers.assert_eq(fields.log_path, "/logs/errors.log")
			helpers.assert_eq(fields.report.fields, { title = "42: boom", version = "9.9.9", os = "TestOS 1", driver = "testdriver" })
			helpers.assert_true(fields.report.text:find("first", 1, true) ~= nil, "recent issues are reported")
			local crash = { kind = "crash", module = "daemon", message = "segfault", time = "t", log_path = "/crash/1.txt" }
			local crashed = Core.compose(crash, snapshot(), "testdriver")
			helpers.assert_eq(crashed.open_id, "crash_report")
			helpers.assert_eq(crashed.log_path, "/crash/1.txt")
			helpers.assert_eq(crashed.paths.crash_report, "/crash/1.txt")
			helpers.assert_eq(crashed.paths.log, "/logs/today.log", "the snapshot's other paths are kept")
			local unknown = snapshot()
			unknown.sections.paths = {}
			helpers.assert_eq(pcall(Core.compose, record, unknown, "testdriver"), false, "an unknown log file is an error")
		end)

		helpers.it("redacts every text of the page's first message", function()
			local record = { kind = "error", module = "mod", message = "msg" }
			local message = Core.init_message(record, { text = "report" }, "/path", 3, function(text) return "<" .. text .. ">" end)
			helpers.assert_eq(message, { type = "init", kind = "error", module = "<mod>", message = "<msg>",
				log_path = "</path>", text = "<report>", more = 3 })
		end)
	end)
end

--- Checks that one host delegates to the core instead of carrying a copy.
--- @param helpers table Driver test API.
--- @param host_path string Path of the host's Lua source.
function M.register_host(helpers, host_path)
	helpers.describe("the error window host delegates to the shared core (error-dialog-core)", function()
		helpers.it(host_path:match("[^/]+/[^/]+$") .. " requires error_dialog.core and keeps no copy", function()
			local file = assert(io.open(host_path, "rb"))
			local source = assert(file:read("*a"))
			assert(file:close())
			helpers.assert_true(source:find('require("error_dialog.core")', 1, true) ~= nil, "requires the core")
			for _, copy in ipairs({ "Policy.validate(", "ErrorReport.compose(", "Policy.new_state(",
				"the error policy cannot be read", "was initialised twice" }) do
				helpers.assert_true(source:find(copy, 1, true) == nil, "the host carries its own " .. copy)
			end
		end)
	end)
end

return M
