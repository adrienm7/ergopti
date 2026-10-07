--- tests/support/input_owner_fixture.lua

--- Actual input/output consumers through an explicitly controlled FFI constructor.
--- No syscall, native descriptor, physical classification or desktop is acquired.
local M = {}
local h = require("tests.helpers")

--- Runs one exact installed ordered-pair owner and always restores its caches.
--- @param options table|nil Controlled callback and failure hooks.
--- @param body function Receives the controlled consumer session.
function M.with_session(options, body)
	options = options or {}
	local names = { "ffi", "adapters.evdev_reader", "adapters.uinput_writer", "adapters.keyboard_hook",
		"adapters.xkb_capture", "modules.hotstrings.device_finder", "platform.remap.tap_hold_engine",
		"platform.remap.key_combination_engine", "modules.shortcuts.key_combinations" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
	local previous_preload = package.preload.ffi
	local Input = require("infra.input_event")
	local queues, paths, descriptors, serial, released_fds = {}, {}, {}, 100, {}
	for _, id in ipairs({ "a", "b" }) do
		local path = os.tmpname(); local file = assert(io.open(path, "w"))
		file:write("controlled input-owner source\n"); file:close()
		paths[id], queues[path] = path, {}
	end
	local s = { rows = {}, captures = {}, paths = paths, acquisitions = 0 }
	function s.descriptor(id) for fd, path in pairs(descriptors) do if path == paths[id] then return fd end end end
	local symbols = {
		open = function(path)
			local fd
			if options.recycle_descriptor and #released_fds > 0 then fd = table.remove(released_fds)
			else serial = serial + 1; fd = serial end
			descriptors[fd] = path; return fd
		end,
		close = function(fd)
			descriptors[fd] = nil; released_fds[#released_fds + 1] = fd
			return options.fail_reader_close and -1 or 0
		end,
		ioctl = function(_, _, argument)
			if type(argument) == "table" then argument.bytes = string.rep("\0", argument.count or 1) end
			return 0
		end,
		read = function(fd, buffer)
			local queue = queues[descriptors[fd]]; local bytes = queue and table.remove(queue, 1)
			if not bytes then return -1 end
			buffer.bytes = bytes; return #bytes
		end,
		poll = function(array)
			local queue = queues[descriptors[array[0].fd]]
			array[0].revents = queue and #queue > 0 and 1 or 0
			return array[0].revents ~= 0 and 1 or 0
		end,
	}
	package.loaded.ffi = nil
	package.preload.ffi = function() return {
		cdef = function() end, sizeof = function() return 24 end,
		new = function(kind, count) return kind == "struct pollfd[1]" and { [0] = {} }
			or { count = count, bytes = string.rep("\0", count or 1) } end,
		cast = function(_, value) return value end,
		string = function(buffer, count) return buffer.bytes:sub(1, count) end,
		errno = function() return 11 end, C = symbols,
	} end
	Input._reset_measurement()
	local down = {}
	local capture = {
		is_ready = function() return true end, reset_state = function() down = {}; return true end,
		modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code] end,
		caps_locked = function() return false end, cancel_compose = function() return true end,
		peek_text = function(code)
			if options.on_text then options.on_text(s) end
			return code == 30 and "a" or nil
		end,
		process = function(code, value)
			s.captures[#s.captures + 1] = { code, value }
			if value == 1 then down[code] = true elseif value == 0 then down[code] = nil end
			return code == 30 and value ~= 0 and (down[42] and "A" or "a") or nil
		end,
	}
	package.loaded["adapters.xkb_capture"] = capture
	package.loaded["modules.hotstrings.device_finder"] = {
		find_devices = function() return { paths.a, paths.b }, {} end,
		is_key_device = function() return true end,
		physical_sources = function(devices)
			local result = {}; for _, path in ipairs(devices) do result[#result + 1] = {
				path = path, sysfs = "/controlled/source", name = "controlled", physical = true } end
			return result
		end,
	}
	local called, err = pcall(function()
		local Engine = h.load_module("platform.remap.tap_hold_engine")
		local Native = h.load_module("platform.remap.key_combination_engine")
		if options.late_reader then
			s.reader = h.load_module("adapters.evdev_reader")
		else
			-- The actual daemon cold-loads Hook/Reader before backend callbacks.
			-- before_hook is the legacy option name for a callback before install/start.
			package.loaded["adapters.evdev_reader"] = nil
			s.hook = h.load_module("adapters.keyboard_hook")
			s.reader = require("adapters.evdev_reader")
		end
		s.bootstrap = options.late_reader and "late-reader" or "cold-hook-before-backend"
		if options.custom_reader then
			s.reader._set_backend({ open = symbols.open, close = function(fd) symbols.close(fd); return true end,
				ioctl = function() return true end, read_bits = function(_, _, count) return string.rep("\0", count) end,
				read = function(fd) local queue = queues[descriptors[fd]]; return queue and table.remove(queue, 1) end,
				poll = function(fd) return #(queues[descriptors[fd]] or {}) > 0 end })
		else assert(s.reader.use_ffi_backend()) end
		s.writer = h.load_module("adapters.uinput_writer")
		local last
		s.writer._set_backend({ open = function() return 7 end, close = function()
				s.output_closes = (s.output_closes or 0) + 1
				if options.output_close then return options.output_close(s) end
				return true
			end,
			ioctl = function(_, request)
				if request == 0x5502 then
					s.output_destroys = (s.output_destroys or 0) + 1
					if options.output_destroy then return options.output_destroy(s) end
				end
				return true
			end, write = function(_, bytes)
				local row = Input.decode(bytes)
				if row.type == Input.EV_KEY then last = row; s.rows[#s.rows + 1] = { row.code, row.value }
				elseif options.fail_sync and last and options.fail_sync(s, last.code, last.value) then return false
				elseif options.after_sync and last then options.after_sync(s, last.code, last.value) end
				return true
			end })
		if options.on_output_view then
			local view = s.writer.output_view
			s.writer.output_view = function(capability)
				local result = view(capability)
				local replacement = options.on_output_view(s, capability, result)
				return replacement ~= nil and replacement or result
			end
		end
		assert(s.writer.open()); s.output = assert(s.writer.capture_output())
		local acquire = s.writer.acquire_transaction
		s.writer.acquire_transaction = function(...)
			s.acquisitions = s.acquisitions + 1; return acquire(...)
		end
		if options.before_hook then options.before_hook(s) end
		if not s.hook then s.hook = h.load_module("adapters.keyboard_hook") end
		s.base = Engine.new({ keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } },
			tap_min_ms = 0, one_shot_timeout_ms = 1000,
			key_text = function(code) return s.hook.key_text(code) end,
			plan_text = function(text)
				if options.on_plan then options.on_plan(s) end
				return text == "A" and { { keycode = 30, mods = { "shift" } } } or nil
			end,
			one_shot_result = function() return nil end })
		local Owner = h.load_module("modules.shortcuts.key_combinations")
		s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "one_shot_shift"\n'
		s.owner = Owner.new({ keys = { { id = "caps_lock", key = "caps_lock" }, { id = "tab", key = "tab" } },
			hold_picker = { modifiers = { "ctrl", "shift" }, layers = { "nav" } },
			files = { read_with_status = function()
				if options.on_guard then options.on_guard(s) end; return s.bytes, "ok"
			end }, route = function() return "/controlled/config.toml" end,
			is_paused = function() return s.paused == true end, changed = function() return true end,
			-- Explicit test-only logical admission, not the production picker or catalogue.
			actions = { is_assignable = function(action) return action == "one_shot_shift" end } })
		s.engine = Native.new(s.base,
			s.owner.engine_options({ caps_lock = 300, tab = 300 }))
		assert(s.hook.set_remapper(s.engine, function(action, binding)
			s.action, s.binding = action, binding
			if options.on_action then options.on_action(s) end
			if s.hook.capture_input_owner then
				s.lease = s.hook.capture_input_owner()
				s.before_arm_acquisitions = s.acquisitions
				s.armed = s.lease and s.hook.arm_one_shot(s.lease) or false
				s.after_arm_acquisitions = s.acquisitions
			end
		end))
		s.hook.start({ intercept = true, requireOutputBroker = true, onEmitRaw = s.writer.emit })
		assert(s.hook.isRunning())
		s.broker = require("adapters.modifier_broker").for_channel(s.writer)
		function s.edge(id, code, value, at_ms)
			queues[paths[id]][#queues[paths[id]] + 1] = Input.encode(Input.EV_KEY, code, value, nil, at_ms * 1000)
			s.hook.pump()
		end
		function s.pair()
			s.edge("a", 58, 1, 0); s.edge("a", 15, 1, 10); s.edge("a", 15, 0, 100)
		end
		body(s)
	end)
	options.after_sync, options.fail_sync, options.on_guard, options.on_text, options.on_plan, options.on_output_view = nil, nil, nil, nil, nil, nil
	if s.hook then pcall(s.hook.stop); pcall(s.hook.set_remapper, nil) end
	if s.reader then pcall(s.reader._reset_backend) end
	if s.writer and s.successor then pcall(s.writer.close_owned, s.successor) end
	if s.writer and s.output then pcall(s.writer.close_owned, s.output) end
	for _, path in pairs(paths) do os.remove(path) end
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	package.preload.ffi = previous_preload; Input._reset_measurement()
	if not called then error(err, 0) end
end
return M
