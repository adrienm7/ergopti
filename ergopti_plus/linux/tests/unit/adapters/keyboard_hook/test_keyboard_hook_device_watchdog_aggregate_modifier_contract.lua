--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_device_watchdog_aggregate_modifier_contract.lua

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
local helpers, tick_until_check, aggregate_consumer_session =
	Fixture.helpers, Fixture.tick_until_check, Fixture.aggregate_consumer_session




helpers.describe("Hook aggregate modifier contract: preserved red controls", function()

	helpers.it("(linux-text-wire-custody) omits a shared key press the output owner coalesced", function()
		local session = aggregate_consumer_session({
			a = { { 30, 1, 1 }, { 30, 0, 3 } }, b = { { 30, 1, 2 }, { 30, 0, 4 } },
		})
		session.pump(); local chars, rows = session.chars, session.rows; session.close()
		helpers.assert_eq(rows, { { 30, 1 }, { 30, 0 } }, "the desktop received only one physical press")
		helpers.assert_eq(chars, { "a" }, "the matcher must see exactly the text delivered to the desktop")
	end)

	helpers.it("(linux-text-wire-custody) preserves real autorepeat while omitting duplicate downs", function()
		local session = aggregate_consumer_session({
			a = { { 30, 1, 1 }, { 30, 1, 2 }, { 30, 2, 3 }, { 30, 0, 4 } },
		})
		session.pump(); local chars, captures = session.chars, session.captures; session.close()
		helpers.assert_eq(chars, { "a", "a" }, "a repeat types a character; a duplicate down does not")
		helpers.assert_eq(captures, { { 30, 1 }, { 30, 2 }, { 30, 0 } })
	end)

	helpers.it("(linux-text-wire-custody) ignores repeats of a key an injection already released", function()
		local session = aggregate_consumer_session({ a = { { 30, 1, 1 } } })
		session.pump()
		local injected = session.inject_text("x")
		session.queue("a", 30, 2, 2); session.queue("a", 30, 0, 3); session.pump()
		local chars, rows = session.chars, session.rows; session.close()
		helpers.assert_true(injected.ok)
		helpers.assert_eq(rows, { { 30, 1 }, { 30, 0 }, { 45, 1 }, { 45, 0 } })
		helpers.assert_eq(chars, { "a" }, "a spent repeat cannot invent text after an expansion")
	end)

	helpers.it("(linux-spent-capture-retirement) retires a captured lock before its next physical press", function()
		local locked, down = false, false
		local session = aggregate_consumer_session({ a = { { 58, 1, 1 }, { 30, 1, 2 } } }, {
			process = function(code, value)
				if code == 58 then
					if value == 1 and not down then locked = not locked end
					if value == 1 then down = true elseif value == 0 then down = false end
				end
			end,
		})
		session.pump()
		local injected = session.inject_text("x")
		session.queue("a", 30, 0, 3); session.queue("a", 58, 0, 4); session.pump()
		session.queue("a", 58, 1, 5); session.queue("a", 58, 0, 6); session.pump()
		local captures = session.captures; session.close()
		helpers.assert_true(injected.ok)
		helpers.assert_eq(locked, false, "the next CapsLock press must toggle after injection spent its prior output owner")
		helpers.assert_eq(captures, { { 58, 1 }, { 30, 1 }, { 30, 0 }, { 58, 0 }, { 58, 1 }, { 58, 0 } },
			"a spent output release still retires the physical transition already admitted to XKB")
	end)

	helpers.it("(linux-spent-capture-retirement) waits for the final shared spent owner before capture release", function()
		local session = aggregate_consumer_session({ a = { { 30, 1, 1 } }, b = { { 30, 1, 2 } } })
		session.pump()
		local injected = session.inject_text("x")
		session.queue("a", 30, 0, 3); session.pump()
		local after_first = #session.captures
		session.queue("b", 30, 0, 4); session.pump()
		local captures, chars = session.captures, session.chars; session.close()
		helpers.assert_true(injected.ok)
		helpers.assert_eq(after_first, 1, "one shared source still owns the captured down")
		helpers.assert_eq(captures, { { 30, 1 }, { 30, 0 } }, "the last physical owner retires capture once")
		helpers.assert_eq(chars, { "a" }, "capture cleanup cannot create additional text")
	end)

	helpers.it("(linux-text-wire-custody) feeds Compose only the aggregate dead-key press", function()
		local pending = false
		local session = aggregate_consumer_session({
			a = { { 40, 1, 1 }, { 40, 0, 3 }, { 18, 1, 5 }, { 18, 0, 6 } },
			b = { { 40, 1, 2 }, { 40, 0, 4 } },
		}, { process = function(code, value)
			if value == 0 then return nil end
			if code == 40 then
				if pending then pending = false; return "^", "^" end
				pending = true; return nil, "^"
			end
			if code == 18 then local char = pending and "ê" or "e"; pending = false; return char, "e" end
		end })
		session.pump(); local chars, captures = session.chars, session.captures; session.close()
		helpers.assert_eq(chars, { "ê" }, "a suppressed second dead key cannot finish Compose early")
		helpers.assert_eq(captures, { { 40, 1 }, { 40, 0 }, { 18, 1 }, { 18, 0 } },
			"the capture state receives one aggregate press and the last owner's release")
	end)

	helpers.it("coalesces shared modifier capture to one global XKB down and final up", function()
		local session = aggregate_consumer_session({
			a = { { 42, 1, 1 }, { 42, 0, 3 } }, b = { { 42, 1, 2 }, { 42, 0, 4 } },
		})
		session.pump(); local captures = session.captures; session.close()
		helpers.assert_eq(captures, { { 42, 1 }, { 42, 0 } }, "per-source edge counts cannot replace a global XKB key bit")
	end)

	helpers.it("deduplicates a source down while retaining its real autorepeat", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 }, { 42, 1, 2 }, { 42, 2, 3 }, { 42, 0, 4 } } })
		session.pump(); local rows = session.rows; session.close()
		helpers.assert_eq(rows, { { 42, 1 }, { 42, 2 }, { 42, 0 } }, "duplicate ownership needs zero-wire settlement, repeat remains native")
	end)

	helpers.it("does not use a hardcoded modifier set when the live layout assigns Menu to Ctrl", function()
		local session = aggregate_consumer_session({
			a = { { 139, 1, 1 }, { 139, 0, 3 } }, b = { { 139, 1, 2 } },
		}, { roles = { [139] = "ctrl" } })
		session.pump(); local held, view = session.hook.held_modifiers(), session.view(); session.close()
		helpers.assert_eq(held.ctrl, true)
		helpers.assert_eq(view.down, { 139 }, "the actual layout role must retain the second Ctrl owner")
	end)

	helpers.it("retires lost-source modifier ownership while preserving the remaining source", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } }, b = { { 42, 1, 2 } } })
		session.pump(); session.retire("a"); session.pump()
		local held, view = session.hook.held_text_modifier_codes(), session.view(); session.close()
		helpers.assert_eq(view.down, { 42 }, "native output retirement already retains the other source")
		helpers.assert_eq(held, { 42 }, "the lost source must leave the live held-owner roster")
	end)

	helpers.it("(linux-retained-source-hotplug) retains held Shift while another keyboard reconnects", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } }, b = {} })
		session.pump()
		session.retire("b"); session.pump()
		tick_until_check(session.hook, 1)
		session.queue("a", 30, 1, 2); session.pump()
		local held, view, chars = session.hook.held_text_modifier_codes(), session.view(), session.chars
		session.close()
		helpers.assert_eq(view.down, { 30, 42 }, "the desktop still owns the retained physical Shift")
		helpers.assert_eq(held, { 42 }, "reopening another source must retain the original Shift owner")
		helpers.assert_eq(chars, { "A" }, "matcher text must follow the Shift still down on the desktop")
	end)

	for _, scenario in ipairs({ { "Ctrl", 29, "ctrl" }, { "Alt", 56, "alt" }, { "Super", 125, "meta" },
		{ "layout-assigned Ctrl", 139, "ctrl" } }) do
		helpers.it("(linux-retained-source-hotplug) retains " .. scenario[1] .. " shortcut suppression after source removal", function()
			local session = aggregate_consumer_session({ a = { { scenario[2], 1, 1 } }, b = {} },
				{ roles = { [scenario[2]] = scenario[3] } })
			session.pump(); session.select({ "a" }); tick_until_check(session.hook, 1)
			session.queue("a", 30, 1, 2); session.pump()
			local held, chars = session.hook.held_modifiers(), session.chars
			session.close()
			helpers.assert_eq(held[scenario[3]], true)
			helpers.assert_eq(chars, {}, "a held shortcut cannot become learned text during another keyboard's removal")
		end)
	end

	helpers.it("(linux-retained-source-hotplug) restores one XKB Shift edge while retaining both physical owners", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } }, b = { { 42, 1, 2 } }, c = {} })
		session.pump(); session.select({ "a", "b" }); tick_until_check(session.hook, 1)
		session.queue("a", 42, 0, 3); session.queue("b", 30, 1, 4); session.queue("b", 30, 0, 5)
		session.pump()
		local held, chars = session.hook.held_text_modifier_codes(), session.chars
		session.queue("b", 42, 0, 6); session.pump()
		local modifier_rows = {}
		for _, row in ipairs(session.rows) do if row[1] == 42 then modifier_rows[#modifier_rows + 1] = row end end
		session.close()
		helpers.assert_eq(held, { 42 })
		helpers.assert_eq(chars, { "A" })
		helpers.assert_eq(modifier_rows, { { 42, 1 }, { 42, 0 } }, "capture restoration cannot synthesize a second desktop Shift")
	end)

	helpers.it("(linux-retained-source-hotplug) keeps XKB state when the replacement source refuses to open", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } }, b = {} }, { initial_sources = { "a" } })
		session.pump(); session.select({ "a", "b" }); session.refuse_open("b")
		tick_until_check(session.hook, 1)
		session.queue("a", 30, 1, 2); session.pump()
		local held, chars = session.hook.held_text_modifier_codes(), session.chars
		session.close()
		helpers.assert_eq(held, { 42 })
		helpers.assert_eq(chars, { "A" }, "a refused source acquisition cannot reset the surviving capture session")
	end)

	helpers.it("does not publish a modifier ACK after emitter reentry closes its input source", function()
		local stopped = false
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } } }, {
			after_emit = function(current, code, value)
				if code == 42 and value == 1 and not stopped then stopped = true; current.hook.stop() end
			end,
		})
		session.pump(); local running, view = session.hook.isRunning(), session.view(); session.close()
		helpers.assert_eq(running, false)
		helpers.assert_eq(view.down, {}, "closed-source reentry must not strand a later committed native bit")
	end)

	helpers.it("neutralizes one shared Shift bit once during actual Injector restoration", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } }, b = { { 42, 1, 2 } } })
		session.pump(); local start = #session.rows
		local result = session.inject_text("x")
		local modifier_rows = {}
		for index = start + 1, #session.rows do
			local row = session.rows[index]
			if row[1] == 42 then modifier_rows[#modifier_rows + 1] = row end
		end
		session.close(); helpers.assert_eq(result.ok, true)
		helpers.assert_eq(modifier_rows, { { 42, 0 }, { 42, 1 } }, "one aggregate bit has one lift and one restoration")
	end)

end)




helpers.describe("actual shared-output handoff dependencies: green controls", function()

	helpers.it("does not orphan the retained physical Shift when retiring its synthetic TapHold owner", function()
		local Engine = require("platform.remap.tap_hold_engine")
		local engine = Engine.new({ keys = { caps_lock = { tap_action = "none", hold_modifier = "shift", time_activation_seconds = 10 } },
			tap_min_ms = 0, one_shot_timeout_ms = 2000 })
		local session = aggregate_consumer_session({ a = { { 58, 1, 1 }, { 42, 1, 2 } } }, { engine = engine })
		session.pump(); local before = session.view()
		local retired = session.hook.set_remapper(nil); local after = session.view()
		session.queue("a", 42, 0, 3); session.pump(); local final = session.view(); session.close()
		helpers.assert_eq(before.down, { 42 }); helpers.assert_eq(retired, true)
		helpers.assert_eq(after.down, { 42 }, "existing engine transfers the still-physical bit rather than lifting it")
		helpers.assert_eq(final.down, {})
	end)

	helpers.it("records actual Injector spending Alt while its originating physical owner remains held", function()
		local session = aggregate_consumer_session({ a = { { 56, 1, 1 } } })
		session.pump(); local before = session.view()
		local result = session.inject_text("x"); local after = session.view()
		local physical = session.hook.held_modifiers(); session.close()
		helpers.assert_eq(result.ok, true); helpers.assert_eq(after.down, {})
		helpers.assert_eq(physical.alt, true, "physical/source ownership differs from intentionally spent output")
		helpers.assert_true(after.write_epoch > before.write_epoch)
	end)

	helpers.it("records legitimate ComboEmitter writes on the same exact output capability", function()
		local session = aggregate_consumer_session({ a = { { 42, 1, 1 } } })
		session.pump(); local before = session.view()
		local combo = helpers.load_module("modules.gestures.combo_emitter")
		local accepted = combo.press_codes({ 56 }, { 30 }, "controlled shared writer")
		local after = session.view(); session.close()
		helpers.assert_eq(accepted, true); helpers.assert_eq(after.down, { 42 })
		helpers.assert_eq(after.write_epoch, before.write_epoch + 4,
			"a private Hook-only epoch would mistake a legitimate same-channel gesture for foreign ownership")
	end)

	helpers.it("retains temporary Writer exact-baseline release instead of silently committing persistent Shift", function()
		local session = aggregate_consumer_session({ a = {} })
		local writer, cap = session.writer, session.cap
		local token = assert(writer.acquire_transaction(cap))
		assert(writer.transaction_emit(token, 42, 1))
		local released = writer.release_transaction(token)
		local retained = writer.transaction_current(token)
		local restored = writer.restore_transaction(token)
		local finally_released = writer.release_transaction(token)
		local view = session.view(); session.close()
		helpers.assert_eq(released, false); helpers.assert_eq(retained, true)
		helpers.assert_eq(restored, true); helpers.assert_eq(finally_released, true)
		helpers.assert_eq(view.down, {}, "persistent forwarding needs its own commit contract, not a weaker temporary release")
	end)

end)




-- Controlled actual Reader/Hook lifecycle; no kernel or physical claim.
helpers.describe("native source state restoration", function()
	local Fixture = require("tests.support.input_owner_fixture")

	for _, code in ipairs({ 42, 29 }) do
		helpers.it("(linux-native-reconciliation) keeps a modal-consumed modifier out of matcher text " .. code, function()
			local chars, wire, held = {}, {}, {}
			Fixture.with_session({ position_bits = true, after_sync = function(_, key, value)
				if key == 42 or key == 29 then held[key] = value ~= 0 end
				if key == 30 and value == 1 and not held[29] then wire[#wire + 1] = held[42] and "A" or "a" end
			end }, function(s)
				s.hook.stop(); assert(s.hook.set_remapper(nil))
				s.start_options.onChar = function(char) chars[#chars + 1] = char end
				s.hook.start(s.start_options); assert(s.hook.isRunning())
				s.edge("a", code, 1, 1); s.edge("a", 30, 1, 2); s.edge("a", 30, 0, 3)
				helpers.assert_true(held[code], "the independent output model actually saw the modifier down")
				helpers.assert_eq(chars, wire)
				helpers.assert_eq(s.hook.while_released(function() return "completed" end), "completed")
				helpers.assert_true(s.held[s.paths.a][code], "the original physical key is still held")
				helpers.assert_eq(held[code], false, "modal entry retired its virtual output")
				s.edge("a", 30, 1, 4); s.edge("a", 30, 0, 5)
				helpers.assert_eq(chars, wire, "the matcher must follow output, not a consumed physical modifier")
				s.edge("a", code, 0, 6)
				s.edge("a", code, 1, 7); s.edge("a", 30, 1, 8); s.edge("a", 30, 0, 9); s.edge("a", code, 0, 10)
				helpers.assert_eq(chars, wire, "a fresh physical press restores the modifier normally")
			end)
		end)
	end

	for _, grabbed in ipairs({ false, true }) do
		helpers.it("(linux-modal-original-open) refuses a replacement without taking over its grab " .. tostring(grabbed), function()
			Fixture.with_session({ position_bits = true, on_capture_reacquired = function() return true end }, function(s)
				local a, b = "keyboard:" .. s.paths.a, "keyboard:" .. s.paths.b
				local old_a, old_b = assert(s.reader.capture_source_owner(a)), assert(s.reader.capture_source_owner(b))
				local successor
				helpers.assert_eq(s.hook.while_released(function()
					assert(s.reader.close(a)); assert(s.reader.open(s.paths.a, a)); if grabbed then assert(s.reader.grab(a)) end
					successor = assert(s.reader.capture_source_owner(a))
					return "completed"
				end), "completed")
				helpers.assert_eq(s.hook.isRunning(), false, "the original cohort cannot adopt a foreign open lifetime")
				helpers.assert_eq(s.reader.source_owner_current(old_a), false)
				helpers.assert_eq(s.reader.source_owner_current(old_b), false)
				helpers.assert_eq(s.reader.is_open(b), false, "the original peer is retired")
				helpers.assert_true(s.reader.is_open(a), "cleanup must leave the successor open")
				helpers.assert_eq(s.reader.is_grabbed(a), grabbed, "the hook must never take over or ungrab its successor")
				helpers.assert_eq(s.reader.source_owner_current(successor), grabbed, "the successor retains its own native currency")
				helpers.assert_eq(s.hook.capture_input_owner(), nil)
				assert(s.reader.close(a))
			end)
		end)
	end

	for _, boundary in ipairs({ "SYN_DROPPED", "modal" }) do
		helpers.it("(linux-native-reconciliation) restores logical input admission after " .. boundary, function()
			local session, published
			local options = { position_bits = true, on_capture_reacquired = function()
				published = true
				helpers.assert_eq(session.hook.capture_input_owner(), nil)
				helpers.assert_eq(session.hook.start(session.start_options), false)
				return true
			end }
			Fixture.with_session(options, function(s)
				session = s
				local old = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.a))
				if boundary == "SYN_DROPPED" then
					s.event("a", 0, 3, 0, 2); s.event("a", 0, 0, 0, 3)
				else
					helpers.assert_eq(s.hook.while_released(function() return "completed" end), "completed")
				end
				helpers.assert_true(s.hook.isRunning())
				for _, path in pairs(s.paths) do helpers.assert_true(s.reader.is_grabbed("keyboard:" .. path)) end
				helpers.assert_true(published)
				helpers.assert_eq(s.reader.source_owner_current(old), false)
				s.pair(); helpers.assert_eq(s.armed, true, "the original logical consumer uses the restored native cohort")
			end)
		end)
	end

	for _, boundary in ipairs({ "query", "restore", "publisher" }) do
		helpers.it("(linux-native-reconciliation) closes original sources when recovery " .. boundary .. " refuses", function()
			local session, recovering
			local options = { position_bits = true, on_capture_reacquired = function() return boundary ~= "publisher" end,
				on_capture_reset = function()
					if recovering and boundary == "restore" then session.hook.stop() end
				end }
			Fixture.with_session(options, function(s)
				session, recovering = s, true
				options.short_key_query = boundary == "query"
				s.event("a", 0, 3, 0, 1); s.event("a", 0, 0, 0, 2)
				helpers.assert_eq(s.hook.isRunning(), false)
				for _, path in pairs(s.paths) do helpers.assert_eq(s.reader.is_open("keyboard:" .. path), false) end
				helpers.assert_eq(s.hook.capture_input_owner(), nil)
			end)
		end)
	end
end)




helpers.describe("managed source cohort reconciliation", function()
	helpers.it("authenticates pre-event input and cleanup currencies separately", function()
require('tests.support.input_owner_fixture').with_session({}, function(s)
 local r = s.reader
 local capture, current, retire = r.capture_source_owner, r.source_owner_current, r.retire_source
 local lease, observer = assert(capture('keyboard:' .. s.paths.a))
 local input, cleanup = current(lease, observer, capture, current, retire)
 helpers.assert_true(input == true and cleanup == true, 'genuine grabbed source authentic before first event')
 helpers.assert_true(select('#', current(lease)) == 1 and current(lease) == true, 'original one-argument first and arity unchanged')
 helpers.assert_true(r.source_current(nil, lease, observer, capture, current, retire) == false, 'nil event source remains refused')
 helpers.assert_true(s.hook.capture_input_owner() == nil and #s.rows == 0 and s.acquisitions == 0, 'cleanup observation mints no event/input/output rights')
 for _, item in ipairs({
  { {}, observer, capture, current, retire, 'copied empty lease' },
  { lease, function() return true end, capture, current, retire, 'positive unregistered lambda' },
  { lease, observer, function() return lease, observer end, current, retire, 'substituted getter' },
  { lease, observer, capture, function() return true, true end, retire, 'substituted currency' },
  { lease, observer, capture, current, function() return true end, 'substituted retirement' },
  { lease, observer, nil, current, retire, 'partial tuple' },
 }) do
  local first, second = current(item[1], item[2], item[3], item[4], item[5])
  helpers.assert_true(first == false and second == false, item[6])
 end
 local other, other_observer = capture('keyboard:' .. s.paths.b)
 input, cleanup = current(lease, other_observer, capture, current, retire)
 helpers.assert_true(input == false and cleanup == false, 'borrowed registered observer')
 r.source_owner_current = function() return true, true end
 input, cleanup = current(lease, observer, capture, current, retire)
 helpers.assert_true(input == false and cleanup == false, 'retained authority rejects rebound live export')
 r.source_owner_current = current
 input, cleanup = current(lease, observer, capture, current, retire)
 helpers.assert_true(input == true and cleanup == true, 'restored original tuple remains current')
 local slot = 'pointer:' .. s.paths.b
 helpers.assert_true(r.open(s.paths.b, slot) == true, 'actual controlled native constructor opens ungrabbed pointer')
 local pointer, pointer_observer = capture(slot)
 input, cleanup = current(pointer, pointer_observer, capture, current, retire)
 helpers.assert_true(input == false and cleanup == true and current(pointer) == false, 'pointer cleanup never grants keyboard input')
 helpers.assert_true(r.close(slot) == true, 'original controlled pointer close ACK observed')
 input, cleanup = current(pointer, pointer_observer, capture, current, retire)
 helpers.assert_true(input == false and cleanup == false, 'retired original lifetime cannot revive')
 helpers.assert_true(r.open(s.paths.b, slot) == true, 'fresh pointer native constructor succeeds')
 local fresh, fresh_observer = capture(slot)
 input, cleanup = current(fresh, fresh_observer, capture, current, retire)
 helpers.assert_true(input == false and cleanup == true and fresh ~= pointer, 'fresh per-open pointer independently authentic')
 input, cleanup = current(pointer, fresh_observer, capture, current, retire)
 helpers.assert_true(input == false and cleanup == false, 'fresh observer cannot upgrade retired lease')
 helpers.assert_true(r.retire_source(pointer) == true and r.is_open(slot) == true, 'original idempotent retirement preserves reopened successor')
end)
	end)
end)




helpers.describe("managed source cohort reconciliation", function()
	helpers.it("renews genuine keyboard leases after descriptor ABA", function()
require('tests.support.input_owner_fixture').with_session({ recycle_descriptor = true }, function(s)
 local slot = 'keyboard:' .. s.paths.a
 local original_fd = s.descriptor('a')
 local previous = assert(s.reader.capture_source_owner(slot))
 assert(s.reader.source_owner_current(previous))
 assert(s.reader.close(slot))
 for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
 assert(s.hook.isRunning(), 'unchanged actual watchdog reports running after reacquisition')
 local fresh = assert(s.reader.capture_source_owner(slot))
 assert(fresh ~= previous and s.reader.source_owner_current(fresh))
 assert(not s.reader.source_owner_current(previous), 'old per-open lease stays retired')
 assert(s.descriptor('a') == original_fd, 'controlled exact descriptor ABA is exercised')
 s.pair()
 assert(s.armed == true, 'the actual new current source cohort must admit a genuinely owned new logical action')
end)
	end)
end)




helpers.describe("managed source cohort reconciliation", function()
	helpers.it("renews pointer cleanup leases without creating pointer input rights", function()
require('tests.support.input_owner_fixture').with_session({ recycle_descriptor = true }, function(s)
 local finder = assert(package.loaded['modules.hotstrings.device_finder'])
 assert(s.hook.stop() ~= false)
 finder.find_devices = function() return { s.paths.a }, { s.paths.b } end
 s.hook.start({ intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit, onClick = function() end })
 assert(s.hook.isRunning(), 'explicit controlled pointer cohort starts')
 assert(s.hook.set_remapper(s.engine, function(action, binding)
  s.action, s.binding = action, binding
  s.lease = s.hook.capture_input_owner()
  s.armed = s.lease and s.hook.arm_one_shot(s.lease) or false
 end))
 s.pair(); assert(s.armed == true, 'original genuine pointer cohort admits keyboard action before replacement')
 s.edge('a', 58, 0, 101); s.armed = nil
 local slot = 'pointer:' .. s.paths.b
 local previous, observe_previous = s.reader.capture_source_owner(slot)
 assert(previous and type(observe_previous) == 'function', 'sealed genuine Reader private observer required')
 local function current(lease, observer)
  return observer(lease, s.reader.capture_source_owner, s.reader.source_owner_current, s.reader.retire_source)
 end
 assert(current(previous, observe_previous), 'original ungrabbed pointer has genuine cleanup-only ownership')
 assert(not s.reader.source_owner_current(previous), 'pointer cleanup never grants keyboard input rights')
 assert(s.reader.close(slot))
 for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
 assert(s.hook.isRunning(), 'unchanged pointer-only watchdog reports running')
 local fresh, observe_fresh = s.reader.capture_source_owner(slot)
 assert(fresh ~= previous and current(fresh, observe_fresh))
 assert(not current(previous, observe_previous), 'old pointer lifetime remains retired')
 s.edge('a', 58, 1, 200); s.edge('a', 15, 1, 210); s.edge('a', 15, 0, 300)
 assert(s.armed == true, 'current keyboard input action must use the renewed original pointer cleanup cohort')
end)
	end)
end)




helpers.describe("managed source cohort callback boundaries", function()
	local Fixture = require("tests.support.input_owner_fixture")
	local function reconcile(s)
		assert(s.reader.close("keyboard:" .. s.paths.a))
		for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
	end

	helpers.it("publishes once after reacquisition before a new action can arm", function()
		local session, calls
		calls = 0
		Fixture.with_session({ on_capture_reacquired = function()
			calls = calls + 1
			assert(session.reader.is_open("keyboard:" .. session.paths.a))
			assert(session.hook.capture_input_owner() == nil)
			return true
		end }, function(s)
			session = s; reconcile(s)
			helpers.assert_eq(calls, 1)
			helpers.assert_true(s.hook.isRunning())
			s.pair(); helpers.assert_eq(s.armed, true)
		end)
	end)

	for _, mode in ipairs({ "refusal", "throw" }) do
		local refusal_mode = mode
		helpers.it("stops managed reacquisition on publication " .. refusal_mode, function()
			Fixture.with_session({ on_capture_reacquired = function()
				if refusal_mode == "throw" then error("controlled publication throw") end
				return false
			end }, function(s)
				reconcile(s)
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
				helpers.assert_eq(s.hook.capture_input_owner(), nil)
				helpers.assert_eq(s.writer.output_current(s.output), false)
			end)
		end)
	end

	helpers.it("blocks pump, owner, start and watchdog reentry while publishing", function()
		local session, nested, calls
		calls = 0
		Fixture.with_session({ on_capture_reacquired = function()
			calls = calls + 1
			session.pair()
			helpers.assert_eq(session.action, nil)
			helpers.assert_eq(session.hook.capture_input_owner(), nil)
			nested = session.hook.start(session.start_options)
			for _ = 1, session.hook.DEVICE_CHECK_TICKS do session.hook.check_device() end
			return true
		end }, function(s)
			session = s; reconcile(s)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(s.acquisitions, 0)
			helpers.assert_true(s.hook.isRunning())
			s.hook.pump(); helpers.assert_eq(s.armed, true)
		end)
	end)

	helpers.it("refuses an original source retired and replaced by the publisher", function()
		local session, successor
		Fixture.with_session({ recycle_descriptor = true, on_capture_reacquired = function()
			local slot = "keyboard:" .. session.paths.a
			assert(session.reader.close(slot))
			assert(session.reader.open(session.paths.a, slot)); assert(session.reader.grab(slot))
			successor = assert(session.reader.capture_source_owner(slot))
			return true
		end }, function(s)
			session = s; reconcile(s)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.reader.source_owner_current(successor))
			helpers.assert_true(s.reader.is_open("keyboard:" .. s.paths.a))
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
		end)
	end)

	helpers.it("preserves a publisher-reopened foreign output successor", function()
		local session
		Fixture.with_session({ on_capture_reacquired = function()
			assert(session.writer.close_owned(session.output))
			assert(session.writer.open())
			session.successor = assert(session.writer.capture_output())
			return true
		end }, function(s)
			session = s; reconcile(s)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.writer.output_current(s.successor))
			helpers.assert_eq(s.writer.output_current(s.output), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
		end)
	end)

	helpers.it("refuses a callback that invalidates the original start session", function()
		local session
		Fixture.with_session({ on_capture_reacquired = function()
			session.hook.stop()
			assert(session.hook.start(session.start_options) == false)
			return true
		end }, function(s)
			session = s; reconcile(s)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
		end)
	end)

	helpers.it("does not publish a stable cohort or a pointer-only replacement", function()
		local calls, resets = 0, 0
		Fixture.with_session({ on_capture_reacquired = function() calls = calls + 1; return true end,
			on_capture_reset = function() resets = resets + 1 end }, function(s)
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(calls, 0)
			assert(s.hook.stop() ~= false)
			local finder = package.loaded["modules.hotstrings.device_finder"]
			finder.find_devices = function() return { s.paths.a }, { s.paths.b } end
			local start = { intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit,
				onClick = function() end, onCaptureReacquired = function() calls = calls + 1; return true end }
			assert(s.hook.start(start))
			local prior_resets = resets
			assert(s.reader.close("pointer:" .. s.paths.b))
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(resets, prior_resets, "pointer cleanup renewal cannot reset the keyboard capture")
			helpers.assert_true(s.hook.isRunning())
		end)
	end)
end)




helpers.describe("managed source cohort retained authority", function()
	local Fixture = require("tests.support.input_owner_fixture")
	local function tick(s)
		for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
	end
	for _, name in ipairs({ "capture_source_owner", "source_owner_current", "retire_source" }) do
		local export_name = name
		helpers.it("refuses a pre-watchdog rebound Reader " .. export_name .. " without borrowing its cleanup", function()
			Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
				local original = s.reader[export_name]
				local borrowed = 0
				s.reader[export_name] = function() borrowed = borrowed + 1; return true, true end
				tick(s)
				s.reader[export_name] = original
				helpers.assert_eq(borrowed, 0)
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
				helpers.assert_eq(s.hook.capture_input_owner(), nil)
			end)
		end)
	end

	helpers.it("refuses a replaced managed option binding", function()
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			s.start_options.onCaptureReacquired = function() return true end
			tick(s)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
		end)
	end)

	helpers.it("keeps output-retirement failure pending without certifying readiness", function()
		local closes = 0
		Fixture.with_session({ on_capture_reacquired = function() return false end,
			output_close = function() closes = closes + 1; return false end }, function(s)
			assert(s.reader.close("keyboard:" .. s.paths.a)); tick(s)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.broker.output_retired(), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
			helpers.assert_eq(closes, 1, "only the original close attempt executes")
		end)
	end)
end)




helpers.describe("managed source cohort provider chronology", function()
	helpers.it("preserves a provider-reopened source instead of acquiring its foreign lifetime", function()
		local Fixture = require("tests.support.input_owner_fixture")
		Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
			local finder = package.loaded["modules.hotstrings.device_finder"]
			local original = finder.find_devices
			local successor
			assert(s.reader.close("keyboard:" .. s.paths.a))
			finder.find_devices = function()
				finder.find_devices = original
				local slot = "keyboard:" .. s.paths.b
				assert(s.reader.close(slot)); assert(s.reader.open(s.paths.b, slot)); assert(s.reader.grab(slot))
				successor = assert(s.reader.capture_source_owner(slot))
				return { s.paths.a, s.paths.b }, {}
			end
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(s.hook.isRunning(), false, "foreign per-open source cannot be adopted as a watchdog acquisition")
			helpers.assert_true(s.reader.source_owner_current(successor), "exact foreign native successor remains current")
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
		end)
	end)
end)




helpers.describe("managed source cohort provider and logger reentry", function()
	for _, mode in ipairs({ "provider", "logger" }) do
		local callback_kind = mode
		helpers.it("blocks actual " .. callback_kind .. " reentry before final cohort publication", function()
			local Fixture = require("tests.support.input_owner_fixture")
			Fixture.with_session({ on_capture_reacquired = function() return true end }, function(s)
				local finder, logger = package.loaded["modules.hotstrings.device_finder"], require("logger.shim")
				local find, success = finder.find_devices, logger.success
				local observed = false
				local function attempt()
					if not observed then s.pair() end
					observed = true
					helpers.assert_eq(s.action, nil)
					helpers.assert_eq(s.hook.capture_input_owner(), nil)
					for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
				end
				if callback_kind == "provider" then finder.find_devices = function() attempt(); return find() end
				else logger.success = function(...) attempt(); return success(...) end end
				local called, failure = pcall(function()
					assert(s.reader.close("keyboard:" .. s.paths.a))
					for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
				end)
				finder.find_devices, logger.success = find, success
				if not called then error(failure, 0) end
				helpers.assert_true(observed)
				helpers.assert_true(s.hook.isRunning())
				s.hook.pump(); helpers.assert_eq(s.armed, true)
			end)
		end)
	end
end)

