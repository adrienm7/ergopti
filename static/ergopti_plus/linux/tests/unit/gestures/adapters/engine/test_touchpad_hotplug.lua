--- tests/unit/gestures/adapters/engine/test_touchpad_hotplug.lua

--- ==============================================================================
--- MODULE: Regression — a touchpad unplugged while gestures are on
--- DESCRIPTION:
--- A failed touchpad read stopped the reader for good (« re-enable gestures to
--- retry »), and the master left on with no reader made capture_scope_state
--- refuse, so the gesture switch and the section's restore and clear were
--- refused until the daemon restarted. Decided by the maintainer on 2026-11-17:
--- the pump looks for a touchpad again every [gestures] touchpad_rescan_ms,
--- reopens it (with the register resync of an open) and the settings stay
--- editable meanwhile, applied when a touchpad is back; one line at the loss and
--- one at the return.
---
--- The kernel is tests/support/touchpad_kernel_model.lua (unplugged: read(2)
--- fails with ENODEV); the reader, the manager and the decoder are the real ones,
--- on a driven clock.
--- ==============================================================================

local helpers = require("tests.helpers")
local Kernel = require("tests.support.touchpad_kernel_model")

local MANAGER, READER, FINDER = "gestures.engine.manager", "platform.input.evdev_reader", "gestures.adapters.touchpad_finder"
local EMITTER, LOGGER = "gestures.engine.combo_emitter", "core.logger.engine.shim"
local DECODER = "gestures.engine.mt_decoder"
local PAD = { path = "/dev/input/event7", name = "Model Touchpad", is_touchpad = true, semi_mt = false, max_fingers = 5 }

local RESCAN_SEC = require("core.timing.engine.timings").sec("gestures", "touchpad_rescan_ms")




-- =========================================
-- =========================================
-- ======= 1/ The gesture chain ============
-- =========================================
-- =========================================

--- Runs a scenario through the manager's start_reading and pump.
--- @param scenario function(env) env = { kernel, manager, pump, advance, lines, pressed, listings }
--- @return table env
local function run(scenario)
	local names = { MANAGER, READER, FINDER, EMITTER, LOGGER, DECODER }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	package.loaded[DECODER] = nil
	local env = { lines = {}, pressed = {}, listings = 0, clock = 100 }
	local ok, failure = xpcall(function()
		local function record(_, fmt, ...)
			local formatted, text = pcall(string.format, fmt, ...)
			env.lines[#env.lines + 1] = formatted and text or tostring(fmt)
		end
		package.loaded[LOGGER] = {
			debug = record, trace = record, done = record, info = record, start = record, success = record,
			warn = record, error = record, set_level = function() end, set_sink = function() end,
			ring_buffer_snapshot = function() return {} end,
		}
		package.loaded[EMITTER] = {
			press = function(combo) env.pressed[#env.pressed + 1] = combo; return true end,
			can_fallback = function() return false end,
		}
		local kernel = Kernel.new()
		env.kernel = kernel
		local real_finder = helpers.load_module(FINDER)
		-- /proc/bus/input/devices lists the pad only while it is plugged in.
		package.loaded[FINDER] = setmetatable({
			list = function()
				env.listings = env.listings + 1
				if kernel.unplugged then return {} end
				return { PAD }
			end,
			find = function()
				if kernel.unplugged then return nil, "no device reports multitouch slots" end
				return PAD
			end,
			read_resolution = function() return 10, 10 end,
		}, { __index = real_finder })
		local reader = helpers.load_module(READER)
		reader._set_backend(kernel.backend(require("platform.input.event"), {}))
		local manager = helpers.load_module(MANAGER)
		env.manager = manager
		manager.init({ enabled = false, persist = false, now_sec = function() return env.clock end })
		for _, slot in ipairs({ "swipe_3_right", "swipe_3_left" }) do
			helpers.assert_true(manager.set_action(slot, "enter"))
			helpers.assert_true(manager.set_mode(slot, "x1"))
		end
		env.pump = function() repeat until (manager.pump() or 0) == 0 end
		env.advance = function(seconds) env.clock = env.clock + seconds; manager.pump() end
		helpers.assert_true(manager.enable(), "the model pad opens through the real reader")
		scenario(env)
		if manager.is_reading() then helpers.assert_true(manager.stop_reading()) end
		reader._reset_backend()
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
	return env
end

--- How many logged lines contain the needle.
local function count_lines(lines, needle)
	local n = 0
	for _, line in ipairs(lines) do if line:find(needle, 1, true) then n = n + 1 end end
	return n
end

--- A three-finger swipe right, drained through the pump.
local function swipe_right(env, first_id)
	env.kernel.land(first_id, 1000 + first_id, 500 + first_id); env.kernel.move(8, 60, 0); env.kernel.lift()
	env.pump()
end

--- Unplugs the pad and lets the pump see the read fail.
local function unplug(env)
	env.kernel.unplugged = true
	env.manager.pump()
end

--- Plugs the pad back in: its node keeps the registers of the same hardware.
local function plug(env)
	env.kernel.unplugged = false
	env.kernel.unread = {}
end




-- =========================================
-- =========================================
-- ======= 2/ Cases ========================
-- =========================================
-- =========================================

helpers.describe("touchpad hotplug: an unplugged touchpad comes back", function()
	helpers.it("touchpad-hotplug: removal, quiet rescans, reappearance, and gestures fire again", function()
		local env = run(function(env)
			local enter = env.manager.emit_combo_for("enter")
			swipe_right(env, 10)
			helpers.assert_eq(#env.pressed, 1, "the pad works before the removal")

			unplug(env)
			helpers.assert_eq(env.manager.is_reading(), false)
			helpers.assert_true(env.manager.is_enabled(), "the master stays on")
			helpers.assert_eq(count_lines(env.lines, "lost (drain fatal): looking for a touchpad every"), 1)
			local lines_at_loss = #env.lines

			-- Absent for five rescans: one listing each, and nothing logged.
			local listings = env.listings
			env.advance(RESCAN_SEC / 2)
			helpers.assert_eq(env.listings, listings, "no rescan before the interval")
			for _ = 1, 5 do env.advance(RESCAN_SEC) end
			helpers.assert_eq(env.listings, listings + 5, "one listing per interval")
			helpers.assert_eq(#env.lines, lines_at_loss, "no line per rescan")
			helpers.assert_eq(env.kernel.opens, 1, "nothing to open while the pad is absent")

			plug(env)
			env.advance(RESCAN_SEC)
			helpers.assert_true(env.manager.is_reading(), "the pad is reopened at the next rescan")
			helpers.assert_eq(env.kernel.opens, 2)
			helpers.assert_eq(count_lines(env.lines, "A touchpad is back (/dev/input/event7): gestures resume."), 1)
			helpers.assert_eq(count_lines(env.lines, "multitouch registers read at open"), 2,
				"the reopened reader is seeded like any open")

			swipe_right(env, 30)
			helpers.assert_eq(env.pressed, { enter, enter }, "gestures fire again")
		end)
		helpers.assert_eq(count_lines(env.lines, "lost (drain fatal)"), 1, "one line at the loss")
	end)

	helpers.it("touchpad-hotplug: settings edited while absent are accepted and applied at the return", function()
		run(function(env)
			local manager = env.manager
			unplug(env)
			helpers.assert_true(manager.capture_scope_state() ~= nil, "the scope can capture a lost touchpad's state")

			-- The switch, off then on again, while no touchpad is read.
			helpers.assert_true(manager.set_enabled(false), "the switch commits while the pad is absent")
			local listings = env.listings
			env.advance(RESCAN_SEC * 3)
			helpers.assert_eq(env.listings, listings, "gestures off: no rescan")
			helpers.assert_true(manager.set_enabled(true), "and back on, still without a pad")
			helpers.assert_true(manager.is_enabled())
			helpers.assert_eq(manager.is_reading(), false)

			-- A binding and a section-wide snapshot, as the scope restore and clear apply them.
			helpers.assert_true(manager.set_action("swipe_3_right", "tab_next"))
			local state = manager.capture_scope_state()
			state.actions.swipe_3_left = "none"
			helpers.assert_true(manager.apply_scope_state(state), "a scope snapshot applies while the pad is absent")
			helpers.assert_eq(manager.get_action("swipe_3_left"), "none")

			plug(env)
			env.advance(RESCAN_SEC)
			helpers.assert_true(manager.is_reading())
			swipe_right(env, 40)
			helpers.assert_eq(env.pressed, { manager.emit_combo_for("tab_next") },
				"the binding edited while the pad was absent is the one that fires")
		end)
	end)

	helpers.it("touchpad-hotplug: a listed pad that cannot be opened is tried once per listed set", function()
		local env = run(function(env)
			unplug(env)
			-- Listed again, but its node refuses to open (permissions, a half-created node).
			env.kernel.unplugged = false
			local backend_open = env.kernel.backend
			local reader = require(READER)
			reader._reset_backend()
			local backend = backend_open(require("platform.input.event"), {})
			backend.open = function() return nil, "open failed" end
			reader._set_backend(backend)
			for _ = 1, 4 do env.advance(RESCAN_SEC) end
			helpers.assert_eq(env.manager.is_reading(), false)
			helpers.assert_eq(count_lines(env.lines, "Could not open /dev/input/event7"), 1,
				"one refusal logged, not one per rescan")
		end)
		helpers.assert_eq(count_lines(env.lines, "A touchpad is back"), 0)
	end)
end)
