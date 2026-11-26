--- tests/unit/core/process/test_app_launcher_log_privacy.lua

--- Verifies that the launcher logs every outcome by the program's name only (lch-01).
local helpers = require("tests.helpers")

--- Loads the launcher with a recording logger and the given hs.application stub.
--- @param application table hs.application stub.
--- @param runner table|nil Shell runner stub.
--- @return table launcher, table lines
local function load(application, runner)
	local lines = {}
	local function record(level)
		return function(_, fmt, ...) lines[#lines + 1] = { level = level, text = string.format(fmt, ...) } end
	end
	package.loaded["core.logger.engine.logger"] = {
		info = record("info"), warn = record("warn"), error = record("error"), debug = record("debug"),
	}
	if runner then package.loaded["core.process.adapters.shell_runner"] = runner end
	local launcher = helpers.load_with_stubs("apps.adapters.launcher", { application = application })
	return launcher, lines
end

--- Asserts that no recorded line contains a literal.
--- @param lines table
--- @param literal string
local function assert_absent(lines, literal)
	for _, line in ipairs(lines) do
		helpers.assert_true(line.text:find(literal, 1, true) == nil,
			"the log quotes a private value: " .. line.text)
	end
end

local SCOPE = { "apps.adapters.launcher", "core.logger.engine.logger", "core.process.adapters.shell_runner" }

helpers.describe("application launch logs (lch-01)", function()
	helpers.it("names a document path by its base name only when the launch raises", function()
		helpers.with_stub_scope(SCOPE, function()
			local target = "/Users/someone/Private/Salary review.numbers"
			local launcher, lines = load({
				launchOrFocus = function(path) error("cannot open " .. path) end,
			})
			helpers.assert_eq(launcher.launch(target), false)
			helpers.assert_eq(#lines, 1)
			helpers.assert_eq(lines[1].level, "error")
			helpers.assert_true(lines[1].text:find("Salary review.numbers", 1, true) ~= nil, lines[1].text)
			assert_absent(lines, "/Users/someone")
		end)
	end)

	helpers.it("logs a refused launch instead of returning false in silence", function()
		helpers.with_stub_scope(SCOPE, function()
			local launcher, lines = load({
				launchOrFocus = function() return false end,
				launchOrFocusByBundleID = function() return false end,
			})
			helpers.assert_eq(launcher.launch("System Preferences"), false)
			helpers.assert_eq(#lines, 1)
			helpers.assert_eq(lines[1].level, "warn")
			helpers.assert_true(lines[1].text:find("'System Preferences'", 1, true) ~= nil, lines[1].text)
		end)
	end)

	helpers.it("logs an accepted launch by its URI scheme", function()
		helpers.with_stub_scope(SCOPE, function()
			local launcher, lines = load({ launchOrFocus = function() return true end })
			helpers.assert_eq(launcher.launch("https://example.com/search?q=private"), true)
			helpers.assert_eq(#lines, 1)
			helpers.assert_eq(lines[1].level, "info")
			helpers.assert_true(lines[1].text:find("'https:'", 1, true) ~= nil, lines[1].text)
			assert_absent(lines, "private")
		end)
	end)

	helpers.it("never logs the arguments of a launch with arguments", function()
		helpers.with_stub_scope(SCOPE, function()
			local launcher, lines = load({}, { spawn = function(_, argv)
				return { start = function() error("spawn refused for " .. table.concat(argv, " ")) end }
			end })
			launcher.launchWithArgs("/Applications/Secret Tool.app", { "--query", "my secret search" })
			helpers.assert_eq(#lines, 1)
			helpers.assert_eq(lines[1].level, "error")
			helpers.assert_true(lines[1].text:find("'Secret Tool.app'", 1, true) ~= nil, lines[1].text)
			assert_absent(lines, "my secret search")
			assert_absent(lines, "/Applications/")
		end)
	end)

	helpers.it("logs a started launch with its argument count only", function()
		helpers.with_stub_scope(SCOPE, function()
			local launcher, lines = load({}, { spawn = function()
				return { start = function() return true end }
			end })
			launcher.launchWithArgs("Safari", { "private text" })
			helpers.assert_eq(#lines, 1)
			helpers.assert_eq(lines[1].text, "Launched 'Safari' with 1 argument(s).")
		end)
	end)

	helpers.it("names a bundle identifier, an app bundle and an empty target", function()
		helpers.with_stub_scope(SCOPE, function()
			local launcher = load({})
			helpers.assert_eq(launcher.program_name("com.apple.Safari"), "com.apple.Safari")
			helpers.assert_eq(launcher.program_name("/Applications/Safari.app/"), "Safari.app")
			helpers.assert_eq(launcher.program_name('  "x-apple.systempreferences:com.apple.Privacy" '), "x-apple.systempreferences:")
			helpers.assert_eq(launcher.program_name(""), "unknown")
		end)
	end)
end)
