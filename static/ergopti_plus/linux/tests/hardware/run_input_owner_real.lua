--- tests/hardware/run_input_owner_real.lua

--- ==============================================================================
--- MODULE: Installed Input Ownership Through Kernel Virtual Keyboards
--- DESCRIPTION:
--- Uses actual evdev/uinput descriptors, Hook, engines and libxkbcommon. Only
--- virtual-source selection/classification and the logical action catalogue are
--- controlled. Production physical discovery and the picker remain unavailable.
--- Handwritten KEY/SYN expectations describe observed wire reports, never ACKs.
--- Signal cases compile actual Main ownership statements with controlled external
--- cleanup debt and a teardown seam that closes the original real native output.
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
local Monotonic = require("infra.monotonic")
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
local signal_timer, signal_deadline
local prerequisite_failure
local original_signal_loaded, original_signal_preload = package.loaded["posix.signal"], package.preload["posix.signal"]

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
--- @param with_shift_hold boolean|nil Adds only the orphan regression's Shift binding.
local function start_session(with_shift_hold)
	local output = open_output()
	assert(Layout.refresh(), "actual Xvfb keymap initializes native libxkbcommon")
	local keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } }
	if with_shift_hold then keys.left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = .3 } end
	local base = Engine.new({ keys = keys,
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
	output.on_tap = function(action, binding)
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
	end
	assert(Hook.set_remapper(output.engine, output.on_tap))
	output.broker = assert(Broker.attach(Writer))
	Hook.start({ intercept = true, requireOutputBroker = true, outputBroker = output.broker, onEmitRaw = Writer.emit,
		onCaptureReacquired = Layout.publish_current_capture })
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

--- Waits across the actual compiled hold threshold without changing a deadline.
--- @param label string Original physical press being measured.
--- @param code integer|nil Defaults to the original Caps binding.
local function wait_for_long_hold(label, code)
	local setting = assert(session.base.by_code[code or 58], "actual compiled hold binding")
	local threshold_ms = setting.threshold_ms
	assert(type(threshold_ms) == "number" and threshold_ms > 0, "actual configured hold threshold")
	local held_at = Monotonic.now_ms()
	assert(os.execute(string.format("sleep %.3f", threshold_ms / 1000)) == 0, "real configured hold-duration wait")
	check(Monotonic.now_ms() - held_at >= threshold_ms, label .. " crosses the actual compiled hold threshold")
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
		if source.destroyed then
			check(not Reader.is_open("keyboard:" .. source.node) and node_for(source.name) == nil,
				"destroyed source has no retained Reader or kernel node")
		else
			local slot = "input-owner-retirement:" .. source.name
			assert(Reader.open(source.node, slot))
			successors[#successors + 1] = assert(Reader.capture_source_owner(slot))
			assert(Reader.grab(slot))
			local owner = assert(Reader.capture_source_owner(slot))
			check(Reader.retire_source(owner), "independent native grab and exact descriptor retirement")
		end
	end
	close_output(session); Broker.detach(Writer)
	check(not Reader.has_native_origin_debt() and not Writer.has_output_debt(), "native session has no retained source/output debt")
end

--- Compiles unchanged Main signal ownership statements with explicit fixture seams.
--- @param body string Actual Main source statements.
--- @param env table Controlled surrounding dependencies.
--- @return function compiled
local function compile_signal_code(body, env)
	if setfenv then return setfenv(assert(loadstring(body, "actual daemon input signal code")), env) end
	return assert(load(body, "actual daemon input signal code", "t", env))
end

--- Joins real signal delivery and final close acknowledgments to a held kernel key.
--- @param first_signal string Actual initial terminal signal.
local function signal_shutdown(first_signal)
	local uv = require("luv")
	local NativeTimer = require("infra.native_timer")
	local signals = require("infra.signal_handlers")
	assert(signals.is_settled(), "no preceding signal installation may remain owned")
	local file = assert(io.open("ergopti_hotstrings.lua", "r"))
	local text = file:read("*a"); assert(file:close())
	local installer = assert(text:match("(local function install_signal_handlers%(%).-)%s*%-%- ========================================="))
	local final = assert(text:match("final_wait%s*=%s*(%b{})"), "actual final signal registry is mandatory")
	local teardown = assert(text:match('(shutdown.request%("event loop returned"%).-)%s*if file_watchers then'))
	package.loaded["posix.signal"] = nil
	package.preload["posix.signal"] = function() error("fixture intentionally has no posix.signal") end
	start_session()
	original(sources[1], 58, 1)
	expect_frames("1:29:1 0:0:0", 2, "signal prerequisite genuinely holds native Ctrl")
	expect_held("29", "kernel Ctrl bitmap is set before terminal signal")
	wait_for_long_hold("the signalled original Caps press")
	local state = { ready = false, terminal = 0, loops = 0, closes = 0, ticks = 0 }
	local owners = {}
	local final_registry = compile_signal_code("return " .. final,
		setmetatable({ privacy_owners = owners }, { __index = _G }))()
	local coordinator = require("infra.shutdown_coordinator").new({
		pre_wait = { { name = "external native cleanup", wait_for_ack = true, stop = function() return state.ready end } },
		final_wait = final_registry,
		keyboard_hook = Hook,
		event_loop = { stop = function()
			check(signals.is_settled() and state.ready and state.closes == 0,
				"real signal close callbacks acknowledge before loop stop and output close")
			state.loops = state.loops + 1
			uv.stop()
		end },
	})
	local env = setmetatable({ shutdown = coordinator, privacy_owners = owners,
		Logger = { info = function() state.terminal = state.terminal + 1 end },
		perform_reload = function() error("terminal signal must not dispatch reload") end,
		tooltip_preview = false, llm_overlay = false,
		injector = { close_fast_channel = function()
			check(signals.is_settled() and not coordinator.is_pending() and state.loops == 1,
				"actual Main teardown reaches native output only after final signal ACK")
			state.closes = state.closes + 1
			close_output(session)
			return true
		end },
	}, { __index = _G })
	assert(compile_signal_code(installer .. "\nreturn install_signal_handlers()", env)())
	signal_timer = assert(uv.new_timer())
	signal_deadline = assert(uv.new_timer())
	-- The existing native signal child is also bounded by this 2.5-second owner.
	NativeTimer.start(uv, signal_deadline, 2500, 0, function() error("native input signal owner deadline expired") end)
	local sent, checked = 0, false
	-- Preserve the existing native_signal_shutdown timer cadence and tick bound.
	NativeTimer.start(uv, signal_timer, 1, 5, function()
		state.ticks = state.ticks + 1
		assert(state.ticks < 300, "native input signal cleanup failed to settle")
		if sent == 0 then sent = 1; assert(uv.kill(uv.os_getpid(), first_signal)); return end
		if state.ready then coordinator.poll(); return end
		if state.terminal == 0 then return end
		if state.terminal < sent then return end
		check(not Hook.isRunning() and coordinator.is_pending() and not signals.is_settled()
			and state.loops == 0 and state.closes == 0 and Writer.output_current(session.cap),
			"terminal signal stops Hook while external debt retains handlers, loop and output")
		if not checked then
			checked = true
			expect_frames("1:29:0 0:0:0", 2, "signal shutdown emits exactly one native Ctrl UP without a tap")
			expect_held("", "signal shutdown clears the real output bitmap before external ACK")
			for _, source in ipairs(sources) do
				check(not Reader.source_owner_current(source.owner), "terminal signal revokes the original native source lease")
				local slot = "input-owner-retirement:" .. source.name
				assert(Reader.open(source.node, slot)); assert(Reader.grab(slot))
				local owner = assert(Reader.capture_source_owner(slot))
				successors[#successors + 1] = owner
				check(Reader.retire_source(owner), "terminal signal releases the actual source grab for an independent owner")
			end
			assert(sources[1].writer.emit_owned(sources[1].cap, 58, 0), "physical Caps UP after capture retirement")
		end
		if sent < 3 then
			sent = sent + 1
			assert(uv.kill(uv.os_getpid(), sent == 2 and "sigint" or "sigterm"))
			return
		end
		if state.terminal < 3 then return end
		expect_frames("", 0, "repeated terminal signals and late physical UP emit no duplicate output")
		expect_held("", "native output stays clear throughout repeated terminal signals")
		state.ready = true
		coordinator.poll()
	end)
	uv.run()
	check(checked and state.terminal == 3 and state.loops == 1 and not coordinator.is_pending(),
		"three real terminal signals settle one exact shutdown transaction")
	compile_signal_code(teardown, env)()
	check(state.closes == 1 and signals.is_settled(), "actual Main teardown destroys output once after signal close ACK")
	uv.timer_stop(signal_timer); uv.close(signal_timer); signal_timer = nil
	uv.timer_stop(signal_deadline); uv.close(signal_deadline); signal_deadline = nil
	uv.run()
	local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
	check(remaining == 0, "native input signal case retains no luv handles")
	assert(Hook.set_remapper(nil)); Broker.detach(Writer)
	check(not Reader.has_native_origin_debt() and not Writer.has_output_debt(), "signal case leaves no input or output transport debt")
	package.loaded["posix.signal"], package.preload["posix.signal"] = original_signal_loaded, original_signal_preload
	completed[#completed + 1] = first_signal == "sigterm" and "signal-term-held-caps" or "signal-int-held-caps"
end

--- Runs genuine kernel scenarios with separately handwritten wire oracles.
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
		elseif status == "fatal" then
			for _, source in ipairs(sources) do
				if slot == "keyboard:" .. source.node then
					source.fatal = { status = status, reason = tostring(reason) }
					print("NATIVE_SOURCE_FATAL " .. source.name .. " " .. tostring(reason))
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

	for _, release_order in ipairs({ { 1, 2 }, { 2, 1 } }) do
		start_session()
		original(sources[1], 58, 1); original(sources[2], 58, 1)
		expect_frames("1:29:1 0:0:0", 2, "two native Caps sources emit exactly one Ctrl DOWN")
		expect_held("29", "two real Caps holds share one kernel-held Ctrl")
		wait_for_long_hold("both overlapping original presses")
		original(sources[release_order[1]], 58, 0)
		expect_frames("", 0, "the first native Caps UP emits no Ctrl release or tap")
		expect_held("29", "the retained original Caps keeps native Ctrl held after the first UP")
		original(sources[release_order[2]], 58, 0)
		expect_frames("1:29:0 0:0:0", 2, "the last native Caps UP emits exactly one Ctrl UP without a tap")
		expect_held("", "the final original release clears the native Ctrl bitmap")
		check(next(Hook.held_modifiers()) == nil, "overlapping holds retain no remapped modifier after both UPs")
		finish_session()
		completed[#completed + 1] = release_order[1] == 1 and "shared-caps-release-ab" or "shared-caps-release-ba"
	end

	signal_shutdown("sigterm")
	signal_shutdown("sigint")

	-- Fixture selection retires A's actual Reader/grab, while A's genuine kernel
	-- device remains registered. Keeping its minor allocated makes reuse of B's
	-- freed minor possible without renaming a node or manufacturing authority.
	start_session(true)
	local a, b = sources[1], sources[2]
	local function select_sources(include_a, include_b)
		Finder.find_devices = function()
			local paths = {}
			if include_a then paths[#paths + 1] = sources[1].node end
			if include_b then paths[#paths + 1] = sources[2].node end
			return paths, {}
		end
		for _ = 1, Hook.DEVICE_CHECK_TICKS do Hook.check_device() end
		check(Hook.isRunning(), "real source selection preserves the running Hook")
	end
	local function expect_retired_holds(label)
		local ready = await(function() journal_output(); return #output_journal >= 4 end)
		-- The two independent modifiers commute; each must have exactly one UP
		-- and its own SYN. Neither iteration order nor an extra report is assumed.
		check(ready ~= nil and (frames_match(output_journal, "1:29:0 0:0:0 1:42:0 0:0:0")
			or frames_match(output_journal, "1:42:0 0:0:0 1:29:0 0:0:0")), label)
		output_journal = {}
		check(not Reader.wait_readable(100, OUTPUT_SLOT), label .. " has no extra native row")
		expect_held("", label .. " clears the output bitmap")
	end
	local function expect_b_physical_shift(label)
		local receipt = Reader.capture_pressed_keys("keyboard:" .. b.node)
		local view = receipt and Reader.pressed_keys_view(receipt)
		check(view ~= nil and view.origin == "native-evdev" and table.concat(view.down, " ") == "42", label)
	end
	local function hold_both()
		original(a, 58, 1); original(b, 42, 1)
		expect_frames("1:29:1 0:0:0 1:42:1 0:0:0", 4, "actual Caps A and Shift B own distinct native modifiers")
		expect_held("29 42", "both consumed sources really hold native Ctrl and Shift")
		expect_b_physical_shift("B's actual source bitmap holds Shift before cohort retirement")
	end
	local function restore_a()
		assert(a.writer.emit_owned(a.cap, 58, 0), "uncaptured A physically releases its original Caps")
		select_sources(true, true)
		a.owner = assert(Reader.capture_source_owner("keyboard:" .. a.node))
		check(Reader.source_owner_current(a.owner), "the same registered A reacquires a fresh actual Reader lifetime")
		expect_frames("", 0, "reacquiring A replays no consumed hold or tap")
	end

	hold_both()
	local old_a = a.owner
	select_sources(false, true)
	expect_retired_holds("A capture departure retires both consumed modifier outputs")
	check(node_for(a.name) == a.node and not Reader.source_owner_current(old_a)
		and Reader.source_owner_current(b.owner), "A stays kernel-registered while only its original capture retires")
	expect_b_physical_shift("retained B is still physically down after its output retirement")
	-- Without the remapper, a leaked ownerless repeat would stop the broker.
	-- Keeping Hook live with no output proves suppression belongs to retained B,
	-- rather than an engine swallowing an arbitrary duplicate input.
	assert(Hook.set_remapper(nil))
	original(b, 42, 2)
	expect_frames("", 0, "retained consumed B repeat emits no replay after remapper removal")
	check(Hook.isRunning(), "suppressed retained repeat never reaches an ownerless raw output")
	original(b, 42, 0)
	expect_frames("", 0, "the genuine retained B UP ends suppression without a duplicate output UP")
	original(b, 42, 1); original(b, 42, 0)
	expect_frames("1:42:1 0:0:0 1:42:0 0:0:0", 4, "after its true UP the same B has a fresh raw Shift pair")
	assert(Hook.set_remapper(session.engine, session.on_tap))
	restore_a()

	hold_both()
	select_sources(false, true)
	expect_retired_holds("second A departure leaves B consumed until its actual lifetime ends")
	expect_b_physical_shift("B remains physically held immediately before native destruction")
	restore_a()
	local old_b_owner, old_b_node, before_destroy = b.owner, b.node, #facts
	-- No B UP: this destroys the actual held source. All old B evdev references
	-- must close before allocation; even one retained FD can delay minor reuse.
	b.close_attempted = true
	assert(b.writer.close_owned(b.cap), "held B UI_DEV_DESTROY and native writer close acknowledge")
	b.destroyed = true
	assert(await(function()
		Hook.pump()
		return b.fatal and not Reader.is_open("keyboard:" .. old_b_node) and node_for(b.name) == nil
	end), "real B disappearance reaches fatal native read and closes its original Reader")
	check(not Reader.source_owner_current(old_b_owner) and Reader.retire_source(old_b_owner),
		"old B observer lifetime has an exact close ACK before its minor can be reused")
	-- Some kernels may deliver an unregister-generated UP before ENODEV. That
	-- legitimately clears the orphan, so it cannot qualify this lost-UP case.
	for index = before_destroy + 1, #facts do
		local fact = facts[index]
		if fact.source == old_b_node and fact.code == 42 and fact.value == 0 then
			prerequisite_failure = "kernel delivered B's release before native retirement; lost-UP orphan regression is unqualified"
			error(prerequisite_failure)
		end
	end
	select_sources(true, false)
	expect_frames("", 0, "destroying the already-retired consumed B emits no replay or duplicate release")
	expect_held("", "A stays captured with no held output during B destruction")
	local replacement = create_source(SOURCE_B)
	if replacement.node ~= old_b_node then
		prerequisite_failure = "kernel allocated a different eventN for recreated B; same-path orphan regression is unqualified"
		error(prerequisite_failure)
	end
	check(replacement.node == old_b_node and node_for(a.name) == a.node,
		"kernel genuinely reuses B's exact eventN while A's original device remains registered")
	-- create_source owns the fresh device before any assertion; after the exact
	-- old closes above, replace its retired bookkeeping entry without aliasing it.
	sources[#sources] = nil
	sources[2] = replacement
	native_origins = original_classify({ a.node, replacement.node })
	assert(#native_origins == 2 and native_origins[1].physical == false and native_origins[2].physical == false,
		"fresh native discovery still rejects the actual recreated virtual device")
	select_sources(true, true)
	replacement.owner = assert(Reader.capture_source_owner("keyboard:" .. replacement.node))
	check(Reader.source_owner_current(replacement.owner) and not Reader.source_owner_current(old_b_owner),
		"fresh B owns its original current Reader while the destroyed same-path lease stays revoked")
	local bitmap = assert(Reader.capture_pressed_keys("keyboard:" .. replacement.node))
	local bitmap_view = assert(Reader.pressed_keys_view(bitmap))
	check(bitmap_view.origin == "native-evdev" and #bitmap_view.down == 0, "recreated B starts with a genuinely empty source bitmap")
	original(replacement, 42, 1)
	expect_frames("1:42:1 0:0:0", 2, "recreated same-path B's first Shift hold is not eaten by the retired orphan")
	expect_held("42", "fresh B's first hold really owns native Shift")
	wait_for_long_hold("the recreated B original hold", 42)
	original(replacement, 42, 0)
	expect_frames("1:42:0 0:0:0", 2, "fresh B's first release emits exactly Shift UP without a tap")
	expect_held("", "same-path reconnection leaves the native output clear after its first release")
	check(next(Hook.held_modifiers()) == nil, "recreated B leaves no remapped modifier after its first real UP")
	finish_session(); completed[#completed + 1] = "orphan-source-same-path-first-hold"

	start_session()
	local departing, retained = sources[1], sources[2]
	original(departing, 58, 1)
	expect_frames("1:29:1 0:0:0", 2, "departing source genuinely owns a native Ctrl hold")
	expect_held("29", "Ctrl is kernel-held before source destruction")
	-- A genuine long hold is the positive control. A kernel disconnect may
	-- retire pressed keys too; that must not accidentally qualify a short tap.
	wait_for_long_hold("the departing original press")
	-- UI_DEV_DESTROY removes the actual native device while its original Caps
	-- stays down. No fabricated UP or injected Reader failure retires this hold.
	departing.close_attempted = true
	assert(departing.writer.close_owned(departing.cap), "source UI_DEV_DESTROY and native close acknowledge")
	departing.destroyed = true
	assert(await(function()
		Hook.pump()
		return departing.fatal and not Reader.is_open("keyboard:" .. departing.node)
	end), "actual source disappearance produces a fatal native read and closes its Reader")
	check(departing.fatal.status == "fatal" and not Reader.source_owner_current(departing.owner),
		"native fatal read revokes the departed original source owner")
	check(Hook.isRunning() and Reader.is_grabbed("keyboard:" .. retained.node),
		"the surviving original source remains captured")
	expect_frames("1:29:0 0:0:0", 2, "native source destruction releases exactly its remapped Ctrl")
	expect_held("", "source destruction leaves no kernel-held output")
	-- Discovery catches up only after the real read failure has been observed;
	-- it cannot manufacture the tested departure through a selected-path edit.
	Finder.find_devices = function() return { retained.node }, {} end
	for _ = 1, Hook.DEVICE_CHECK_TICKS do Hook.check_device() end
	check(Hook.isRunning() and Reader.is_grabbed("keyboard:" .. retained.node),
		"source-roster reconciliation preserves the surviving native grab")
	original(retained, 58, 1)
	expect_frames("1:29:1 0:0:0", 2, "the surviving keyboard's first Caps hold emits native Ctrl DOWN")
	expect_held("29", "the first surviving Caps hold really owns kernel Ctrl")
	wait_for_long_hold("the surviving original press")
	original(retained, 58, 0)
	expect_frames("1:29:0 0:0:0", 2, "the first surviving Caps release emits only Ctrl UP, never a tap")
	expect_held("", "source departure and successor hold leave the native output clear")
	check(next(Hook.held_modifiers()) == nil, "no remapped modifier remains after successor release")
	finish_session(); completed[#completed + 1] = "destroy-source-first-surviving-hold"
end

print("\ninput owner: real kernel virtual keyboards; controlled virtual classification, no physical or product-action claim")
if not Writer.use_ffi_backend() or not Reader.use_ffi_backend() or not Writer.is_available() then
	io.stderr:write("ENVIRONMENT: native LuaJIT FFI and writable /dev/uinput + /dev/input are mandatory\n")
	os.exit(2)
end
local ok, failure = xpcall(run, debug.traceback)
ack_observer = nil
if not ok then
	if prerequisite_failure then io.stderr:write("ENVIRONMENT: " .. prerequisite_failure .. "\n")
	else check(false, tostring(failure)) end
end
local cleanup_ok = true
local function cleanup(callback, label)
	local called, settled = pcall(callback)
	if not check(called and settled == true, label) then cleanup_ok = false end
end
cleanup(function() if Hook then Hook.stop(); return not Hook.isRunning() end; return true end, "final actual Hook stop")
cleanup(function()
	local signals = package.loaded["infra.signal_handlers"]
	if not signals and not signal_timer and not signal_deadline then return true end
	local uv = require("luv")
	if signal_timer then uv.timer_stop(signal_timer); uv.close(signal_timer); signal_timer = nil end
	if signal_deadline then uv.timer_stop(signal_deadline); uv.close(signal_deadline); signal_deadline = nil end
	if signals then signals.stop() end
	uv.run("nowait")
	return not signals or signals.is_settled()
end, "final native signal and timer close acknowledgments")
package.loaded["posix.signal"], package.preload["posix.signal"] = original_signal_loaded, original_signal_preload
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
	if source.cap and not source.close_attempted then
		cleanup(function() return source.writer.close_owned(source.cap) end, "captured source native destroy/close")
	elseif source.close_attempted and not source.destroyed then
		check(false, "original source close debt retained without retry")
		cleanup_ok = false
	end
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
if not prerequisite_failure then
	check(table.concat(completed, " ") == "shift-repeat-up replace-frame-source-fd replace-other-original-fd retire-output-protect-successor shared-caps-release-ab shared-caps-release-ba signal-term-held-caps signal-int-held-caps orphan-source-same-path-first-hold destroy-source-first-surviving-hold",
		"all ten mandatory native scenarios completed")
end
if namespace and cleanup_ok and failures == 0 then
	cleanup(function() return os.remove(config_path) ~= nil and ffi.C.rmdir(namespace) == 0 end, "exclusive successful fixture namespace removed")
end
if namespace and (not cleanup_ok or failures > 0) then
	io.stderr:write("RETAINED owned failed input fixture namespace: " .. namespace .. "\n")
end
print(string.format("INPUT_OWNER_KERNEL %d %d %d", checks - failures, failures, #completed))
os.exit((failures > 0 or not cleanup_ok) and 1 or (prerequisite_failure and 2 or 0))
