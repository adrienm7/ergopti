--- tests/unit/adapters/keyboard_hook/test_evdev_reader_open.lua

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
local helpers, recorder, flag_set, encoded =
	Fixture.helpers, Fixture.recorder, Fixture.flag_set, Fixture.encoded




-- =================================================================
-- =================================================================
-- ======= 1/ Opening ==============================================
-- =================================================================
-- =================================================================

helpers.describe("evdev_reader: open", function()

	helpers.it("opens the device non-blocking", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		helpers.assert_eq(reader.open("/dev/input/event3"), true, "the open must succeed")
		helpers.assert_eq(log.opened.path, "/dev/input/event3", "and use the path it was given")
		-- O_RDONLY is 0, so the flag word IS the non-blocking bit. Written as the
		-- literal from fcntl.h rather than as reader.O_NONBLOCK: comparing the
		-- module's constant against itself is an equality that holds for every
		-- possible value, including 0, which is the one that breaks everything.
		-- Without this bit every read blocks and the daemon advances only when a
		-- key arrives — the defect that made the tray and every timer
		-- keystroke-driven.
		helpers.assert_eq(flag_set(log.opened.flags, 0x0800), true,
			"the descriptor must be opened O_NONBLOCK (0x800 on Linux); a blocking "
				.. "read turns the event loop into a keystroke loop")
		helpers.assert_eq(log.opened.flags % 4, 0,
			"and read-only (O_ACCMODE bits 0): the reader never writes to the device")
		reader._reset_backend()
	end)

	helpers.it("opens the device close-on-exec (cloexec-grab-outlives-daemon)", function()
		-- EVIOCGRAB belongs to the open file, not to the process. Every child the
		-- daemon starts (`xdg-open … &`, a gesture's application, the update
		-- relay) inherits a descriptor opened without O_CLOEXEC, keeps that file
		-- open after the daemon dies, and with it the grab: the keyboard stays
		-- dead for as long as the child runs, and the restarted daemon's own grab
		-- fails with EBUSY. Literal from fcntl.h for the same reason as above.
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		helpers.assert_eq(reader.open("/dev/input/event3"), true, "the open must succeed")
		helpers.assert_eq(flag_set(log.opened.flags, 0x80000), true,
			"the descriptor must be opened O_CLOEXEC (0x80000 on Linux) so no child "
				.. "the daemon starts can keep the grab after the daemon dies")
		helpers.assert_eq(log.opened.flags, 0x80800,
			"the whole flag word is O_RDONLY | O_NONBLOCK | O_CLOEXEC, nothing else")
		reader._reset_backend()
	end)

	helpers.it("reports failure rather than pretending to be open", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder(nil, { open_fails = true })
		reader._set_backend(backend)

		helpers.assert_eq(reader.open("/dev/input/event3"), false, "a denied open must return false")
		helpers.assert_eq(reader.is_open(), false, "and must not leave the module believing it is open")
		reader._reset_backend()
	end)

	helpers.it("refuses an empty path instead of opening something else", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend((recorder()))
		helpers.assert_eq(reader.open(""), false, "an empty path is a resolution failure upstream")
		helpers.assert_eq(reader.open(nil), false, "and so is nil")
		reader._reset_backend()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The grab, and its order ==============================
-- =================================================================
-- =================================================================

helpers.describe("evdev_reader: EVIOCGRAB", function()

	helpers.it("takes the grab with the ioctl the kernel defines", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")

		helpers.assert_eq(reader.grab(), true, "the grab must succeed on a live descriptor")
		helpers.assert_eq(#log.ioctls, 1, "exactly one ioctl")
		-- _IOW('E', 0x90, int). A wrong request number does not fail loudly; it
		-- fails as "the keyboard still reaches the desktop", i.e. as everything
		-- being typed twice once re-emission is on.
		helpers.assert_eq(log.ioctls[1].request, 0x40044590, "EVIOCGRAB is _IOW('E', 0x90, int)")
		helpers.assert_eq(log.ioctls[1].arg, 1, "argument 1 takes the grab")
		helpers.assert_eq(reader.is_grabbed(), true, "and the module must know it holds it")
		reader._reset_backend()
	end)

	helpers.it("is taken before the first read", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder({ encoded(1, 30, 1) })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		reader.grab()
		reader.drain(function() end)

		helpers.assert_true(#log.ioctls >= 1, "the grab must have happened at all")
		helpers.assert_eq(log.ioctls[1].after_reads, 0,
			"no read may precede the grab: an event read before it also reached the "
				.. "desktop, so re-emitting it types that key twice")
		reader._reset_backend()
	end)

	helpers.it("does not re-issue the ioctl when already grabbed", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		reader.grab()
		reader.grab()
		helpers.assert_eq(#log.ioctls, 1, "grab() is idempotent, not repeated")
		reader._reset_backend()
	end)

	helpers.it("refuses to grab with no device open", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		helpers.assert_eq(reader.grab(), false, "there is nothing to grab")
		helpers.assert_eq(#log.ioctls, 0, "and no ioctl may be issued on a nil descriptor")
		reader._reset_backend()
	end)

	helpers.it("reports a failed grab instead of running ungrabbed", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder(nil, { ioctl_fails = true })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		-- Another process already holding the grab is the normal cause. Continuing
		-- would mean the daemon re-emits every key while the desktop also gets the
		-- physical one — everything typed twice.
		helpers.assert_eq(reader.grab(), false, "a rejected ioctl is not a grab")
		helpers.assert_eq(reader.is_grabbed(), false, "and must not be recorded as one")
		reader._reset_backend()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Closing ==============================================
-- =================================================================
-- =================================================================

helpers.describe("evdev_reader: close", function()

	helpers.it("releases the grab before closing the descriptor", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		reader.grab()
		reader.close()

		helpers.assert_eq(#log.ioctls, 2, "one to take the grab, one to release it")
		helpers.assert_eq(log.ioctls[2].arg, 0, "argument 0 releases the grab")
		helpers.assert_eq(log.closed, true, "and the descriptor is closed afterwards")
		helpers.assert_eq(reader.is_open(), false, "leaving nothing open")
		reader._reset_backend()
	end)

	helpers.it("is safe to call twice", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		reader.close()
		reader.close()
		helpers.assert_eq(reader.is_open(), false,
			"a second close on a closed reader must not raise on the shutdown path")
		reader._reset_backend()
	end)

	helpers.it("issues no ungrab when it never grabbed", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		reader.close()
		helpers.assert_eq(#log.ioctls, 0, "observe mode takes no grab, so it releases none")
		reader._reset_backend()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ Draining =============================================
-- =================================================================
-- =================================================================

helpers.describe("evdev_reader: drain", function()

	helpers.it("hands every available event to the handler, in order", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder({
			encoded(1, 42, 1),
			encoded(1, 30, 1),
			encoded(1, 30, 0),
		})
		reader._set_backend(backend)
		reader.open("/dev/input/event3")

		local seen = {}
		local count = reader.drain(function(ev)
			seen[#seen + 1] = string.format("%d:%d:%d", ev.type, ev.code, ev.value)
		end)

		helpers.assert_eq(count, 3, "three events were available")
		helpers.assert_eq(table.concat(seen, " "), "1:42:1 1:30:1 1:30:0",
			"order is the whole contract: under a grab the application sees exactly "
				.. "the sequence this loop re-emits")
		reader._reset_backend()
	end)

	helpers.it("stops as soon as a read comes back empty", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder({ encoded(1, 30, 1) })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		reader.drain(function() end)
		-- One read for the event, one that returns nothing. Anything more means the
		-- loop kept asking an empty device, which is the busy-wait this design
		-- replaced a blocking read with.
		helpers.assert_eq(log.reads, 2, "exactly one read past the end, got " .. log.reads)
		reader._reset_backend()
	end)

	helpers.it("is bounded, so one burst cannot starve the rest of the daemon", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local endless = {}
		for i = 1, reader.MAX_EVENTS_PER_DRAIN + 50 do endless[i] = encoded(1, 30, 1) end
		local backend = recorder(endless)
		reader._set_backend(backend)
		reader.open("/dev/input/event3")

		local count = reader.drain(function() end)
		helpers.assert_eq(count, reader.MAX_EVENTS_PER_DRAIN,
			"a held key produces events faster than they are consumed; an unbounded "
				.. "drain never returns to the tray or the periodic tick")
		reader._reset_backend()
	end)

	helpers.it("keeps draining after a handler raises", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder({ encoded(1, 30, 1), encoded(1, 31, 1), encoded(1, 32, 1) })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")

		local seen = {}
		reader.drain(function(ev)
			seen[#seen + 1] = ev.code
			if ev.code == 31 then error("domain callback exploded") end
		end)

		-- Under a grab an aborted drain is not a lost log line, it is input the
		-- user typed and the application never received.
		helpers.assert_eq(seen, { 30, 31, 32 },
			"one failing handler must not swallow the events behind it")
		reader._reset_backend()
	end)

	helpers.it("decodes nothing from a short read", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder({ "\0\0\0" })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		helpers.assert_eq(reader.read_event(), nil,
			"a truncated struct must not be decoded — the fields would be read from "
				.. "whatever follows and become a keystroke nobody made")
		reader._reset_backend()
	end)

	helpers.it("keeps the descriptor open when non-blocking read says not yet", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder(nil, { read_status = "would_block", read_reason = "EAGAIN" })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		local event, status, reason = reader.read_event()
		helpers.assert_eq(event, nil)
		helpers.assert_eq(status, "would_block")
		helpers.assert_eq(reason, "EAGAIN")
		helpers.assert_true(reader.is_open(), "EAGAIN is idle, not a disconnect")
		reader._reset_backend()
	end)

	helpers.it("closes a descriptor immediately when read reports ENODEV", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder(nil, { read_status = "fatal", read_reason = "ENODEV" })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		local event, status, reason = reader.read_event()
		helpers.assert_eq(event, nil)
		helpers.assert_eq(status, "fatal")
		helpers.assert_eq(reason, "ENODEV")
		helpers.assert_true(not reader.is_open(), "a dead fd must not remain healthy in the watchdog")
		helpers.assert_true(log.closed, "closing is the kernel-guaranteed emergency ungrab")
		reader._reset_backend()
	end)

	helpers.it("treats a backend read exception as fatal and closes", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder(nil, { read_raises = "read exploded" })
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		local _, status, reason = reader.read_event()
		helpers.assert_eq(status, "fatal")
		helpers.assert_contains(reason, "read exploded")
		helpers.assert_true(not reader.is_open())
		reader._reset_backend()
	end)

	helpers.it("drains nothing when no device is open", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend((recorder({ encoded(1, 30, 1) })))
		helpers.assert_eq(reader.drain(function() end), 0,
			"a closed reader has no events, and must not read a descriptor it does not hold")
		reader._reset_backend()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 5/ Kernel State Snapshots ================================
-- =================================================================
-- =================================================================

helpers.describe("evdev_reader: kernel state snapshots", function()

	helpers.it("decodes the pressed-key bitset returned by EVIOCGKEY", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		local seen = {}
		backend.read_bits = function(fd, request, count)
			seen = { fd = fd, request = request, count = count }
			return string.char(0x02, 0x02)
		end
		reader._set_backend(backend)
		reader.open("/dev/input/event3")

		local pressed = assert(reader.pressed_keys(reader.KEYBOARD, 15))
		helpers.assert_eq(seen.fd, 7, "the snapshot must query the open descriptor")
		helpers.assert_eq(seen.request, 0x80024518,
			"EVIOCGKEY(2) must be encoded as _IOC(_IOC_READ, 'E', 0x18, 2)")
		helpers.assert_eq(seen.count, 2, "codes 0 through 15 occupy exactly two bytes")
		helpers.assert_true(pressed[1] and pressed[9], "bits 1 and 9 must decode as pressed")
		helpers.assert_true(not pressed[0] and not pressed[8], "clear bits must stay clear")
		reader._reset_backend()
	end)

	helpers.it("decodes the lock LED bitset returned by EVIOCGLED", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		local request
		backend.read_bits = function(_, ioctl_request)
			request = ioctl_request
			return string.char(0x02)
		end
		reader._set_backend(backend)
		reader.open("/dev/input/event3")

		local leds = assert(reader.active_leds(reader.KEYBOARD, 1))
		helpers.assert_eq(request, 0x80014519,
			"EVIOCGLED(1) must be encoded as _IOC(_IOC_READ, 'E', 0x19, 1)")
		helpers.assert_true(leds[1], "LED_CAPSL must decode from bit one")
		reader._reset_backend()
	end)

	helpers.it("fails closed when the backend cannot provide a complete snapshot", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		local missing, missing_err = reader.pressed_keys(reader.KEYBOARD, 15)
		helpers.assert_eq(missing, nil)
		helpers.assert_contains(missing_err, "cannot query")

		backend.read_bits = function() return "\0" end
		local short, short_err = reader.pressed_keys(reader.KEYBOARD, 15)
		helpers.assert_eq(short, nil)
		helpers.assert_contains(short_err, "invalid ioctl bitset")
		reader._reset_backend()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 6/ Availability =========================================
-- =================================================================
-- =================================================================

helpers.describe("evdev_reader: is_available", function()

	helpers.it("says why, so the user can act on the answer", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend((recorder()))
		local ok, why = reader.is_available("/dev/input/definitely-not-here")
		helpers.assert_eq(ok, false, "an unreadable node is not available")
		helpers.assert_type(why, "string",
			"'no hotstrings happen' used to be the symptom of a missing binary, a "
				.. "masked keycode and a permission problem alike; the reason has to "
				.. "come back with the answer")
		reader._reset_backend()
	end)

	helpers.it("refuses an empty path", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend((recorder()))
		helpers.assert_eq((reader.is_available("")), false, "there is no device to check")
		reader._reset_backend()
	end)

	helpers.it("opens nothing while checking", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)
		reader.is_available("/dev/input/event3")
		-- A probe with side effects on an input device is a grab nobody asked for.
		helpers.assert_eq(log.opened, nil, "is_available must not open the descriptor")
		helpers.assert_eq(#log.ioctls, 0, "and must issue no ioctl")
		reader._reset_backend()
	end)

end)


helpers.describe("evdev_reader: open descriptor capabilities", function()
	helpers.it("queries event types on the exact open fd before any grab", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		local queries = {}
		backend.read_event_bits = function(fd, request, count)
			queries[#queries + 1] = { fd, request, count }
			return string.char(19, 0, 18, 0)
		end
		reader._set_backend(backend); assert(reader.open("/dev/input/event3"))
		local called, detail = pcall(function()
			helpers.assert_eq(reader.event_capabilities(), 0x120013)
			helpers.assert_eq(queries, { { 7, 0x80044520, 4 } }, "EVIOCGBIT(0, 4) identifies this fd, not its path")
			helpers.assert_eq(log.ioctls, {}, "capability inspection must not acquire a grab")
		end)
		assert(reader.close()); reader._reset_backend()
		if not called then error(detail, 0) end
	end)

	helpers.it("does not inspect capabilities on a closed descriptor", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		backend.read_event_bits = function() error("closed fd must not issue an ioctl") end
		reader._set_backend(backend)
		local called, detail = pcall(function() helpers.assert_eq(reader.event_capabilities(), nil) end)
		reader._reset_backend()
		if not called then error(detail, 0) end
	end)

	helpers.it("keeps its descriptor stable through a reentrant query callback", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		backend.read_event_bits = function()
			helpers.assert_eq(reader.close(), false)
			helpers.assert_eq(reader.open("/dev/input/event4"), false)
			helpers.assert_eq(reader.event_capabilities(), nil)
			return string.char(19, 0, 18, 0)
		end
		reader._set_backend(backend); assert(reader.open("/dev/input/event3"))
		local called, detail = pcall(function()
			helpers.assert_eq(reader.event_capabilities(), 0x120013)
			helpers.assert_eq(log.closed, false)
		end)
		assert(reader.close()); reader._reset_backend()
		if not called then error(detail, 0) end
	end)
end)

helpers.describe("evdev_reader: native capability ioctl acknowledgement", function()
	for _, result in ipairs({ 4, 0, -1, 3, 5 }) do
		helpers.it("requires exactly four copied bytes from ioctl, result " .. result, function()
			Fixture.controlled_native_reader({}, { event_result = result }, function(reader, log)
				assert(reader.open("/dev/input/event3"))
				local called, detail = pcall(function()
					local mask = reader.event_capabilities()
					helpers.assert_eq(mask, result == 4 and 0x120013 or nil)
					helpers.assert_eq(log.capability_queries, 1)
					helpers.assert_eq(log.grabs, 0, "capabilities are queried without taking a grab")
				end)
				assert(reader.close()); helpers.assert_eq(log.closes, 1)
				if not called then error(detail, 0) end
			end)
		end)
	end
end)

helpers.describe("evdev_reader: capability query ownership", function()
	helpers.it("distinguishes descriptors in separate slots, including fd zero", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		local next_fd, queries = 0, {}
		backend.open = function() local fd = next_fd; next_fd = next_fd + 1; return fd end
		backend.read_event_bits = function(fd, request, count)
			queries[#queries + 1] = { fd, request, count }
			return fd == 0 and string.char(19, 0, 18, 0) or string.char(51, 0, 0, 0)
		end
		reader._set_backend(backend); assert(reader.open("/dev/input/event0", "a")); assert(reader.open("/dev/input/event1", "b"))
		local called, detail = pcall(function()
			helpers.assert_eq(reader.event_capabilities("a"), 0x120013)
			helpers.assert_eq(reader.event_capabilities("b"), 0x33)
			helpers.assert_eq(queries, { { 0, 0x80044520, 4 }, { 1, 0x80044520, 4 } })
		end)
		assert(reader.close("a")); assert(reader.close("b")); reader._reset_backend()
		if not called then error(detail, 0) end
	end)

	helpers.it("keeps a failed native retirement fenced after a refused capabilities ioctl", function()
		Fixture.controlled_native_reader({}, { event_result = -1, close_fails = true }, function(reader, log)
			assert(reader.open("/dev/input/event3"))
			helpers.assert_eq(reader.event_capabilities(), nil)
			helpers.assert_eq(reader.close(), false)
			helpers.assert_eq(reader.has_native_origin_debt(), true)
			helpers.assert_eq(reader.close(), false)
			helpers.assert_eq(reader.open("/dev/input/event3"), false)
			helpers.assert_eq(reader._reset_backend(), false)
			helpers.assert_eq(log.closes, 1, "an unacknowledged native close cannot be retried against a reused fd")
			helpers.assert_eq(log.grabs, 0)
		end)
	end)
end)
