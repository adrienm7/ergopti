--- tests/hardware/run_modifier_custody.lua

--- ==============================================================================
--- MODULE: Shared Modifier Custody Through Real Kernel Virtual Keyboards
--- DESCRIPTION:
--- Exercises actual Reader, Writer, Hook, Combo and OutputTransaction owners.
--- Two owned uinput sources are explicitly selected because production discovery
--- correctly excludes virtual sysfs. No syscall backend or XKB oracle is replaced.
--- This qualifies kernel virtual keyboards, never physical hardware or discovery.
--- ==============================================================================

local Input = require("infra.input_event")
local Names = require("infra.device_names")
local Finder = require("modules.hotstrings.device_finder")
local Reader = require("adapters.evdev_reader")
local Writer = require("adapters.uinput_writer")
local Broker = require("adapters.modifier_broker")
local Hook = require("adapters.keyboard_hook")

-- Match the existing uinput round-trip's node publication bound. This probe runs
-- before the live daemon/tray host; its existing deadlines remain unchanged.
local NODE_WAIT_ATTEMPTS = 50
local NODE_WAIT_SECONDS = 0.1
local SOURCE_A = "Ergopti custody virtual source A"
local SOURCE_B = "Ergopti custody virtual source B"
local OUTPUT_SLOT = "custody-output"
local checks, failures = 0, 0
local inputs, receipts, facts = {}, {}, {}
local output_cap, output_node, ack_observer, output_broker
local original_find = Finder.find_devices
local original_capture = Reader.capture_event
local original_emit = Writer.transaction_emit

--- Records one native assertion without stopping exact resource cleanup.
--- @param condition boolean
--- @param message string
local function check(condition, message)
	checks = checks + 1
	if condition then print("  ok   " .. message)
	else failures = failures + 1; print("  FAIL " .. message) end
end

--- Waits using the existing kernel harness's publication bound.
--- @param predicate function
--- @return any|nil result
local function await(predicate)
	for _ = 1, NODE_WAIT_ATTEMPTS do
		local result = predicate()
		if result then return result end
		os.execute(string.format("sleep %.3f", NODE_WAIT_SECONDS))
	end
	return nil
end

--- Resolves one exact name and refuses duplicate-name source ambiguity.
--- @param name string
--- @return string|nil node
local function node_for(name)
	local file = assert(io.open("/proc/bus/input/devices", "r"))
	local text = file:read("*a"); assert(file:close())
	local nodes = {}
	for _, device in ipairs(Finder.parse_devices(text)) do
		if device.name == name then
			for _, handler in ipairs(device.handlers) do
				if handler:match("^event%d+$") then nodes[#nodes + 1] = "/dev/input/" .. handler end
			end
		end
	end
	assert(#nodes <= 1, "duplicate native fixture device name: " .. name)
	return nodes[1]
end

--- Creates an independent production Writer instance with a captured native owner.
--- @param name string
--- @return table input
local function create_source(name)
	assert(node_for(name) == nil, "fixture source already exists")
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = name
	local loaded, source = pcall(function() return assert(loadfile("adapters/uinput_writer.lua"))() end)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, source)
	local entry = { name = name, writer = source }
	inputs[#inputs + 1] = entry
	assert(source.use_ffi_backend(), "source FFI backend")
	assert(source.open(), "source native device creation")
	entry.cap = assert(source.capture_output(), "source strict native output capability")
	entry.node = assert(await(function() return node_for(name) end), "source node publication")
	return entry
end

--- Reads literal native KEY/SYN frames, rejecting queue-loss and unexpected types.
--- @return table rows
local function drain_output()
	local rows = {}
	Reader.drain(function(event)
		check(event.type == Input.EV_KEY or (event.type == Input.EV_SYN and event.code == 0),
			"native output contains only KEY/SYN_REPORT")
		rows[#rows + 1] = string.format("%d:%d:%d", event.type, event.code, event.value)
	end, OUTPUT_SLOT)
	return rows
end

--- Compares real kernel reports against independently written literal frames.
--- @param expected string
--- @param count integer Exact KEY and SYN row count.
--- @param label string
local function expect_frames(expected, count, label)
	local rows = {}
	local ready = await(function()
		for _, row in ipairs(drain_output()) do rows[#rows + 1] = row end
		return #rows >= count
	end)
	check(ready ~= nil and table.concat(rows, " ") == expected, label .. ": " .. table.concat(rows, " "))
	check(not Reader.wait_readable(math.floor(NODE_WAIT_SECONDS * 1000), OUTPUT_SLOT),
		label .. " has no additional native frame")
end

--- Checks the kernel's current held bitmap through its exact native receipt.
--- @param slot string
--- @param expected string Sorted held keycodes, joined with spaces.
--- @param label string
local function expect_held(slot, expected, label)
	local capability = Reader.capture_pressed_keys(slot)
	local view = capability and Reader.pressed_keys_view(capability)
	check(view ~= nil and view.origin == "native-evdev"
		and table.concat(view.down, " ") == expected, label)
end

--- Emits an original edge on a real source and waits for Hook's native receipt.
--- @param source table
--- @param code integer
--- @param value integer
local function original(source, code, value)
	local before = #facts
	assert(source.writer.emit_owned(source.cap, code, value), "source KEY/SYN acknowledged")
	assert(await(function() Hook.pump(); return #facts > before end), "Hook reads real original source edge")
	local fact = facts[#facts]
	check(fact.source == source.node and fact.code == code and fact.value == value
		and fact.origin == "native-evdev", "original receipt binds the exact native source and edge")
end

--- Runs the real kernel scenarios; the caller always performs exact teardown.
local function run()
	assert(node_for(Names.VIRTUAL_KEYBOARD) == nil, "production-named fixture output must be unique")
	local a, b = create_source(SOURCE_A), create_source(SOURCE_B)
	assert(Writer.open(), "output native device creation")
	output_cap = assert(Writer.capture_output(), "output strict native capability")
	output_node = assert(await(function() return node_for(Names.VIRTUAL_KEYBOARD) end), "output node publication")
	assert(Reader.open(output_node, OUTPUT_SLOT), "native output reader")
	assert(Reader.grab(OUTPUT_SLOT), "output fixture excludes desktop side effects")
	assert(require("adapters.keyboard_layout").refresh(), "live Xvfb XKB capture and injection map")

	-- Selection is test-owned; native key-device validation, read, grab, origin
	-- receipts, held queries, KEY/SYN writes and retirement stay production ports.
	Finder.find_devices = function() return { a.node, b.node }, {} end
	Reader.capture_event = function(event, slot)
		local capability = original_capture(event, slot)
		if capability and (slot == "keyboard:" .. a.node or slot == "keyboard:" .. b.node) then
			local view = assert(Reader.event_view(capability))
			facts[#facts + 1] = view; receipts[#receipts + 1] = capability
		end
		return capability
	end
	-- Observe the literal native transaction ACK, rather than replacing its
	-- backend. Reentry occurs before the broker's synthetic wire call returns.
	Writer.transaction_emit = function(token, code, value)
		local accepted = original_emit(token, code, value)
		if accepted == true and ack_observer then ack_observer(code, value) end
		return accepted
	end
	local broker = assert(Broker.attach(Writer)); output_broker = broker
	Hook.start({ intercept = true, requireOutputBroker = true, outputBroker = broker,
		onEmitRaw = Writer.emit })
	assert(Hook.isRunning(), "Hook owns both real virtual source grabs")
	check(Reader.is_grabbed("keyboard:" .. a.node) and Reader.is_grabbed("keyboard:" .. b.node),
		"both original sources hold native EVIOCGRAB")

	-- Independent source overlap: one down survives the first original up.
	original(a, 42, 1); original(b, 42, 1)
	expect_held(OUTPUT_SLOT, "42", "two originals produce one kernel-held Shift")
	original(a, 42, 0)
	expect_held("keyboard:" .. a.node, "", "first source is really released")
	expect_held("keyboard:" .. b.node, "42", "second source is really held")
	expect_held(OUTPUT_SLOT, "42", "first original UP preserves the kernel output hold")
	original(b, 42, 0)
	expect_frames("1:42:1 0:0:0 1:42:0 0:0:0", 4, "first DOWN and final UP survive native KEY/SYN")
	expect_held(OUTPUT_SLOT, "", "overlap final UP clears native output state")

	-- Borrowed Shift: actual source UP reenters while Combo owns the reservation.
	original(a, 42, 1)
	local fired = false
	ack_observer = function(code, value)
		if code == 30 and value == 1 and not fired then fired = true; original(a, 42, 0) end
	end
	local combo = require("modules.gestures.combo_emitter")
	check(combo.press_codes({ 42 }, { 30 }, "native queued original UP"), "Combo acknowledges real queued retirement")
	ack_observer = nil
	check(fired, "native synthetic DOWN ACK delivered the reentrant source callback")
	expect_frames("1:42:1 0:0:0 1:30:1 0:0:0 1:30:0 0:0:0 1:42:0 0:0:0", 8,
		"queued borrowed modifier retires after native chord key UP")
	expect_held(OUTPUT_SLOT, "", "Combo final native bitmap is clear")
	check(not broker.view().busy and not broker.has_debt(), "Combo commits its exact native reservation")
	check(combo.press_codes({ 56 }, { 30 }, "native successor"), "a successor acquires acknowledged native custody")
	expect_frames("1:56:1 0:0:0 1:30:1 0:0:0 1:30:0 0:0:0 1:56:0 0:0:0", 8,
		"native successor owns and releases each synthetic key")

	-- Suspended Shift: an actual source release must never be restored.
	original(a, 42, 1); fired = false
	ack_observer = function(code, value)
		if code == 45 and value == 1 and not fired then fired = true; original(a, 42, 0) end
	end
	local tx = require("modules.hotstrings.output_transaction").new(Writer)
	assert(tx.neutralize({ 42 }), "native original suspension")
	assert(tx.emit(45, 1)); assert(tx.emit(45, 0))
	local result = tx.finish(); ack_observer = nil
	check(fired and result.ok == true and result.cleanup_ok == true, "OutputTransaction acknowledges native released-owner cleanup")
	expect_frames("1:42:1 0:0:0 1:42:0 0:0:0 1:45:1 0:0:0 1:45:0 0:0:0", 8,
		"released original is not re-pressed during native suspended restore")
	expect_held(OUTPUT_SLOT, "", "suspended source retirement leaves native output clear")
	check(not broker.view().busy and not broker.has_debt(), "text output commits its exact native reservation")

	-- A still-held source at Hook retirement requires one native inverse ACK.
	original(b, 42, 1); Hook.stop()
	check(not Hook.isRunning(), "Hook closes its actual source session")
	expect_frames("1:42:1 0:0:0 1:42:0 0:0:0", 4, "Hook stop acknowledges final original native UP")
	expect_held(OUTPUT_SLOT, "", "Hook retirement clears actual kernel output bitmap")
	local revoked = true
	for _, capability in ipairs(receipts) do if Reader.source_current(capability) then revoked = false end end
	check(revoked and #receipts == 9, "every exact native original receipt is revoked on source retirement")
	for _, source in ipairs(inputs) do
		local slot = "custody-probe:" .. source.name
		assert(Reader.open(source.node, slot)); check(Reader.grab(slot), "retired source grab can be independently acquired")
		check(Reader.ungrab(slot), "independent retirement probe releases its grab")
		check(Reader.close(slot), "independent retirement probe closes its exact descriptor")
	end
	check(not Reader.has_native_origin_debt(), "native source retirement has no descriptor debt")
	check(Writer.output_current(output_cap) and #Writer.output_view(output_cap).down == 0,
		"the original native output owner remains current and clear after all consumers")
end

print("\nmodifier custody: real kernel virtual keyboards (no physical hardware claim)")
if not Writer.use_ffi_backend() or not Reader.use_ffi_backend() then
	io.stderr:write("ENVIRONMENT: this native fixture requires LuaJIT FFI\n")
	os.exit(2)
end
if not Writer.is_available() then
	io.stderr:write("ENVIRONMENT: /dev/uinput must be present and writable\n")
	os.exit(2)
end
local ok, error_message = xpcall(run, debug.traceback)
ack_observer = nil
if not ok then check(false, tostring(error_message)) end
pcall(Hook.stop)
Finder.find_devices, Reader.capture_event, Writer.transaction_emit = original_find, original_capture, original_emit
check(Reader.close(OUTPUT_SLOT), "native output observer closes its exact descriptor")
if output_cap then
	if output_broker and output_broker.view().busy then
		check(output_broker.retire(), "unresolved native reservation retires through its exact token")
	else check(Writer.close_owned(output_cap), "native output destroy and close acknowledge exact ownership") end
end
for _, source in ipairs(inputs) do
	if source.cap then check(source.writer.close_owned(source.cap), "native source destroy and close acknowledge exact ownership") end
end
local vanished = await(function()
	if node_for(Names.VIRTUAL_KEYBOARD) then return nil end
	for _, source in ipairs(inputs) do if node_for(source.name) then return nil end end
	return true
end)
check(vanished == true, "all three exact fixture nodes disappear after native retirement")
print(string.format("MODIFIER_CUSTODY_KERNEL %d %d", checks - failures, failures))
os.exit(failures > 0 and 1 or 0)
