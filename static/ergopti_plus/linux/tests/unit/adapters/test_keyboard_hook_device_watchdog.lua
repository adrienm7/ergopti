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
