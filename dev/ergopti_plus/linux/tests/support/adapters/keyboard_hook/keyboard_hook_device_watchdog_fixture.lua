--- tests/support/adapters/keyboard_hook/keyboard_hook_device_watchdog_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_keyboard_hook_device_watchdog
--- DESCRIPTION:
--- Prelude shared by the test_keyboard_hook_device_watchdog_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
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
		-- Controlled keyboard sources have no REL/ABS axes.
		is_interceptable_key_device = function() return true, nil end,
		is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
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
		read_event_bits = require("tests.support.evdev_capabilities_fixture").key_bits,
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
		read_event_bits = require("tests.support.evdev_capabilities_fixture").key_bits,
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

--- Starts the real Hook, reviewed Writer and Reader with controlled syscalls/layout.
--- The XKB port records actual Hook transitions and models a single desktop key bit.
--- No kernel, display, libuv handle or native command is acquired by these controls.
local function aggregate_consumer_session(streams, options)
	options = options or {}
	local Input = require("infra.input_event")
	local paths, queues, desired = {}, {}, {}
	for _, id in ipairs({ "a", "b", "c" }) do
		if streams[id] then
			local path = fake_node("aggregate-" .. id)
			paths[id], desired[#desired + 1], queues[path] = path, path, {}
			for _, row in ipairs(streams[id]) do
				queues[path][#queues[path] + 1] = Input.encode(1, row[1], row[2], nil, row[3])
			end
		end
	end
	if options.initial_sources then
		desired = {}
		for _, id in ipairs(options.initial_sources) do desired[#desired + 1] = assert(paths[id]) end
	end
	package.loaded["modules.hotstrings.device_finder"] = {
		find_devices = function() return desired, {} end,
		is_key_device = function() return true end,
		-- Controlled keyboard sources have no REL/ABS axes.
		is_interceptable_key_device = function() return true end,
		is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
	}
	local reader = helpers.load_module("adapters.evdev_reader")
	local backend = multi_recorder(queues)
	local open, refused = backend.open, {}
	backend.open = function(path)
		if refused[path] then return nil, "controlled permission refusal" end
		return open(path)
	end
	reader._set_backend(backend)
	local writer = helpers.load_module("adapters.uinput_writer")
	local session = { rows = {}, captures = {}, chars = {}, paths = paths, queues = queues, Input = Input }
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
			if options.process then return options.process(code, value) end
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
	hook.start({ intercept = true, onChar = function(char) session.chars[#session.chars + 1] = char end,
		onEmitRaw = function(code, value)
		local acknowledged = writer.emit(code, value)
		if options.after_emit then options.after_emit(session, code, value) end
		return acknowledged
	end })
	assert(hook.isRunning())
	function session.pump() hook.pump() end
	function session.select(ids)
		desired = {}
		for _, id in ipairs(ids) do desired[#desired + 1] = assert(paths[id]) end
	end
	function session.refuse_open(id) refused[assert(paths[id])] = true end
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

return {
	helpers = helpers,
	load_hook = load_hook,
	fake_node = fake_node,
	stub_device_finder = stub_device_finder,
	recorder = recorder,
	multi_recorder = multi_recorder,
	tick_until_check = tick_until_check,
	aggregate_consumer_session = aggregate_consumer_session,
}
