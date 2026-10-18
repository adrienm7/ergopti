--- tests/unit/adapters/keyboard_hook/test_evdev_reader_controlled_native_origin.lua

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
local helpers, recorder, encoded, controlled_native_reader, independent_slot_observer_case =
	Fixture.helpers, Fixture.recorder, Fixture.encoded, Fixture.controlled_native_reader, Fixture.independent_slot_observer_case




helpers.describe("evdev_reader: controlled native-origin receipts", function()

	helpers.it("never grants native authority to an explicit custom backend or decoded copy", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder({ encoded(1, 30, 1) })
		backend.native = true
		reader._set_backend(backend)
		helpers.assert_eq(reader.open("/dev/input/event3"), true)
		helpers.assert_eq(reader.grab(), true)
		local event = assert(reader.read_event())
		helpers.assert_eq(reader.capture_event(event), nil)
		helpers.assert_eq(reader.capture_event({ type = 1, code = 30, value = 1 }), nil)
		helpers.assert_eq(reader.close(), true)
	end)

	helpers.it("binds an opaque current receipt to actual controlled native KEY bytes", function()
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader)
			helpers.assert_eq(reader.open("/dev/input/event3", "owned"), true)
			helpers.assert_eq(reader.grab("owned"), true)
			local event = assert(reader.read_event("owned"))
			local cap = reader.capture_event(event, "owned")
			helpers.assert_eq(type(cap), "table")
			helpers.assert_eq(next(cap), nil)
			helpers.assert_eq(reader.capture_event(event, "foreign"), nil)
			helpers.assert_eq(reader.capture_event(event, "owned"), cap)
			helpers.assert_eq(reader.event_current(cap), true)
			helpers.assert_eq(reader.source_current(cap), true)
			local view = reader.event_view(cap)
			helpers.assert_eq(view.code, 30)
			helpers.assert_eq(view.value, 1)
			helpers.assert_eq(view.source, "/dev/input/event3")
			helpers.assert_eq(view.slot, "owned")
			helpers.assert_eq(view.origin, "native-evdev")
			helpers.assert_eq(view.fd, nil)
			helpers.assert_eq(view.backend, nil)
			view.code = 42
			helpers.assert_eq(reader.event_view(cap).code, 30)
			helpers.assert_eq(reader.close("owned"), true)
		end)
	end)

	helpers.it("does not mistake equal-shaped or metamethod-equal objects for issued authority", function()
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local event = assert(reader.read_event())
			local copy = {}; for field, value in pairs(event) do copy[field] = value end
			helpers.assert_eq(reader.capture_event(copy), nil)
			local cap = assert(reader.capture_event(event))
			local alias = setmetatable({}, { __eq = function() return true end })
			setmetatable(cap, getmetatable(alias))
			helpers.assert_eq(reader.event_current(alias), false)
			helpers.assert_eq(reader.event_view(alias), nil)
			helpers.assert_eq(reader.source_current(alias), false)
			reader.close()
		end)
	end)

	helpers.it("refuses remapped, mutated or metatable-backed decoded event objects", function()
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local event = assert(reader.read_event())
			local cap = assert(reader.capture_event(event))
			event.code = 42
			helpers.assert_eq(reader.capture_event(event), nil)
			helpers.assert_eq(reader.event_view(cap), nil)
			helpers.assert_eq(reader.source_current(cap), false)
			event.code, event.remapped = 30, true
			helpers.assert_eq(reader.capture_event(event), nil)
			event.remapped = nil
			setmetatable(event, { __pairs = function() error("not a native row") end })
			helpers.assert_eq(reader.event_current(cap), false)
			reader.close()
		end)
	end)

	helpers.it("separates current event admission from held-origin session currency", function()
		controlled_native_reader({ encoded(1, 42, 1), encoded(1, 30, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local first = assert(reader.read_event())
			local cap = assert(reader.capture_event(first))
			local second = assert(reader.read_event())
			helpers.assert_eq(reader.capture_event(first), nil)
			helpers.assert_eq(reader.event_current(cap), false)
			helpers.assert_eq(reader.event_view(cap), nil)
			helpers.assert_eq(reader.source_current(cap), true)
			local next_cap = assert(reader.capture_event(second))
			helpers.assert_eq(reader.event_view(next_cap).read_epoch, 2)
			reader.close()
		end)
	end)

	helpers.it("requires an acknowledged grab before issuing any native event receipt", function()
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader)
			reader.open("/dev/input/event3")
			local event = assert(reader.read_event())
			helpers.assert_eq(reader.capture_event(event), nil)
			reader.close()
		end)
		controlled_native_reader({ encoded(1, 30, 1) }, { grab_fails = true }, function(reader)
			reader.open("/dev/input/event3")
			helpers.assert_eq(reader.grab(), false)
			helpers.assert_eq(reader.capture_event((assert(reader.read_event()))), nil)
			reader.close()
		end)
	end)

	helpers.it("revokes old receipts on ungrab even after the same descriptor is grabbed again", function()
		controlled_native_reader({ encoded(1, 42, 1), encoded(1, 30, 1) }, { native_bitmaps = true }, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			helpers.assert_eq(reader.ungrab(), true)
			helpers.assert_eq(reader.source_current(cap), false)
			helpers.assert_eq(reader.grab(), true)
			helpers.assert_eq(reader.source_current(cap), false)
			helpers.assert_true(reader.reconcile_sources({ reader.KEYBOARD }, function() return true end))
			helpers.assert_eq(type(reader.capture_event((assert(reader.read_event())))), "table")
			reader.close()
		end)
	end)

	helpers.it("rejects a recycled numeric fd after native close and fresh open", function()
		controlled_native_reader({ encoded(1, 30, 1), encoded(1, 31, 1) }, nil, function(reader, log)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			helpers.assert_eq(reader.close(), true)
			helpers.assert_eq(reader.open("/dev/input/event3"), true)
			reader.grab()
			helpers.assert_eq(reader.source_current(cap), false)
			helpers.assert_eq(reader.event_current(cap), false)
			helpers.assert_eq(type(reader.capture_event((assert(reader.read_event())))), "table")
			helpers.assert_eq(log.opens, 2)
			reader.close()
		end)
	end)

	helpers.it("fences the native session on queue loss until real close and reopen", function()
		controlled_native_reader({ encoded(1, 42, 1), encoded(0, 3, 0), encoded(0, 0, 0),
			encoded(1, 30, 1), encoded(1, 31, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			reader.read_event()
			helpers.assert_eq(reader.source_current(cap), false)
			reader.read_event()
			helpers.assert_eq(reader.capture_event((assert(reader.read_event()))), nil)
			helpers.assert_eq(reader.close(), true)
			reader.open("/dev/input/event3"); reader.grab()
			helpers.assert_eq(type(reader.capture_event((assert(reader.read_event())))), "table")
			reader.close()
		end)
	end)

	helpers.it("refuses native rebinding while a descriptor is live and rejects prior-session receipts", function()
		controlled_native_reader({ encoded(1, 30, 1), encoded(1, 31, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			helpers.assert_eq(reader.use_ffi_backend(), false)
			helpers.assert_eq(reader._set_backend((recorder())), false)
			helpers.assert_eq(reader.source_current(cap), true)
			helpers.assert_eq(reader.close(), true)
			helpers.assert_eq(reader.use_ffi_backend(), true)
			reader.open("/dev/input/event3"); reader.grab()
			helpers.assert_eq(reader.source_current(cap), false)
			helpers.assert_eq(type(reader.capture_event((assert(reader.read_event())))), "table")
			reader.close()
		end)
	end)

	helpers.it("reserves read and native closure against reentrant lifecycle operations", function()
		local options = {}
		controlled_native_reader({ encoded(1, 42, 1), encoded(1, 30, 1) }, options, function(reader, log)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			local function probe(current)
				helpers.assert_eq(current.source_current(cap), false)
				helpers.assert_eq(current.close(), false)
				helpers.assert_eq(current.open("/dev/input/foreign"), false)
				helpers.assert_eq(current._reset_backend(), false)
				helpers.assert_eq(current._set_backend((recorder())), false)
			end
			options.before_read = probe
			helpers.assert_eq(type(reader.capture_event((assert(reader.read_event())))), "table")
			options.before_close = probe
			helpers.assert_eq(reader.close(), true)
			helpers.assert_eq(log.closes, 1)
		end)
	end)

	helpers.it("holds binding reservation before lazy FFI and cdef callbacks", function()
		local options = {}
		local function probe(reader)
			helpers.assert_eq(reader.open("/dev/input/foreign"), false)
			helpers.assert_eq(reader.use_ffi_backend(), false)
			helpers.assert_eq(reader._set_backend((recorder())), false)
		end
		options.before_load, options.before_cdef = probe, probe
		controlled_native_reader({}, options, function(reader, log)
			helpers.assert_eq(reader.open("/dev/input/event3"), true)
			helpers.assert_eq(log.opens, 1)
			helpers.assert_eq(reader.close(), true)
		end)
	end)

	helpers.it("pins native symbols so later public ffi.C replacement cannot substitute a descriptor operation", function()
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader, log, symbols)
			reader.open("/dev/input/event3"); reader.grab()
			symbols.read = function() error("foreign read") end
			symbols.close = function() error("foreign close") end
			symbols.ioctl = function() error("foreign ioctl") end
			helpers.assert_eq(type(reader.capture_event((assert(reader.read_event())))), "table")
			helpers.assert_eq(reader.close(), true)
			helpers.assert_eq(log.reads, 1)
			helpers.assert_eq(log.closes, 1)
		end)
	end)

	helpers.it("checks actual bytes even if a callback temporarily substitutes the decoder primitives", function()
		local codec = require("infra.input_event")
		local original = codec.unpack_u16_le
		local options = { before_string = function()
			codec.unpack_u16_le = function(data, offset)
				codec.unpack_u16_le = original
				return 1 + original(data, offset)
			end
		end }
		controlled_native_reader({ encoded(1, 30, 1) }, options, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local event = assert(reader.read_event())
			helpers.assert_eq(codec.unpack_u16_le, original)
			helpers.assert_eq(reader.capture_event(event), nil)
			reader.close()
		end)
	end)

	helpers.it("retains native close debt without reset or numeric-fd retry", function()
		controlled_native_reader({ encoded(1, 30, 1) }, { close_fails = true }, function(reader, log)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			helpers.assert_eq(reader.close(), false)
			helpers.assert_eq(reader.has_native_origin_debt(), true)
			helpers.assert_eq(reader.source_current(cap), false)
			helpers.assert_eq(reader.close(), false)
			helpers.assert_eq(reader._reset_backend(), false)
			helpers.assert_eq(reader._set_backend((recorder())), false)
			helpers.assert_eq(reader.use_ffi_backend(), false)
			helpers.assert_eq(reader.open("/dev/input/event3"), false)
			helpers.assert_eq(log.closes, 1)
		end)
	end)

	helpers.it("does not trust a replaceable public event-current callback for receipt views", function()
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			reader.event_current = function() return true end
			reader.close()
			helpers.assert_eq(reader.event_view(cap), nil)
			helpers.assert_eq(reader.source_current(cap), false)
		end)
	end)

end)




helpers.describe("evdev_reader: bounded native receipt lifetime", function()

	helpers.it("keeps held-origin authority without requiring the caller to retain the event table", function()
		controlled_native_reader({ encoded(1, 42, 1), encoded(1, 30, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local cap = assert(reader.capture_event((assert(reader.read_event()))))
			reader.read_event()
			collectgarbage("collect")
			helpers.assert_eq(reader.source_current(cap), true)
			reader.close()
		end)
	end)

	helpers.it("does not retain abandoned opaque receipts or prior decoded rows through weak-key value cycles", function()
		controlled_native_reader({ encoded(1, 30, 1), encoded(1, 31, 1) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local event = assert(reader.read_event())
			local cap = assert(reader.capture_event(event))
			local weak = setmetatable({ event, cap }, { __mode = "v" })
			event, cap = nil, nil
			reader.read_event()
			collectgarbage("collect")
			collectgarbage("collect")
			helpers.assert_eq(weak[1], nil)
			helpers.assert_eq(weak[2], nil)
			reader.close()
		end)
	end)

end)




helpers.describe("evdev_reader: exact slot cleanup after native peer debt", function()

	helpers.it("keeps known peer input readable and retireable without minting authority after another slot's unknown close", function()
		local options = { fds = { 7, 8 } }
		controlled_native_reader({ encoded(1, 30, 1), encoded(1, 31, 1) }, options, function(reader, log)
			reader.open("/dev/input/event3", "keyboard"); reader.grab("keyboard")
			reader.open("/dev/input/event4", "peer"); reader.grab("peer")
			local first = assert(reader.read_event("keyboard"))
			local cap = assert(reader.capture_event(first, "keyboard"))
			options.before_close = function(_, fd) options.close_fails = fd == 8 end
			helpers.assert_eq(reader.close("peer"), false)
			helpers.assert_eq(reader.source_current(cap), false)
			helpers.assert_eq(reader.wait_readable(0, "keyboard"), true)
			local next_event, status = reader.read_event("keyboard")
			helpers.assert_eq(status, "event")
			helpers.assert_eq(next_event.code, 31)
			helpers.assert_eq(reader.capture_event(next_event, "keyboard"), nil)
			helpers.assert_eq(reader.ungrab("keyboard"), true)
			helpers.assert_eq(reader.close("keyboard"), true)
			helpers.assert_eq(reader.close("peer"), false)
			helpers.assert_eq(log.closes, 2)
			helpers.assert_eq(reader.has_native_origin_debt(), true)
		end)
	end)

end)




helpers.describe("evdev_reader: origin is separate from current held-state authority", function()

	helpers.it("reports a later native release without turning an original-session receipt into a held-key oracle", function()
		controlled_native_reader({ encoded(1, 42, 1), encoded(1, 42, 0) }, nil, function(reader)
			reader.open("/dev/input/event3"); reader.grab()
			local down = assert(reader.capture_event((assert(reader.read_event()))))
			local release = assert(reader.read_event())
			local up = assert(reader.capture_event(release))
			helpers.assert_eq(reader.event_current(down), false)
			helpers.assert_eq(reader.event_view(up).code, 42)
			helpers.assert_eq(reader.event_view(up).value, 0)
			helpers.assert_eq(reader.source_current(down), true)
			reader.close()
		end)
	end)

end)




helpers.describe("independent exact native slot identity", function()
	helpers.it("refuses metamethod-equal foreign slot aliases", function()
		local mt = { __eq = function() return true end }
		local owned, foreign = setmetatable({}, mt), setmetatable({}, mt)
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader)
			helpers.assert_eq(reader.open("/dev/input/event3", owned), true)
			helpers.assert_eq(reader.grab(owned), true)
			local event = assert(reader.read_event(owned))
			local alias = reader.capture_event(event, foreign)
			helpers.assert_eq(reader.close(owned), true)
			helpers.assert_eq(alias, nil, "only the exact issuing slot may capture its native row")
		end)
	end)
end)




helpers.describe("independent opaque slot observer purity", function()
	helpers.it("never invokes matching two-sided alias callbacks during source observation", function()
		independent_slot_observer_case(false)
	end)
	helpers.it("never invokes Lua54 single-sided alias callbacks during source observation", function()
		independent_slot_observer_case(true)
	end)
end)




helpers.describe("evdev_reader: legitimate opaque slot receipt", function()

	helpers.it("preserves exact owned table slots without invoking their equality handlers", function()
		local owned = setmetatable({}, { __eq = function() error("opaque slot equality must stay private") end })
		controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader, log)
			helpers.assert_eq(reader.open("/dev/input/event3", owned), true)
			helpers.assert_eq(reader.grab(owned), true)
			local event = assert(reader.read_event(owned))
			local cap = assert(reader.capture_event(event, owned))
			helpers.assert_eq(reader.event_current(cap), true)
			helpers.assert_eq(rawequal(reader.event_view(cap).slot, owned), true)
			helpers.assert_eq(reader.source_current(cap), true)
			helpers.assert_eq(reader.close(owned), true)
			helpers.assert_eq(log.closes, 1)
			helpers.assert_eq(reader.source_current(cap), false)
		end)
	end)

end)

