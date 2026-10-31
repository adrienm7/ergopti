--- tests/unit/adapters/test_field_probe_ports_scratch_typing.lua

--- ==============================================================================
--- MODULE: Field Run Scratch Typing Uses the Selftest Path
--- DESCRIPTION:
--- The scratch typing port types through the selftest class only, publishes its
--- own scratch window for the keymap's selftest gate while it types, and
--- retracts it before the window closes. It types nothing while the keymap taps
--- that would consume a stray selftest key are off, and nothing once the
--- scratch window lost the focus.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger", "adapters.field_probe_ports", "adapters.timer_scheduler", "adapters.own_window",
	"adapters.synthetic_input", "ui.ui_builder", "modules.keymap", "infra.field_run_selftest",
}

local OWN_PID = 1234
local SCRATCH_WINDOW = 99

-- The virtual clock of the scripted timers, in seconds.
local now = 0

--- Runs scratch_typing over scripted system pieces until every timer fired.
--- @param world table { taps = "enabled"|"disabled", focus = fn(index)->boolean }
--- @param keys table Keys.
--- @return table world With outcome, emitted keys, publications seen per key.
local function run(world, keys, options)
	world.emitted, world.published_at_key = {}, {}
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		-- A virtual clock: the earliest pending timer fires next.
		local queue = {}
		now = 0
		package.loaded["adapters.timer_scheduler"] = {
			after = function(seconds, fn)
				local entry = { at = now + seconds, fn = fn }
				queue[#queue + 1] = entry
				return entry
			end,
			cancel = function(entry) entry.cancelled = true; return true end,
		}
		package.loaded["adapters.own_window"] = { for_webview = function() return { id = function() return SCRATCH_WINDOW end } end }
		-- The shared chrome is its own owner's concern; the steps are recorded only
		package.loaded["ui.ui_builder"] = {
			force_focus = function() end,
			window_chrome_steps = function()
				world.chrome_applied = true
				return {}
			end,
		}
		package.loaded["modules.keymap"] = {
			tap_states = function()
				return { started = true, taps = { { name = "keyDown", state = world.taps }, { name = "loopbackKeyUp", state = world.taps } } }
			end,
		}
		package.loaded["infra.field_run_selftest"] = nil
		local Selftest = require("infra.field_run_selftest")
		world.selftest = Selftest
		package.loaded["adapters.synthetic_input"] = {
			emit_selftest_key_stroke = function(modifiers, key)
				world.emitted[#world.emitted + 1] = key
				world.published_at_key[#world.published_at_key + 1] = Selftest.window_id()
				return true
			end,
			emit_key_stroke = function() error("scratch typing must not use ordinary synthetic keys") end,
		}
		local key_index = 0
		local own_app = { pid = function() return OWN_PID end, activate = function() end }
		local view = {}
		for _, name in ipairs({ "windowStyle", "windowTitle", "allowTextEntry", "level", "html", "show" }) do
			view[name] = function(self) return self end
		end
		view.delete = function() world.window_id_at_close = Selftest.window_id() end
		view.evaluateJavaScript = function(_, _, fn)
			world.reads = (world.reads or 0) + 1
			fn(world.field_text and world.field_text(world.reads) or table.concat(world.emitted))
		end
		_G.hs = {
			application = { frontmostApplication = function() return own_app end },
			processInfo = { processID = OWN_PID },
			window = {
				focusedWindow = function()
					key_index = key_index + 1
					if world.focus and not world.focus(key_index) then return { id = function() return 7 end } end
					return { id = function() return SCRATCH_WINDOW end }
				end,
			},
			screen = { mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 800, h = 600 } end } end },
			webview = { new = function() return view end },
			drawing = { windowLevels = { floating = 3 } },
			timer = { absoluteTime = function() return math.floor(now * 1e9) end },
		}
		package.loaded["adapters.field_probe_ports"] = nil
		local Ports = require("adapters.field_probe_ports")
		Ports.new().scratch_typing(keys, function(outcome) world.outcome = outcome end, options)
		while #queue > 0 do
			table.sort(queue, function(a, b) return a.at < b.at end)
			local entry = table.remove(queue, 1)
			now = entry.at
			if not entry.cancelled then entry.fn() end
		end
	end)
	return world
end

helpers.describe("field run scratch typing", function()
	helpers.it("types selftest keys only while its published window has the focus", function()
		local world = run({ taps = "enabled" }, { "w", "k" })
		helpers.assert_eq(table.concat(world.emitted, ","), "w,k", tostring(world.outcome and world.outcome.aborted))
		helpers.assert_eq(world.published_at_key[1], SCRATCH_WINDOW, "the gate must know the window before the first key")
		helpers.assert_eq(world.published_at_key[2], SCRATCH_WINDOW)
		helpers.assert_nil(world.window_id_at_close, "the window must be retracted before it closes")
		helpers.assert_nil(world.selftest.window_id())
		helpers.assert_eq(world.outcome.posted, 2)
		helpers.assert_eq(world.outcome.text, "wk")
	end)

	helpers.it("types nothing while the keymap taps are off", function()
		local world = run({ taps = "disabled" }, { "w", "k" })
		helpers.assert_eq(#world.emitted, 0, "with the keymap tap off a selftest key would reach any focused app")
		helpers.assert_eq(world.outcome.aborted, "keymap_tap_off")
		helpers.assert_nil(world.selftest.window_id())
	end)

	helpers.it("stops and retracts once the scratch window lost the focus", function()
		local world = run({ taps = "enabled", focus = function(index) return index == 1 end }, { "w", "k" })
		helpers.assert_eq(table.concat(world.emitted, ","), "w")
		helpers.assert_eq(world.outcome.aborted, "focus_lost_window_unfocused")
		helpers.assert_nil(world.selftest.window_id())
	end)

	helpers.it("names the time from the last key to the awaited text", function()
		local world = run({ taps = "enabled", field_text = function(reads) return reads >= 3 and " AXA " or " axa" end },
			{ "a" }, { until_text = " AXA ", wait_seconds = 1, bound_seconds = 10 })
		helpers.assert_eq(world.outcome.text, " AXA ")
		helpers.assert_not_nil(world.outcome.effect_ms, "the expansion was seen, so its delay is named")
		helpers.assert_true(world.outcome.effect_ms > 0 and world.outcome.effect_ms < 1000)
		helpers.assert_nil(world.outcome.aborted)
	end)

	helpers.it("gives up on an effect that never comes and names no delay", function()
		local world = run({ taps = "enabled", field_text = function() return " axa " end },
			{ "a" }, { until_text = " AXA ", wait_seconds = 0.5, bound_seconds = 10 })
		helpers.assert_eq(world.outcome.text, " axa ")
		helpers.assert_nil(world.outcome.effect_ms)
		helpers.assert_nil(world.outcome.aborted, "the wait ends before the bound")
	end)
end)
