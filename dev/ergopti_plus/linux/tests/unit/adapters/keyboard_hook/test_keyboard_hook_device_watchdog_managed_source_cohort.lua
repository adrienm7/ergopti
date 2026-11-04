--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_device_watchdog_managed_source_cohort.lua

--- ==============================================================================
--- MODULE: Keyboard Hook Device Watchdog
--- DESCRIPTION:
--- What the hook does when the device it is reading is not the device it should
--- be reading any more.
---
--- WHY THIS IS THE ASSERTION:
--- Neither of the two events that invalidate the descriptor announces itself on
--- that descriptor:
---   - A keyboard unplugged and plugged back in gets a NEW /dev/input/eventN
---     node. The old one stays open and simply delivers nothing forever, which
---     from the outside is indistinguishable from a hung daemon.
---   - Restarting the remap daemon destroys and recreates its output device.
---     That device is the one this daemon prefers, because it carries post-remap
---     keycodes — the codes the application actually receives. Losing it does not
---     stop capture, it downgrades it: the engine starts resolving characters
---     from the physical keyboard, i.e. characters the user never typed. Silent,
---     wrong, and only visible as "hotstrings match the wrong things".
---
--- The check is driven from the periodic tick, so the second property pinned
--- here is that it does NOT run on every one: it re-reads
--- /proc/bus/input/devices, and that has no business on the keystroke path.
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.keyboard_hook_device_watchdog_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_device_watchdog_fixture")
local helpers =
	Fixture.helpers




helpers.describe("managed source cohort consumed retirement", function()
	helpers.it("withdraws a spent original arm before any keyboard reacquisition or publication", function()
		local calls = 0
		require("tests.support.input_owner_fixture").with_session({ on_capture_reacquired = function()
			calls = calls + 1; return true
		end }, function(s)
			s.pair(); helpers.assert_eq(s.armed, true)
			s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 }, { 42, 1 }, { 30, 1 } },
				"the original tap prefix and actual one-shot Shift/key ACKs are required")
			assert(s.reader.close("keyboard:" .. s.paths.a))
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
			helpers.assert_true(s.broker.output_retired())
		end)
	end)
end)




helpers.describe("managed source cohort original map authority", function()
	helpers.it("does not mint ownership from a foreign slot already reopened before the watchdog", function()
		require("tests.support.input_owner_fixture").with_session({ on_capture_reacquired = function() return true end }, function(s)
			local slot = "keyboard:" .. s.paths.b
			assert(s.reader.close("keyboard:" .. s.paths.a)); assert(s.reader.close(slot))
			assert(s.reader.open(s.paths.b, slot)); assert(s.reader.grab(slot))
			local foreign = assert(s.reader.capture_source_owner(slot))
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.reader.source_owner_current(foreign), "fresh ownership comes from actual acquisition, never a slot lookup")
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
		end)
	end)
end)




helpers.describe("managed source cohort pointer acquisition refusal", function()
	helpers.it("does not drop an owned pointer cleanup cohort when a replacement open fails", function()
		local options = { on_capture_reacquired = function() return true end }
		require("tests.support.input_owner_fixture").with_session(options, function(s)
			local finder = package.loaded["modules.hotstrings.device_finder"]
			assert(s.hook.stop() ~= false)
			finder.find_devices = function() return { s.paths.a }, { s.paths.b } end
			assert(s.hook.start({ intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit,
				onClick = function() end, onCaptureReacquired = options.on_capture_reacquired }))
			local prior = assert(s.reader.capture_source_owner("pointer:" .. s.paths.b))
			s.paths.c = os.tmpname(); local file = assert(io.open(s.paths.c, "w")); file:write("controlled replacement\n"); file:close()
			finder.find_devices = function() return { s.paths.a }, { s.paths.c } end
			options.fail_reader_open = true
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			options.fail_reader_open = false
			helpers.assert_eq(s.hook.isRunning(), false, "managed acquisition failure cannot publish a reduced cleanup cohort")
			helpers.assert_eq(s.reader.is_open("pointer:" .. s.paths.b), false)
			helpers.assert_eq(s.reader.is_open("pointer:" .. s.paths.c), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
			helpers.assert_eq(s.reader.source_owner_current(prior), false)
		end)
	end)
end)

