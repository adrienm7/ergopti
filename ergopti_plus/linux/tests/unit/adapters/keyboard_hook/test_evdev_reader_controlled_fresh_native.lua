--- tests/unit/adapters/keyboard_hook/test_evdev_reader_controlled_fresh_native.lua

--- ==============================================================================
--- MODULE: evdev Reader — grab, drain and lifecycle
--- DESCRIPTION:
--- The syscalls the reader makes, in the order it makes them, against a recorded
--- backend.
---
--- WHY THIS IS THE ASSERTION:
--- Capture used to be a child process, so EVIOCGRAB belonged to `evtest` and the
--- daemon could not observe it, release it, or take it again. Nothing in the
--- suite could say whether the device had been grabbed at all — the only
--- available evidence was a user reporting that their keyboard had stopped
--- working, which is the worst possible way to learn it.
---
--- Three orderings are the whole safety argument and each one is pinned below:
---   1. The grab is taken BEFORE the first read. An event read before the grab
---      also reached the desktop, so re-emitting it types that key twice.
---   2. The grab is released BEFORE the descriptor closes. Closing does release
---      it — the kernel binds EVIOCGRAB to the descriptor — but relying on that
---      alone means a leaked descriptor is a dead keyboard.
---   3. A drain is bounded. Under autorepeat the kernel produces events faster
---      than the loop consumes them, and an unbounded drain starves the tray and
---      the periodic tick, which is the defect the whole rewrite exists to fix.
---
--- The backend is a recorder rather than the FFI one: this interpreter has no
--- ffi module and no /dev/input, and a test that needed either would be a test
--- that never ran.
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.evdev_reader_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.evdev_reader_fixture")
local helpers, recorder, encoded, controlled_held_reader =
	Fixture.helpers, Fixture.recorder, Fixture.encoded, Fixture.controlled_held_reader




helpers.describe("evdev_reader: controlled fresh native held-state receipts", function()

	helpers.it("(linux-modal-original-open) preserves exact original opens across a legitimate two-source regrab", function()
		controlled_held_reader(nil, function(reader)
			local originals
			for _, slot in ipairs({ "a", "b" }) do assert(reader.open("/controlled/" .. slot, slot)); assert(reader.grab(slot)) end
			originals = { (assert(reader.capture_source_owner("a"))), (assert(reader.capture_source_owner("b"))) }
			for _, slot in ipairs({ "a", "b" }) do assert(reader.ungrab(slot)); assert(reader.grab(slot)) end
			local staged
			helpers.assert_true(reader.reconcile_sources({ "a", "b" }, function(snapshots)
				staged = snapshots
				for _, row in ipairs(snapshots) do helpers.assert_eq(reader.source_owner_current(row.lease), false) end
				return true
			end, originals))
			for _, row in ipairs(staged) do helpers.assert_true(reader.source_owner_current(row.lease)) end
			for _, lease in ipairs(originals) do helpers.assert_eq(reader.source_owner_current(lease), false) end
			assert(reader.close("a")); assert(reader.close("b"))
		end)
	end)

	helpers.it("(linux-modal-original-open) rejects a reopened peer before querying native state", function()
		controlled_held_reader(nil, function(reader, _, log)
			for _, slot in ipairs({ "a", "b" }) do assert(reader.open("/controlled/" .. slot, slot)); assert(reader.grab(slot)) end
			local originals = { (assert(reader.capture_source_owner("a"))), (assert(reader.capture_source_owner("b"))) }
			for _, slot in ipairs({ "a", "b" }) do assert(reader.ungrab(slot)) end
			assert(reader.close("a")); assert(reader.open("/controlled/a", "a")); assert(reader.grab("a")); assert(reader.grab("b"))
			local successor, queries, closes = assert(reader.capture_source_owner("a")), log.queries, log.closes
			helpers.assert_eq(reader.reconcile_sources({ "a", "b" }, function() error("foreign open admitted") end, originals), false)
			helpers.assert_eq(log.queries, queries); helpers.assert_eq(log.closes, closes)
			helpers.assert_true(reader.is_grabbed("a") and reader.source_owner_current(successor))
			for _, lease in ipairs(originals) do helpers.assert_eq(reader.source_owner_current(lease), false) end
			assert(reader.close("a")); assert(reader.close("b"))
		end)
	end)

	helpers.it("(linux-modal-original-open) rechecks the original opaque owner after restoration callbacks", function()
		controlled_held_reader(nil, function(reader)
			assert(reader.open("/controlled/a", "a")); assert(reader.grab("a"))
			local original, observer = reader.capture_source_owner("a"); assert(original)
			local staged
			assert(reader.ungrab("a")); assert(reader.grab("a"))
			local input, cleanup, same_open = reader.source_owner_current(original, observer,
				reader.capture_source_owner, reader.source_owner_current, reader.retire_source)
			helpers.assert_eq(input, false); helpers.assert_eq(cleanup, false)
			helpers.assert_true(same_open, "per-open identity never grants old input or cleanup currency")
			helpers.assert_eq(reader.reconcile_sources({ "a" }, function(rows)
				staged = rows[1].lease; original.changed = true; return true
			end, { original }), false)
			helpers.assert_eq(reader.source_owner_current(staged), false)
			original.changed = nil
			helpers.assert_true(reader.reconcile_sources({ "a" }, function() return true end, { original }))
			helpers.assert_eq(reader.source_owner_current(original), false)
			helpers.assert_eq(reader.source_owner_current(staged), false, "a rejected transaction never borrows a later commit")
			assert(reader.close("a"))
		end)
	end)

	helpers.it("(linux-native-reconciliation) refuses partial or ambiguous cohort lists before native queries", function()
		controlled_held_reader(nil, function(reader, _, log)
			assert(reader.open("/controlled/native-a", "a")); assert(reader.grab("a"))
			assert(reader.ungrab("a")); assert(reader.grab("a"))
			for _, slots in ipairs({ { [1] = "a", [3] = "b" }, { "a", rogue = "b" },
				{ [0] = "b", [1] = "a" }, { "a", "a" } }) do
				helpers.assert_eq(reader.reconcile_sources(slots, function() error("invalid cohort admitted") end), false)
			end
			helpers.assert_eq(log.queries, 0); helpers.assert_eq(log.led_queries, 0)
			helpers.assert_eq(reader.source_owner_current(reader.capture_source_owner("a")), false)
			assert(reader.close("a"))
		end)
	end)

	helpers.it("(linux-native-reconciliation) commits fresh source and held leases only after a native report and restore ACK", function()
		controlled_held_reader({ rows = { encoded(0, 3, 0), encoded(1, 30, 1), encoded(0, 0, 0) } }, function(reader)
			assert(reader.open("/controlled/native-a", "a")); assert(reader.grab("a"))
			local old = assert(reader.capture_source_owner("a"))
			assert(reader.read_event("a"))
			helpers.assert_eq(reader.source_owner_current(old), false)
			helpers.assert_eq(reader.reconcile_sources({ "a" }, function() error("before native report") end), false)
			local ignored = assert(reader.read_event("a"))
			helpers.assert_eq(reader.capture_event(ignored, "a"), nil)
			assert(reader.read_event("a"))
			local fresh, held
			helpers.assert_true(reader.reconcile_sources({ "a" }, function(snapshots)
				local snapshot = snapshots[1]
				fresh, held = snapshot.lease, snapshot.held
				helpers.assert_eq(snapshot.keys, { [29] = true, [42] = true })
				helpers.assert_eq(snapshot.leds, { [1] = true })
				helpers.assert_eq(reader.source_owner_current(fresh), false)
				helpers.assert_eq(reader.pressed_keys_current(held), false)
				helpers.assert_eq(reader.capture_source_owner("a"), nil)
				helpers.assert_eq(reader.close("a"), false)
				helpers.assert_eq(reader.ungrab("a"), false)
				helpers.assert_eq(reader.reconcile_sources({ "a" }, function() return true end), false)
				snapshot.keys[42] = nil
				return true
			end))
			helpers.assert_eq(reader.source_owner_current(fresh), true)
			helpers.assert_eq(reader.source_owner_current(old), false)
			helpers.assert_eq(reader.pressed_keys_view(held).down, { 29, 42 }, "detached restore input never rewrites native evidence")
			assert(reader.close("a"))
		end)
	end)

	for _, mode in ipairs({ "refuses", "throws", "truthy" }) do
		helpers.it("(linux-native-reconciliation) withholds every staged lease when restoration " .. mode, function()
			controlled_held_reader(nil, function(reader)
				assert(reader.open("/controlled/native-a", "a")); assert(reader.grab("a"))
				assert(reader.ungrab("a")); assert(reader.grab("a"))
				local pending
				helpers.assert_eq(reader.reconcile_sources({ "a" }, function(snapshots)
					pending = snapshots[1]
					if mode == "throws" then error("controlled restore exception") end
					return mode == "truthy" and 1 or false
				end), false)
				helpers.assert_eq(reader.source_owner_current(pending.lease), false)
				helpers.assert_eq(reader.pressed_keys_current(pending.held), false)
				helpers.assert_eq(reader.source_owner_current(reader.capture_source_owner("a")), false)
				helpers.assert_true(reader.is_grabbed("a"), "reconciliation never drops physical custody")
				helpers.assert_true(reader.reconcile_sources({ "a" }, function() return true end), "an explicit fresh retry can recover")
				helpers.assert_eq(reader.source_owner_current(pending.lease), false, "a refused transaction never borrows a later ACK")
				assert(reader.close("a"))
			end)
		end)
	end

	for _, invalid in ipairs({ { copied = 95 }, { led_copied = 1 }, { led_bytes = "\0" } }) do
		helpers.it("(linux-native-reconciliation) refuses incomplete native key or LED evidence", function()
			controlled_held_reader(invalid, function(reader)
				assert(reader.open("/controlled/native-a", "a")); assert(reader.grab("a"))
				assert(reader.ungrab("a")); assert(reader.grab("a"))
				local restored = false
				helpers.assert_eq(reader.reconcile_sources({ "a" }, function() restored = true; return true end), false)
				helpers.assert_eq(restored, false)
				helpers.assert_eq(reader.source_owner_current(reader.capture_source_owner("a")), false)
				assert(reader.close("a"))
			end)
		end)
	end

	helpers.it("(linux-native-reconciliation) restores a regrabbed cohort atomically and refuses authority port reentry", function()
		controlled_held_reader(nil, function(reader)
			for _, slot in ipairs({ "a", "b" }) do assert(reader.open("/controlled/native-" .. slot, slot)); assert(reader.grab(slot)) end
			local old_a, old_b = reader.capture_source_owner("a"), reader.capture_source_owner("b")
			for _, slot in ipairs({ "a", "b" }) do assert(reader.ungrab(slot)); assert(reader.grab(slot)) end
			local pending
			helpers.assert_eq(reader.reconcile_sources({ "a", "b" }, function(snapshots)
				pending = snapshots
				for _, snapshot in ipairs(snapshots) do helpers.assert_eq(reader.source_owner_current(snapshot.lease), false) end
				return false
			end), false)
			for _, snapshot in ipairs(pending) do helpers.assert_eq(reader.source_owner_current(snapshot.lease), false) end
			local original = reader.capture_source_owner
			helpers.assert_eq(reader.reconcile_sources({ "a", "b" }, function()
				reader.capture_source_owner = function() return {} end
				return true
			end), false)
			reader.capture_source_owner = original
			helpers.assert_true(reader.reconcile_sources({ "a", "b" }, function(snapshots) pending = snapshots; return true end))
			for _, snapshot in ipairs(pending) do helpers.assert_eq(reader.source_owner_current(snapshot.lease), true) end
			helpers.assert_eq(reader.source_owner_current(old_a), false); helpers.assert_eq(reader.source_owner_current(old_b), false)
			assert(reader.close("a")); assert(reader.close("b"))
		end)
	end)

	helpers.it("issues detached opaque full-key state including nonzero Ctrl and Shift", function()
		controlled_held_reader(nil, function(reader)
			assert(reader.open("/controlled/native-a", "a")); assert(reader.grab("a"))
			local cap = assert(reader.capture_pressed_keys("a"))
			helpers.assert_eq(next(cap), nil)
			helpers.assert_eq(reader.pressed_keys_current(cap), true)
			local view = assert(reader.pressed_keys_view(cap))
			helpers.assert_eq(view.down, { 29, 42 })
			helpers.assert_eq(view.max_code, 0x2ff)
			helpers.assert_eq(view.source, "/controlled/native-a")
			helpers.assert_eq(view.slot, "a")
			helpers.assert_eq(view.fd, nil); helpers.assert_eq(view.backend, nil)
			view.down[1], view.slot = 1, "foreign"
			helpers.assert_eq(reader.pressed_keys_view(cap).down, { 29, 42 })
			helpers.assert_eq(reader.close("a"), true)
		end)
	end)

	helpers.it("does not mint native held authority from a custom bitset provider", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		local queries = 0
		backend.native = true
		backend.read_bits = function() queries = queries + 1; return string.rep("\0", 96) end
		reader._set_backend(backend); assert(reader.open("/controlled/custom")); assert(reader.grab())
		local cap = reader.capture_pressed_keys()
		reader.close(); reader._reset_backend()
		helpers.assert_eq(cap, nil); helpers.assert_eq(queries, 0)
	end)

	helpers.it("requires literal native grab acknowledgement before the held ioctl", function()
		controlled_held_reader(nil, function(reader, _, log)
			assert(reader.open("/controlled/native-a"))
			helpers.assert_eq(reader.capture_pressed_keys(), nil)
			helpers.assert_eq(log.queries, 0)
			reader.close()
		end)
		controlled_held_reader({ grab_fails = true }, function(reader, _, log)
			assert(reader.open("/controlled/native-a")); helpers.assert_eq(reader.grab(), false)
			helpers.assert_eq(reader.capture_pressed_keys(), nil); helpers.assert_eq(log.queries, 0)
			reader.close()
		end)
	end)

	helpers.it("rejects short, failed and unknown native ioctl copy acknowledgements", function()
		for _, copied in ipairs({ 0, 95, -1, 97, 1.5, false }) do
			controlled_held_reader({ copied = copied }, function(reader)
				assert(reader.open("/controlled/native-a")); assert(reader.grab())
				helpers.assert_eq(reader.capture_pressed_keys(), nil)
				reader.close()
			end)
		end
	end)

	helpers.it("refuses invalid native buffers and provider exceptions", function()
		for _, options in ipairs({ { bytes = "\0" }, { before_query = function() error("controlled") end },
			{ before_string = function() error("controlled") end } }) do
			controlled_held_reader(options, function(reader)
				assert(reader.open("/controlled/native-a")); assert(reader.grab())
				helpers.assert_eq(reader.capture_pressed_keys(), nil)
				reader.close()
			end)
		end
	end)

	helpers.it("seals query callbacks against lifecycle reentry and old-current observations", function()
		controlled_held_reader(nil, function(reader, options, log)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			local old = assert(reader.capture_pressed_keys())
			options.before_query = function(current)
				helpers.assert_eq(current.pressed_keys_current(old), false)
				helpers.assert_eq(current.capture_pressed_keys(), nil)
				helpers.assert_eq(current.close(), false)
				helpers.assert_eq(current.ungrab(), false)
				helpers.assert_eq(current.use_ffi_backend(), false)
				helpers.assert_eq(current._reset_backend(), false)
			end
			local cap = assert(reader.capture_pressed_keys())
			helpers.assert_eq(reader.pressed_keys_current(old), false)
			helpers.assert_eq(reader.pressed_keys_current(cap), true)
			helpers.assert_eq(log.closes, 0)
			options.before_query = nil
			options.copied = 0
			helpers.assert_eq(reader.capture_pressed_keys(), nil)
			helpers.assert_eq(reader.pressed_keys_current(cap), false, "even a refused native query revokes its older observation")
			options.copied = nil
			options.down = { 42 }
			local fresh = assert(reader.capture_pressed_keys())
			helpers.assert_eq(reader.pressed_keys_view(fresh).down, { 42 })
			reader.close()
		end)
	end)

	helpers.it("rechecks decoder/provider currency after the last external buffer callback", function()
		controlled_held_reader(nil, function(reader, options)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			local codec = require("infra.input_event")
			local original = codec.decode
			options.before_string = function() codec.decode = function() return {} end end
			local cap = reader.capture_pressed_keys()
			codec.decode = original; options.before_string = nil; reader.close()
			helpers.assert_eq(cap, nil)
		end)
	end)

	helpers.it("revokes held observations on the next read even if event session provenance survives", function()
		controlled_held_reader({ rows = { encoded(1, 42, 1), encoded(1, 30, 1) } }, function(reader)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			local event = assert(reader.read_event())
			local origin = assert(reader.capture_event(event))
			local held = assert(reader.capture_pressed_keys())
			reader.read_event()
			helpers.assert_eq(reader.source_current(origin), true)
			helpers.assert_eq(reader.pressed_keys_current(held), false)
			local fresh = assert(reader.capture_pressed_keys())
			reader.read_event()
			helpers.assert_eq(reader.pressed_keys_current(fresh), false, "an empty queue read still ends the observation")
			reader.close()
		end)
	end)

	helpers.it("revokes observations after ordinary held queries and preserves independent source epochs", function()
		controlled_held_reader(nil, function(reader)
			for _, slot in ipairs({ "a", "b" }) do assert(reader.open("/controlled/native-" .. slot, slot)); assert(reader.grab(slot)) end
			local a = assert(reader.capture_pressed_keys("a"))
			local b = assert(reader.capture_pressed_keys("b"))
			reader.read_event("b")
			helpers.assert_eq(reader.pressed_keys_current(a), true)
			helpers.assert_eq(reader.pressed_keys_current(b), false)
			reader.pressed_keys("a", 0x2ff)
			helpers.assert_eq(reader.pressed_keys_current(a), false)
			reader.close("a"); reader.close("b")
		end)
	end)

	helpers.it("revokes held receipts on ungrab, reused fd/session and native close debt", function()
		controlled_held_reader(nil, function(reader, options)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			local cap = assert(reader.capture_pressed_keys())
			assert(reader.ungrab()); assert(reader.grab())
			helpers.assert_eq(reader.pressed_keys_current(cap), false)
			helpers.assert_true(reader.reconcile_sources({ reader.KEYBOARD }, function() return true end))
			local next_cap = assert(reader.capture_pressed_keys())
			options.close_fails = true; helpers.assert_eq(reader.close(), false)
			helpers.assert_eq(reader.pressed_keys_current(next_cap), false)
			helpers.assert_eq(reader.has_native_origin_debt(), true)
			helpers.assert_eq(reader.capture_pressed_keys(), nil)
		end)
	end)

	helpers.it("refuses query-loss authority until acknowledged native retirement and reopen", function()
		controlled_held_reader({ rows = { encoded(0, 3, 0) } }, function(reader)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			local cap = assert(reader.capture_pressed_keys())
			reader.read_event()
			helpers.assert_eq(reader.pressed_keys_current(cap), false)
			helpers.assert_eq(reader.capture_pressed_keys(), nil)
			assert(reader.close()); assert(reader.open("/controlled/native-a")); assert(reader.grab())
			helpers.assert_eq(type(reader.capture_pressed_keys()), "table")
			reader.close()
		end)
	end)

	helpers.it("does not invoke capability or slot equality metamethods for forged observations", function()
		controlled_held_reader(nil, function(reader)
			local calls = 0
			local meta = { __eq = function() calls = calls + 1; return true end }
			local slot, alias = setmetatable({}, meta), setmetatable({}, meta)
			assert(reader.open("/controlled/native-a", slot)); assert(reader.grab(slot))
			local cap = assert(reader.capture_pressed_keys(slot))
			setmetatable(cap, meta)
			helpers.assert_eq(reader.capture_pressed_keys(alias), nil)
			helpers.assert_eq(reader.pressed_keys_current(setmetatable({}, meta)), false)
			helpers.assert_eq(reader.pressed_keys_view(setmetatable({}, meta)), nil)
			helpers.assert_eq(calls, 0)
			reader.close(slot)
		end)
	end)

	helpers.it("records bounded partial coverage and rejects invalid query ranges before native calls", function()
		controlled_held_reader(nil, function(reader, _, log)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			for _, last in ipairs({ -1, 768, 1.5, false, "767", math.huge }) do
				helpers.assert_eq(reader.capture_pressed_keys(nil, last), nil)
			end
			helpers.assert_eq(log.queries, 0)
			local cap = assert(reader.capture_pressed_keys(nil, 31))
			local view = reader.pressed_keys_view(cap)
			helpers.assert_eq(view.max_code, 31); helpers.assert_eq(view.down, { 29 })
			reader.close()
		end)
	end)

	helpers.it("retains private view validation even if a public current method is replaced", function()
		controlled_held_reader(nil, function(reader)
			assert(reader.open("/controlled/native-a")); assert(reader.grab())
			local cap = assert(reader.capture_pressed_keys())
			reader.close()
			reader.pressed_keys_current = function() return true end
			helpers.assert_eq(reader.pressed_keys_view(cap), nil)
		end)
	end)

end)

