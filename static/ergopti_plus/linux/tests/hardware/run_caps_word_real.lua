--- tests/hardware/run_caps_word_real.lua

--- ==============================================================================
--- MODULE: Genuine Kernel CapsWord Owner Receipts
--- DESCRIPTION:
--- Exercises actual Reader/uinput/XKB/output owners on independently owned virtual
--- devices. Logical fixture classification grants no physical-hardware claim.
--- Kernel text-key frames and final bitmaps are observed; application text,
--- Manager/public selection and hardware interaction require separate qualification.
--- ==============================================================================

local Hook = require("adapters.keyboard_hook") -- Cold original Reader construction.
local ffi = require("ffi")
pcall(ffi.cdef, "int usleep(unsigned int usec);")
local Finder = require("modules.hotstrings.device_finder")
local Reader = require("adapters.evdev_reader")
local Writer = require("adapters.uinput_writer")
local Names = require("infra.device_names")
local Input = require("infra.input_event")
local Layout = require("adapters.keyboard_layout")
local Engine = require("platform.remap.tap_hold_engine")
local Native = require("platform.remap.key_combination_engine")
local Owner = require("modules.shortcuts.key_combinations")
local Broker = require("adapters.modifier_broker")
local sources, output, checks = {}, nil, 0
local original_find, original_classify = Finder.find_devices, Finder.physical_sources
local original_read = Reader.read_event
local facts, journal = {}, {}
local OUTPUT = "caps-word-native-output"
local namespace = assert(arg[1], "original owned fixture namespace")
local config_path = namespace .. "/caps-word.toml"

local function check(value, label)
	checks = checks + 1
	assert(value, label)
	print("  ok   " .. label)
end

local function await(predicate)
	for _ = 1, 50 do
		local result = predicate()
		if result then return result end
		ffi.C.usleep(100000)
	end
	error("owned CapsWord native receipt deadline")
end

local function node_for(name)
	local file = assert(io.open("/proc/bus/input/devices", "r"))
	local bytes = file:read("*a"); assert(file:close())
	local result
	for _, device in ipairs(Finder.parse_devices(bytes)) do
		if device.name == name then
			for _, handler in ipairs(device.handlers) do
				if handler:match("^event%d+$") then
					assert(result == nil, "owned native name is unique")
					result = "/dev/input/" .. handler
				end
			end
		end
	end
	return result
end

local function source(name)
	check(node_for(name) == nil, "original virtual source namespace is absent")
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = name
	local loaded, writer = pcall(function() return assert(loadfile("adapters/uinput_writer.lua"))() end)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, writer)
	local owned = { writer = writer, name = name }; sources[#sources + 1] = owned
	assert(writer.use_ffi_backend() and writer.open())
	owned.cap = assert(writer.capture_output())
	owned.node = await(function() return node_for(name) end)
	return owned
end

local function edge(code, value)
	local before = #facts
	assert(sources[1].writer.emit_owned(sources[1].cap, code, value))
	await(function() Hook.pump(); return #facts > before end)
	local fact = facts[#facts]
	check(fact.origin == "native-evdev" and fact.source == sources[1].node
		and fact.code == code and fact.value == value, "exact original kernel source event")
end

local function expect(literal)
	local result = {}
	await(function()
		Reader.drain(function(event) journal[#journal + 1] = event end, OUTPUT)
		return #journal >= 1
	end)
	for _, event in ipairs(journal) do
		result[#result + 1] = event.type .. ":" .. event.code .. ":" .. event.value
	end
	check(table.concat(result, " ") == literal, "independent complete native KEY/SYN order")
	journal = {}
	check(not Reader.wait_readable(100, OUTPUT), "no extra native output frame")
	local receipt = Reader.capture_pressed_keys(OUTPUT)
	local keys = receipt and Reader.pressed_keys_view(receipt)
	check(keys and keys.origin == "native-evdev" and #keys.down == 0, "actual native bitmap has no modifier/key debt")
end

local function run()
	assert(Writer.use_ffi_backend() and Reader.use_ffi_backend() and Writer.is_available())
	source("Ergopti CapsWord native source A"); source("Ergopti CapsWord native source B")
	local origins = original_classify({ sources[1].node, sources[2].node })
	check(#origins == 2 and not origins[1].physical and not origins[2].physical,
		"production discovery rejects genuine virtual fixture devices")
	Finder.find_devices = function() return { sources[1].node, sources[2].node }, {} end
	Finder.physical_sources = function(paths)
		local records = {}
		for _, path in ipairs(paths) do
			local found
			for _, origin in ipairs(origins) do if origin.path == path then found = origin end end
			assert(found, "logical fixture admission cannot classify an unrelated device")
			records[#records + 1] = { path = path, name = found.name, sysfs = found.sysfs, physical = true }
		end
		return records
	end
	Reader.read_event = function(slot)
		local event, status, reason = original_read(slot)
		if event and status == "event" and slot == "keyboard:" .. sources[1].node then
			local receipt = Reader.capture_event(event, slot)
			local view = receipt and Reader.event_view(receipt)
			assert(view and Reader.event_current(receipt, event, slot), "original receipt observer cannot mint a native event")
			facts[#facts + 1] = view
		end
		return event, status, reason
	end
	check(node_for(Names.VIRTUAL_KEYBOARD) == nil, "production-named output is absent")
	assert(Writer.open()); output = { cap = assert(Writer.capture_output()) }
	output.node = await(function() return node_for(Names.VIRTUAL_KEYBOARD) end)
	assert(Reader.open(output.node, OUTPUT) and Reader.grab(OUTPUT))
	output.observer = assert(Reader.capture_source_owner(OUTPUT))
	assert(Layout.refresh())
	local file = assert(io.open(config_path, "w"))
	assert(file:write('[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "caps_word"\n')); assert(file:close())
	local base = Engine.new({ keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } },
		tap_min_ms = 0, one_shot_timeout_ms = 1000, key_text = Hook.key_text,
		plan_text = Layout.plan, caps_word_plan = Hook.plan_caps_word,
		one_shot_result = function() error("CapsWord cannot use OneShot substitutions") end,
		held_text_modifier_codes = Hook.held_text_modifier_codes })
	local owner = Owner.new({ keys = { { id = "caps_lock", key = "caps_lock" }, { id = "tab", key = "tab" } },
		hold_picker = { modifiers = { "ctrl", "shift" }, layers = { "nav" } },
		route = function() return config_path end, is_paused = function() return false end,
		changed = function() return true end,
		-- Explicit logical fixture action admission; public Manager denial remains closed.
		actions = { is_assignable = function(action) return action == "caps_word" end } })
	local installed = Native.new(base, owner.engine_options({ caps_lock = 300, tab = 300 }))
	assert(Hook.set_remapper(installed, function(action, binding)
		check(action == "caps_word" and binding == "combination__caps_lock_then_tab", "genuine acknowledged frame requests CapsWord")
		return action
	end))
	local broker = assert(Broker.attach(Writer))
	Hook.start({ intercept = true, requireOutputBroker = true, outputBroker = broker, onEmitRaw = Writer.emit })
	assert(Hook.isRunning() and Layout.publish_current_capture())
	edge(58, 1); edge(15, 1); edge(15, 0); edge(58, 0)
	check(base:input_arm_state() == "armed", "genuine persistent native frame arm")
	Reader.drain(function() end, OUTPUT)
	local literals = {
		[30] = "1:42:1 0:0:0 1:30:1 0:0:0 1:30:0 0:0:0 1:42:0 0:0:0",
		[48] = "1:42:1 0:0:0 1:48:1 0:0:0 1:48:0 0:0:0 1:42:0 0:0:0",
		[46] = "1:42:1 0:0:0 1:46:1 0:0:0 1:46:0 0:0:0 1:42:0 0:0:0" }
	for _, code in ipairs({ 30, 48, 46 }) do
		edge(code, 1); edge(code, 0); expect(literals[code])
		check(base:input_arm_state() == "armed", "native word persists across complete acknowledged character")
	end
	edge(57, 1); edge(57, 0)
	expect("1:57:1 0:0:0 1:57:0 0:0:0")
	check(base:input_arm_state() == nil, "native Space cancels persistent word")
	edge(32, 1); edge(32, 0)
	expect("1:32:1 0:0:0 1:32:0 0:0:0")
end

local succeeded, failure = pcall(run)
local cleaned, cleanup_failure = pcall(function()
	Hook.stop(); Hook.set_remapper(nil)
	if output then
		if output.observer then assert(Reader.retire_source(output.observer)) end
		assert(Writer.close_owned(output.cap))
		await(function() return node_for(Names.VIRTUAL_KEYBOARD) == nil end)
	end
	for _, owned in ipairs(sources) do
		if owned.cap then assert(owned.writer.close_owned(owned.cap)) end
		await(function() return node_for(owned.name) == nil end)
	end
	check(not Hook.isRunning() and not Reader.has_native_origin_debt() and not Writer.has_output_debt(),
		"original Hook Reader and output owners retain zero native debt after exact cleanup")
	if output and output.observer then
		check(not Reader.source_owner_current(output.observer) and not Writer.output_current(output.cap),
			"original observer and output lifetimes remain revoked after native retirement")
	end
	assert(os.remove(config_path))
end)
Finder.find_devices, Finder.physical_sources = original_find, original_classify
Reader.read_event = original_read
assert(cleaned, cleanup_failure)
assert(succeeded, failure)
print("Native CapsWord kernel receipts: " .. checks .. " passed, 0 failed, 0 skipped")
