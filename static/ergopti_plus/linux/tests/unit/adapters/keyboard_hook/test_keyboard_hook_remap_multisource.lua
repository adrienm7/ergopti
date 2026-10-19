--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_remap_multisource.lua

--- Actual source-owned remapping over the controlled native-transport fixture.
--- These checks do not claim kernel or physical-device qualification.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.input_owner_fixture")
local function both(s)
	s.edge("a", 58, 1, 0); s.edge("b", 58, 1, 10)
	helpers.assert_eq(s.rows, { { 29, 1 } })
end

local function roster_session(s, initial)
	s.hook.stop(); helpers.assert_eq(s.hook.isRunning(), false)
	assert(s.hook.set_remapper(s.engine))
	local paths = {}
	for _, id in ipairs(initial) do paths[#paths + 1] = s.paths[id] end
	package.loaded["modules.hotstrings.device_finder"].find_devices = function() return paths, {} end
	s.hook.start(s.start_options); helpers.assert_true(s.hook.isRunning())
	return function(ids)
		paths = {}; for _, id in ipairs(ids) do paths[#paths + 1] = s.paths[id] end
		for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
	end
end

helpers.describe("source-owned simultaneous standalone remap holds", function()
	for _, order in ipairs({ { "a", "b" }, { "b", "a" } }) do
		local first, last = order[1], order[2]
		helpers.it("(remap-multisource) keeps Ctrl until last UP in order " .. first .. last, function()
			Fixture.with_session({}, function(s)
				both(s); s.edge(first, 58, 0, 20)
				helpers.assert_eq(s.rows, { { 29, 1 } })
				helpers.assert_eq(s.hook.held_modifiers(), { ctrl = true })
				s.edge(last, 58, 0, 30)
				helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
				helpers.assert_eq(s.hook.held_modifiers(), {})
				helpers.assert_eq(s.action, nil, "concurrent presses cannot produce either source's tap")
			end)
		end)
	end

	helpers.it("(remap-multisource) refuses an UP from a source without its own DOWN", function()
		Fixture.with_session({}, function(s)
			s.edge("a", 58, 1, 0); s.edge("b", 58, 0, 20)
			helpers.assert_eq(s.rows, { { 29, 1 } })
			helpers.assert_eq(s.hook.held_modifiers(), { ctrl = true })
			s.edge("a", 58, 0, 500)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
		end)
	end)

	helpers.it("(remap-multisource) repeats cannot acquire or release another source's hold", function()
		Fixture.with_session({}, function(s)
			s.edge("a", 58, 1, 0); s.edge("b", 58, 2, 5)
			s.edge("b", 58, 1, 10); s.edge("b", 58, 2, 20)
			s.edge("a", 58, 0, 30); s.edge("b", 58, 2, 40)
			helpers.assert_eq(s.rows, { { 29, 1 } })
			s.edge("b", 58, 0, 50)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			helpers.assert_eq(s.action, nil)
		end)
	end)

	helpers.it("(remap-multisource) one source's repeated DOWN is not a new owner", function()
		Fixture.with_session({}, function(s)
			s.edge("a", 58, 1, 0); s.edge("a", 58, 1, 10); s.edge("a", 58, 0, 500)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
		end)
	end)

	helpers.it("(remap-multisource) keeps a remaining Ctrl shortcut out of character collection", function()
		local chars = {}
		Fixture.with_session({ on_char = function(c) chars[#chars + 1] = c end }, function(s)
			both(s); s.edge("a", 58, 0, 20); s.edge("b", 30, 1, 30); s.edge("b", 30, 0, 40)
			helpers.assert_eq(chars, {})
			s.edge("b", 58, 0, 500)
			helpers.assert_eq(s.hook.held_modifiers(), {})
		end)
	end)

	helpers.it("(remap-multisource) cannot borrow a foreign source's ordered prefix", function()
		Fixture.with_session({}, function(s)
			s.edge("a", 58, 1, 0); s.edge("b", 15, 1, 10); s.edge("b", 15, 0, 100)
			helpers.assert_eq(s.action, nil); helpers.assert_eq(s.armed, nil)
		end)
	end)

	helpers.it("(remap-multisource) cannot lend the remaining B hold to a released A prefix", function()
		Fixture.with_session({}, function(s)
			both(s); s.edge("a", 58, 0, 20); s.edge("a", 15, 1, 30); s.edge("a", 15, 0, 40)
			helpers.assert_eq(s.action, nil); helpers.assert_eq(s.armed, nil)
			s.edge("b", 58, 0, 500)
			helpers.assert_eq(s.hook.held_modifiers(), {})
		end)
	end)

	helpers.it("(remap-multisource) stops two owned holds with one native Ctrl UP", function()
		Fixture.with_session({}, function(s)
			both(s); s.hook.stop()
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
		end)
	end)

	helpers.it("(remap-multisource) keeps exact cleanup rows after two-owner retirement is refused", function()
		local options = {}
		Fixture.with_session(options, function(s)
			both(s); options.fail_sync = function() return true end
			helpers.assert_eq(s.hook.stop(), false)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.broker.has_debt())
			local rows = s.engine:release_all()
			helpers.assert_eq(rows, { { code = 29, value = 0 } })
			helpers.assert_true(rawequal(rows, s.engine:release_all()), "clearing the source ledger cannot clear pending native retirement")
			helpers.assert_eq(s.engine:ack_retirement(false, rows), false)
		end)
	end)

	helpers.it("(remap-multisource) preserves native lifetime fencing after same-path B replacement", function()
		Fixture.with_session({ recycle_descriptor = true, on_capture_reacquired = function() return true end }, function(s)
			both(s)
			local slot = "keyboard:" .. s.paths.b
			local original = assert(s.reader.capture_source_owner(slot))
			assert(s.reader.close(slot)); assert(s.reader.open(s.paths.b, slot)); assert(s.reader.grab(slot))
			local successor = assert(s.reader.capture_source_owner(slot))
			s.edge("b", 58, 0, 20)
			helpers.assert_eq(s.rows, { { 29, 1 } }, "foreign native lifetime cannot retire an old held contribution")
			helpers.assert_eq(s.reader.source_owner_current(original), false)
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.reader.source_owner_current(successor), "cleanup must preserve the foreign successor")
			helpers.assert_true(s.broker.output_retired(), "terminal device retirement clears its held keys")
			helpers.assert_true((s.output_destroys or 0) > 0)
		end)
	end)

	for _, change in ipairs({ "add", "remove" }) do
		local direction = change
		helpers.it("(remap-multisource) preserves the original keyboard hold when pointers " .. direction, function()
			Fixture.with_session({}, function(s)
				s.hook.stop(); assert(s.hook.set_remapper(s.engine))
				local pointers = direction == "remove" and { s.paths.b } or {}
				package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { s.paths.a }, pointers end
				s.hook.start({ intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit,
					onClick = function() end, onCaptureReacquired = function() return true end })
				helpers.assert_true(s.hook.isRunning())
				local original = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.a))
				local generation = s.hook.physical_source_receipt().generation
				s.edge("a", 58, 1, 0)
				pointers = direction == "add" and { s.paths.b } or {}
				for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
				helpers.assert_true(s.hook.isRunning())
				helpers.assert_true(s.reader.source_owner_current(original), "the keyboard's original native opening is unchanged")
				helpers.assert_eq(s.hook.physical_source_receipt().generation, generation)
				helpers.assert_eq(s.rows, { { 29, 1 } })
				s.edge("a", 58, 0, 500)
				helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } }, "publishing new leases cannot strand an unchanged keyboard's modifier")
			end)
		end)
	end

	for _, order in ipairs({ { "a", "b" }, { "b", "a" } }) do
		local first, last = order[1], order[2]
		helpers.it("(remap-multisource) keeps both native holds through repeated pointer publications " .. first .. last, function()
			Fixture.with_session({}, function(s)
				s.hook.stop(); assert(s.hook.set_remapper(s.engine))
				local pointers = {}
				package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { s.paths.a, s.paths.b }, pointers end
				s.hook.start({ intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit,
					onClick = function() end, onCaptureReacquired = function() return true end })
				helpers.assert_true(s.hook.isRunning()); both(s)
				-- Only publish observers while the queues are empty: this fixture's
				-- two descriptors on A share a controlled queue, unlike real evdev.
				for _ = 1, 2 do
					pointers = { s.paths.a }
					for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
					pointers = {}
					for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
				end
				helpers.assert_eq(s.rows, { { 29, 1 } })
				s.edge(first, 58, 0, 20)
				helpers.assert_eq(s.rows, { { 29, 1 } })
				s.edge(last, 58, 0, 30)
				helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
				helpers.assert_eq(s.action, nil)
			end)
		end)
	end

	helpers.it("(remap-multisource) retains global fail-closed retirement on keyboard removal", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			both(s)
			package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { s.paths.b }, {} end
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			s.edge("b", 58, 2, 30); s.edge("b", 58, 0, 40)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
			s.edge("b", 58, 1, 500); s.edge("b", 58, 0, 1000)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 } })
		end)
	end)

	helpers.it("(remap-multisource) keeps the original single-source ordered action eligible", function()
		Fixture.with_session({}, function(s)
			s.pair(); helpers.assert_eq(s.action, "one_shot_shift"); helpers.assert_eq(s.armed, true)
		end)
	end)

	helpers.it("(remap-multisource) accounts for each source's deferred modifier hold", function()
		Fixture.with_session({ keys = { right_ctrl = { tap_action = "one_shot_shift", time_activation_seconds = .3 } } }, function(s)
			s.edge("a", 97, 1, 0); s.edge("b", 97, 1, 100); s.pump_at(450)
			helpers.assert_eq(s.rows, { { 42, 1 } })
			s.edge("a", 97, 0, 500)
			helpers.assert_eq(s.rows, { { 42, 1 } })
			s.edge("b", 97, 0, 550)
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 } })
			helpers.assert_eq(s.action, nil)
		end)
	end)
end)

helpers.describe("retained remap provenance across keyboard roster changes", function()
	helpers.it("(remap-roster-provenance) retires A without an intermediate roster publication", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			local roster = roster_session(s, { "a", "b" })
			s.edge("a", 58, 1, 0); roster({ "b" })
			helpers.assert_true(s.hook.isRunning())
			s.edge("b", 58, 1, 500); s.edge("b", 58, 0, 1000)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 } })
		end)
	end)

	for _, change in ipairs({ "add peer", "remove and reconnect peer" }) do
		helpers.it("(remap-roster-provenance) preserves A retirement after " .. change, function()
			local chars = {}
			Fixture.with_session({ on_capture_reacquired = function() return true end,
				on_char = function(char) chars[#chars + 1] = char end }, function(s)
				local roster = roster_session(s, change == "add peer" and { "a" } or { "a", "b" })
				s.edge("a", 58, 1, 0)
				if change ~= "add peer" then roster({ "a" }) end
				roster({ "a", "b" })
				helpers.assert_eq(s.rows, { { 29, 1 } }, "a retained hold is not replayed or withdrawn")
				roster({ "b" }); helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
				s.edge("b", 58, 1, 500)
				helpers.assert_eq(s.hook.held_modifiers(), { ctrl = true }, "B owns a new Ctrl, not a stale A reference")
				s.edge("b", 30, 1, 600); s.edge("b", 30, 0, 650)
				helpers.assert_eq(chars, {}, "a real Ctrl+A must never enter the hotstring text buffer")
				s.edge("b", 58, 0, 1000)
				helpers.assert_eq(s.hook.held_modifiers(), {}); helpers.assert_eq(s.action, nil)
			end)
		end)
	end

	for _, order in ipairs({ { "a", "b" }, { "b", "a" } }) do
		helpers.it("(remap-roster-provenance) retires simultaneous same-code holds after release order " .. table.concat(order), function()
			Fixture.with_session({ source_ids = { "a", "b", "c" }, on_capture_reacquired = function() return true end }, function(s)
				local roster = roster_session(s, { "a", "b" })
				s.edge("a", 58, 1, 0); s.edge("b", 58, 1, 10)
				helpers.assert_eq(s.rows, { { 29, 1 } })
				if order[1] == "b" then
					s.edge("b", 58, 0, 20); helpers.assert_eq(s.rows, { { 29, 1 } })
				end
				roster({ "a", "b", "c" }); helpers.assert_eq(s.rows, { { 29, 1 } })
				roster({ "b", "c" }); helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } })
				if order[1] == "a" then
					s.edge("b", 58, 2, 30); s.edge("b", 58, 0, 40)
					helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 } }, "retained B's old held press stays orphaned until its UP")
				end
				s.edge("b", 58, 1, 500); s.edge("b", 58, 0, 1000)
				helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 } })
				helpers.assert_eq(s.action, nil)
			end)
		end)
	end

	helpers.it("(remap-roster-provenance) retires different retained hold modifiers as one original cohort", function()
		Fixture.with_session({ source_ids = { "a", "b", "c" }, on_capture_reacquired = function() return true end,
			keys = { caps_lock = { tap_action = "none", hold_modifier = "ctrl", time_activation_seconds = .3 },
				left_alt = { tap_action = "none", hold_modifier = "win", time_activation_seconds = .3 } } }, function(s)
			local roster = roster_session(s, { "a", "b" })
			s.edge("a", 58, 1, 0); s.edge("b", 56, 1, 10)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 125, 1 } })
			roster({ "a", "b", "c" }); helpers.assert_eq(s.rows, { { 29, 1 }, { 125, 1 } })
			roster({ "b", "c" }); helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(s.hook.held_modifiers(), {}); helpers.assert_eq(s.broker.view().down, {})
			local count = #s.rows
			s.edge("b", 56, 2, 30); s.edge("b", 56, 0, 40)
			helpers.assert_eq(#s.rows, count, "the retained old press cannot replay its retired hold")
			s.edge("b", 56, 1, 500); s.edge("b", 56, 0, 1000)
			helpers.assert_eq(s.rows[count + 1], { 125, 1 })
			helpers.assert_eq(s.rows[count + 2], { 194, 1 }); helpers.assert_eq(s.rows[count + 3], { 194, 0 })
			helpers.assert_eq(s.rows[count + 4], { 125, 0 }, "the ordinary F24 menu mask precedes the final Super UP")
			helpers.assert_eq(s.action, nil)
		end)
	end)

	for _, mapping in ipairs({
		{ id = "left_alt", code = 56, modifier = "win", output = 125 },
		{ id = "right_ctrl", code = 97, modifier = "shift", output = 42, deferred = true },
	}) do
		helpers.it("(remap-roster-provenance) retains the " .. mapping.id .. " mapping provenance", function()
			local setting = { tap_action = mapping.deferred and "one_shot_shift" or "none", time_activation_seconds = .3 }
			if not mapping.deferred then setting.hold_modifier = mapping.modifier end
			local keys = { [mapping.id] = setting }
			Fixture.with_session({ keys = keys, on_capture_reacquired = function() return true end }, function(s)
				local roster = roster_session(s, { "a" })
				s.edge("a", mapping.code, 1, 0)
				if mapping.deferred then s.pump_at(400) end
				helpers.assert_eq(s.rows, { { mapping.output, 1 } })
				roster({ "a", "b" }); helpers.assert_eq(s.rows, { { mapping.output, 1 } })
				roster({ "b" }); helpers.assert_true(s.hook.isRunning())
				s.edge("b", mapping.code, 1, 500)
				if mapping.deferred then s.pump_at(900) end
				s.edge("b", mapping.code, 0, 1000)
				local expected = { { mapping.output, 1 }, { mapping.output, 0 }, { mapping.output, 1 } }
				if mapping.modifier == "win" then expected[#expected + 1] = { 194, 1 }; expected[#expected + 1] = { 194, 0 } end
				expected[#expected + 1] = { mapping.output, 0 }
				helpers.assert_eq(s.rows, expected)
			end)
		end)
	end

	helpers.it("(remap-roster-provenance) retires a deferred hold before its activation deadline", function()
		Fixture.with_session({ keys = { right_ctrl = { tap_action = "one_shot_shift", time_activation_seconds = .3 } },
			on_capture_reacquired = function() return true end }, function(s)
			local roster = roster_session(s, { "a" })
			s.edge("a", 97, 1, 0); helpers.assert_eq(s.rows, {})
			roster({ "a", "b" }); roster({ "b" }); helpers.assert_true(s.hook.isRunning())
			s.pump_at(400); helpers.assert_eq(s.rows, {}, "an unplugged pending owner cannot activate later")
			s.edge("b", 97, 1, 500); s.pump_at(900); s.edge("b", 97, 0, 1000)
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 } })
			helpers.assert_eq(s.action, nil)
		end)
	end)

	helpers.it("(remap-roster-provenance) preserves an ordinary physical UP with no source departure", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			local roster = roster_session(s, { "a" })
			s.edge("a", 58, 1, 0); roster({ "a", "b" })
			helpers.assert_eq(s.rows, { { 29, 1 } }); s.edge("a", 58, 0, 500)
			s.edge("b", 58, 1, 600); s.edge("b", 58, 0, 1100)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 } })
			helpers.assert_eq(s.hook.held_modifiers(), {}); helpers.assert_eq(s.action, nil)
		end)
	end)

	helpers.it("(remap-roster-provenance) cannot republish input after original Reader close is refused", function()
		local options = { on_capture_reacquired = function() return true end }
		Fixture.with_session(options, function(s)
			local roster = roster_session(s, { "a" })
			s.edge("a", 58, 1, 0); roster({ "a", "b" })
			options.fail_reader_close = true; roster({ "b" })
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
			local count = #s.rows
			s.edge("b", 58, 1, 500); s.edge("b", 58, 0, 1000)
			helpers.assert_eq(#s.rows, count, "a refused cleanup never lends old or new source delivery rights")
			helpers.assert_true(s.broker.output_retired())
		end)
	end)
end)
