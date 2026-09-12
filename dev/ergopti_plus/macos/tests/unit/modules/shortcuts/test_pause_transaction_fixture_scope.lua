--- tests/unit/modules/shortcuts/test_pause_transaction_fixture_scope.lua

--- ==============================================================================
--- MODULE: Pause Transaction Fixture Scope Tests
--- DESCRIPTION:
--- Preserves predecessor collaborators and native timer ownership across scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.pause_transaction_fixture")
local OWNERS = {
	"modules.shortcuts.script_control",
	"infra.logger",
	"infra.notifications",
	"infra.keycodes",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"adapters.key_state",
	"adapters.synthetic_input",
	"modules.llm.warmup_controller",
	"modules.llm.api_mlx",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"modules.keylogger",
	"adapters.event_provenance",
	"adapters.timer_scheduler",
	"hs", "tests.stubs.hs", "hs.timer",
}

helpers.describe("Pause transaction fixture ownership", function()
	for _, predecessor_kind in ipairs({ "absent", "false", "table" }) do
		for _, outcome in ipairs({ "success", "callback failure", "construction failure" }) do
			helpers.it("(pause-fixture-scope) restores " .. predecessor_kind .. " after " .. outcome, function()
				helpers.with_stub_scope(OWNERS, function()
					local predecessor
					if predecessor_kind == "false" then predecessor = false end
					if predecessor_kind == "table" then predecessor = {} end
					for _, name in ipairs(OWNERS) do
						if name ~= "adapters.event_provenance" and name ~= "adapters.timer_scheduler" then
							package.loaded[name] = predecessor
						end
					end
					_G.hs = predecessor
					local saved = {}
					for _, name in ipairs(OWNERS) do saved[name] = package.loaded[name] end
					local original_require = require
					local construction_reached = false
					if outcome == "construction failure" then
						_G.require = function(name)
							local loaded = table.pack(original_require(name))
							if name == "modules.shortcuts.script_control" then
								construction_reached = true
								error("pause construction marker")
							end
							return table.unpack(loaded, 1, loaded.n)
						end
					end
					local reached = false
					local ok, detail = pcall(Fixture.with_context, nil, function(control, ctx)
						helpers.assert_true(control.pause_all())
						ctx.fire_deferred()
						helpers.assert_eq(ctx.calls.karabiner_pause, 1)
						ctx.pause_callback(true, "paused")
						helpers.assert_eq(control.is_paused(), true)
						helpers.assert_eq(ctx.calls.keymap_pause, 1)
						helpers.assert_true(control.stop())
						reached = true
						if outcome == "callback failure" then error("pause callback marker") end
					end)
					_G.require = original_require
					helpers.assert_eq(ok, outcome == "success")
					if outcome == "construction failure" then
						helpers.assert_eq(construction_reached, true)
						helpers.assert_eq(reached, false)
						helpers.assert_contains(detail, "pause construction marker")
					else
						helpers.assert_eq(reached, true)
						if outcome == "callback failure" then helpers.assert_contains(detail, "pause callback marker") end
					end
					for _, name in ipairs(OWNERS) do
						helpers.assert_eq(package.loaded[name], saved[name], "predecessor: " .. name)
					end
					helpers.assert_eq(rawget(_G, "hs"), predecessor)
				end)
			end)
		end
	end

	helpers.it("(pause-fixture-scope) dispatches deferred pause on the current native timer host", function()
		helpers.with_stub_scope(OWNERS, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local predecessor_scheduler = helpers.load_with_stubs("adapters.timer_scheduler")
			local predecessor_hs = hs
			local fired = 0
			local handle, committed = predecessor_scheduler.after(0, function() fired = fired + 1 end)
			helpers.assert_eq(committed, true)
			local timers_before = #predecessor_hs.timer.__timers
			Fixture.with_context(nil, function(control, ctx)
				helpers.assert_true(hs ~= predecessor_hs)
				helpers.assert_true(control.pause_all())
				ctx.fire_deferred()
				helpers.assert_eq(ctx.calls.karabiner_pause, 1, "pause must dispatch through this fixture's timer host")
				helpers.assert_eq(fired, 0, "fixture work must not fire a predecessor timer")
				helpers.assert_eq(#predecessor_hs.timer.__timers, timers_before)
				ctx.pause_callback(true, "paused")
				helpers.assert_eq(control.is_paused(), true)
				helpers.assert_true(control.stop())
			end)
			helpers.assert_eq(package.loaded["adapters.timer_scheduler"], predecessor_scheduler)
			helpers.assert_eq(hs, predecessor_hs)
			handle.timer:fire()
			helpers.assert_eq(fired, 1, "the predecessor still owns its original callback")
		end)
	end)
end)
