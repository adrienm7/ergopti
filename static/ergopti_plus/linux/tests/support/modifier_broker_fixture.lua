--- tests/support/modifier_broker_fixture.lua

--- ==============================================================================
--- MODULE: Actual Modifier Consumer Fixture
--- DESCRIPTION:
--- Runs real Reader, Writer and Hook through controlled byte ports.
--- No native input descriptor, display, event loop or physical proof is acquired.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")
local Input = require("infra.input_event")

--- Creates one fully controlled source/output session.
--- @param options table|nil Engine and wire failure/reentry hooks.
--- @return table session
function M.new(options)
	options = options or {}
	local queues, sources, handles, paths, next_fd = {}, {}, {}, {}, 10
	for _, id in ipairs({ "a", "b", "c" }) do
		local path = os.tmpname()
		local file = assert(io.open(path, "w")); file:write("controlled source\n"); file:close()
		paths[id], sources[#sources + 1], queues[path] = path, path, {}
	end
	package.loaded["modules.hotstrings.device_finder"] = {
		find_devices = function() return sources, {} end,
		is_key_device = function() return true end,
	}
	local Reader = helpers.load_module("adapters.evdev_reader")
	Reader._set_backend({
		open = function(path) next_fd = next_fd + 1; handles[next_fd] = path; return next_fd end,
		close = function(fd) handles[fd] = nil; return true end,
		ioctl = function() return true end,
		read_bits = function(_, _, count) return string.rep("\0", count) end,
		read = function(fd)
			local queue = queues[handles[fd]]
			if not queue or #queue == 0 then return nil, "would_block" end
			return table.remove(queue, 1)
		end,
		poll = function(fd) local queue = queues[handles[fd]]; return queue and #queue > 0 end,
	})
	local session = { rows = {}, captures = {}, chars = {}, physical = {}, paths = paths }
	local Writer = helpers.load_module("adapters.uinput_writer")
	local last
	Writer._set_backend({
		open = function() return 7 end, ioctl = function() return true end, close = function() return true end,
		write = function(_, bytes)
			local row = Input.decode(bytes)
			if row.type == Input.EV_KEY then
				last = row
				session.rows[#session.rows + 1] = { row.code, row.value }
			elseif options.fail_sync and last and options.fail_sync(last.code, last.value) then return false
			elseif options.after_sync and last then options.after_sync(session, last.code, last.value) end
			return true
		end,
	})
	assert(Writer.open()); session.writer = Writer; session.cap = assert(Writer.capture_output())
	local saved = package.loaded["adapters.xkb_capture"]
	local capture_down = {}
	package.loaded["adapters.xkb_capture"] = {
		is_ready = function() return true end,
		reset_state = function() capture_down = {}; return true end,
		modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code] end,
		caps_locked = function() return false end,
		cancel_compose = function() return true end,
		process = function(code, value)
			session.captures[#session.captures + 1] = { code, value }
			if value == 1 then capture_down[code] = true elseif value == 0 then capture_down[code] = nil end
			if code == 30 and value ~= 0 then return capture_down[42] and "A" or "a", "a" end
		end,
	}
	local Hook = helpers.load_module("adapters.keyboard_hook")
	package.loaded["adapters.xkb_capture"] = saved
	session.hook = Hook
	if options.engine then assert(Hook.set_remapper(options.engine)) end
	Hook.start({ intercept = true, onEmitRaw = function(code, value)
		local acknowledged = Writer.emit(code, value)
		if options.after_emit then options.after_emit(session, code, value) end
		return acknowledged
	end,
		onChar = function(char) session.chars[#session.chars + 1] = char end,
		onPhysical = function(code, _, _, value) session.physical[#session.physical + 1] = { code, value } end,
	})
	assert(Hook.isRunning())
	function session.queue(id, code, value, time)
		local queue = queues[paths[id]]
		queue[#queue + 1] = Input.encode(Input.EV_KEY, code, value, nil, time)
	end
	function session.pump() Hook.pump() end
	function session.view() return Writer.output_view(session.cap) end
	function session.inject()
		local saved_xkb = package.loaded["adapters.xkb_capture"]
		package.loaded["adapters.xkb_capture"] = { caps_locked = function() return false end }
		local Layout = helpers.load_module("adapters.keyboard_layout")
		Layout._set_table_for_test({ x = { keycode = 45, level = 1, mods = {} } })
		local Injector = helpers.load_module("modules.hotstrings.injector")
		package.loaded["adapters.xkb_capture"] = saved_xkb
		Injector._set_uinput(Writer); Injector._set_nanosleep_for_test(function() end)
		local result = Injector.type_directly("x")
		Injector._set_uinput(nil)
		return result
	end
	function session.close()
		options.after_emit, options.fail_sync, options.after_sync = nil, nil, nil
		pcall(Hook.stop); pcall(Hook.set_remapper, nil)
		Reader._reset_backend(); Writer.close_owned(session.cap)
		for _, path in pairs(paths) do os.remove(path) end
	end
	return session
end

--- Runs a scenario and always retires its controlled channels/files.
--- @param options table|nil Session options.
--- @param body function Scenario.
function M.with_session(options, body)
	local session = M.new(options)
	local ok, err = pcall(body, session)
	session.close()
	if not ok then error(err, 0) end
end

return M
