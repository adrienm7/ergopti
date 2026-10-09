--- tests/hardware/run_input_owner_real.lua

--- ==============================================================================
--- MODULE: Installed Input Ownership Through Kernel Virtual Keyboards
--- DESCRIPTION:
--- Uses actual evdev/uinput descriptors, Hook, engines and libxkbcommon. Only
--- virtual-source selection/classification and the logical action catalogue are
--- controlled. Production physical discovery and the picker remain unavailable.
--- Handwritten KEY/SYN expectations describe observed wire reports, never ACKs.
--- ==============================================================================

--- Compares dense native KEY/SYN_REPORT rows with an independent literal oracle.
--- This pure classifier grants no descriptor, source, frame or output authority.
--- @param rows table Actual decoded evdev rows.
--- @param literal string Independently authored wire sequence.
--- @return boolean exact
local function frames_match(rows, literal)
	if type(rows) ~= "table" or getmetatable(rows) ~= nil or type(literal) ~= "string" then return false end
	local count, encoded = 0, {}
	for index, row in pairs(rows) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #rows
			or type(row) ~= "table" or getmetatable(row) ~= nil then return false end
		local kind, code, value = row.type, row.code, row.value
		if type(kind) ~= "number" or type(code) ~= "number" or type(value) ~= "number"
			or code % 1 ~= 0 or value % 1 ~= 0
			or not (kind == 1 and code >= 0 and code <= 0x2ff and value >= 0 and value <= 2
				or kind == 0 and code == 0 and value == 0) then return false end
		count = count + 1
		encoded[index] = string.format("%d:%d:%d", kind, code, value)
	end
	return count == #rows and table.concat(encoded, " ") == literal
end

-- Portable controls exercise only this classifier. They do not load or replace
-- native adapters and cannot issue an input lease or certify a kernel outcome.
if arg and arg[1] == "--classifier" then return { frames_match = frames_match } end

-- Cold Hook construction pins the genuine first Reader authority before any
-- backend or fixture callback. Transport observation below grants no authority.
local Hook = require("adapters.keyboard_hook")
local ffi = require("ffi")
local Input = require("infra.input_event")
local Names = require("infra.device_names")
local Finder = require("modules.hotstrings.device_finder")
local Reader = require("adapters.evdev_reader")
local Writer = require("adapters.uinput_writer")
local Broker = require("adapters.modifier_broker")
local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")
local Engine = require("platform.remap.tap_hold_engine")
local Native = require("platform.remap.key_combination_engine")
local Owner = require("modules.shortcuts.key_combinations")

-- Same node-publication and event-observation bounds as run_modifier_custody.lua.
-- The registered existing subreaper owns the unchanged 40-second process budget.
local NODE_WAIT_ATTEMPTS, NODE_WAIT_SECONDS = 50, 0.1
local SOURCE_A, SOURCE_B = "Ergopti input-owner virtual source A", "Ergopti input-owner virtual source B"
local OUTPUT_SLOT = "input-owner-output"
local checks, failures, completed = 0, 0, {}
local sources, outputs, successors, facts = {}, {}, {}, {}
local session, namespace, config_path, ack_observer
local output_journal = {}
local original_find, original_classify = Finder.find_devices, Finder.physical_sources
local original_read, original_emit = Reader.read_event, Writer.transaction_emit
local original_acquire, acquisitions = Writer.acquire_transaction, 0

pcall(ffi.cdef, [[
	long readlink(const char *path, char *buffer, unsigned long size);
	char *mkdtemp(char *template);
	int rmdir(const char *path);
]])

--- Records an assertion while retaining exact cleanup on refusal.
--- @param condition boolean
--- @param label string
local function check(condition, label)
	checks = checks + 1
	if condition then print("  ok   " .. label)
	else failures = failures + 1; print("  FAIL " .. label) end
	return condition == true
end

--- Waits within the existing fixture's native publication bound.
--- @param predicate function
--- @return any|nil observed
local function await(predicate)
	for _ = 1, NODE_WAIT_ATTEMPTS do
		local found = predicate()
		if found then return found end
		os.execute(string.format("sleep %.3f", NODE_WAIT_SECONDS))
	end
	return nil
end

--- Resolves only one exact owned device name; duplicate names refuse admission.
--- @param name string
--- @return string|nil node
local function node_for(name)
	local file = assert(io.open("/proc/bus/input/devices", "r"))
	local bytes = file:read("*a"); assert(file:close())
	local nodes = {}
	for _, device in ipairs(Finder.parse_devices(bytes)) do
		if device.name == name then
			for _, handler in ipairs(device.handlers) do
				if handler:match("^event%d+$") then nodes[#nodes + 1] = "/dev/input/" .. handler end
			end
		end
	end
	assert(#nodes <= 1, "duplicate owned native fixture name")
	return nodes[1]
end

--- Observes the actual numeric descriptor through procfs; grants no FD rights.
--- @param node string Exact already-open native source path.
--- @return integer descriptor
local function descriptor_for(node)
	local matches, buffer = {}, ffi.new("char[4096]")
	for descriptor = 0, 1023 do
		local count = tonumber(ffi.C.readlink("/proc/self/fd/" .. descriptor, buffer, 4096))
		if count >= 0 and count < 4096 and ffi.string(buffer, count) == node then
			matches[#matches + 1] = descriptor
		end
	end
	assert(#matches == 1, "one concrete procfs descriptor must witness the original Reader lifetime")
	return matches[1]
end

--- Creates one independently owned real uinput source without replacing FFI.
--- @param name string
--- @return table source
local function create_source(name)
	assert(node_for(name) == nil, "owned source name must be absent")
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = name
	local loaded, writer = pcall(function() return assert(loadfile("adapters/uinput_writer.lua"))() end)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, writer)
	local source = { name = name, writer = writer }
	sources[#sources + 1] = source
	assert(writer.use_ffi_backend()); assert(writer.open())
	source.cap = assert(writer.capture_output())
	source.node = assert(await(function() return node_for(name) end), "native source node publication")
	return source
end

--- Reads real output before any EVIOCGKEY ioctl can flush its queued KEY rows.
local function journal_output()
	assert(session and Reader.source_owner_current(session.observer), "original native output Reader must remain current")
	Reader.drain(function(event) output_journal[#output_journal + 1] = event end, OUTPUT_SLOT)
end

--- Consumes each actual KEY/SYN row once and checks the independent full order.
--- @param literal string
--- @param count integer Exact expected native row count.
--- @param label string
local function expect_frames(literal, count, label)
	local ready = await(function() journal_output(); return #output_journal >= count end)
	check(ready ~= nil and frames_match(output_journal, literal), label)
	output_journal = {}
	check(not Reader.wait_readable(100, OUTPUT_SLOT), label .. " has no extra native row")
end

--- Reads the actual output bitmap after journaling its real wire observations.
--- @param literal string Sorted independently expected held codes.
--- @param label string
local function expect_held(literal, label)
	journal_output()
	local receipt = Reader.capture_pressed_keys(OUTPUT_SLOT)
	local view = receipt and Reader.pressed_keys_view(receipt)
	check(view ~= nil and view.origin == "native-evdev" and table.concat(view.down, " ") == literal, label)
end

--- Emits a real source edge and requires Hook to read its genuine origin receipt.
--- @param source table
--- @param code integer
--- @param value integer
local function original(source, code, value)
	local before = #facts
	assert(source.writer.emit_owned(source.cap, code, value), "source KEY/SYN native acknowledgement")
	assert(await(function() Hook.pump(); return #facts > before end), "Hook must observe the emitted native source")
	local fact = facts[#facts]
	check(fact.origin == "native-evdev" and fact.source == source.node and fact.code == code and fact.value == value,
		"original event receipt binds actual source/code/value")
end

--- Acquires a native output and its independent grabbed kernel observer.
--- @return table output
local function open_output()
	assert(node_for(Names.VIRTUAL_KEYBOARD) == nil, "old production-named output must be absent")
	assert(Writer.open()); local output = { cap = assert(Writer.capture_output()) }
	outputs[#outputs + 1] = output
	output.node = assert(await(function() return node_for(Names.VIRTUAL_KEYBOARD) end), "native output node publication")
	assert(Reader.open(output.node, OUTPUT_SLOT))
	output.observer_cleanup = assert(Reader.capture_source_owner(OUTPUT_SLOT))
	assert(Reader.grab(OUTPUT_SLOT))
	output.observer = assert(Reader.capture_source_owner(OUTPUT_SLOT))
	output_journal, session = {}, output
	return output
end

--- Closes only the original output observer and captured device capability.
--- @param output table
local function close_output(output)
	assert(Reader.retire_source(output.observer), "original output observer close acknowledgement")
	output.observer_retired = true
	output.close_attempted = true
	assert(Writer.close_owned(output.cap), "original output destroy/close acknowledgement")
	output.retired = true
	assert(await(function() return node_for(Names.VIRTUAL_KEYBOARD) == nil end), "original output node disappears")
end

--- Starts actual Hook/engines with real canonical bytes and explicit fixture admission.
local function start_session()
	local output = open_output()
	assert(Layout.refresh(), "actual Xvfb keymap initializes native libxkbcommon")
	local base = Engine.new({ keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } },
		tap_min_ms = 0, one_shot_timeout_ms = 1000,
		key_text = function(code) return Hook.key_text(code) end,
		plan_text = function(text) return Layout.plan(text) end,
		one_shot_result = function() return nil end,
		held_modifiers = Hook.held_modifiers,
		held_text_modifier_codes = Hook.held_text_modifier_codes,
		held_shortcut_modifier_codes = Hook.held_shortcut_modifier_codes })
	local owner = Owner.new({ keys = { { id = "caps_lock", key = "caps_lock" }, { id = "tab", key = "tab" } },
		hold_picker = { modifiers = { "ctrl", "shift" }, layers = { "nav" } },
		route = function() return config_path end, is_paused = function() return false end,
		changed = function() return true end,
		-- Deliberate test-only logical source action admission. Manager and picker
		-- remain untouched and continue rejecting this unqualified production route.
		actions = { is_assignable = function(action) return action == "one_shot_shift" end } })
	output.base, output.engine = base, Native.new(base, owner.engine_options({ caps_lock = 300, tab = 300 }))
	assert(Hook.set_remapper(output.engine, function(action, binding)
		check(action == "one_shot_shift" and binding == "combination__caps_lock_then_tab", "actual canonical pair frame selects OneShotShift")
		local before = assert(Writer.output_view(output.cap))
		local broker_before = output.broker.view()
		local reservations_before = acquisitions
		output.lease = Hook.capture_input_owner()
		output.armed = output.lease ~= nil and Hook.arm_one_shot(output.lease)
		local after = assert(Writer.output_view(output.cap))
		local broker_after = output.broker.view()
		check(output.armed == true and before.write_epoch == after.write_epoch
			and reservations_before == acquisitions and broker_before.busy == false and broker_after.busy == false,
			"logical arm adds no native output write or reservation")
	end))
	output.broker = assert(Broker.attach(Writer))
	Hook.start({ intercept = true, requireOutputBroker = true, outputBroker = output.broker, onEmitRaw = Writer.emit })
	assert(Hook.isRunning(), "actual Hook must acquire both native sources")
	-- This separate, reviewed bootstrap successor republishes the genuine inverse
	-- after Hook's state reset. It performs no load/reset or fabricated map lookup.
	assert(type(Layout.publish_current_capture) == "function" and Layout.publish_current_capture(), "actual current inverse publication prerequisite")
	local plan = Layout.plan("A")
	assert(Hook.key_text(30) == "a" and type(plan) == "table" and #plan == 1
		and plan[1].keycode == 30 and #plan[1].mods == 1 and plan[1].mods[1] == "shift",
		"native Xvfb US family must actually map A to Shift+KEY_A")
	for _, source in ipairs(sources) do
		source.owner = assert(Reader.capture_source_owner("keyboard:" .. source.node))
		check(Reader.source_owner_current(source.owner), "actual original Reader lifetime/grab is current")
	end
	check(Hook.capture_input_owner() == nil and not Hook.arm_one_shot({}), "no input authority outside actual frame or from copied tables")
end

--- Produces one accepted native ordered-pair frame and releases its first key.
local function arm()
	original(sources[1], 58, 1); original(sources[1], 15, 1); original(sources[1], 15, 0)
	assert(session.armed == true and Hook.input_owner_current(session.lease), "genuine admitted frame must arm current owner")
	check(not Hook.arm_one_shot(session.lease), "spent action frame cannot arm twice")
	original(sources[1], 58, 0)
	expect_frames("1:29:1 0:0:0 1:29:0 0:0:0 1:29:1 0:0:0 1:29:0 0:0:0", 8,
		"native pair first hold/lift/restore/final release")
	expect_held("", "native arm leaves output clear before character")
end

--- Finishes one session and proves source-grab retirement independently.
local function finish_session()
	Hook.stop(); check(not Hook.isRunning(), "actual Hook session stopped")
	assert(Hook.set_remapper(nil), "exact remapper retirement")
	for _, source in ipairs(sources) do
		check(not Reader.source_owner_current(source.owner), "old native source lifetime revoked")
		local slot = "input-owner-retirement:" .. source.name
		assert(Reader.open(source.node, slot))
		successors[#successors + 1] = assert(Reader.capture_source_owner(slot))
		assert(Reader.grab(slot))
		local owner = assert(Reader.capture_source_owner(slot))
		check(Reader.retire_source(owner), "independent native grab and exact descriptor retirement")
	end
	close_output(session); Broker.detach(Writer)
	check(not Reader.has_native_origin_debt() and not Writer.has_output_debt(), "native session has no retained source/output debt")
end

--- Runs four genuine kernel scenarios with separately handwritten wire oracles.
local function run()
	assert(rawequal(package.loaded["adapters.keyboard_hook"], Hook), "original cold Hook construction must remain loaded")
	local template = ffi.new("char[?]", #"/tmp/ergopti-input-owner-XXXXXX" + 1, "/tmp/ergopti-input-owner-XXXXXX")
	local created = ffi.C.mkdtemp(template); assert(created ~= nil, "exclusive private fixture namespace")
	namespace = ffi.string(created); config_path = namespace .. "/config.toml"
	local file = assert(io.open(config_path, "w"))
	assert(file:write('[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "one_shot_shift"\n')); assert(file:close())
	create_source(SOURCE_A); create_source(SOURCE_B)
	local native_origins = original_classify({ sources[1].node, sources[2].node })
	assert(#native_origins == 2 and native_origins[1].physical == false and native_origins[2].physical == false,
		"production discovery must reject both actual virtual fixture sources")
	Finder.find_devices = function() return { sources[1].node, sources[2].node }, {} end
	Finder.physical_sources = function(paths)
		local result = {}
		for _, path in ipairs(paths) do
			local found
			for _, origin in ipairs(native_origins) do if origin.path == path then found = origin end end
			assert(found, "controlled virtual classification cannot admit an unrelated source")
			result[#result + 1] = { path = path, sysfs = found.sysfs, name = found.name, physical = true }
		end
		return result
	end
	Reader.read_event = function(slot)
		local event, status, reason = original_read(slot)
		if event and status == "event" then
			for _, source in ipairs(sources) do
				if slot == "keyboard:" .. source.node then
					local receipt = Reader.capture_event(event, slot)
					if receipt then facts[#facts + 1] = assert(Reader.event_view(receipt)) end
				end
			end
		end
		return event, status, reason
	end
	Writer.transaction_emit = function(token, code, value)
		local accepted = original_emit(token, code, value)
		if accepted == true and ack_observer then ack_observer(code, value) end
		return accepted
	end
	Writer.acquire_transaction = function(...)
		acquisitions = acquisitions + 1
		return original_acquire(...)
	end
	-- Hook already captured genuine Reader authority at first cold import.
	-- Only transport read_event is passively observed; capture/event/source/owner
	-- authority functions retain their exact originals. Writer observers forward
	-- real ports before startup and never issue an ACK or input capability.

	start_session(); arm()
	original(sources[1], 30, 1); expect_held("30 42", "real shifted character DOWN holds only A and Shift")
	original(sources[1], 30, 2); original(sources[1], 30, 0)
	expect_frames("1:42:1 0:0:0 1:30:1 0:0:0 1:30:2 0:0:0 1:30:0 0:0:0 1:42:0 0:0:0", 10,
		"native OneShot Shift/character DOWN repeat UP inverse order")
	expect_held("", "native character final UP clears kernel bitmap")
	check(not Hook.input_owner_current(session.lease) and session.base:input_arm_state() == nil, "consumed input owner retires after final native UP")
	original(sources[1], 30, 1); original(sources[1], 30, 0)
	expect_frames("1:30:1 0:0:0 1:30:0 0:0:0", 4, "following ordinary character remains unshifted")
	finish_session(); completed[#completed + 1] = "shift-repeat-up"

	for index = 1, 2 do
		start_session(); arm()
		local target, replaced = sources[index], false
		ack_observer = function(code, value)
			if code == 42 and value == 1 and not replaced then
				replaced = true; ack_observer = nil
				local slot, descriptor = "keyboard:" .. target.node, descriptor_for(target.node)
				local old = assert(Reader.capture_source_owner(slot))
				assert(Reader.close(slot)); assert(Reader.open(target.node, slot))
				successors[#successors + 1] = assert(Reader.capture_source_owner(slot))
				assert(Reader.grab(slot))
				local new = assert(Reader.capture_source_owner(slot))
				successors[#successors + 1] = new
				check(descriptor_for(target.node) == descriptor, "actual kernel reopened the same numeric original FD")
				target.replaced_old, target.successor = old, new
			end
		end
		original(sources[1], 30, 1); ack_observer = nil
		check(replaced and not Hook.isRunning(), "original Reader replacement withdraws consumed Hook owner")
		expect_frames("1:42:1 0:0:0 1:42:0 0:0:0", 4, "withdrawal acknowledges original Shift inverse without character DOWN")
		expect_held("", "original inverse clears actual kernel output")
		check(not Reader.source_owner_current(target.replaced_old)
			and Reader.retire_source(target.replaced_old) and Reader.source_owner_current(target.successor),
			"old exact retirement preserves reopened successor lifetime and grab")
		assert(Reader.retire_source(target.successor)); target.successor = nil
		assert(sources[1].writer.emit_owned(sources[1].cap, 30, 0))
		finish_session(); completed[#completed + 1] = index == 1 and "replace-frame-source-fd" or "replace-other-original-fd"
	end

	start_session(); arm(); original(sources[1], 30, 1)
	expect_frames("1:42:1 0:0:0 1:30:1 0:0:0", 4, "original output acknowledges shifted character DOWN")
	expect_held("30 42", "original output really holds shifted character before destroy")
	local old = session; close_output(old)
	local successor = open_output()
	check(not old.broker.output_current() and Writer.output_current(successor.cap), "old output issuer cannot redeem new native Writer lifetime")
	original(sources[1], 30, 2)
	check(not Hook.isRunning(), "old consumed output owner refuses repeat after native retirement")
	expect_frames("", 0, "successor receives no old repeat or inverse")
	expect_held("", "new native output remains kernel-clear")
	old.broker.retire()
	check(Writer.output_current(successor.cap), "old exact output retirement cannot close successor")
	assert(Writer.emit_owned(successor.cap, 45, 1)); assert(Writer.emit_owned(successor.cap, 45, 0))
	expect_frames("1:45:1 0:0:0 1:45:0 0:0:0", 4, "successor independently emits genuine native KEY/SYN after old cleanup")
	expect_held("", "successor independent final UP clears kernel bitmap")
	assert(sources[1].writer.emit_owned(sources[1].cap, 30, 0))
	assert(Hook.set_remapper(nil)); close_output(successor); Broker.detach(Writer)
	completed[#completed + 1] = "retire-output-protect-successor"
end

print("\ninput owner: real kernel virtual keyboards; controlled virtual classification, no physical or product-action claim")
if not Writer.use_ffi_backend() or not Reader.use_ffi_backend() or not Writer.is_available() then
	io.stderr:write("ENVIRONMENT: native LuaJIT FFI and writable /dev/uinput + /dev/input are mandatory\n")
	os.exit(2)
end
local ok, failure = xpcall(run, debug.traceback)
ack_observer = nil
if not ok then check(false, tostring(failure)) end
local cleanup_ok = true
local function cleanup(callback, label)
	local called, settled = pcall(callback)
	if not check(called and settled == true, label) then cleanup_ok = false end
end
cleanup(function() if Hook then Hook.stop(); return not Hook.isRunning() end; return true end, "final actual Hook stop")
cleanup(function() return not Hook or Hook.set_remapper(nil) end, "final remapper retirement")
for _, owner in ipairs(successors) do cleanup(function() return Reader.retire_source(owner) end, "captured successor exact native close") end
for _, output in ipairs(outputs) do
	local observer = output.observer or output.observer_cleanup
	if observer and not output.observer_retired then
		cleanup(function() return Reader.retire_source(observer) end, "captured output observer native close")
	end
	if output.cap and not output.close_attempted then
		output.close_attempted = true
		cleanup(function()
			if output.broker and output.broker.view().busy then return output.broker.retire() end
			return Writer.close_owned(output.cap)
		end, "captured output native destroy/close")
	elseif output.close_attempted and not output.retired then
		check(false, "original output close debt retained without retry")
		cleanup_ok = false
	end
end
Finder.find_devices, Finder.physical_sources = original_find, original_classify
Reader.read_event, Writer.transaction_emit = original_read, original_emit
Writer.acquire_transaction = original_acquire
for _, source in ipairs(sources) do
	if source.cap then cleanup(function() return source.writer.close_owned(source.cap) end, "captured source native destroy/close") end
end
cleanup(function() Capture.clear(); return not Capture.is_ready() end, "XKB adapter readiness cleared (no native destroy acknowledgement API)")
check(not Reader.is_open(OUTPUT_SLOT), "final owned output observer descriptor is closed")
for _, source in ipairs(sources) do
	check(type(source.node) == "string" and not Reader.is_open("keyboard:" .. source.node)
		and not Reader.is_open("input-owner-retirement:" .. source.name), "final owned source/probe descriptors are closed")
end
cleanup(function()
	return await(function()
		if node_for(Names.VIRTUAL_KEYBOARD) then return nil end
		for _, source in ipairs(sources) do if node_for(source.name) then return nil end end
		return true
	end) == true
end, "all exact owned kernel nodes disappear")
check(not Reader.has_native_origin_debt() and not Writer.has_output_debt(), "final Reader/Writer transport custody has no debt")
check(table.concat(completed, " ") == "shift-repeat-up replace-frame-source-fd replace-other-original-fd retire-output-protect-successor",
	"all four mandatory native scenarios completed")
if namespace and cleanup_ok and failures == 0 then
	cleanup(function() return os.remove(config_path) ~= nil and ffi.C.rmdir(namespace) == 0 end, "exclusive successful fixture namespace removed")
end
if namespace and (not cleanup_ok or failures > 0) then
	io.stderr:write("RETAINED owned failed input fixture namespace: " .. namespace .. "\n")
end
print(string.format("INPUT_OWNER_KERNEL %d %d %d", checks - failures, failures, #completed))
os.exit((failures > 0 or not cleanup_ok) and 1 or 0)
