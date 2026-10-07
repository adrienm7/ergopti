--- tests/unit/adapters/test_modifier_broker_consumers.lua

--- ==============================================================================
--- MODULE: Modifier Consumer Causal Regressions
--- DESCRIPTION:
--- Independent literal wire/capture expectations exercise actual consumers.
--- These controlled byte-port cases make no native or physical delivery claim.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modifier_broker_fixture")
local Engine = require("platform.remap.tap_hold_engine")

local function engine()
	return Engine.new({ keys = { caps_lock = { tap_action = "none", hold_modifier = "shift", time_activation_seconds = 10 } },
		tap_min_ms = 0, one_shot_timeout_ms = 2000 })
end

helpers.describe("modifier consumers: independent causal wire and capture expectations", function()
	helpers.it("three sources produce one first down and one final up while retaining every physical edge", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 42, 1, 1); s.queue("b", 42, 1, 2); s.queue("c", 42, 1, 3)
			s.queue("a", 42, 0, 4); s.queue("c", 42, 0, 5); s.queue("b", 42, 0, 6); s.pump()
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 } })
			helpers.assert_eq(s.captures, { { 42, 1 }, { 42, 0 } })
			helpers.assert_eq(#s.physical, 6)
		end)
	end)

	helpers.it("the remaining source still shifts a real captured letter after the first source releases", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 42, 1, 1); s.queue("b", 42, 1, 2); s.queue("a", 42, 0, 3)
			s.queue("b", 30, 1, 4); s.queue("b", 30, 0, 5); s.pump()
			helpers.assert_eq(s.chars, { "A" })
			helpers.assert_eq(s.view().down, { 42 })
		end)
	end)

	helpers.it("a physical owner acquired before Caps survives Caps retirement and retires on its own up", function()
		Fixture.with_session({ engine = engine() }, function(s)
			s.queue("a", 42, 1, 1); s.queue("a", 58, 1, 2); s.pump()
			helpers.assert_true(s.hook.set_remapper(nil))
			helpers.assert_eq(s.view().down, { 42 })
			s.queue("a", 42, 0, 3); s.pump()
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 } })
			helpers.assert_eq(s.view().down, {})
		end)
	end)

	helpers.it("Caps and two physical Shift owners retire independently without swallowing either physical up", function()
		Fixture.with_session({ engine = engine() }, function(s)
			s.queue("a", 58, 1, 1); s.queue("a", 42, 1, 2); s.queue("b", 42, 1, 3); s.pump()
			helpers.assert_true(s.hook.set_remapper(nil))
			s.queue("a", 42, 0, 4); s.pump(); helpers.assert_eq(s.view().down, { 42 })
			s.queue("b", 42, 0, 5); s.pump(); helpers.assert_eq(s.view().down, {})
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 } })
		end)
	end)

	helpers.it("an old spent Alt release cannot lift a newly acknowledged second-source Alt", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 56, 1, 1); s.pump(); helpers.assert_true(s.inject().ok)
			s.queue("b", 56, 1, 2); s.pump(); helpers.assert_eq(s.view().down, { 56 })
			local count = #s.rows
			s.queue("a", 56, 0, 3); s.pump()
			helpers.assert_eq(#s.rows, count, "spent ownership retirement has no native UP")
			helpers.assert_eq(s.view().down, { 56 })
			s.queue("b", 56, 0, 4); s.pump(); helpers.assert_eq(s.view().down, {})
		end)
	end)

	helpers.it("ComboEmitter reacquires a spent modifier instead of borrowing a stale physical getter", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 56, 1, 1); s.pump(); helpers.assert_true(s.inject().ok)
			local count = #s.rows
			local Combo = helpers.load_module("modules.gestures.combo_emitter")
			helpers.assert_true(Combo.press_codes({ 56 }, { 30 }, "spent modifier control"))
			local rows = {}; for index = count + 1, #s.rows do rows[#rows + 1] = s.rows[index] end
			helpers.assert_eq(rows, { { 56, 1 }, { 30, 1 }, { 30, 0 }, { 56, 0 } })
			helpers.assert_eq(s.hook.held_modifiers().alt, true)
		end)
	end)

	helpers.it("duplicate downs settle ownership but genuine repeats still reach the wire", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 42, 1, 1); s.queue("a", 42, 1, 2); s.queue("a", 42, 2, 3); s.queue("a", 42, 0, 4); s.pump()
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 2 }, { 42, 0 } })
		end)
	end)

	helpers.it("a raw adapter cannot sneak another ordinary Writer emission into a reserved ACK", function()
		local attempted
		Fixture.with_session({ after_emit = function(s, code, value)
			if code == 42 and value == 1 then attempted = s.writer.emit(56, 1) end
		end }, function(s)
			s.queue("a", 42, 1, 1); s.queue("a", 42, 0, 2); s.pump()
			helpers.assert_eq(attempted, false)
			helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 } })
		end)
	end)

	helpers.it("a legitimate ComboEmitter transaction leaves the original Hook owner current", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 42, 1, 1); s.pump()
			local Combo = helpers.load_module("modules.gestures.combo_emitter")
			helpers.assert_true(Combo.press_codes({ 42 }, { 30 }, "borrowed Shift"))
			s.queue("a", 42, 0, 2); s.pump()
			helpers.assert_eq(s.rows, { { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } })
			helpers.assert_eq(s.view().down, {})
		end)
	end)

	helpers.it("an unacknowledged SYN cannot publish ownership or keep input grabbed", function()
		Fixture.with_session({ fail_sync = function(code, value) return code == 42 and value == 1 end }, function(s)
			s.queue("a", 42, 1, 1); s.pump()
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_nil(s.view())
			helpers.assert_eq(s.writer.is_open(), false, "exact native owner retires after transport ambiguity")
		end)
	end)

	helpers.it("foreign Writer advancement cannot refresh the Hook's output epoch", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 42, 1, 1); s.pump()
			assert(s.writer.emit(194, 1)); assert(s.writer.emit(194, 0))
			s.queue("a", 42, 0, 2); s.pump()
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.writer.is_open(), false)
		end)
	end)

	helpers.it("a gesture refuses an occupied key before lifting an owner it never acknowledged", function()
		Fixture.with_session(nil, function(s)
			s.queue("a", 30, 1, 1); s.pump(); local count = #s.rows
			local Combo = helpers.load_module("modules.gestures.combo_emitter")
			helpers.assert_eq(Combo.press_codes({ 56 }, { 30 }, "occupied physical key"), false)
			helpers.assert_eq(#s.rows, count)
			helpers.assert_eq(s.view().down, { 30 })
			s.queue("a", 30, 0, 2); s.pump(); helpers.assert_eq(s.view().down, {})
		end)
	end)

	helpers.it("persistent commit requires the exact acknowledged plain dense roster", function()
		Fixture.with_session(nil, function(s)
			helpers.assert_true(type(s.writer.commit_transaction) == "function", "persistent custody has a distinct commit API")
			local token = assert(s.writer.acquire_transaction(s.cap))
			assert(s.writer.transaction_emit(token, 42, 1))
			helpers.assert_eq(s.writer.release_transaction(token), false)
			helpers.assert_eq(s.writer.commit_transaction(token, { 42, extra = true }), false)
			helpers.assert_eq(s.writer.commit_transaction(token, { [1] = 42, [3] = 54 }), false)
			helpers.assert_eq(s.writer.commit_transaction(token, setmetatable({ 42 }, {})), false)
			helpers.assert_eq(s.writer.commit_transaction({}, { 42 }), false)
			helpers.assert_eq(s.writer.commit_transaction(token, { 42 }), true)
			helpers.assert_eq(s.view().down, { 42 })
		end)
	end)
end)


helpers.describe("modifier broker: producer receipts and typed attach admission", function()
	helpers.it("keeps public hold rows exact while custody stays with the original engine", function()
		local first, second = engine(), engine()
		local rows = first:process(58, 1, 0)
		helpers.assert_eq(rows, { { code = 42, value = 1 } })
		helpers.assert_eq(first:output_holder(rows[1]), "hold")
		helpers.assert_nil(second:output_holder(rows[1]))
		helpers.assert_nil(first:output_holder({ code = 42, value = 1 }))
		rows[1].code = 54
		helpers.assert_nil(first:output_holder(rows[1]), "mutable data cannot rewrite retained producer custody")
	end)

	helpers.it("observes handoff restoration role before the actual XKB callback", function()
		local Engine = require("platform.remap.tap_hold_engine")
		local configured = Engine.new({ tap_min_ms = 0, tap_max_ms = 300, double_press_ms = 400, one_shot_timeout_ms = 2000, keys = {
			caps_lock = { tap_action = "enter", hold_modifier = "shift", time_activation_seconds = 10 },
		} })
		Fixture.with_session({ engine = configured }, function(s)
			local capture
			for index = 1, 100 do
				local name, value = debug.getupvalue(s.hook.key_text, index)
				if name == "XkbCapture" then capture = value; break end
				if not name then break end
			end
			helpers.assert_type(capture, "table")
			local roles, process = capture.modifier_role, capture.process
			local trace = {}
			capture.modifier_role = function(code) trace[#trace + 1] = "role:" .. code; return roles(code) end
			capture.process = function(code, value) trace[#trace + 1] = "capture:" .. code .. ":" .. value; return process(code, value) end
			s.queue("a", 28, 1, 1); s.queue("a", 58, 1, 2); s.queue("a", 58, 0, 3); s.pump()
			local restores = 0
			for index, entry in ipairs(trace) do
				if entry == "capture:28:1" then
					restores = restores + 1
					helpers.assert_eq(trace[index - 1], "role:28", "even restored handoff DOWN observes pre-transition state")
				end
			end
			helpers.assert_eq(restores, 2, "the original held Enter and exact handoff restoration both ran")
			helpers.assert_eq(s.view().down, { 28 })
			local trace_start = #trace
			s.queue("a", 28, 0, 4); s.queue("a", 42, 1, 5); s.queue("a", 42, 0, 6); s.pump()
			local shift_roles = 0
			for index, entry in ipairs(trace) do
				if index > trace_start and entry == "role:42" then shift_roles = shift_roles + 1 end
				if entry == "capture:42:1" then helpers.assert_eq(trace[index - 1], "role:42") end
			end
			helpers.assert_eq(shift_roles, 1, "UP retires the retained DOWN role without querying a post-transition role")
			helpers.assert_nil(s.hook.held_modifiers().shift)
			helpers.assert_eq(s.view().down, {})
		end)
	end)

	for _, kind in ipairs({ "missing", "capture throws", "view throws", "capture replaces port" }) do
		helpers.it("refuses " .. kind .. " before borrowing malformed output authority", function()
			local Broker = helpers.load_module("adapters.modifier_broker")
			local writer = require("tests.fakes").uinput_writer()
			helpers.assert_true(writer.open())
			local old_capture, old_view, captures, lookalikes = writer.capture_output, writer.output_view, 0, 0
			writer.capture_output = function()
				captures = captures + 1
				if kind == "capture throws" then error("controlled capture refusal") end
				local cap = old_capture()
				if kind == "capture replaces port" then writer.output_view = function() lookalikes = lookalikes + 1; return { down = {} } end end
				return cap
			end
			if kind == "missing" then writer.output_view = nil end
			if kind == "view throws" then writer.output_view = function() error("controlled view refusal") end end
			local called, admitted = pcall(Broker.attach, writer)
			writer.capture_output, writer.output_view = old_capture, old_view
			helpers.assert_true(called, "typed admission reports refusal without a bootstrap exception")
			helpers.assert_nil(admitted)
			helpers.assert_nil(Broker.for_channel(writer))
			helpers.assert_eq(lookalikes, 0, "port replacement cannot borrow the captured capability")
			if kind == "missing" then helpers.assert_eq(captures, 0, "missing transport cannot acquire output first") end
			writer.close()
		end)
	end
end)


helpers.describe("modifier broker: reentrant batch retirement", function()
	for _, fail_inverse in ipairs({ false, true }) do
		helpers.it(fail_inverse and "retires exact output after unacknowledged reentrant inverse" or "acknowledges the remaining inverse after producer withdrawal", function()
			local configured = Engine.new({ tap_min_ms = 0, one_shot_timeout_ms = 2000, keys = {
				caps_lock = { tap_action = "none", hold_modifier = "ctrl+shift", time_activation_seconds = 10 },
			} })
			local withdrawn, inner, inverse_sync, up_sync_attempts = false, nil, 0, 0
			Fixture.with_session({ engine = configured,
				after_emit = function(s, _, value)
					if value == 0 and not withdrawn then withdrawn = true; inner = s.hook.set_remapper(nil) end
				end,
				fail_sync = function(_, value)
					if value == 0 then up_sync_attempts = up_sync_attempts + 1 end
					return fail_inverse and value == 0 and up_sync_attempts == 2
				end,
				after_sync = function(_, _, value) if value == 0 and up_sync_attempts == 2 then inverse_sync = inverse_sync + 1 end end,
			}, function(s)
				s.queue("a", 58, 1, 1); s.pump()
				helpers.assert_eq(s.view().down, { 29, 42 })
				local called, accepted = pcall(s.hook.set_remapper, nil)
				helpers.assert_true(called, "producer withdrawal cannot replace the retained row issuer")
				helpers.assert_eq(accepted, false, "a withdrawn batch reports refusal")
				helpers.assert_eq(inner, true)
				helpers.assert_eq(s.hook.isRunning(), false)
				-- release_all has always used an unordered key roster: both literal
				-- UP orders are valid; neither permits an omitted or unowned edge.
				local expected = s.rows[3] and s.rows[3][1] == 29
					and { { 29, 1 }, { 42, 1 }, { 29, 0 }, { 42, 0 } }
					or { { 29, 1 }, { 42, 1 }, { 42, 0 }, { 29, 0 } }
				helpers.assert_eq(s.rows, expected, "KEY writes include the final inverse even when its SYN was refused")
				helpers.assert_eq(up_sync_attempts, 2)
				helpers.assert_eq(inverse_sync, fail_inverse and 0 or 1)
				if fail_inverse then
					helpers.assert_nil(s.view(), "the exact channel retired after ambiguous inverse SYN")
					helpers.assert_eq(s.writer.is_open(), false)
				else
					helpers.assert_eq(s.view().down, {}, "the original owner's remaining UP was acknowledged")
				end
			end)
		end)
	end
end)
