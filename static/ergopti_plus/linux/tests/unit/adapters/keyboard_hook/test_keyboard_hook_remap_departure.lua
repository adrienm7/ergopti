--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_remap_departure.lua

--- Removing a keyboard retires its physical output and its tap-hold state.
--- These use the actual Hook/Reader/remapper over an explicitly controlled
--- transport; they do not claim kernel or physical-device coverage.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.input_owner_fixture")

local function select_sources(s, ids)
	local paths = {}
	for _, id in ipairs(ids) do paths[#paths + 1] = s.paths[id] end
	package.loaded["modules.hotstrings.device_finder"].find_devices = function() return paths, {} end
	for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
end

helpers.describe("keyboard source departure retires remapper input", function()
	helpers.it("(remap-source-departure) accepts the first new hold on the surviving keyboard", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			s.edge("a", 58, 1, 0)
			helpers.assert_eq(s.rows, { { 29, 1 } }, "the original CapsLock hold must actually own Ctrl")
			select_sources(s, { "b" })
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			helpers.assert_true(s.hook.isRunning())
			s.edge("b", 58, 1, 500)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 } },
				"a removed source cannot suppress the next keyboard's first hold")
			s.edge("b", 58, 0, 1000)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 } })
			helpers.assert_eq(s.action, nil, "neither removal nor a long hold invents a tap")
			helpers.assert_eq(s.hook.held_modifiers(), {})
		end)
	end)

	helpers.it("(remap-source-departure) retires a failed reader before the surviving keyboard's next hold", function()
		local options = { on_capture_reacquired = function() return true end }
		Fixture.with_session(options, function(s)
			s.edge("a", 58, 1, 0)
			options.eof_path = s.paths.a
			s.hook.pump()
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			s.edge("b", 58, 1, 500)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 } })
			s.edge("b", 58, 0, 1000)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 } })
		end)
	end)

	helpers.it("(remap-source-departure) preserves a remapped hold on a retained keyboard", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			s.edge("a", 58, 1, 0)
			select_sources(s, { "a" })
			helpers.assert_eq(s.rows, { { 29, 1 } }, "removing an unrelated source must not lift this hold")
			helpers.assert_eq(s.hook.held_modifiers().ctrl, true)
			s.edge("a", 58, 0, 500)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			helpers.assert_eq(s.hook.held_modifiers(), {})
		end)
	end)

	helpers.it("(remap-source-departure) swallows the rest of another consumed hold after shared retirement", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end,
			keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 },
				left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = .3 } } }, function(s)
			s.edge("a", 58, 1, 0)
			s.edge("b", 42, 1, 20)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 42, 1 } })
			select_sources(s, { "b" })
			local retired = #s.rows
			helpers.assert_eq(s.hook.held_modifiers(), {})
			s.edge("b", 42, 2, 500); s.edge("b", 42, 0, 600)
			helpers.assert_eq(#s.rows, retired, "the old physical press cannot replay or tap after shared retirement")
			helpers.assert_eq(s.action, nil)
			s.edge("b", 42, 1, 700)
			helpers.assert_eq(s.rows[#s.rows], { 42, 1 }, "a fresh surviving press acquires its own hold")
			s.edge("b", 42, 0, 1200)
			helpers.assert_eq(s.rows[#s.rows], { 42, 0 })
		end)
	end)

	helpers.it("(remap-source-departure) stops original capture when remapped key retirement is not acknowledged", function()
		local options = { on_capture_reacquired = function() return true end }
		Fixture.with_session(options, function(s)
			s.edge("a", 58, 1, 0)
			options.fail_sync = function() return true end
			select_sources(s, { "b" })
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
		end)
	end)

	helpers.it("(remap-source-departure) keeps the surviving physical Shift owner", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			s.edge("a", 58, 1, 0)
			s.edge("b", 42, 1, 20)
			select_sources(s, { "b" })
			helpers.assert_eq(s.rows, { { 29, 1 }, { 42, 1 }, { 29, 0 } })
			helpers.assert_eq(s.hook.held_modifiers(), { shift = true })
			s.edge("b", 42, 0, 500)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 42, 1 }, { 29, 0 }, { 42, 0 } })
		end)
	end)
end)
