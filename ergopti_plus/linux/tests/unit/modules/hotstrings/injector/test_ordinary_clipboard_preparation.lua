--- tests/unit/modules/hotstrings/injector/test_ordinary_clipboard_preparation.lua

--- ==============================================================================
--- MODULE: Ordinary Clipboard Preparation Before Destructive Output
--- DESCRIPTION:
--- Runs the actual Injector, Clipboard and OutputTransaction against independent
--- clipboard I/O and document ports. Preparation refusal must preserve the trigger.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = { "modules.hotstrings.injector", "adapters.clipboard", "modules.hotstrings.output_transaction",
	"adapters.keyboard_layout", "adapters.xkb_capture", "adapters.shell_runner", "infra.display_server",
	"logger.shim", "adapters.keyboard_hook", "adapters.modifier_broker", "input.modifier_custody", "adapters.uinput_writer" }

local function fixture(options, callback)
	options = options or {}
	local old = {}
	for _, name in ipairs(names) do old[name] = package.loaded[name]; package.loaded[name] = nil end
	local world = { document = "prefix trg", clipboard = "saved clipboard", calls = {}, down = {}, writes = 0,
		stops = 0, notifications = 0, error_formats = 0, destination = {}, payload = "🙂" }
	local original_destination = world.destination
	local function record(value) world.calls[#world.calls + 1] = value end
	local function retire() world.destination = {} end
	package.loaded["logger.shim"] = setmetatable({}, { __index = function() return function() end end })
	package.loaded["infra.display_server"] = { is_wayland = function() return false end, is_x11 = function() return true end }
	package.loaded["adapters.keyboard_layout"] = {
		is_ready = function() return false end, plan = function() error("the controlled layout cannot type the payload") end,
		plan_current = function() return false end, plan_view = function() return nil end,
		shortcut_keycode = function(_, fallback) return fallback end,
	}
	package.loaded["adapters.xkb_capture"] = { caps_locked = function() return false end }
	package.loaded["adapters.keyboard_hook"] = {
		held_text_modifier_codes = function() return {} end, held_shortcut_modifier_codes = function() return {} end,
		held_forwarded_keys = function() return {} end, emergency_stop = function()
			world.stops = world.stops + 1
			if world.emergency then world.emergency() end
		end,
	}
	local Shell = { has_command = function(name) return name == "xclip" end }
	function Shell.exec_checked()
		record("read")
		if options.read_refuses then return false, "", "native pipe read failed" end
		if options.retire_on_read then retire() end
		return true, world.clipboard, nil
	end
	function Shell.with_exact_stdin(command, text) return { command = command, text = text } end
	function Shell.run(command)
		record("write:" .. command.text)
		if command.text == world.payload then
			world.writes = world.writes + 1
			if options.write_throws then error("independent clipboard write exception") end
			if options.write_refuses then return false end
			world.clipboard = command.text
			if options.retire_on_write then retire() end
		else
			if options.restore_refuses then return false end
			world.clipboard = command.text
			if world.on_restore then world.on_restore() end
		end
		return true
	end
	package.loaded["adapters.shell_runner"] = Shell
	local Output = require("modules.hotstrings.output_transaction")
	local new_transaction = Output.new
	Output.new = function(...)
		if options.constructor_error_object then
			error(setmetatable({}, { __tostring = function()
				world.error_formats = world.error_formats + 1
				error("independent error rendering exception")
			end }), 0)
		end
		if options.constructor_throws then error("independent transaction constructor exception") end
		return new_transaction(...)
	end
	local Codes = require("infra.evdev_codes")
	local channel = { is_open = function() return true end, close = function() record("channel_close"); return true end }
	function channel.emit(code, value)
		record("key:" .. code .. ":" .. value)
		if options.emit_throws and code == 47 and value == 1 then error("independent output exception") end
		if value == 1 then world.down[code] = true else world.down[code] = nil end
		if code == Codes.KEY_BACKSPACE and value == 1 then world.document = world.document:sub(1, -2) end
		if code == 47 and value == 1 and world.down[Codes.KEY_LEFTCTRL] then world.document = world.document .. world.clipboard end
		if options.retire_on_ctrl and code == Codes.KEY_LEFTCTRL and value == 1 then retire() end
		return true
	end
	local Injector = require("modules.hotstrings.injector")
	local writer, writer_path
	if options.real_writer then
		local Input, Broker = require("infra.input_event"), require("adapters.modifier_broker")
		writer_path = os.tmpname()
		assert(assert(io.open(writer_path, "wb")):close())
		writer = helpers.load_module("adapters.uinput_writer")
		writer._set_path_for_test(writer_path)
		writer._set_backend({ open = function() return 7 end, ioctl = function() return true end,
			close = function() return true end, write = function(_, bytes)
				local event = Input.decode(bytes)
				if event.type == Input.EV_KEY then return channel.emit(event.code, event.value) end
				return true
			end })
		assert(Injector.open_fast_channel())
		local original, broker = assert(writer.capture_output()), assert(Broker.for_channel(writer))
		world.authority_current = function()
			return writer.output_current(original) and Broker.for_channel(writer) == broker and broker.output_current()
		end
		world.replace_output = function(kind)
			if kind == "writer" then
				assert(writer.close_owned(assert(writer.capture_output()))); assert(writer.open())
			end
			if kind ~= "none" then Broker.detach(writer); assert(Broker.attach(writer)) end
		end
		local file = assert(io.open("adapters/keyboard_hook.lua", "rb"))
		local hook_source = file:read("*a"); file:close()
		local first = assert(hook_source:find("function M.emergency_stop(reason)", 1, true))
		local last = assert(hook_source:find("\n--- Runs a blocking modal", first, true))
		local hook_body = hook_source:sub(first, last - 1)
		assert(#hook_body > 500, "the actual emergency-stop body must be present")
		local env = setmetatable({ M = {}, Logger = package.loaded["logger.shim"], _broker = broker,
			_number_row = { retire = function() return true end }, _locks = { end_word = function() end },
			_emit_raw = writer.emit, _forwarded_down = {}, _output_owners = {}, _devices = {}, _pointer_devices = {},
			_close_paths = function(paths) assert(next(paths) == nil, "no native input source is admitted by this fixture") end,
		}, { __index = _G })
		local chunk
		if setfenv then chunk = assert(loadstring(hook_body .. "\nreturn M.emergency_stop")); setfenv(chunk, env)
		else chunk = assert(load(hook_body .. "\nreturn M.emergency_stop", "actual empty-input emergency stop", "t", env)) end
		local emergency = chunk()
		world.emergency = function() emergency("controlled clipboard-only cleanup debt") end
	else Injector._set_uinput(channel) end
	Injector._set_nanosleep_for_test(function(seconds)
		if seconds == 0.03 and options.retire_on_settle then retire() end
		if seconds == 0.03 and options.settle_throws then error("independent settle exception") end
	end)
	Injector.set_output_observer(function() world.notifications = world.notifications + 1 end)
	local function current() return world.destination == original_destination end
	world.publication = { current = current, cached = current }
	function world.inject()
		if options.single_field then return Injector.inject_fields(3, { world.payload }, true) end
		return Injector.inject(3, world.payload, true, nil, world.publication)
	end
	world.injector = Injector
	local ok, reason = pcall(callback, world)
	options.restore_refuses = false
	pcall(Injector.close_fast_channel)
	if writer then writer._reset_backend(); assert(os.remove(writer_path)) end
	for _, name in ipairs(names) do package.loaded[name] = old[name] end
	if not ok then error(reason, 0) end
end

local function unchanged(world, result)
	helpers.assert_eq(result.ok, false)
	helpers.assert_eq(result.cleanup_ok, true)
	helpers.assert_eq(world.document, "prefix trg", "preparation failure must not erase the trigger")
	helpers.assert_eq(world.clipboard, "saved clipboard")
	helpers.assert_eq(world.down, {})
	helpers.assert_eq(world.notifications, 0)
	for _, call in ipairs(world.calls) do helpers.assert_true(not call:match("^key:"), "no output before clipboard preparation") end
end

local function case(name, callback) helpers.it("ordinary clipboard preparation: " .. name, callback) end

helpers.describe("ordinary clipboard preparation before erasure", function()
	case("healthy preparation writes once before erasure and pastes without a second write", function()
		fixture({}, function(world)
			local result = world.inject()
			helpers.assert_eq(result.ok, true)
			helpers.assert_eq(result.cleanup_ok, true)
			helpers.assert_eq(world.document, "prefix 🙂")
			helpers.assert_eq(world.clipboard, "saved clipboard")
			helpers.assert_eq(world.writes, 1)
			helpers.assert_eq(world.notifications, 1)
			helpers.assert_eq(world.down, {})
			local write, erase
			for index, call in ipairs(world.calls) do
				if call == "write:" .. world.payload then write = index end
				if call == "key:14:1" and not erase then erase = index end
			end
			helpers.assert_true(write ~= nil and erase ~= nil and write < erase)
		end)
	end)
	for _, option in ipairs({ "read_refuses", "write_refuses", "write_throws", "settle_throws",
		"retire_on_read", "retire_on_write", "retire_on_settle" }) do
		local refusal = option
		case(refusal .. " preserves the original document and clipboard", function()
			fixture({ [refusal] = true }, function(world) unchanged(world, world.inject()) end)
		end)
	end
	case("single-field injection uses the same preparation boundary", function()
		fixture({ single_field = true, read_refuses = true }, function(world) unchanged(world, world.inject()) end)
	end)
	case("destination retirement after Ctrl DOWN still releases all owned keys and restores clipboard", function()
		fixture({ retire_on_ctrl = true }, function(world)
			local result = world.inject()
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, true)
			helpers.assert_eq(world.down, {})
			helpers.assert_eq(world.clipboard, "saved clipboard")
			helpers.assert_eq(world.stops, 0, "expected destination retirement must not emergency-stop healthy input")
		end)
	end)
	case("an output callback exception cannot skip key UP or saved clipboard restoration", function()
		fixture({ emit_throws = true }, function(world)
			local result = world.inject()
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, true)
			helpers.assert_eq(world.down, {})
			helpers.assert_eq(world.clipboard, "saved clipboard")
			helpers.assert_eq(world.notifications, 0)
		end)
	end)
	case("transaction construction refusal still restores the prepared clipboard before returning", function()
		local options = { constructor_throws = true }
		fixture(options, function(world)
			local result = world.inject()
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, false, "unknown constructor cleanup is never a physical ACK")
			helpers.assert_eq(world.document, "prefix trg")
			helpers.assert_eq(world.clipboard, "saved clipboard")
			helpers.assert_eq(world.down, {})
			helpers.assert_eq(world.notifications, 0)
			options.constructor_throws = false
			helpers.assert_eq(world.inject().ok, true, "the retained clipboard stage has genuinely retired")
		end)
	end)
	case("an unprintable constructor error cannot intercept saved clipboard restoration", function()
		fixture({ constructor_error_object = true }, function(world)
			local returned, result = pcall(world.inject)
			helpers.assert_eq(world.clipboard, "saved clipboard", "cleanup must precede formatting a foreign error")
			helpers.assert_eq(returned, true)
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, false)
			helpers.assert_eq(world.error_formats, 0)
			helpers.assert_eq(world.document, "prefix trg")
			helpers.assert_eq(world.down, {})
		end)
	end)
	case("failed restoration retains debt until the original cleanup later acknowledges", function()
		local options = { restore_refuses = true }
		fixture(options, function(world)
			local result = world.inject()
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.cleanup_ok, false)
			helpers.assert_eq(world.notifications, 0)
			helpers.assert_eq(world.down, {})
			local calls = #world.calls
			local blocked = world.inject()
			helpers.assert_eq(blocked.ok, false)
			helpers.assert_eq(blocked.cleanup_ok, false)
			for index = calls + 1, #world.calls do helpers.assert_true(not world.calls[index]:match("^key:")) end
			helpers.assert_eq(world.injector.close_fast_channel(), false)
			options.restore_refuses = false
			helpers.assert_eq(world.injector.close_fast_channel(), true)
			helpers.assert_eq(world.clipboard, "saved clipboard")
		end)
	end)
	case("retained clipboard debt blocks batch erasure even while its genuine Writer capability remains current", function()
		local options = { real_writer = true, restore_refuses = true }
		fixture(options, function(world)
			local first = world.inject()
			helpers.assert_eq(first.ok, false)
			helpers.assert_eq(first.cleanup_ok, false)
			helpers.assert_eq(first.native_cleanup_ok, true)
			helpers.assert_true(world.authority_current(), "real empty-input emergency stop does not retire a healthy Writer")
			local before, document = #world.calls, world.document
			local refused = world.injector.inject_fields(3, { world.payload, world.payload }, true)
			for index = before + 1, #world.calls do
				helpers.assert_true(not world.calls[index]:match("^key:"), "unacknowledged clipboard cleanup must precede every batch key")
			end
			helpers.assert_eq(refused.ok, false)
			helpers.assert_eq(refused.cleanup_ok, false)
			helpers.assert_eq(world.document, document)
			options.restore_refuses = false
			helpers.assert_eq(world.injector.inject_fields(0, { world.payload, world.payload }, true).ok, true)
			helpers.assert_true(world.authority_current(), "ACK recovery admits the same original Writer without replacement")
		end)
	end)
	for _, mode in ipairs({ "ordinary", "single", "multiple" }) do
		for _, change in ipairs({ "writer", "broker", "none" }) do
			case(mode .. " retains its original output while cleanup acknowledges " .. change, function()
				local options = { real_writer = true, restore_refuses = true }
				fixture(options, function(world)
					local first = world.inject()
					helpers.assert_eq({ first.ok, first.cleanup_ok, first.native_cleanup_ok }, { false, false, true })
					helpers.assert_true(world.authority_current(), "clipboard-only debt leaves the genuine output owner current")
					local function inject()
						if mode == "ordinary" then return world.injector.inject(3, world.payload, true) end
						return world.injector.inject_fields(3, mode == "single" and { world.payload } or { world.payload, world.payload }, true)
					end
					local restored, before, document = 0, #world.calls, world.document
					world.on_restore = function()
						world.on_restore = nil; restored = restored + 1
						world.replace_output(change)
					end
					options.restore_refuses = false
					local result = inject()
					helpers.assert_eq(restored, 1, "the actual pending clipboard setter must acknowledge cleanup")
					helpers.assert_eq(world.clipboard, "saved clipboard", "old clipboard cleanup must finish despite output succession")
					helpers.assert_eq(result.cleanup_ok, true)
					helpers.assert_eq(world.down, {})
					if change == "none" then
						helpers.assert_eq(result.ok, true)
						helpers.assert_eq(world.notifications, 1)
						helpers.assert_true(#world.calls > before)
					else
						local keys = 0
						for index = before + 1, #world.calls do
							if world.calls[index]:match("^key:") then keys = keys + 1 end
						end
						helpers.assert_eq(result.ok, false, "an old request cannot adopt the successor during restoration (emitted " .. keys .. " keys)")
						helpers.assert_eq(world.document, document)
						helpers.assert_eq(world.notifications, 0)
						for index = before + 1, #world.calls do
							helpers.assert_true(not world.calls[index]:match("^key:"), "no erase or replacement through the successor")
						end
						helpers.assert_eq(inject().ok, true, "a new request may use the acknowledged successor")
						helpers.assert_eq(world.notifications, 1)
					end
				end)
			end)
		end
		case(mode .. " without clipboard debt still completes on its original output", function()
			fixture({ real_writer = true }, function(world)
				local result
				if mode == "ordinary" then result = world.injector.inject(3, world.payload, true)
				else result = world.injector.inject_fields(3, mode == "single" and { world.payload } or { world.payload, world.payload }, true) end
				helpers.assert_eq({ result.ok, result.cleanup_ok, world.notifications }, { true, true, 1 })
				helpers.assert_eq(world.clipboard, "saved clipboard")
				helpers.assert_eq(world.down, {})
			end)
		end)
	end
end)
