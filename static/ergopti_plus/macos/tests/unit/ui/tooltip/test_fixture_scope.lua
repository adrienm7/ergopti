--- tests/unit/ui/tooltip/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: Tooltip Fixture Isolation
--- DESCRIPTION:
--- Proves exact native cleanup and fresh transitive owners across tooltip mounts.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local TooltipContext = require("tests.support.tooltip_context_watchers")
local OWNERS = {
	"hs", "tests.stubs.hs", "ui.tooltip.config", "ui.tooltip.renderer",
	"ui.tooltip.tooltip_llm", "ui.tooltip.tooltip_hotstring", "ui.tooltip.init",
	"adapters.event_provenance", "adapters.key_state", "adapters.synthetic_input",
	"adapters.timer_scheduler", "adapters.storage", "infra.hotpath_profiler", "infra.logger",
}

local function with_observer(callback)
	helpers.with_stub_scope(OWNERS, function()
		local install = TooltipContext.install
		local preload = package.preload["ui.tooltip.tooltip_llm"]
		local outcome = table.pack(xpcall(callback, debug.traceback))
		TooltipContext.install = install
		package.preload["ui.tooltip.tooltip_llm"] = preload
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Tooltip fixture isolation", function()
	for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
		helpers.it("(tooltip-fixture-scope) restores native and module owners after " .. mode, function()
			with_observer(function()
				local alias = {}
				package.loaded["hs"] = alias
				local native = rawget(_G, "hs")
				local captured
				local install = TooltipContext.install
				TooltipContext.install = function()
					captured = { target = hs, spaces = hs.spaces, uielement = hs.uielement,
						focused_window = hs.window.focusedWindow }
					return install()
				end
				local marker = "tooltip fixture injected failure"
				if mode == "construction failure" then
					package.preload["ui.tooltip.tooltip_llm"] = function() error(marker, 0) end
				end
				local ok, result = pcall(support.with_fixture, function(fixture)
					local context = fixture.load_tooltip(support.CASES[1])
					helpers.assert_type(context.tooltip.show_predictions, "function")
					if mode == "callback failure" then error(marker, 0) end
					return "completed"
				end)
				helpers.assert_type(captured, "table", "native setup must precede the tested outcome")
				helpers.assert_eq(ok, mode == "success")
				if mode == "success" then
					helpers.assert_eq(result, "completed")
				else
					helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil)
				end
				helpers.assert_true(rawequal(rawget(_G, "hs"), native))
				helpers.assert_true(package.loaded["hs"] == alias)
				for _, name in ipairs(OWNERS) do
					if name ~= "hs" then helpers.assert_nil(package.loaded[name], name .. " must leave its scope") end
				end
				helpers.assert_true(captured.target.spaces == captured.spaces)
				helpers.assert_true(captured.target.uielement == captured.uielement)
				helpers.assert_true(captured.target.window.focusedWindow == captured.focused_window)
			end)
		end)
	end

	helpers.it("(tooltip-fixture-scope) remounts real transitive consumers on the new native host", function()
		with_observer(function()
			support.with_fixture(function(fixture)
				local previous_storage, previous_profiler
				for attempt = 1, 2 do
					fixture.load_tooltip(support.CASES[1])
					local storage = require("adapters.storage")
					local profiler = require("infra.hotpath_profiler")
					helpers.assert_type(storage.get, "function")
					helpers.assert_type(profiler.now, "function")
					local settings_reads, clock_reads = 0, 0
					hs.settings.get = function()
						settings_reads = settings_reads + 1
						return attempt
					end
					hs.timer.absoluteTime = function()
						clock_reads = clock_reads + 1
						return attempt * 1000
					end
					helpers.assert_eq(storage.get("fixture_probe"), attempt)
					helpers.assert_type(profiler.now(), "number")
					helpers.assert_eq(settings_reads, 1, "storage must read the current native settings")
					helpers.assert_eq(clock_reads, 1, "profiler must read the current native clock")
					if attempt == 2 then
						helpers.assert_true(storage ~= previous_storage, "storage must not retain the previous native host")
						helpers.assert_true(profiler ~= previous_profiler, "profiler must not retain the previous timer adapter")
					end
					previous_storage, previous_profiler = storage, profiler
				end
			end)
		end)
	end)
end)
