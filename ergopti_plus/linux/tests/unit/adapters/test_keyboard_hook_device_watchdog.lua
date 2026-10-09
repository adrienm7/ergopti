--- tests/unit/adapters/test_keyboard_hook_device_watchdog.lua

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

local helpers = require("tests.helpers")

--- Loads the hook with a validated XKB-state stub.
---
--- These cases exercise descriptor replacement, not keymap acquisition. The
--- production hook now refuses to touch a device until keyboard_layout has
--- loaded live XKB state, so the fixture must satisfy that precondition instead
--- of weakening the fail-closed startup guard.
--- @return table keyboard_hook
local function load_hook()
	local name = "adapters.xkb_capture"
	local saved = package.loaded[name]
	package.loaded[name] = {
		is_ready = function() return true end,
		reset_state = function() return true end,
		process = function(code, value)
			if value ~= 1 then return nil, nil, nil end
			local text = ({ [30] = "a", [31] = "s", [48] = "b" })[code]
			return text, text, nil
		end,
		-- A layout whose modifier keys all play their usual role.
		modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code], nil end,
	}
	local hook = helpers.load_module("adapters.keyboard_hook")
	package.loaded[name] = saved
	return hook
end

--- Creates a readable file to stand in for a device node.
---
--- is_available() opens the path for reading, deliberately: an unreadable node
--- is the single most common failure on a real machine (the user is not in the
--- input group) and the reason has to reach the log. So the fixture has to be a
--- real file, not a string.
--- @param suffix string Distinguishes the two nodes.
--- @return string path
local function fake_node(suffix)
	local path = os.tmpname()
	-- os.tmpname on some runtimes returns a name without creating the file.
	local fh = assert(io.open(path, "w"))
	fh:write(suffix)
	fh:close()
	return path
end

--- Installs a device_finder stub whose answer can be changed mid-test.
--- @param initial string|nil First answer.
--- @return function set Replaces the answer.
--- @return function calls Returns the find_keyboard call count.
local function stub_device_finder(initial)
	local answer = initial
	local calls = 0
	package.loaded["modules.hotstrings.device_finder"] = {
		find_keyboard = function() calls = calls + 1 ; return answer end,
		-- The hook asks the finder whether a path can actually produce key events
		-- before it commits to it — /dev/null is readable, and without this check
		-- the daemon sat in its read loop forever waiting for events that cannot
		-- arrive. These tests drive synthetic node paths that are in no /proc, so
		-- the stub answers for them; the check itself is covered against real
		-- fixture text in test_device_finder_selection.lua.
		is_key_device = function() return true, nil end,
	}
	return function(next_answer) answer = next_answer end, function() return calls end
end

--- A recording syscall backend for the reader.
--- @return table backend, table log
local function recorder()
	local log = { opens = {}, ioctls = {}, ioctl_fds = {}, closes = 0 }
	return {
		open = function(path)
			log.opens[#log.opens + 1] = path
			return #log.opens
		end,
		ioctl = function(fd, _, arg)
			log.ioctls[#log.ioctls + 1] = arg
			log.ioctl_fds[#log.ioctl_fds + 1] = fd
			return true
		end,
		read  = function() return nil end,
		poll  = function() return false end,
		close = function() log.closes = log.closes + 1 end,
	}, log
end

--- A per-device backend: each descriptor drains only its own kernel queue.
--- @param queues table path -> array of encoded input_event values.
--- @return table backend, table log
local function multi_recorder(queues)
	local log = { opens = {}, ioctls = {}, closes = {} }
	return {
		open = function(path)
			log.opens[#log.opens + 1] = path
			return path
		end,
		ioctl = function(fd, _, arg)
			log.ioctls[#log.ioctls + 1] = { fd = fd, arg = arg }
			return true
		end,
		read = function(fd)
			local queue = queues[fd] or {}
			local next_value = table.remove(queue, 1)
			if type(next_value) == "table" and next_value.fatal then
				return nil, "fatal", next_value.fatal
			end
			return next_value
		end,
		poll = function() return false end,
		close = function(fd) log.closes[#log.closes + 1] = fd end,
	}, log
end

--- Advances the periodic tick enough times to trigger exactly one check.
--- @param kh table The loaded hook.
--- @param rounds integer How many checks to trigger.
local function tick_until_check(kh, rounds)
	for _ = 1, kh.DEVICE_CHECK_TICKS * rounds do
		kh.check_device()
	end
end





-- =================================================================
-- =================================================================
-- ======= 1/ The device it should read changed ====================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: re-acquires when the preferred device changes", function()

	helpers.it("switches to the device the finder now prefers, and grabs it", function()
		local node_a, node_b = fake_node("a"), fake_node("b")
		local set_device = stub_device_finder(node_a)
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({ device = node_a, intercept = true, onEmitRaw = function() return true end })
		helpers.assert_eq(kh.isRunning(), true, "the hook must start on the first device")
		helpers.assert_eq(log.opens[1], node_a, "and open it")
		helpers.assert_eq(log.ioctls[1], 1, "and grab it")

		-- The remap daemon restarts: its output device is destroyed and recreated
		-- under a new node, and the finder now points at that one.
		set_device(node_b)
		tick_until_check(kh, 1)

		helpers.assert_eq(#log.opens, 2,
			"the hook must open the new node; staying on the old descriptor means "
				.. "reading pre-remap keycodes, or nothing at all")
		helpers.assert_eq(log.opens[2], node_b, "and it must be the node the finder chose")
		local new_device_grabbed = false
		for index, arg in ipairs(log.ioctls) do
			if arg == 1 and log.ioctl_fds[index] == 2 then new_device_grabbed = true end
		end
		helpers.assert_true(new_device_grabbed,
			"the new device must be grabbed before the old one is released — an "
				.. "ungrabbed re-acquisition types everything twice")
		helpers.assert_true(log.closes >= 1, "and the old descriptor must be closed, not leaked")

		kh.stop()
		reader._reset_backend()
		os.remove(node_a) ; os.remove(node_b)
	end)

	helpers.it("releases keys held by the source before closing it", function()
		local node_a, node_b = fake_node("held-a"), fake_node("held-b")
		local set_device = stub_device_finder(node_a)
		local InputEvent = require("infra.input_event")
		local queues = {
			[node_a] = {
				InputEvent.encode(InputEvent.EV_KEY, 42, InputEvent.VALUE_DOWN, nil, 1),
				InputEvent.encode(InputEvent.EV_KEY, 14, InputEvent.VALUE_DOWN, nil, 2),
			},
			[node_b] = {},
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = multi_recorder(queues)
		local timeline = {}
		local close = backend.close
		backend.close = function(fd)
			timeline[#timeline + 1] = "close:" .. fd
			close(fd)
		end
		reader._set_backend(backend)
		local emitted = {}
		local kh = load_hook()
		kh.start({
			device = node_a,
			intercept = true,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = { code = code, value = value }
				timeline[#timeline + 1] = string.format("emit:%d:%d", code, value)
				return true
			end,
		})
		kh.pump()
		set_device(node_b)
		tick_until_check(kh, 1)

		helpers.assert_eq(emitted, {
			{ code = 42, value = InputEvent.VALUE_DOWN },
			{ code = 14, value = InputEvent.VALUE_DOWN },
			{ code = 14, value = InputEvent.VALUE_UP },
			{ code = 42, value = InputEvent.VALUE_UP },
		}, "every forwarded key must be balanced when its source disappears")
		local close_at = nil
		for index, event in ipairs(timeline) do
			if event == "close:" .. node_a then close_at = index; break end
		end
		helpers.assert_true(close_at ~= nil)
		helpers.assert_eq(timeline[close_at - 2], "emit:14:0")
		helpers.assert_eq(timeline[close_at - 1], "emit:42:0",
			"virtual releases must commit before the grabbed source closes")

		kh.stop()
		reader._reset_backend()
		os.remove(node_a) ; os.remove(node_b)
	end)

	helpers.it("stops every grab when a source-key release fails", function()
		local node_a, node_b = fake_node("release-fail-a"), fake_node("release-fail-b")
		local set_device = stub_device_finder(node_a)
		local InputEvent = require("infra.input_event")
		local queues = {
			[node_a] = { InputEvent.encode(InputEvent.EV_KEY, 42, InputEvent.VALUE_DOWN, nil, 1) },
			[node_b] = {},
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = multi_recorder(queues)
		reader._set_backend(backend)
		local kh = load_hook()
		kh.start({
			device = node_a,
			intercept = true,
			onEmitRaw = function(_, value) return value ~= InputEvent.VALUE_UP end,
		})
		kh.pump()
		set_device(node_b)
		tick_until_check(kh, 1)

		helpers.assert_true(not kh.isRunning(),
			"a failed release must emergency-stop instead of publishing the new source set")
		helpers.assert_true(#log.closes >= 2,
			"both the staged successor and the previous grabbed source must close")

		reader._reset_backend()
		os.remove(node_a) ; os.remove(node_b)
	end)

	helpers.it("keeps modifier state when a new source cannot be opened", function()
		local node_a, node_b = fake_node("keep-a"), fake_node("keep-b")
		local InputEvent = require("infra.input_event")
		local devices = { { node_a }, {} }
		package.loaded["modules.hotstrings.device_finder"] = {
			find_devices = function() return devices[1], devices[2] end,
			is_key_device = function() return true, nil end,
		}
		local queues = {
			[node_a] = { InputEvent.encode(InputEvent.EV_KEY, 42, InputEvent.VALUE_DOWN, nil, 1) },
			[node_b] = {},
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend({
			open = function(path)
				if path == node_b then return nil, "permission denied" end
				return path
			end,
			ioctl = function() return true end,
			read = function(fd)
				local queue = queues[fd] or {}
				local next_value = table.remove(queue, 1)
				if type(next_value) == "table" and next_value.fatal then
					return nil, "fatal", next_value.fatal
				end
				return next_value
			end,
			poll = function() return false end,
			close = function() end,
		})

		local kh = load_hook()
		kh.start({ intercept = false })
		helpers.assert_true(kh.isRunning(), "the hook must start on the readable keyboard")
		kh.pump()
		helpers.assert_true(kh.held_modifiers().shift == true,
			"the pumped Shift press must be visible as held")

		-- A second keyboard appears, but this user cannot read its node.
		-- Acquisition fails and the old source stays live.
		devices = { { node_a, node_b }, {} }
		tick_until_check(kh, 1)

		local ok, failure = xpcall(function()
			helpers.assert_true(kh.isRunning(), "the previous source set must keep running")
			helpers.assert_true(kh.held_modifiers().shift == true,
				"a failed acquisition must not discard the live modifier state — "
					.. "the user is still holding Shift and the next keys would "
					.. "resolve unshifted")
		end, debug.traceback)

		kh.stop()
		reader._reset_backend()
		os.remove(node_a) ; os.remove(node_b)
		if not ok then error(failure, 0) end
	end)

	helpers.it("does nothing while the answer is unchanged", function()
		local node = fake_node("a")
		stub_device_finder(node)
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({ device = node, intercept = true, onEmitRaw = function() return true end })
		tick_until_check(kh, 4)

		helpers.assert_eq(#log.opens, 1,
			"a stable device must not be reopened; each reopen drops the grab for a "
				.. "moment, and doing that four times a second is a keyboard that "
				.. "stutters for no reason")

		kh.stop()
		reader._reset_backend()
		os.remove(node)
	end)

	helpers.it("does not check on every tick", function()
		local node_a, node_b = fake_node("a"), fake_node("b")
		local set_device = stub_device_finder(node_a)
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({ device = node_a, intercept = true, onEmitRaw = function() return true end })
		set_device(node_b)

		-- One short of a full round. The check re-reads /proc/bus/input/devices,
		-- and the daemon ticks four times a second.
		for _ = 1, kh.DEVICE_CHECK_TICKS - 1 do kh.check_device() end
		helpers.assert_eq(#log.opens, 1, "the check must be rate-limited, not per-tick")

		kh.check_device()
		helpers.assert_eq(#log.opens, 2, "and it must actually fire on the tick it is due")

		kh.stop()
		reader._reset_backend()
		os.remove(node_a) ; os.remove(node_b)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ A pinned device stays pinned =========================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: an explicit device owns its watchdog policy", function()

	helpers.it("waits for the pinned path and never switches to the preferred device", function()
		local pinned, preferred = fake_node("pinned"), fake_node("preferred")
		local _, finder_calls = stub_device_finder(preferred)
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({
			device = pinned,
			pinned = true,
			intercept = true,
			onEmitRaw = function() return true end,
		})
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 1, "a healthy pinned path must not be reopened")
		helpers.assert_eq(finder_calls(), 0,
			"auto-detection must not participate in a pinned watchdog decision")

		os.remove(pinned)
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 1,
			"a missing pinned path must not be replaced by the preferred keyboard")
		helpers.assert_eq(finder_calls(), 0)

		local fh = assert(io.open(pinned, "w"))
		fh:write("reconnected")
		fh:close()
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 2, "the reappearing pinned node must be reopened")
		helpers.assert_eq(log.opens[2], pinned, "only the exact CLI-selected path may be reacquired")
		helpers.assert_true(log.opens[2] ~= preferred)

		kh.stop()
		reader._reset_backend()
		os.remove(pinned) ; os.remove(preferred)
	end)

	helpers.it("the daemon marks only a CLI-selected device as pinned", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		helpers.assert_contains(source, "pinned = opts.device ~= nil",
			"the adapter cannot distinguish CLI ownership after auto-detection unless the daemon carries it")
	end)

	helpers.it("pinned-watchdog: a reappearing path that lost EV_KEY is not adopted", function()
		-- Regression: the pinned branch trusted readability alone, but the
		-- kernel reuses eventN numbers across hotplug. A keyboard unplugged
		-- and a mouse plugged back at the same path was re-acquired and
		-- grabbed as a keyboard: hotstrings stopped and mouse buttons were
		-- swallowed into a keyboard-only uinput device.
		local pinned, preferred = fake_node("pinned"), fake_node("preferred")
		local pinned_is_key = true
		package.loaded["modules.hotstrings.device_finder"] = {
			find_keyboard = function()
				error("auto-detection must not participate in a pinned watchdog decision")
			end,
			is_key_device = function(path)
				if path == pinned then
					return pinned_is_key, pinned_is_key and nil or "reports no EV_KEY capability"
				end
				return true, nil
			end,
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({
			device = pinned,
			pinned = true,
			intercept = true,
			onEmitRaw = function() return true end,
		})
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 1, "a healthy pinned path must not be reopened")

		-- The keyboard is unplugged, then a mouse enumerates at the same path.
		os.remove(pinned)
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 1, "a missing pinned path waits, it is not replaced")
		local fh = assert(io.open(pinned, "w"))
		fh:write("impostor")
		fh:close()
		pinned_is_key = false
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 1,
			"a readable path that cannot produce key events must not be re-acquired, "
				.. "let alone grabbed as the keyboard")
		helpers.assert_true(kh.isRunning(),
			"waiting must not stop the hook: the previous source set stays live")

		-- The real keyboard returns at the same path: recovery works as before.
		pinned_is_key = true
		tick_until_check(kh, 1)
		helpers.assert_eq(#log.opens, 2, "the recovered keyboard must be reopened")
		helpers.assert_eq(log.opens[2], pinned, "only the exact CLI-selected path may be reacquired")

		kh.stop()
		reader._reset_backend()
		os.remove(pinned) ; os.remove(preferred)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ Every independent input source =======================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: multi-device ownership", function()

	helpers.it("grabs both keyboards and observes clicks from every pointer", function()
		local keyboard_a = fake_node("keyboard-a")
		local keyboard_b = fake_node("keyboard-b")
		local pointer_a = fake_node("pointer-a")
		local pointer_b = fake_node("pointer-b")
		local InputEvent = require("infra.input_event")
		local queues = {
			[keyboard_a] = { InputEvent.encode(InputEvent.EV_KEY, 30, InputEvent.VALUE_DOWN, nil, 99) },
			[keyboard_b] = { InputEvent.encode(InputEvent.EV_KEY, 48, InputEvent.VALUE_DOWN, nil, 102) },
			[pointer_a] = { InputEvent.encode(InputEvent.EV_KEY, 0x110, InputEvent.VALUE_DOWN, nil, 100) },
			[pointer_b] = { InputEvent.encode(InputEvent.EV_KEY, 0x111, InputEvent.VALUE_DOWN, nil, 101) },
		}
		package.loaded["modules.hotstrings.device_finder"] = {
			find_devices = function()
				return { keyboard_a, keyboard_b }, { pointer_a, pointer_b }
			end,
			is_key_device = function() return true, nil end,
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = multi_recorder(queues)
		reader._set_backend(backend)
		local physical, clicks, ordered = {}, {}, {}
		local buffer = "stale"
		local kh = load_hook()
		kh.start({
			intercept = true,
			onEmitRaw = function() return true end,
			onPhysical = function(code)
				physical[#physical + 1] = code
				ordered[#ordered + 1] = "key:" .. code
			end,
			onChar = function(char) buffer = buffer .. char end,
			onClick = function(code)
				clicks[#clicks + 1] = code
				ordered[#ordered + 1] = "click:" .. code
				buffer = ""
			end,
		})
		kh.pump()

		helpers.assert_eq(log.opens, { keyboard_a, keyboard_b, pointer_a, pointer_b },
			"every independent source must own a descriptor")
		helpers.assert_eq(#log.ioctls, 2, "only the two keyboards are grabbed")
		helpers.assert_eq(physical, { 30, 48 }, "both keyboards feed one physical-key state")
		helpers.assert_eq(clicks, { 0x110, 0x111 }, "both pointers invalidate the typing context")
		helpers.assert_eq(ordered, { "key:30", "click:272", "click:273", "key:48" },
			"independent queues must be merged by kernel timestamp, not drained by source")
		helpers.assert_eq(buffer, "b",
			"the click boundary must discard text before the caret move, not the key after it")

		queues[keyboard_a][1] = InputEvent.encode(InputEvent.EV_KEY, 31, InputEvent.VALUE_DOWN, nil, 200)
		queues[pointer_a][1] = InputEvent.encode(InputEvent.EV_KEY, 0x112, InputEvent.VALUE_DOWN, nil, 200)
		ordered = {}
		buffer = "stale"
		kh.pump()
		helpers.assert_eq(ordered, { "click:274", "key:31" },
			"a deterministic timestamp tie resets the caret context before typing")
		helpers.assert_eq(buffer, "s", "the tied key belongs to the post-click buffer")

		kh.stop()
		reader._reset_backend()
		os.remove(keyboard_a) ; os.remove(keyboard_b)
		os.remove(pointer_a) ; os.remove(pointer_b)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ Nothing to switch to =================================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: the watchdog when no device is there", function()

	helpers.it("reopens the same path after a fatal read", function()
		local node = fake_node("same-path")
		stub_device_finder(node)
		local queues = { [node] = { { fatal = "ENODEV" } } }
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = multi_recorder(queues)
		reader._set_backend(backend)
		local kh = load_hook()
		kh.start({ device = node, intercept = true, onEmitRaw = function() return true end })

		kh.pump()
		helpers.assert_true(not kh.isRunning(), "the dead descriptor cannot remain healthy")
		helpers.assert_true(kh.isRecovering(),
			"a live session must remain recoverable until the periodic watchdog runs")
		helpers.assert_eq(log.closes, { node }, "fatal read closes and ungrabs immediately")
		tick_until_check(kh, 1)
		helpers.assert_eq(log.opens, { node, node },
			"path equality must not hide that the old file descriptor died")
		helpers.assert_true(kh.isRunning(), "the exact same eventN path is live again")
		helpers.assert_true(not kh.isRecovering(), "successful acquisition ends recovery")

		kh.stop()
		reader._reset_backend()
		os.remove(node)
	end)

	helpers.it("releases a held key after a fatal source read", function()
		local node = fake_node("fatal-held")
		stub_device_finder(node)
		local InputEvent = require("infra.input_event")
		local queues = {
			[node] = {
				InputEvent.encode(InputEvent.EV_KEY, 42, InputEvent.VALUE_DOWN, nil, 1),
				{ fatal = "ENODEV" },
			},
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = multi_recorder(queues)
		reader._set_backend(backend)
		local emitted = {}
		local kh = load_hook()
		kh.start({
			device = node,
			intercept = true,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = { code = code, value = value }
				return true
			end,
		})
		kh.pump()

		helpers.assert_eq(emitted, {
			{ code = 42, value = InputEvent.VALUE_DOWN },
			{ code = 42, value = InputEvent.VALUE_UP },
		}, "fatal ENODEV must not leave the virtual Shift held")

		kh.stop()
		reader._reset_backend()
		os.remove(node)
	end)

	helpers.it("keeps the current descriptor when the finder answers nothing", function()
		local node = fake_node("a")
		local set_device = stub_device_finder(node)
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({ device = node, intercept = true, onEmitRaw = function() return true end })

		-- /proc briefly listing nothing usable is normal during a suspend/resume
		-- cycle. Closing on the strength of it would turn a hiccup into a dead
		-- daemon, and the descriptor we hold is still the best guess available.
		set_device(nil)
		tick_until_check(kh, 3)

		helpers.assert_eq(#log.opens, 1, "no device to switch to means no switch")
		helpers.assert_eq(log.closes, 0, "and the working descriptor must not be dropped")
		helpers.assert_eq(kh.isRunning(), true, "the hook keeps running on what it has")

		kh.stop()
		reader._reset_backend()
		os.remove(node)
	end)

	helpers.it("is inert before start and after stop", function()
		stub_device_finder("/dev/input/event99")
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		tick_until_check(kh, 2)
		helpers.assert_eq(#log.opens, 0,
			"a daemon that has not started capture must not open a device from its "
				.. "periodic tick")

		reader._reset_backend()
	end)

end)

helpers.describe("keyboard_hook: ordinary overlapping physical-source release", function()

	helpers.it("keeps the single acknowledged output Shift bit held until its last source releases", function()
		local a, b = fake_node("shared-shift-a"), fake_node("shared-shift-b")
		local InputEvent = require("infra.input_event")
		local queues = {
			[a] = { InputEvent.encode(1, 42, 1, nil, 1), InputEvent.encode(1, 42, 0, nil, 3) },
			[b] = { InputEvent.encode(1, 42, 1, nil, 2) },
		}
		package.loaded["modules.hotstrings.device_finder"] = {
			find_devices = function() return { a, b }, {} end,
			is_key_device = function() return true end,
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = multi_recorder(queues)
		reader._set_backend(backend)
		local writer = helpers.load_module("adapters.uinput_writer")
		local rows = {}
		writer._set_backend({
			open = function() return 9 end,
			ioctl = function() return true end,
			write = function(_, bytes) rows[#rows + 1] = bytes; return true end,
			close = function() return true end,
		})
		assert(writer.open())
		local output = assert(writer.capture_output())
		local hook = load_hook()
		hook.start({ intercept = true, onEmitRaw = writer.emit })
		hook.pump()
		local held = hook.held_text_modifier_codes()
		local output_after_first_release = writer.output_view(output)
		queues[b][1] = InputEvent.encode(1, 42, 0, nil, 4)
		hook.pump()
		local final = writer.output_view(output)
		hook.stop()
		reader._reset_backend()
		writer.close_owned(output)
		os.remove(a); os.remove(b)
		helpers.assert_eq(held, { 42 }, "the second source still physically owns Shift")
		helpers.assert_eq(output_after_first_release.down, { 42 },
			"a first-source up must not lift the shared virtual modifier bit")
		helpers.assert_eq(final.down, {}, "the final-source up must release the virtual bit")
	end)

end)

--- Starts the real Hook, reviewed Writer and Reader with controlled syscalls/layout.
--- The XKB port records actual Hook transitions and models a single desktop key bit.
--- No kernel, display, libuv handle or native command is acquired by these controls.
local function aggregate_consumer_session(streams, options)
	options = options or {}
	local Input = require("infra.input_event")
	local paths, queues, desired = {}, {}, {}
	for _, id in ipairs({ "a", "b" }) do
		if streams[id] then
			local path = fake_node("aggregate-" .. id)
			paths[id], desired[#desired + 1], queues[path] = path, path, {}
			for _, row in ipairs(streams[id]) do
				queues[path][#queues[path] + 1] = Input.encode(1, row[1], row[2], nil, row[3])
			end
		end
	end
	package.loaded["modules.hotstrings.device_finder"] = {
		find_devices = function() return desired, {} end,
		is_key_device = function() return true end,
	}
	local reader = helpers.load_module("adapters.evdev_reader")
	reader._set_backend((multi_recorder(queues)))
	local writer = helpers.load_module("adapters.uinput_writer")
	local session = { rows = {}, captures = {}, paths = paths, queues = queues, Input = Input }
	writer._set_backend({
		open = function() return 7 end, ioctl = function() return true end,
		write = function(_, bytes)
			local row = Input.decode(bytes)
			if row.type == 1 then session.rows[#session.rows + 1] = { row.code, row.value } end
			return true
		end,
		close = function() return true end,
	})
	assert(writer.open()); session.cap = assert(writer.capture_output()); session.writer = writer
	local saved_xkb = package.loaded["adapters.xkb_capture"]
	local held = {}
	package.loaded["adapters.xkb_capture"] = {
		is_ready = function() return true end,
		reset_state = function() held = {}; return true end,
		modifier_role = function(code)
			return options.roles and options.roles[code] or require("infra.evdev_codes").MODIFIER_OF[code], nil
		end,
		process = function(code, value)
			session.captures[#session.captures + 1] = { code, value }
			if value == 1 then held[code] = true elseif value == 0 then held[code] = nil end
			if code == 30 and value ~= 0 then return held[42] and "A" or "a", "a" end
			return nil, nil, nil
		end,
		caps_locked = function() return false end,
	}
	local hook = helpers.load_module("adapters.keyboard_hook")
	package.loaded["adapters.xkb_capture"] = saved_xkb
	session.hook = hook
	if options.engine then assert(hook.set_remapper(options.engine)) end
	hook.start({ intercept = true, onEmitRaw = function(code, value)
		local acknowledged = writer.emit(code, value)
		if options.after_emit then options.after_emit(session, code, value) end
		return acknowledged
	end })
	assert(hook.isRunning())
	function session.pump() hook.pump() end
	function session.queue(id, code, value, at)
		queues[paths[id]][#queues[paths[id]] + 1] = Input.encode(1, code, value, nil, at)
	end
	function session.retire(id) queues[paths[id]][1] = { fatal = "controlled exact source loss" } end
	function session.view() return writer.output_view(session.cap) end
	function session.close()
		options.after_emit = nil
		pcall(hook.stop); pcall(hook.set_remapper, nil)
		reader._reset_backend(); writer.close_owned(session.cap)
		for _, path in pairs(paths) do os.remove(path) end
	end
	function session.inject_text(text)
		local saved = package.loaded["adapters.xkb_capture"]
		package.loaded["adapters.xkb_capture"] = { caps_locked = function() return false end }
		local layout = helpers.load_module("adapters.keyboard_layout")
		layout._set_table_for_test({ x = { keycode = 45, level = 1, mods = {} } })
		local injector = helpers.load_module("modules.hotstrings.injector")
		package.loaded["adapters.xkb_capture"] = saved
		injector._set_uinput(writer); injector._set_nanosleep_for_test(function() end)
		local result = injector.type_directly(text)
		injector._set_uinput(nil)
		return result
	end
	return session
end

helpers.describe("Hook aggregate modifier contract: preserved red controls", function()

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

helpers.describe("managed source cohort consumed retirement", function()
	helpers.it("withdraws a spent original arm before any keyboard reacquisition or publication", function()
		local calls = 0
		require("tests.support.input_owner_fixture").with_session({ on_capture_reacquired = function()
			calls = calls + 1; return true
		end }, function(s)
			s.pair(); helpers.assert_eq(s.armed, true)
			s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 29, 0 }, { 29, 1 }, { 29, 0 }, { 42, 1 }, { 30, 1 } },
				"the original tap prefix and actual one-shot Shift/key ACKs are required")
			assert(s.reader.close("keyboard:" .. s.paths.a))
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
			helpers.assert_true(s.broker.output_retired())
		end)
	end)
end)

helpers.describe("managed source cohort original map authority", function()
	helpers.it("does not mint ownership from a foreign slot already reopened before the watchdog", function()
		require("tests.support.input_owner_fixture").with_session({ on_capture_reacquired = function() return true end }, function(s)
			local slot = "keyboard:" .. s.paths.b
			assert(s.reader.close("keyboard:" .. s.paths.a)); assert(s.reader.close(slot))
			assert(s.reader.open(s.paths.b, slot)); assert(s.reader.grab(slot))
			local foreign = assert(s.reader.capture_source_owner(slot))
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_true(s.reader.source_owner_current(foreign), "fresh ownership comes from actual acquisition, never a slot lookup")
			helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
		end)
	end)
end)

helpers.describe("managed source cohort pointer acquisition refusal", function()
	helpers.it("does not drop an owned pointer cleanup cohort when a replacement open fails", function()
		local options = { on_capture_reacquired = function() return true end }
		require("tests.support.input_owner_fixture").with_session(options, function(s)
			local finder = package.loaded["modules.hotstrings.device_finder"]
			assert(s.hook.stop() ~= false)
			finder.find_devices = function() return { s.paths.a }, { s.paths.b } end
			assert(s.hook.start({ intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit,
				onClick = function() end, onCaptureReacquired = options.on_capture_reacquired }))
			local prior = assert(s.reader.capture_source_owner("pointer:" .. s.paths.b))
			s.paths.c = os.tmpname(); local file = assert(io.open(s.paths.c, "w")); file:write("controlled replacement\n"); file:close()
			finder.find_devices = function() return { s.paths.a }, { s.paths.c } end
			options.fail_reader_open = true
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			options.fail_reader_open = false
			helpers.assert_eq(s.hook.isRunning(), false, "managed acquisition failure cannot publish a reduced cleanup cohort")
			helpers.assert_eq(s.reader.is_open("pointer:" .. s.paths.b), false)
			helpers.assert_eq(s.reader.is_open("pointer:" .. s.paths.c), false)
			helpers.assert_eq(s.hook.capture_input_owner(), nil)
			helpers.assert_eq(s.reader.source_owner_current(prior), false)
		end)
	end)
end)
