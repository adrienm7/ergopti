--- tests/unit/infra/field_check/test_field_check_engine.lua

--- ==============================================================================
--- MODULE: Field Check Engine
--- DESCRIPTION:
--- The evidence model of the Debug menu's one-click Mac checks:
--- 1. a step value outside the closed grammar (a path, a URL, a user name, a
---    long text) is replaced by "redacted", so the log line cannot leak one;
--- 2. a step cannot be recorded twice and a run passes unless a step failed;
--- 3. one check runs at a time and settles exactly once, even if a port calls
---    back twice, and a check that raises is recorded as a failed step.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks" }

--- Loads the engine over a recording logger and a scripted check table.
--- @param body function(Engine, world)
local function with_engine(body)
	helpers.with_stub_scope(MODULES, function()
		local world = { lines = {}, info_lines = {} }
		local logger = helpers.make_logger_stub()
		-- The result record is evidence (spec 4.3): the logger must never fold it.
		logger.evidence = function(_, message, ...) world.lines[#world.lines + 1] = string.format(message, ...) end
		logger.info = function(_, message, ...)
			world.info_lines[#world.info_lines + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.field_check_checks"] = { checks = {} }
		package.loaded["infra.field_check"] = nil
		local Engine = require("infra.field_check")
		world.checks = package.loaded["infra.field_check_checks"].checks
		body(Engine, world)
	end)
end

helpers.describe("field check evidence (privacy)", function()
	helpers.it("keeps counts, states and versions", function()
		with_engine(function(Engine)
			helpers.assert_eq(Engine.sanitize_value(12), "12")
			helpers.assert_eq(Engine.sanitize_value("activated_enabled"), "activated_enabled")
			helpers.assert_eq(Engine.sanitize_value("16.0.0"), "16.0.0")
			helpers.assert_nil(Engine.sanitize_value(nil))
			helpers.assert_nil(Engine.sanitize_value(""))
		end)
	end)

	helpers.it("redacts anything that could carry a path, a URL or a name", function()
		with_engine(function(Engine)
			for _, leaked in ipairs({
				"/Users/jane/Library", "https://example.org/pac.js", "jane doe",
				"~/.config/karabiner", "a=b", "x@y.z", string.rep("a", Engine.MAX_VALUE_LENGTH + 1),
			}) do
				helpers.assert_eq(Engine.sanitize_value(leaked), Engine.REDACTED, leaked)
			end
		end)
	end)

	helpers.it("never lets a leaked value reach the log line", function()
		with_engine(function(Engine)
			local report = Engine.new_report("lease")
			report.step("cli_version", "fail", "/Users/jane/bin/tool")
			local line = Engine.format_log_line(report.result())
			helpers.assert_eq(line:find("jane", 1, true), nil)
			helpers.assert_eq(line:find("/", 1, true), nil)
			helpers.assert_contains(line, "cli_version=fail:redacted")
		end)
	end)
end)

helpers.describe("field check report", function()
	helpers.it("passes unless a step failed; info and skip never fail", function()
		with_engine(function(Engine)
			local report = Engine.new_report("lease")
			report.step("a", "pass", 1)
			report.step("b", "info", "yes")
			report.step("c", "skip")
			helpers.assert_true(report.result().passed)
			report.step("d", "fail", "timeout")
			helpers.assert_eq(report.result().passed, false)
			helpers.assert_eq(Engine.format_log_line(report.result()),
				"check=lease verdict=fail steps=4 a=pass:1 b=info:yes c=skip d=fail:timeout")
		end)
	end)

	helpers.it("refuses a repeated step and an unknown state", function()
		with_engine(function(Engine)
			local report = Engine.new_report("lease")
			report.step("a", "pass")
			local repeated_ok, repeated_err = pcall(report.step, "a", "pass")
			helpers.assert_eq(repeated_ok, false)
			helpers.assert_true(tostring(repeated_err):find("recorded twice", 1, true) ~= nil, tostring(repeated_err))
			local unknown_ok, unknown_err = pcall(report.step, "b", "maybe")
			helpers.assert_eq(unknown_ok, false)
			helpers.assert_true(tostring(unknown_err):find("unknown step state", 1, true) ~= nil, tostring(unknown_err))
		end)
	end)

	helpers.it("renders one localized line per step", function()
		with_engine(function(Engine)
			local report = Engine.new_report("lease")
			report.step("a", "pass", 3)
			report.step("b", "fail")
			local text = Engine.format_text(report.result(), function(key) return "<" .. key .. ">" end)
			helpers.assert_eq(text,
				"<field_check.verdict_fail>\n\n✅ <field_check.step.a> : 3\n❌ <field_check.step.b>")
		end)
	end)
end)

helpers.describe("field check run", function()
	helpers.it("delivers one result and logs the evidence line", function()
		with_engine(function(Engine, world)
			world.checks.demo = function(_, report, finish)
				report.step("a", "pass", 1)
				finish()
				finish()
			end
			local delivered = {}
			helpers.assert_true(Engine.run("demo", {}, function(result) delivered[#delivered + 1] = result end))
			helpers.assert_eq(#delivered, 1)
			helpers.assert_true(delivered[1].passed)
			helpers.assert_eq(Engine.is_running(), false)
			helpers.assert_eq(world.lines[1], "Field check result: check=demo verdict=pass steps=1 a=pass:1")
			for _, line in ipairs(world.info_lines) do
				helpers.assert_eq(line:find("Field check result", 1, true), nil,
					"the result record must not go through the collapsible info variant")
			end
		end)
	end)

	helpers.it("refuses a second check while one is pending, then accepts again", function()
		with_engine(function(Engine, world)
			local release
			world.checks.slow = function(_, report, finish)
				release = function() report.step("a", "pass"); finish() end
			end
			helpers.assert_true(Engine.run("slow", {}, function() end))
			helpers.assert_true(Engine.is_running())
			helpers.assert_eq(Engine.run("slow", {}, function() end), false)
			release()
			helpers.assert_eq(Engine.is_running(), false)
			helpers.assert_true(Engine.run("slow", {}, function() end))
		end)
	end)

	helpers.it("records a raising check as a failed step instead of losing it", function()
		with_engine(function(Engine, world)
			world.checks.boom = function() error("secret /Users/jane/x") end
			local delivered
			helpers.assert_true(Engine.run("boom", {}, function(result) delivered = result end))
			helpers.assert_eq(delivered.passed, false)
			helpers.assert_eq(delivered.steps[1].id, "internal_error")
			helpers.assert_eq(Engine.is_running(), false)
			for _, line in ipairs(world.lines) do helpers.assert_eq(line:find("jane", 1, true), nil) end
		end)
	end)

	helpers.it("refuses an unknown check without becoming busy", function()
		with_engine(function(Engine)
			helpers.assert_eq(Engine.run("nope", {}, function() end), false)
			helpers.assert_eq(Engine.is_running(), false)
		end)
	end)
end)
