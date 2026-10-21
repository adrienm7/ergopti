--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_hybrid_capture.lua

--- ==============================================================================
--- MODULE: Pinned Hybrid Input Capture
--- DESCRIPTION:
--- Runs the original Hook/Reader with controlled descriptors and real device
--- capability predicates. Axis/switch nodes cannot be grabbed by a KEY-only
--- output; explicit observe mode and KEY-only macroboards keep their contract.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_device_watchdog_fixture")

--- Runs an isolated controlled input transport; no native authority is issued.
--- @param mask string Printed kernel EV capability word.
--- @param body function Receives the original consumer and mutable capabilities.
--- @param options table|nil Controlled transport and discovery options.
local function with_device(mask, body, options)
	options = options or {}
	local names = { "modules.hotstrings.device_finder", "adapters.keyboard_hook", "adapters.evdev_reader",
		"adapters.xkb_capture", "adapters.keyboard_layout", "adapters.uinput_writer" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
	local node, hook, reader = Fixture.fake_node("controlled hybrid capabilities")
	local writer, output_owner
	local state = { mask = mask, fd_mask = options.fd_mask or mask }
	local called, detail = pcall(function()
		-- Hook's private CapsWord constructor also loads Layout. Build that
		-- dependency with its real producer before the controlled XKB is installed,
		-- and restore both exact cache entries after this isolated transport ends.
		helpers.load_module("adapters.xkb_capture")
		helpers.load_module("adapters.keyboard_layout")
		local actual = helpers.load_module("modules.hotstrings.device_finder")
		local function snapshot()
			return actual.parse_devices(table.concat({
				"I: Bus=0003 Vendor=0001 Product=0001 Version=0001",
				'N: Name="Unlabelled foot switch"',
				"S: Sysfs=/devices/controlled/input/input7",
				"H: Handlers=event7",
				"B: EV=" .. state.mask,
			}, "\n") .. "\n\n")
		end
		-- The temporary readable file is a controlled Reader transport. Translate
		-- only its path to the explicit proc fixture; all capability decisions run
		-- through the real Finder, not a preselected admission boolean.
		local finder = {
			find_keyboard = function() error("an explicitly pinned source cannot use auto-discovery") end,
			find_devices = function()
				assert(options.auto, "an explicitly pinned source cannot use auto-discovery")
				local selected = actual.select_keyboards(snapshot())
				return #selected == 1 and { node } or {}, {}
			end,
			is_interceptable_event_mask = actual.is_interceptable_event_mask,
			is_key_device = function(path)
				assert(path == node)
				return actual.is_key_device("/dev/input/event7", snapshot())
			end,
			is_interceptable_key_device = function(path)
				assert(path == node)
				local admitted, why = actual.is_interceptable_key_device("/dev/input/event7", snapshot())
				if options.after_validation then options.after_validation(state) end
				return admitted, why
			end,
		}
		package.loaded["modules.hotstrings.device_finder"] = finder
		reader = helpers.load_module("adapters.evdev_reader")
		local backend, log = Fixture.recorder()
		log.capabilities = {}
		backend.read_event_bits = function(fd, request, count)
			assert(request == 0x80044520 and count == 4)
			log.capabilities[#log.capabilities + 1] = fd
			if options.query then return options.query(state, backend) end
			local value = assert(tonumber(state.fd_mask, 16))
			return string.char(value % 256, math.floor(value / 256) % 256,
				math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
		end
		if options.missing_query then backend.read_event_bits = nil end
		local Input = require("infra.input_event")
		local queue = {}
		if options.transport then
			log.consumed, log.output = {}, {}
			backend.read = function()
				local bytes = table.remove(queue, 1)
				if bytes then
					local row = assert(Input.decode(bytes))
					log.consumed[#log.consumed + 1] = { row.type, row.code, row.value }
				end
				return bytes
			end
		end
		if options.refuse_open then
			backend.open = function(path)
				log.opens[#log.opens + 1] = path
				return nil, "controlled permission refusal"
			end
		end
		reader._set_backend(backend)
		package.loaded["adapters.uinput_writer"] = nil
		if options.transport then
			writer = helpers.load_module("adapters.uinput_writer")
			writer._set_backend({ open = function() return 42 end, ioctl = function() return true end,
				write = function(_, bytes)
					local row = assert(Input.decode(bytes))
					log.output[#log.output + 1] = { row.type, row.code, row.value }
					return true
				end,
				close = function() log.writer_closed = true; return true end })
			assert(writer.open()); output_owner = assert(writer.capture_output())
		end
		hook = Fixture.load_hook()
		state.hook, state.reader, state.log, state.finder, state.actual = hook, reader, log, finder, actual
		state.backend = backend
		function state.start(intercept)
			return hook.start({ device = not options.auto and node or nil, pinned = not options.auto, intercept = intercept,
				onEmitRaw = function(code, value) return not writer or writer.emit(code, value) end })
		end
		function state.queue(rows)
			for i, row in ipairs(rows) do queue[#queue + 1] = Input.encode(row[1], row[2], row[3], nil, i * 1000) end
		end
		function state.reappear(next_mask)
			assert(reader.close("keyboard:" .. node))
			state.mask, state.fd_mask = next_mask, next_mask
			Fixture.tick_until_check(hook, 1)
		end
		if options.missing then assert(os.remove(node)) end
		body(state)
	end)
	if hook then hook.stop() end
	if reader then
		local closed, reason = reader.close("keyboard:" .. node)
		if options.expect_close_debt then
			assert(closed == false and type(reason) == "string", "unknown retirement must remain a failure")
		else assert(closed) end
		assert(not reader.is_open("keyboard:" .. node))
		reader._reset_backend()
	end
	if writer then
		assert(writer.close_owned(output_owner))
		assert(state.log.writer_closed)
		writer._reset_backend()
	end
	os.remove(node)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	if not called then error(detail, 0) end
end

helpers.describe("keyboard_hook: explicit pinned hybrid capture", function()
	for _, row in ipairs({ { "EV_ABS", "b" }, { "EV_REL", "7" }, { "EV_REL and EV_ABS", "f" }, { "EV_SW", "33" } }) do
		local label, mask = row[1], row[2]
		helpers.it("refuses " .. label .. " before any source open or grab", function()
			with_device(mask, function(s)
				s.start(true)
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.log.opens, {}, "refusal must precede descriptor acquisition")
				helpers.assert_eq(s.log.ioctls, {}, "no native grab may precede capability validation")
				helpers.assert_true(s.actual.is_key_device("/dev/input/event7", s.actual.parse_devices(
					'I: Bus=0003\nN: Name="Hybrid"\nH: Handlers=event7\nB: EV=' .. mask .. '\n\n')),
					"the old EV_KEY predicate remains true for the same axis-bearing node")
			end)
		end)

		helpers.it("keeps explicit observe mode available for " .. label, function()
			with_device(mask, function(s)
				s.start(false)
				helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(#s.log.opens, 1)
				helpers.assert_eq(s.log.ioctls, {}, "observe never consumes the physical node")
			end)
		end)

		helpers.it("refuses a pinned eventN reused for " .. label .. " before reacquiring it", function()
			with_device("120013", function(s)
				s.start(true)
				helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(#s.log.opens, 1)
				s.reappear(mask)
				helpers.assert_eq(#s.log.opens, 1, "same-path hotplug cannot bypass the startup capability rule")
				helpers.assert_eq(s.log.ioctls, { 1, 0 }, "only the original keyboard grab and its retirement are permitted")
			end)
		end)
	end

	helpers.it("keeps KEY-only macroboards eligible without KEY_A or keyboard naming", function()
		with_device("120013", function(s)
			s.start(true)
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(#s.log.opens, 1)
			helpers.assert_eq(s.log.ioctls, { 1 })
			s.reappear("120013")
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(#s.log.opens, 2, "a healthy KEY/MSC/LED/REP successor remains capturable")
			helpers.assert_eq(s.log.ioctls, { 1, 0, 1 })
		end)
	end)

	helpers.it("does not fall back to EV_KEY when the intercept validator is unavailable", function()
		with_device("120013", function(s)
			s.finder.is_interceptable_key_device = nil
			s.start(true)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.log.opens, {})
		end)
	end)

	helpers.it("does not reacquire a pinned node after its intercept validator is withdrawn", function()
		with_device("120013", function(s)
			s.start(true)
			helpers.assert_true(s.hook.isRunning())
			s.finder.is_interceptable_key_device = nil
			s.reappear("120013")
			helpers.assert_eq(#s.log.opens, 1)
			helpers.assert_eq(s.hook.isRunning(), false)
		end)
	end)

	for _, cold in ipairs({ true, false }) do
		local mode = cold and "cold" or "warm"
		helpers.it("restores the " .. mode .. " Layout cache after controlled Hook construction", function()
			local layout_name, capture_name = "adapters.keyboard_layout", "adapters.xkb_capture"
			local old_layout, old_capture = package.loaded[layout_name], package.loaded[capture_name]
			local called, detail = pcall(function()
				package.loaded[layout_name], package.loaded[capture_name] = nil, nil
				local expected
				if not cold then
					require(capture_name)
					expected = require(layout_name)
				end
				with_device("120013", function(s)
					s.start(true)
					helpers.assert_true(s.hook.isRunning(), "the original Hook must actually construct")
				end)
				helpers.assert_eq(package.loaded[layout_name], expected,
					"a controlled Hook must not publish a Layout retaining its fake XKB producer")
			end)
			package.loaded[layout_name], package.loaded[capture_name] = old_layout, old_capture
			if not called then error(detail, 0) end
		end)
	end
end)

helpers.describe("keyboard_hook: mixed key and tablet switch transport", function()
	-- Linux thinkpad_acpi registers KEY_WLAN and SW_TABLET_MODE on the same
	-- ThinkPad Extra Buttons input_dev (EV=33); these are its actual key codes.
	local mixed = { { 5, 1, 1 }, { 0, 0, 0 }, { 1, 238, 1 }, { 0, 0, 0 },
		{ 1, 238, 0 }, { 0, 0, 0 }, { 5, 1, 0 }, { 0, 0, 0 } }
	local keys = { { 1, 238, 1 }, { 0, 0, 0 }, { 1, 238, 0 }, { 0, 0, 0 } }

	for _, auto in ipairs({ true, false }) do
		helpers.it("refuses " .. (auto and "discovered" or "pinned") .. " switches without consuming their packets", function()
			with_device("33", function(s)
				s.queue(mixed); s.start(true); s.hook.pump()
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.log.opens, {})
				helpers.assert_eq(s.log.ioctls, {})
				helpers.assert_eq(s.log.consumed, {}, "both tablet transitions must remain on the ungrabbed source")
				helpers.assert_eq(s.log.output, {})
			end, { transport = true, auto = auto })
		end)
	end

	helpers.it("decodes both tablet transitions in observe mode without grabbing or re-emitting", function()
		with_device("33", function(s)
			s.queue(mixed); s.start(false); s.hook.pump()
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(s.log.consumed, mixed)
			helpers.assert_eq(s.log.ioctls, {})
			helpers.assert_eq(s.log.output, {})
		end, { transport = true })
	end)

	helpers.it("forwards a healthy KEY/MSC/LED/REP macroboard through the original Writer", function()
		with_device("120013", function(s)
			s.queue(keys); s.start(true); s.hook.pump()
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(s.log.ioctls, { 1 })
			helpers.assert_eq(s.log.consumed, keys)
			helpers.assert_eq(s.log.output, keys, "KEY_WLAN DOWN and UP must reach the original keyboard output")
		end, { transport = true })
	end)

	for _, row in ipairs({ { "missing", "unreadable source", 0 }, { "refuse_open", "source permission refusal", 1 } }) do
		helpers.it("keeps the " .. row[2] .. " guard before any grab", function()
			with_device("120013", function(s)
				s.queue(keys); s.start(true); s.hook.pump()
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(#s.log.opens, row[3])
				helpers.assert_eq(s.log.ioctls, {})
				helpers.assert_eq(s.log.consumed, {})
				helpers.assert_eq(s.log.output, {})
			end, { transport = true, [row[1]] = true })
		end)
	end
end)

helpers.describe("keyboard_hook: descriptor capability admission", function()
	local mixed = { { 5, 1, 1 }, { 0, 0, 0 }, { 1, 238, 1 }, { 0, 0, 0 },
		{ 1, 238, 0 }, { 0, 0, 0 }, { 5, 1, 0 }, { 0, 0, 0 } }
	for _, row in ipairs({ { "EV_REL", "7" }, { "EV_ABS", "b" }, { "EV_SW", "33" }, { "no EV_KEY", "1" } }) do
		for _, auto in ipairs({ true, false }) do
			helpers.it("refuses opened " .. row[1] .. " after a stale " .. (auto and "discovery" or "pin") .. " snapshot", function()
				with_device("120013", function(s)
					s.queue(mixed); s.start(true); s.hook.pump()
					helpers.assert_eq(s.hook.isRunning(), false)
					helpers.assert_eq(#s.log.opens, 1, "the actual successor must be opened to identify its fd")
					helpers.assert_eq(s.log.capabilities, { 1 })
					helpers.assert_eq(s.log.ioctls, {}, "a stale pathname admission cannot authorize EVIOCGRAB")
					helpers.assert_eq(s.log.consumed, {}, "unsupported desktop packets must remain unread")
					helpers.assert_eq(s.log.output, {})
					helpers.assert_eq(s.log.closes, 1, "the rejected successor must retire exactly once")
				end, { transport = true, auto = auto, fd_mask = row[2] })
			end)
		end
	end

	helpers.it("rejects an eventN successor that changes after the original pin predicate returns", function()
		with_device("120013", function(s)
			s.queue(mixed); s.start(true); s.hook.pump()
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.mask, "33")
			helpers.assert_eq(s.log.ioctls, {})
			helpers.assert_eq(s.log.consumed, {})
		end, { transport = true, after_validation = function(s) s.mask, s.fd_mask = "33", "33" end })
	end)

	helpers.it("checks the opened successor again during pinned reacquisition", function()
		with_device("120013", function(s)
			s.start(true); helpers.assert_true(s.hook.isRunning())
			s.backend.open = function(path)
				s.log.opens[#s.log.opens + 1] = path; s.fd_mask = "33"; return #s.log.opens
			end
			s.reappear("120013")
			helpers.assert_eq(#s.log.opens, 2)
			helpers.assert_eq(s.log.capabilities, { 1, 2 })
			helpers.assert_eq(s.log.ioctls, { 1, 0 }, "only the retired keyboard may ever have been grabbed")
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.log.closes, 2)
		end)
	end)

	for _, row in ipairs({
		{ "missing query", { missing_query = true } },
		{ "query error", { query = function() error("controlled ioctl failure") end } },
		{ "negative acknowledgement", { query = function() return nil, "query refused" end } },
		{ "short bitset", { query = function() return string.char(19, 0, 18) end } },
		{ "long bitset", { query = function() return string.char(19, 0, 18, 0, 0) end } },
		{ "changed query port", { query = function(_, backend)
			backend.read_event_bits = function() return string.char(19, 0, 18, 0) end
			return string.char(19, 0, 18, 0)
		end } },
	}) do
		helpers.it("rolls back the opened descriptor on " .. row[1], function()
			with_device("120013", function(s)
				s.start(true)
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.log.ioctls, {})
				helpers.assert_eq(s.log.closes, 1)
			end, row[2])
		end)
	end

	helpers.it("refuses interception without the shared fd mask policy", function()
		with_device("120013", function(s)
			s.finder.is_interceptable_event_mask = nil
			s.start(true)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.log.ioctls, {})
		end)
	end)

	helpers.it("does not require a capabilities ioctl for non-grabbing observe mode", function()
		with_device("33", function(s)
			s.queue(mixed); s.start(false); s.hook.pump()
			helpers.assert_true(s.hook.isRunning())
			helpers.assert_eq(s.log.capabilities, {})
			helpers.assert_eq(s.log.consumed, mixed)
			helpers.assert_eq(s.log.ioctls, {})
		end, { transport = true, missing_query = true })
	end)
end)

helpers.describe("keyboard_hook: rejected descriptor retirement", function()
	helpers.it("does not claim or retry a rejected descriptor whose close is not acknowledged", function()
		with_device("120013", function(s)
			s.backend.close = function() s.log.closes = s.log.closes + 1; return false, "controlled close uncertainty" end
			s.start(true)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.log.ioctls, {})
			helpers.assert_eq(s.log.closes, 1)
			local closed, reason = s.reader.close("keyboard:" .. s.log.opens[1])
			helpers.assert_eq(closed, false)
			helpers.assert_type(reason, "string")
			s.start(true)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(#s.log.opens, 1, "unknown retirement must fence the old source slot")
			helpers.assert_eq(s.log.closes, 1, "retrying close could affect a recycled numeric fd")
		end, { fd_mask = "33", expect_close_debt = true })
	end)
end)

helpers.describe("keyboard_hook: original capability query port", function()
	helpers.it("does not substitute a changed Reader query export", function()
		with_device("120013", function(s)
			s.reader.event_capabilities = function() return 0x120013 end
			s.start(true)
			helpers.assert_eq(s.hook.isRunning(), false)
			helpers.assert_eq(s.log.ioctls, {})
			helpers.assert_eq(s.log.closes, 1)
		end)
	end)
end)

helpers.describe("keyboard_hook: original fd cleanup authority", function()
	for _, row in ipairs({
		{ "switch capability", { event_bits = string.char(51, 0, 0, 0) } },
		{ "incomplete ioctl ACK", { event_result = 0 } },
		{ "unknown native close", { event_result = -1, fail_reader_close = true } },
	}) do
		helpers.it("retires the exact original open after " .. row[1] .. " refuses admission", function()
			local options = {}
			require("tests.support.input_owner_fixture").with_session(options, function(s)
				assert(s.hook.stop() ~= false)
				local closes = s.source_closes
				for key, value in pairs(row[2]) do options[key] = value end
				helpers.assert_eq(s.hook.start(s.start_options), false)
				helpers.assert_eq(s.hook.isRunning(), false)
				helpers.assert_eq(s.hook.capture_input_owner(), nil)
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.a), false)
				helpers.assert_eq(s.reader.is_open("keyboard:" .. s.paths.b), false)
				helpers.assert_eq(s.source_closes - closes, 1, "only the rejected original fd must be closed, exactly once")
				helpers.assert_eq(s.reader.has_native_origin_debt(), options.fail_reader_close == true)
				if options.fail_reader_close then
					helpers.assert_eq(s.reader._reset_backend(), false)
					helpers.assert_eq(s.hook.start(s.start_options), false)
					helpers.assert_eq(s.source_closes - closes, 1, "unknown native retirement cannot be retried")
				end
			end)
		end)
	end
end)
