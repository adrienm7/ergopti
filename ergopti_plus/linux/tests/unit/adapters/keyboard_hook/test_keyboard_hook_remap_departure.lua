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



	helpers.it("(remap-source-departure) keeps a retained colon-path orphan distinct from a shorter event-name prefix", function()
		Fixture.with_session({ position_bits = true, source_suffixes = { a = ":event1", b = ":event10" },
			on_capture_reacquired = function() return true end,
			keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 },
				left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = .3 } } }, function(s)
			s.edge("a", 58, 1, 0); s.edge("b", 42, 1, 20)
			select_sources(s, { "b" })
			assert(s.hook.set_remapper(nil))
			local retired = #s.rows
			-- Without a remapper, losing this retained suppression would pass an
			-- ownerless repeat to the output broker and stop the keyboard hook.
			s.edge("b", 42, 2, 400); s.edge("b", 42, 0, 500)
			helpers.assert_true(s.hook.isRunning(), "retiring event1 cannot erase event10's consumed press")
			helpers.assert_eq(#s.rows, retired, "only the actual retained UP ends suppression, with no native replay")
			s.edge("b", 42, 1, 600); s.edge("b", 42, 0, 700)
			helpers.assert_eq(#s.rows, retired + 2)
			helpers.assert_eq(s.rows[retired + 1], { 42, 1 })
			helpers.assert_eq(s.rows[retired + 2], { 42, 0 })
			helpers.assert_eq(s.action, nil)
		end)
	end)

	for _, departure in ipairs({ "watchdog removal", "fatal reader" }) do
		helpers.it("(remap-source-departure) forgets an orphan from the old lifetime after " .. departure, function()
			local options = { position_bits = true, on_capture_reacquired = function() return true end,
				source_suffixes = { a = ":event1", b = ":event10" },
				keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 },
					left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = .3 } } }
			Fixture.with_session(options, function(s)
				s.edge("a", 58, 1, 0); s.edge("b", 42, 1, 20)
				select_sources(s, { "b" })
				local retired = #s.rows
				s.edge("b", 42, 2, 400)
				helpers.assert_eq(#s.rows, retired, "the retained orphan cannot replay while its original physical hold continues")
				select_sources(s, { "a", "b" })
				local old = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.b))
				if departure == "watchdog removal" then select_sources(s, { "a" })
				else options.eof_path = s.paths.b; s.hook.pump(); options.eof_path = nil end
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
				helpers.assert_eq(s.reader.source_owner_current(old), false)
				-- A new keyboard reuses the pathname with no key held. This is a
				-- fresh per-open Reader lifetime, not an UP from the consumed press.
				s.held[s.paths.b] = {}
				select_sources(s, { "a", "b" })
				helpers.assert_true(s.hook.isRunning())
				local fresh = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.b))
				helpers.assert_true(s.reader.source_owner_current(fresh))
				helpers.assert_eq(s.reader.source_owner_current(old), false, "same pathname does not revive the old input owner")
				helpers.assert_eq(#s.rows, retired, "removal and acquisition neither replay the orphan nor synthesize a tap")
				s.edge("b", 42, 1, 500)
				helpers.assert_eq(#s.rows, retired + 1, "the successor keyboard's first new hold must reach output")
				helpers.assert_eq(s.rows[#s.rows], { 42, 1 })
				s.edge("b", 42, 0, 1000)
				helpers.assert_eq(s.rows[#s.rows], { 42, 0 })
				helpers.assert_eq(s.action, nil, "a long successor hold and old source removal cannot fire a tap")
				helpers.assert_eq(s.hook.held_modifiers(), {})
			end)
		end)
	end


	helpers.it("(remap-source-departure) refuses a successor after an orphaned source cannot retire its output", function()
		local options = { position_bits = true, on_capture_reacquired = function() return true end,
			keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 },
				left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = .3 } } }
		Fixture.with_session(options, function(s)
			s.edge("a", 58, 1, 0); s.edge("b", 42, 1, 20)
			select_sources(s, { "b" }); select_sources(s, { "a", "b" })
			local prior = #s.rows
			s.edge("b", 42, 2, 400)
			helpers.assert_eq(#s.rows, prior, "the retained consumed press is still suppressed")
			s.edge("b", 30, 1, 450)
			helpers.assert_eq(s.rows[#s.rows], { 30, 1 }, "the orphaned source separately owns real forwarded output")
			options.fail_sync = function(_, code, value) return code == 30 and value == 0 end
			options.output_close = function() return false end
			select_sources(s, { "a" })
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.writer.has_output_debt(), "unknown output close remains retained")
			helpers.assert_eq(s.writer.output_current(s.output), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
			local retired = #s.rows
			options.fail_sync = nil
			s.held[s.paths.b] = {}
			select_sources(s, { "a", "b" })
			s.edge("b", 42, 1, 500); s.edge("b", 42, 0, 1000)
			helpers.assert_eq(#s.rows, retired, "unacknowledged retirement grants no successor output or replay")
			helpers.assert_eq(s.action, nil)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
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
