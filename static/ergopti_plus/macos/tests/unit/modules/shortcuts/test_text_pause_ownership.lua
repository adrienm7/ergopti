--- tests/unit/modules/shortcuts/test_text_pause_ownership.lua

--- ==============================================================================
--- MODULE: Text Composite Pause Ownership
--- DESCRIPTION:
--- Drives the real text owner, TimerScheduler, and SyntheticInput stack against
--- observable native timers. Every named slot must restore the exact clipboard,
--- retain a refused timer identity, and keep late callbacks behind PAUSE. The
--- parenthesis action additionally remains one retained synthetic transaction
--- until its closing batch reaches the FIFO.
--- ==============================================================================

local helpers = require("tests.helpers")


local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = clone(child) end
	return out
end


local function fresh_fixture()
	for _, name in ipairs({
		"modules.shortcuts.actions.text",
		"adapters.synthetic_input",
		"adapters.event_provenance",
		"adapters.timer_scheduler",
		"infra.logger",
		"infra.paths",
		"infra.timings",
		"tests.stubs.hs",
		"hs",
	}) do package.loaded[name] = nil end

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local fixture = {
		native_timers = {},
		next_native_options = {},
		posted_triggers = {},
		batches = {},
		original = {
			["public.utf8-plain-text"] = "hello world",
			["public.html"] = "<b>hello world</b>",
		},
		clipboard = nil,
		restore_outcomes = {},
		restore_calls = 0,
		clear_calls = 0,
		snapshot_calls = 0,
	}
	fixture.clipboard = clone(fixture.original)

	function fixture.queue_native(options)
		fixture.next_native_options[#fixture.next_native_options + 1] = options or {}
	end

	local timer_contract = {}
	for key, value in pairs(hs_stub.timer) do timer_contract[key] = value end
	timer_contract.new = function(delay, callback)
		local options = table.remove(fixture.next_native_options, 1) or {}
		local native = {
			delay = delay,
			callback = callback,
			running_state = false,
			start_calls = 0,
			stop_calls = 0,
			stop_identities = {},
			start_mode = options.start_mode or "success",
			stop_mode = options.stop_mode or "success",
		}
		function native:start()
			self.start_calls = self.start_calls + 1
			local mode = self.start_mode
			if mode == "false_mutate" or mode == "nil_mutate"
				or mode == "throw_mutate" or mode == "sync_true" then
				self.running_state = true
			end
			if mode == "sync_true" then self.callback() end
			if type(options.on_start) == "function" then options.on_start(self) end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "throw" then error("native timer start exploded before activation") end
			if mode == "false_mutate" then return false end
			if mode == "nil_mutate" then return nil end
			if mode == "throw_mutate" then error("native timer start exploded") end
			self.running_state = true
			return self
		end
		function native:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("native timer stop exploded") end
			self.running_state = false
			return self
		end
		function native:running() return self.running_state end
		function native:fire()
			if self.running_state then self.callback() end
		end
		function native:deliver()
			self.callback()
		end
		fixture.native_timers[#fixture.native_timers + 1] = native
		return native
	end
	hs_stub.timer = timer_contract

	local base_new_mouse = hs_stub.eventtap.event.newMouseEvent
	hs_stub.eventtap.event.newMouseEvent = function(event_type, position, modifiers)
		local event = base_new_mouse(event_type, position, modifiers)
		event.post = function(self)
			fixture.posted_triggers[#fixture.posted_triggers + 1] = self
			return self
		end
		return event
	end

	hs_stub.pasteboard = {
		readAllData = function()
			fixture.snapshot_calls = fixture.snapshot_calls + 1
			return clone(fixture.clipboard)
		end,
		getContents = function() return "hello world" end,
		setContents = function(value)
			fixture.clipboard = { ["public.utf8-plain-text"] = value }
			return true
		end,
		writeAllData = function(snapshot)
			fixture.restore_calls = fixture.restore_calls + 1
			local mode = fixture.restore_outcomes[fixture.restore_calls] or "success"
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "throw" then error("clipboard restore exploded") end
			fixture.clipboard = clone(snapshot)
			return true
		end,
		clearContents = function()
			fixture.clear_calls = fixture.clear_calls + 1
			fixture.clipboard = {}
			-- Hammerspoon exposes no boolean success result for this operation.
			return nil
		end,
	}

	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.paths"] = { shared = function() return nil end }
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }
	local subject = require("modules.shortcuts.actions.text")
	local synthetic = require("adapters.synthetic_input")

	local function pump_tap()
		for _, tap in ipairs(hs_stub.eventtap.__taps) do
			if tap.types and tap.types[1] == hs_stub.eventtap.event.types.otherMouseUp then
				return tap
			end
		end
		return nil
	end

	function fixture.drain_synthetic()
		local guard = 0
		while guard < 100 do
			guard = guard + 1
			local progressed = false
			if #fixture.posted_triggers > 0 then
				local trigger = table.remove(fixture.posted_triggers, 1)
				local tap = assert(pump_tap(), "synthetic FIFO pump was not installed")
				local consume, events = tap.fn(trigger)
				helpers.assert_eq(consume, true)
				fixture.batches[#fixture.batches + 1] = events or {}
				progressed = true
			else
				for _, pending in ipairs(hs_stub.timer.__timers) do
					if pending.running == true and pending.recurring ~= true
						and pending.delay == 0 then
						pending:fire()
						progressed = true
						break
					end
				end
			end
			if not progressed then break end
		end
		helpers.assert_true(guard < 100, "synthetic FIFO did not quiesce")
	end

	fixture.subject = subject
	fixture.synthetic = synthetic
	return fixture
end


local function start_slot(fixture, slot)
	local before = #fixture.native_timers
	if slot == "transform" then
		helpers.assert_eq(fixture.subject.toggle_uppercase(), true)
		fixture.drain_synthetic() -- Cmd+C
	elseif slot == "plain" then
		helpers.assert_eq(fixture.subject.paste_as_plain_text(), true)
	elseif slot == "wrap" then
		helpers.assert_eq(fixture.subject.wrap_selection("hello", "(", ")"), true)
		fixture.drain_synthetic() -- Cmd+V
	else
		helpers.assert_eq(fixture.subject.surround_with_parens(), true)
		fixture.drain_synthetic() -- opening batch
	end
	helpers.assert_true(#fixture.native_timers > before,
		"the real TimerScheduler must acquire a native owner for " .. slot)
	return fixture.native_timers[before + 1]
end


helpers.describe("text composite owner: positive controls", function()
	helpers.it("completes transform, plain, and wrap phases with exact restoration", function()
		local transform = fresh_fixture()
		helpers.assert_eq(transform.subject.toggle_uppercase(), true)
		transform.drain_synthetic()
		-- failsafe, copy, paste, reselection, restore
		transform.native_timers[2]:fire()
		transform.native_timers[3]:fire()
		transform.drain_synthetic()
		transform.native_timers[4]:fire()
		transform.drain_synthetic()
		transform.native_timers[5]:fire()
		helpers.assert_eq(transform.clipboard, transform.original)
		helpers.assert_eq(transform.subject.has_pending_text_action(), false)

		local plain = fresh_fixture()
		helpers.assert_eq(plain.subject.paste_as_plain_text(), true)
		plain.native_timers[1]:fire()
		plain.drain_synthetic()
		plain.native_timers[2]:fire()
		helpers.assert_eq(plain.clipboard, plain.original)
		helpers.assert_eq(plain.subject.has_pending_text_action(), false)

		local wrap = fresh_fixture()
		helpers.assert_eq(wrap.subject.wrap_selection("hello", "[", "]"), true)
		wrap.drain_synthetic()
		wrap.native_timers[1]:fire()
		helpers.assert_eq(wrap.clipboard, wrap.original)
		helpers.assert_eq(wrap.subject.has_pending_text_action(), false)
	end)

	helpers.it("retains one surround transaction until the closing batch", function()
		local f = fresh_fixture()
		helpers.assert_eq(f.subject.surround_with_parens(), true)
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 1)
		helpers.assert_eq(f.synthetic.stats().active_transactions, 1,
			"the opening batch must not terminate the retained surround action")
		f.native_timers[1]:fire()
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 2)
		helpers.assert_eq(f.synthetic.stats().active_transactions, 0)
		helpers.assert_eq(f.synthetic.stats().action_handoffs, 1,
			"opening and closing are siblings of one logical action")
		helpers.assert_eq(f.subject.has_pending_text_action(), false)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("discards a partially built close before retry after " .. mode, function()
			local f = fresh_fixture()
			helpers.assert_eq(f.subject.surround_with_parens(), true)
			f.drain_synthetic()

			local original = f.synthetic.keyStrokes
			local refused = false
			f.synthetic.keyStrokes = function(batch, value)
				if value == ")" and refused ~= true then
					refused = true
					if mode == "throw" then error("closing build exploded") end
					return false
				end
				return original(batch, value)
			end

			f.native_timers[1]:fire()
			f.synthetic.keyStrokes = original
			helpers.assert_eq(#f.batches, 1,
				"a partially built close must never reach the synthetic FIFO")
			helpers.assert_true(f.native_timers[2] ~= nil,
				"the discarded batch must leave one autonomous retry owner")
			f.native_timers[2]:fire()
			f.drain_synthetic()
			helpers.assert_eq(#f.batches, 2,
				"exactly one complete closing sibling must be dispatched")
			helpers.assert_eq(f.synthetic.stats().active_transactions, 0,
				"the discarded building batch must not pin the transaction")
			helpers.assert_eq(f.subject.has_pending_text_action(), false)
		end)
	end

	helpers.it("duplicate RESUME leaves an active text transaction untouched", function()
		local f = fresh_fixture()
		helpers.assert_eq(f.subject.paste_as_plain_text(), true)
		local active = f.native_timers[1]
		helpers.assert_eq(active.stop_calls, 0)
		helpers.assert_eq(f.subject.resume_text_actions(), true)
		helpers.assert_eq(active.stop_calls, 0,
			"idempotent RESUME must not quiesce work admitted in the active generation")
		helpers.assert_eq(f.subject.has_pending_text_action(), true)
		active:fire()
		f.drain_synthetic()
		f.native_timers[2]:fire()
		helpers.assert_eq(f.clipboard, f.original)
		helpers.assert_eq(f.subject.has_pending_text_action(), false)
	end)

	helpers.it("restores an exactly empty clipboard on the native void boundary", function()
		local f = fresh_fixture()
		f.clipboard = {}
		helpers.assert_eq(f.subject.paste_as_plain_text(), true)
		f.native_timers[1]:fire()
		f.drain_synthetic()
		f.native_timers[2]:fire()
		helpers.assert_eq(f.clipboard, {})
		helpers.assert_eq(f.clear_calls, 1,
			"clearContents returning nil is the exact Hammerspoon success contract")
		helpers.assert_eq(f.subject.has_pending_text_action(), false)
	end)

	helpers.it("falls back to an immediate close when the post-opening timer fires synchronously", function()
		local f = fresh_fixture()
		f.queue_native({ start_mode = "sync_true", stop_mode = "success" })
		helpers.assert_eq(f.subject.surround_with_parens(), true)
		helpers.assert_eq(#f.native_timers, 0,
			"the close timer may not exist before opening on_dispatched")
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 2,
			"a refused cosmetic delay must still complete the proven opening")
		helpers.assert_eq(f.synthetic.stats().active_transactions, 0)
		helpers.assert_eq(f.subject.has_pending_text_action(), false)
	end)

	helpers.it("bounds repeated synchronous closing recovery failures", function()
		local f = fresh_fixture()
		helpers.assert_eq(f.subject.surround_with_parens(), true)
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 1)

		local original_key_strokes = f.synthetic.keyStrokes
		local close_attempts = 0
		f.synthetic.keyStrokes = function(batch, value)
			if value == ")" then
				close_attempts = close_attempts + 1
				return false
			end
			return original_key_strokes(batch, value)
		end
		f.queue_native({ start_mode = "false" })
		f.queue_native({ start_mode = "false" })
		f.native_timers[1]:fire()

		helpers.assert_eq(close_attempts, 2,
			"one direct recovery is allowed, but synchronous refusals may not recurse")
		helpers.assert_eq(#f.batches, 1,
			"no incomplete closing batch may enter the synthetic FIFO")
		helpers.assert_eq(f.subject.has_pending_text_action(), true,
			"the unmatched opening must remain an exact retryable intent")

		f.synthetic.keyStrokes = original_key_strokes
		helpers.assert_eq(f.subject.pause_text_actions(), false,
			"PAUSE must wait for the retained closing intent")
		local retry = f.native_timers[4]
		helpers.assert_not_nil(retry)
		retry:fire()
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 2)
		helpers.assert_eq(f.subject.pause_text_actions(), true)
		helpers.assert_eq(f.subject.resume_text_actions(), true)
	end)

	helpers.it("settles a real SyntheticInput admission refusal without a ghost slot", function()
		local f = fresh_fixture()
		local fence = f.synthetic.acquire_admission_fence("text-owner-test")
		helpers.assert_not_nil(fence)
		helpers.assert_eq(f.subject.surround_with_parens(), false)
		helpers.assert_eq(#f.native_timers, 0)
		helpers.assert_eq(#f.batches, 0)
		helpers.assert_eq(f.subject.has_pending_text_action(), false)
		helpers.assert_eq(f.synthetic.release_admission_fence(fence), true)
	end)
end)


helpers.describe("text composite owner: exact timer cleanup", function()
	for _, slot in ipairs({ "transform", "plain", "wrap" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(slot .. " retains the same timer after stop " .. mode, function()
				local f = fresh_fixture()
				local target = start_slot(f, slot)
				local timer_count = #f.native_timers
				target.stop_mode = mode
				helpers.assert_eq(f.subject.pause_text_actions(), false)
				helpers.assert_eq(f.subject.is_text_actions_paused(), true)
				helpers.assert_true(target.stop_identities[1] == target,
					"cleanup must target the exact native timer identity")
				helpers.assert_eq(f.clipboard, f.original,
					"PAUSE must restore the all-type snapshot before it can settle")
				helpers.assert_eq(f.subject.toggle_uppercase(), false)
				helpers.assert_eq(f.subject.paste_as_plain_text(), false)
				helpers.assert_eq(f.subject.wrap_selection("x", "(", ")"), false)
				helpers.assert_eq(f.subject.surround_with_parens(), false)
				helpers.assert_eq(#f.native_timers, timer_count)

				target:deliver()
				helpers.assert_eq(#f.native_timers, timer_count)
				helpers.assert_eq(f.clipboard, f.original)
				target.stop_mode = "success"
				target:deliver()
				helpers.assert_eq(target.stop_calls, 3)
				for _, identity in ipairs(target.stop_identities) do
					helpers.assert_true(identity == target,
						"every cleanup retry must target the exact native timer")
				end
				helpers.assert_eq(f.subject.pause_text_actions(), true)
				helpers.assert_eq(f.subject.resume_text_actions(), true)
				target:deliver()
				helpers.assert_eq(#f.native_timers, timer_count,
					"late and duplicate callbacks may not replay a text phase")
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("surround waits on its due closing timer after stop " .. mode, function()
			local f = fresh_fixture()
			local target = start_slot(f, "surround")
			target.stop_mode = mode
			target:fire()
			helpers.assert_eq(#f.batches, 1,
				"a due timer with live native debt may not dispatch the closing batch")
			helpers.assert_eq(f.subject.pause_text_actions(), false,
				"PAUSE must remain pending rather than leave a lone opening parenthesis")
			helpers.assert_true(target.stop_identities[1] == target,
				"due cleanup must target the exact native timer identity")
			target:deliver()
			helpers.assert_eq(#f.batches, 1)
			target.stop_mode = "success"
			target:deliver()
			helpers.assert_eq(target.stop_calls, 3)
			for _, identity in ipairs(target.stop_identities) do
				helpers.assert_true(identity == target,
					"every due cleanup retry must retain the exact native timer")
			end
			f.drain_synthetic()
			helpers.assert_eq(#f.batches, 2)
			helpers.assert_eq(f.subject.pause_text_actions(), true)
			helpers.assert_eq(f.subject.resume_text_actions(), true)
			target:deliver()
			helpers.assert_eq(#f.batches, 2)
		end)
	end
end)


helpers.describe("text composite owner: pause around surround opening", function()
	helpers.it("joins a re-entrant PAUSE while arming the post-opening close", function()
		local f = fresh_fixture()
		local pause_result = nil
		f.queue_native({
			on_start = function()
				pause_result = f.subject.pause_text_actions()
			end,
		})
		helpers.assert_eq(f.subject.surround_with_parens(), true)
		helpers.assert_eq(#f.native_timers, 0)
		f.drain_synthetic()
		helpers.assert_eq(pause_result, false,
			"the timer acquisition itself must keep PAUSE pending")
		helpers.assert_eq(#f.batches, 1)
		f.native_timers[1]:fire()
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 2,
			"a PAUSE re-entering timer activation may not strand the proven opening")
		helpers.assert_eq(f.subject.pause_text_actions(), true)
		helpers.assert_eq(f.subject.resume_text_actions(), true)
		helpers.assert_eq(#f.native_timers, 1)
	end)

	helpers.it("finishes the retained closing half after PAUSE follows the opening", function()
		local f = fresh_fixture()
		local original_dispatch = f.synthetic.dispatch
		local pause_result = nil
		local dispatch_calls = 0
		f.synthetic.dispatch = function(batch)
			dispatch_calls = dispatch_calls + 1
			local accepted = original_dispatch(batch)
			if dispatch_calls == 1 then pause_result = f.subject.pause_text_actions() end
			return accepted
		end
		helpers.assert_eq(f.subject.surround_with_parens(), true)
		helpers.assert_eq(pause_result, false)
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 1)
		f.native_timers[1]:fire()
		f.drain_synthetic()
		helpers.assert_eq(#f.batches, 2,
			"the already-accepted opening must receive its closing sibling")
		helpers.assert_eq(f.subject.pause_text_actions(), true)
		helpers.assert_eq(f.subject.resume_text_actions(), true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("completes the opening and retains mutate-then-refused timer " .. mode, function()
			local f = fresh_fixture()
			f.queue_native({ start_mode = mode .. "_mutate", stop_mode = mode })
			helpers.assert_eq(f.subject.surround_with_parens(), true)
			f.drain_synthetic()
			local target = f.native_timers[1]
			helpers.assert_eq(#f.batches, 2,
				"timer rollback debt may delay release but may not orphan the opening")
			helpers.assert_true(target.stop_calls >= 1)
			for _, identity in ipairs(target.stop_identities) do
				helpers.assert_true(identity == target,
					"opening cleanup must retain the exact native timer")
			end
			helpers.assert_eq(f.subject.pause_text_actions(), false)
			target.stop_mode = "success"
			helpers.assert_eq(f.subject.pause_text_actions(), true)
			helpers.assert_eq(f.subject.resume_text_actions(), true)
			helpers.assert_eq(#f.native_timers, 1)
			for _, identity in ipairs(target.stop_identities) do
				helpers.assert_true(identity == target,
					"opening settlement must retain the exact native timer")
			end
			target:deliver()
			helpers.assert_eq(#f.batches, 2,
				"late rollback delivery may not invent a third parenthesis batch")
		end)
	end
end)


helpers.describe("text composite owner: mutate-then-refused timer acquisition", function()
	for _, slot in ipairs({ "transform", "plain", "wrap" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(slot .. " retains the exact candidate after start " .. mode, function()
				local f = fresh_fixture()
				f.queue_native({ start_mode = mode .. "_mutate", stop_mode = mode })
				local accepted
				if slot == "transform" then
					accepted = f.subject.toggle_uppercase()
				elseif slot == "plain" then
					accepted = f.subject.paste_as_plain_text()
				else
					accepted = f.subject.wrap_selection("hello", "(", ")")
				end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(#f.native_timers, 1)
				local target = f.native_timers[1]
				helpers.assert_true(target.stop_calls >= 2)
				helpers.assert_eq(#f.batches, 0)
				helpers.assert_eq(f.clipboard, f.original)
				helpers.assert_eq(f.subject.pause_text_actions(), false)
				target:deliver()
				helpers.assert_eq(#f.batches, 0)
				helpers.assert_eq(f.clipboard, f.original)
				target.stop_mode = "success"
				helpers.assert_eq(f.subject.pause_text_actions(), true)
				helpers.assert_eq(f.subject.resume_text_actions(), true)
				helpers.assert_eq(#f.native_timers, 1)
				for _, identity in ipairs(target.stop_identities) do
					helpers.assert_true(identity == target,
						"refused acquisition cleanup must retain the exact native timer")
				end
				target:deliver()
				helpers.assert_eq(#f.batches, 0)
			end)
		end
	end
end)


helpers.describe("text composite owner: clipboard restore debt", function()
	for _, slot in ipairs({ "transform", "plain", "wrap" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(slot .. " retains its snapshot after restore " .. mode, function()
				local f = fresh_fixture()
				start_slot(f, slot)
				f.restore_outcomes = { mode, mode, "success" }
				helpers.assert_eq(f.subject.pause_text_actions(), false)
				helpers.assert_eq(f.subject.has_pending_text_action(), true)
				helpers.assert_eq(f.subject.resume_text_actions(), false,
					"RESUME must retry restoration before reopening admission")
				helpers.assert_eq(f.clipboard["public.html"], nil,
					"a refused restore must retain ownership without pretending to settle")
				helpers.assert_eq(f.subject.resume_text_actions(), true)
				helpers.assert_eq(f.restore_calls, 3)
				helpers.assert_eq(f.clipboard, f.original)
				helpers.assert_eq(f.subject.is_text_actions_paused(), false)
			end)
		end
	end
end)


helpers.describe("text composite owner: parent isolation", function()
	helpers.it("keeps gesture admission and ownership live while shortcuts pause", function()
		local f = fresh_fixture()
		helpers.assert_eq(
			f.subject.pause_text_actions("shortcut_bindings"), true)
		helpers.assert_eq(
			f.subject.select_line("shortcut_bindings"), false)
		helpers.assert_eq(f.subject.select_line("gestures"), true,
			"gesture text dispatch must remain admitted")

		helpers.assert_eq(f.subject.toggle_uppercase("gestures"), true)
		local gesture_timer = f.native_timers[1]
		helpers.assert_eq(
			f.subject.pause_text_actions("shortcut_bindings"), true)
		helpers.assert_eq(gesture_timer.stop_calls, 0,
			"shortcut cleanup must not stop a gesture timer")
		helpers.assert_eq(
			f.subject.has_pending_text_action("shortcut_bindings"), false)
		helpers.assert_eq(
			f.subject.has_pending_text_action("gestures"), true)

		helpers.assert_eq(f.subject.pause_text_actions("gestures"), true)
		helpers.assert_eq(gesture_timer.stop_calls, 1)
		helpers.assert_eq(f.subject.resume_text_actions("gestures"), true)
		helpers.assert_eq(
			f.subject.is_text_actions_paused("shortcut_bindings"), true)
	end)

	helpers.it("serialises the shared clipboard without settling a sibling parent", function()
		local f = fresh_fixture()
		helpers.assert_eq(f.subject.toggle_uppercase("shortcut_bindings"), true)
		local owner_timer = f.native_timers[1]
		local timer_count = #f.native_timers
		helpers.assert_eq(f.snapshot_calls, 1)

		helpers.assert_eq(f.subject.paste_as_plain_text("gestures"), false)
		helpers.assert_eq(f.subject.wrap_selection(
			"hello", "[", "]", "gestures"), false)
		helpers.assert_eq(f.snapshot_calls, 1,
			"a sibling parent may not snapshot clipboard data owned by the first action")
		helpers.assert_eq(#f.native_timers, timer_count)

		helpers.assert_eq(f.subject.pause_text_actions("gestures"), true)
		helpers.assert_eq(owner_timer.stop_calls, 0,
			"pausing a sibling scope may not consume the exact first-parent timer")
		helpers.assert_eq(
			f.subject.has_pending_text_action("shortcut_bindings"), true)
		helpers.assert_eq(
			f.subject.pause_text_actions("shortcut_bindings"), true)
		helpers.assert_eq(owner_timer.stop_calls, 1)
		helpers.assert_eq(
			f.subject.resume_text_actions("shortcut_bindings"), true)
		helpers.assert_eq(f.subject.resume_text_actions("gestures"), true)
		helpers.assert_eq(f.subject.paste_as_plain_text("gestures"), true)
	end)

	for _, action in ipairs({ "select_line", "select_word" }) do
		helpers.it(action .. " revalidates PAUSE between its two emissions", function()
			local f = fresh_fixture()
			local original_emit = f.synthetic.emit_key_stroke
			local calls = 0
			f.synthetic.emit_key_stroke = function(...)
				calls = calls + 1
				if calls == 1 then
					helpers.assert_eq(
						f.subject.pause_text_actions("gestures"), true)
				end
				return original_emit(...)
			end

			helpers.assert_eq(f.subject[action]("gestures"), false)
			helpers.assert_eq(calls, 1,
				"the second mutation must stay behind the re-entrant PAUSE fence")
			helpers.assert_eq(
				f.subject.is_text_actions_paused("gestures"), true)
		end)
	end
end)
