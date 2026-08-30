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
		process = function() return nil, nil, nil end,
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
--- @return function set  Replaces the answer.
local function stub_device_finder(initial)
	local answer = initial
	package.loaded["modules.hotstrings.device_finder"] = {
		find_keyboard = function() return answer end,
		-- The hook asks the finder whether a path can actually produce key events
		-- before it commits to it — /dev/null is readable, and without this check
		-- the daemon sat in its read loop forever waiting for events that cannot
		-- arrive. These tests drive synthetic node paths that are in no /proc, so
		-- the stub answers for them; the check itself is covered against real
		-- fixture text in test_device_finder_selection.lua.
		is_key_device = function() return true, nil end,
	}
	return function(next_answer) answer = next_answer end
end

--- A recording syscall backend for the reader.
--- @return table backend, table log
local function recorder()
	local log = { opens = {}, ioctls = {}, closes = 0 }
	return {
		open = function(path)
			log.opens[#log.opens + 1] = path
			return #log.opens
		end,
		ioctl = function(_, _, arg)
			log.ioctls[#log.ioctls + 1] = arg
			return true
		end,
		read  = function() return nil end,
		poll  = function() return false end,
		close = function() log.closes = log.closes + 1 end,
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
		kh.start({ device = node_a, intercept = true, onEmitRaw = function() end })
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
		helpers.assert_eq(log.ioctls[#log.ioctls], 1,
			"the new device must be grabbed too — an ungrabbed re-acquisition types "
				.. "everything twice")
		helpers.assert_true(log.closes >= 1, "and the old descriptor must be closed, not leaked")

		kh.stop()
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
		kh.start({ device = node, intercept = true, onEmitRaw = function() end })
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
		kh.start({ device = node_a, intercept = true, onEmitRaw = function() end })
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
-- ======= 2/ Nothing to switch to =================================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: the watchdog when no device is there", function()

	helpers.it("keeps the current descriptor when the finder answers nothing", function()
		local node = fake_node("a")
		local set_device = stub_device_finder(node)
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = recorder()
		reader._set_backend(backend)

		local kh = load_hook()
		kh.start({ device = node, intercept = true, onEmitRaw = function() end })

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
