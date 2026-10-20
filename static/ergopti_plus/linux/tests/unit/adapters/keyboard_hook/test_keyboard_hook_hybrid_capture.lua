--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_hybrid_capture.lua

--- ==============================================================================
--- MODULE: Pinned Hybrid Input Capture
--- DESCRIPTION:
--- Runs the original Hook/Reader with controlled descriptors and real device
--- capability predicates. Axis-bearing nodes cannot be grabbed by a KEY-only
--- output; explicit observe mode and KEY-only macroboards keep their contract.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_device_watchdog_fixture")

--- Runs an isolated controlled input transport; no native authority is issued.
--- @param mask string Printed kernel EV capability word.
--- @param body function Receives the original consumer and mutable capabilities.
local function with_device(mask, body)
	local names = { "modules.hotstrings.device_finder", "adapters.keyboard_hook", "adapters.evdev_reader",
		"adapters.xkb_capture", "adapters.keyboard_layout", "adapters.uinput_writer" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
	local node, hook, reader = Fixture.fake_node("controlled hybrid capabilities")
	local state = { mask = mask }
	local called, detail = pcall(function()
		-- Hook's private CapsWord constructor also loads Layout. Build that
		-- dependency with its real producer before the controlled XKB is installed,
		-- and restore both exact cache entries after this isolated transport ends.
		helpers.load_module("adapters.xkb_capture")
		helpers.load_module("adapters.keyboard_layout")
		local actual = helpers.load_module("modules.hotstrings.device_finder")
		local function snapshot()
			return actual.parse_devices(table.concat({
				"I: Bus=0003 Vendor=0001 Product=0001 Version=0001",
				'N: Name="Unlabelled foot switch"',
				"S: Sysfs=/devices/controlled/input/input7",
				"H: Handlers=event7",
				"B: EV=" .. state.mask,
			}, "\n") .. "\n\n")
		end
		-- The temporary readable file is a controlled Reader transport. Translate
		-- only its path to the explicit proc fixture; all capability decisions run
		-- through the real Finder, not a preselected admission boolean.
		local finder = {
			find_keyboard = function() error("an explicitly pinned source cannot use auto-discovery") end,
			is_key_device = function(path)
				assert(path == node)
				return actual.is_key_device("/dev/input/event7", snapshot())
			end,
			is_interceptable_key_device = function(path)
				assert(path == node)
				return actual.is_interceptable_key_device("/dev/input/event7", snapshot())
			end,
		}
		package.loaded["modules.hotstrings.device_finder"] = finder
		reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = Fixture.recorder()
		reader._set_backend(backend)
		package.loaded["adapters.uinput_writer"] = nil
		hook = Fixture.load_hook()
		state.hook, state.reader, state.log, state.finder, state.actual = hook, reader, log, finder, actual
		function state.start(intercept)
			return hook.start({ device = node, pinned = true, intercept = intercept,
				onEmitRaw = function() return true end })
		end
		function state.reappear(next_mask)
			assert(reader.close("keyboard:" .. node))
			state.mask = next_mask
			Fixture.tick_until_check(hook, 1)
		end
		body(state)
	end)
	if hook then hook.stop() end
	if reader then reader._reset_backend() end
	os.remove(node)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	if not called then error(detail, 0) end
end

helpers.describe("keyboard_hook: explicit pinned hybrid capture", function()
	for _, row in ipairs({ { "EV_ABS", "b" }, { "EV_REL", "7" }, { "EV_REL and EV_ABS", "f" } }) do
		local label, mask = row[1], row[2]
		helpers.it("refuses " .. label .. " before any source open or grab", function()
			with_device(mask, function(s)
				s.start(true)
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.log.opens, {}, "refusal must precede descriptor acquisition")
				helpers.assert_eq(s.log.ioctls, {}, "no native grab may precede capability validation")
				helpers.assert_true(s.actual.is_key_device("/dev/input/event7", s.actual.parse_devices(
					'I: Bus=0003\nN: Name="Hybrid"\nH: Handlers=event7\nB: EV=' .. mask .. '\n\n')),
					"the old EV_KEY predicate remains true for the same axis-bearing node")
			end)
		end)

		helpers.it("keeps explicit observe mode available for " .. label, function()
			with_device(mask, function(s)
				s.start(false)
				helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(#s.log.opens, 1)
				helpers.assert_eq(s.log.ioctls, {}, "observe never consumes the physical node")
			end)
		end)

		helpers.it("refuses a pinned eventN reused for " .. label .. " before reacquiring it", function()
			with_device("120013", function(s)
				s.start(true)
				helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(#s.log.opens, 1)
				s.reappear(mask)
				helpers.assert_eq(#s.log.opens, 1, "same-path hotplug cannot bypass the startup capability rule")
				helpers.assert_eq(s.log.ioctls, { 1, 0 }, "only the original keyboard grab and its retirement are permitted")
			end)
		end)
	end

	helpers.it("keeps KEY-only macroboards eligible without KEY_A or keyboard naming", function()
		with_device("120013", function(s)
			s.start(true)
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(#s.log.opens, 1)
			helpers.assert_eq(s.log.ioctls, { 1 })
			s.reappear("120013")
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(#s.log.opens, 2, "a healthy KEY/MSC/LED/REP successor remains capturable")
			helpers.assert_eq(s.log.ioctls, { 1, 0, 1 })
		end)
	end)

	helpers.it("does not fall back to EV_KEY when the intercept validator is unavailable", function()
		with_device("120013", function(s)
			s.finder.is_interceptable_key_device = nil
			s.start(true)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.log.opens, {})
		end)
	end)

	helpers.it("does not reacquire a pinned node after its intercept validator is withdrawn", function()
		with_device("120013", function(s)
			s.start(true)
			helpers.assert_true(s.hook.isRunning())
			s.finder.is_interceptable_key_device = nil
			s.reappear("120013")
			helpers.assert_eq(#s.log.opens, 1)
			helpers.assert_eq(s.hook.isRunning(), false)
		end)
	end)

	for _, cold in ipairs({ true, false }) do
		local mode = cold and "cold" or "warm"
		helpers.it("restores the " .. mode .. " Layout cache after controlled Hook construction", function()
			local layout_name, capture_name = "adapters.keyboard_layout", "adapters.xkb_capture"
			local old_layout, old_capture = package.loaded[layout_name], package.loaded[capture_name]
			local called, detail = pcall(function()
				package.loaded[layout_name], package.loaded[capture_name] = nil, nil
				local expected
				if not cold then
					require(capture_name)
					expected = require(layout_name)
				end
				with_device("120013", function(s)
					s.start(true)
					helpers.assert_true(s.hook.isRunning(), "the original Hook must actually construct")
				end)
				helpers.assert_eq(package.loaded[layout_name], expected,
					"a controlled Hook must not publish a Layout retaining its fake XKB producer")
			end)
			package.loaded[layout_name], package.loaded[capture_name] = old_layout, old_capture
			if not called then error(detail, 0) end
		end)
	end
end)
