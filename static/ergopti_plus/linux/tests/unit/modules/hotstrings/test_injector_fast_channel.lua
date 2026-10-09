--- tests/unit/modules/hotstrings/test_injector_fast_channel.lua

--- ==============================================================================
--- MODULE: Injector Non-Forking Emit Channel
--- DESCRIPTION:
--- `emit_key` must not spawn a subprocess when the uinput channel is open.
---
--- WHY THIS IS THE ASSERTION:
--- The Linux daemon cannot take EVIOCGRAB — which is the root cause of the
--- `abcd` → `acd` corruption, because without a grab every physical keystroke
--- reaches the application in real time and interleaves with the ~90 ms
--- erase-then-type window of an expansion. The measured blocker is that
--- re-emitting a consumed event shells out `ydotool key <code>:<value>` ONCE PER
--- EVENT: a fork per physical keystroke, on the input path.
---
--- So the property that unblocks the grab is not "emit_key works" — it always
--- worked — it is "emit_key does not fork". That cannot be observed from a
--- return value: os.execute reports the same thing whether it was called once or
--- not at all, and io.popen does not raise on anything. The only way to assert it
--- is to make the spawn observable and require that it does not happen.
---
--- WHY NOT BATCHING:
--- `ydotool key` accepts several `code:value` pairs per call, so collapsing a
--- pump batch into one fork looks like the obvious fix. It is wrong: `_pump_one`
--- re-emits an event and THEN dispatches it, so an injection triggered by event
--- N would run before the re-emit of N itself — reintroducing exactly the
--- interleaving the grab exists to remove. The channel has to be non-forking,
--- which is what these tests pin.
--- ==============================================================================

local helpers = require("tests.helpers")


--- A stand-in for the uinput channel that records what it was asked to emit.
--- @param open boolean Whether the channel reports itself as open.
local function fake_channel(open)
	local ch = { emitted = {} }
	ch.is_open = function() return open end
	ch.emit = function(code, value)
		ch.emitted[#ch.emitted + 1] = { code = code, value = value }
		return true
	end
	return ch
end





-- ==============================================================
-- ==============================================================
-- ======= 1/ With the channel open, nothing is spawned =========
-- ==============================================================
-- ==============================================================

helpers.describe("injector: emit_key does not fork when the uinput channel is open", function()

	helpers.it("routes the event to the channel and never runs a shell command", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local ch = fake_channel(true)
		injector._set_uinput(ch)

		-- Both spawn paths, made observable. shell_run() goes through os.execute;
		-- the test runner seam is deliberately NOT used here, because a test that
		-- asserts on the seam would pass on an implementation that bypasses it.
		local real_execute, real_popen = os.execute, io.popen
		local spawned = {}
		os.execute = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return true end
		io.popen = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return nil end

		local ok, err = pcall(function()
			injector.emit_key(30, 1)
			injector.emit_key(30, 0)
		end)

		os.execute, io.popen = real_execute, real_popen
		injector._set_uinput(nil)

		if not ok then error(err, 0) end

		helpers.assert_eq(#spawned, 0,
			"emit_key spawned " .. #spawned .. " subprocess(es) (" .. table.concat(spawned, " | ")
			.. ") with the non-forking channel open. Under EVIOCGRAB that is a fork per physical "
			.. "keystroke on the input path, which is the measured reason the daemon cannot grab")

		helpers.assert_eq(#ch.emitted, 2, "both events must reach the channel")
		helpers.assert_eq(ch.emitted[1].code, 30, "the keycode must be passed through unchanged")
		helpers.assert_eq(ch.emitted[1].value, 1, "the press must be passed through unchanged")
		helpers.assert_eq(ch.emitted[2].value, 0, "the release must be passed through unchanged")
	end)

	helpers.it("passes autorepeat to the channel without collapsing it", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local ch = fake_channel(true)
		injector._set_uinput(ch)

		injector.emit_key(30, 2)
		injector._set_uinput(nil)

		helpers.assert_eq(#ch.emitted, 1, "the autorepeat must reach the channel")
		helpers.assert_eq(ch.emitted[1].value, 2,
			"emit_key must hand the channel the value it was given. The ydotool path collapses 2 "
			.. "into 1 because its wire format cannot express a repeat; routing that collapse "
			.. "through a channel that CAN express it would discard information for no reason")
	end)

end)





-- ==============================================================
-- ==============================================================
-- ======= 2/ Without a channel it refuses, it does not fork ====
-- ==============================================================
-- ==============================================================

helpers.describe("injector: emit_key has one channel and no fallback", function()

	helpers.it("refuses rather than spawning a subprocess when no channel is open", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		injector._set_uinput(nil)

		-- The seam is deliberately NOT used to observe this: a test that watches
		-- the seam would pass on an implementation that bypasses it. os.execute
		-- and io.popen are the two ways a process can be spawned at all.
		local real_execute, real_popen = os.execute, io.popen
		local spawned = {}
		os.execute = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return true end
		io.popen = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return nil end

		local ok, result = pcall(injector.emit_key, 30, 1)

		os.execute, io.popen = real_execute, real_popen
		if not ok then error(result, 0) end

		helpers.assert_eq(#spawned, 0,
			"a subprocess per event is the cost that made the grab impossible; falling "
				.. "back to it silently reintroduces the defect on exactly the machines "
				.. "where uinput is unavailable. Spawned: " .. table.concat(spawned, " | "))
		helpers.assert_eq(result, false,
			"and it must SAY it failed, so the daemon can refuse to grab rather than "
				.. "grabbing a keyboard it cannot give back")
	end)

	helpers.it("treats a channel that reports itself closed as no channel", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		-- is_open() is the contract: a channel that failed to open reports false
		-- rather than raising, and half-open must not read as open.
		injector._set_uinput(fake_channel(false))
		local result = injector.emit_key(30, 1)
		injector._set_uinput(nil)

		helpers.assert_eq(result, false,
			"a closed channel cannot carry the event, and reporting success for an "
				.. "event the application never received is the worst of the options")
	end)

end)





-- ==============================================================
-- ==============================================================
-- ======= 3/ Opening the channel fails closed ==================
-- ==============================================================
-- ==============================================================

helpers.describe("injector: open_fast_channel", function()

	helpers.it("returns false rather than raising when no uinput exists here", function()
		-- This machine has neither LuaJIT FFI nor /dev/uinput, which is exactly
		-- the case the daemon must survive: it keeps the subprocess path and does
		-- not take the grab.
		local injector = helpers.load_module("modules.hotstrings.injector")
		local ok, result = pcall(injector.open_fast_channel)
		helpers.assert_true(ok, "open_fast_channel must not raise: " .. tostring(result))
		helpers.assert_eq(type(result), "boolean",
			"it must answer with a boolean so the daemon can decide whether grabbing is safe")
	end)

end)


--- Drives real capture, refresh and planning over a controlled native protocol.
--- @param body function
local function cohort_fixture(body)
	local capture = helpers.load_module("adapters.xkb_capture")
	local state = { rows = {} }
	local backend = {
		create = function() return { identity = "owned-cohort-map", group = 0, groups = 2 } end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function() return nil end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		update_key = function(session, code, direction)
			if code == 107 and direction == 1 then session.group = 1 - session.group end
		end,
		capture_group = function(session)
			if state.on_group then state.on_group() end
			return session.group
		end,
		caps_locked = function()
			if state.on_caps then state.on_caps() end
			return state.caps == true
		end,
	}
	backend.inverse = function(session, group)
		local rows = {}
		for code = 32, 126 do rows[string.char(code)] = { keycode = code, level = 1, mods = {} } end
		rows.z = { keycode = group == 1 and 21 or 44, level = 1, mods = {} }
		rows.Z = { keycode = group == 1 and 21 or 44, level = 2, mods = { "shift" } }
		state.rows = rows
		if state.on_inverse then state.on_inverse() end
		return rows
	end
	capture._set_backend(backend)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write("owned-cohort-map")
	file:close()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local ok, err = pcall(function()
		helpers.assert_true(layout.refresh(path))
		body(capture, layout, state, backend, path)
	end)
	layout._set_table_for_test(nil)
	capture._reset_backend()
	os.remove(path)
	if not ok then error(err, 0) end
end


--- Captures literal acknowledged rows through the real Injector transaction.
--- @param capture table
--- @param layout table
--- @param state table
--- @param body function
local function output_fixture(capture, layout, state, body)
	local rows, stopped = {}, 0
	local old_hook = package.loaded["adapters.keyboard_hook"]
	package.loaded["adapters.keyboard_hook"] = {
		held_text_modifier_codes = function() return {} end,
		held_shortcut_modifier_codes = function() return {} end,
		held_forwarded_keys = function() return {} end,
		emergency_stop = function() stopped = stopped + 1 end,
	}
	local channel = {
		is_open = function() return true end,
		emit = function(code, value)
			rows[#rows + 1] = tostring(code) .. ":" .. tostring(value)
			if state.on_emit then state.on_emit(code, value) end
			return true
		end,
	}
	local injector = helpers.load_module("modules.hotstrings.injector")
	injector._set_uinput(channel)
	local ok, err = pcall(body, injector, function() return table.concat(rows, ",") end,
		function() return stopped end)
	injector._set_uinput(nil)
	package.loaded["adapters.keyboard_hook"] = old_hook
	if not ok then error(err, 0) end
end


helpers.describe("injector: source currency before new DOWN and owned cleanup UP", function()
	helpers.it("refuses stale native planning before any output", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				capture.process(99, 1)
				helpers.assert_eq(injector.type_directly("z").ok, false)
				helpers.assert_eq(rows(), "")
			end)
		end)
	end)
	helpers.it("refuses new DOWN after CapsLock observation reentry", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				state.on_caps = function() capture.process(99, 1) end
				local result = injector.type_directly("z")
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "")
			end)
		end)
	end)
	helpers.it("releases admitted modifier before refusing the stale character DOWN", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				state.on_emit = function(code, value)
					if code == 42 and value == 1 then capture.process(99, 1) end
				end
				local result = injector.type_directly("Z")
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "42:1,42:0")
			end)
		end)
	end)
	helpers.it("finishes exact character UP before refusing another stale DOWN", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				state.on_emit = function(code, value)
					if code == 44 and value == 1 then capture.process(99, 1) end
				end
				local result = injector.type_directly("zz")
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "44:1,44:0")
			end)
		end)
	end)
	helpers.it("keeps exact admitted data if native producer rows mutate", function()
		cohort_fixture(function(_, layout, state)
			output_fixture(nil, layout, state, function(injector, rows)
				state.on_emit = function() state.rows.z.keycode = 30 end
				helpers.assert_true(injector.type_directly("zz").ok)
				helpers.assert_eq(rows(), "44:1,44:0,44:1,44:0")
			end)
		end)
	end)
	helpers.it("refuses export replacement while still releasing its old admitted key", function()
		cohort_fixture(function(_, layout, state)
			output_fixture(nil, layout, state, function(injector, rows)
				state.on_emit = function(code, value)
					if code == 44 and value == 1 then layout.plan_current = function() return true end end
				end
				local result = injector.type_directly("zz")
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "44:1,44:0")
			end)
		end)
	end)
	helpers.it("keeps cleanup on its original channel after source retirement", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				local replacement_rows = 0
				state.on_emit = function(code, value)
					if code == 44 and value == 1 then
						capture.process(99, 1)
						injector._set_uinput({ is_open = function() return true end,
							emit = function() replacement_rows = replacement_rows + 1; return true end })
					end
				end
				local result = injector.type_directly("zz")
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "44:1,44:0")
				helpers.assert_eq(replacement_rows, 0)
			end)
		end)
	end)
	helpers.it("restores admitted CapsLock while refusing a stale replacement", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				state.caps = true
				state.on_emit = function(code, value)
					if code == 58 and value == 1 then capture.process(99, 1) end
				end
				local result = injector.type_directly("z")
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "58:1,58:0,58:1,58:0")
			end)
		end)
	end)
end)

helpers.describe("injector: joined programmable and layout admission", function()
	helpers.it("checks the source after programmable admission and before new DOWN", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				local armed, fired = false, false
				state.on_caps = function() armed = true end
				local publication = { current = function() return true end, cached = function()
					if armed and not fired then fired = true; capture.process(99, 1) end
					return true
				end }
				local result = injector.inject(0, "z", false, nil, publication)
				helpers.assert_true(fired)
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "")
			end)
		end)
	end)
	helpers.it("joins the last callback to a RAM source seal without another native read", function()
		cohort_fixture(function(capture, layout, state)
			output_fixture(capture, layout, state, function(injector, rows)
				local checks, ready, fired = 0, false, false
				state.on_caps = function()
					state.on_group = function() if checks == 1 then ready = true end end
				end
				local publication = { current = function() return true end, cached = function()
					checks = checks + 1
					if ready and not fired then
						fired = true
						state.on_group = nil
						capture.process(99, 1)
					end
					return true
				end }
				local result = injector.inject(0, "z", false, nil, publication)
				helpers.assert_true(fired)
				helpers.assert_eq(result.ok, false)
				helpers.assert_true(result.cleanup_ok)
				helpers.assert_eq(rows(), "")
			end)
		end)
	end)
end)
