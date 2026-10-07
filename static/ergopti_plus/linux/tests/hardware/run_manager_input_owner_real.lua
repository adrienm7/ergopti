--- tests/hardware/run_manager_input_owner_real.lua

--- ==============================================================================
--- MODULE: Saved-Pair Manager Through The Genuine Native Daemon
--- DESCRIPTION:
--- Runs the production daemon's cold imports, configuration, Manager, Hook,
--- watchdog, broker and shutdown against real evdev/uinput. Only the exact
--- virtual-source discovery/classification is controlled. This grants no
--- physical keyboard evidence, action-picker capability or legacy test credit.
--- ==============================================================================

local ffi = require("ffi")
local uv = require("luv")
local Json = require("json")
local Finder = require("modules.hotstrings.device_finder")
local Names = require("infra.device_names")
local Writer = require("adapters.uinput_writer")

local scenario = arg and arg[1]
local oracle_file = assert(io.open("tests/hardware/manager_input_owner_oracles.json", "r"))
local corpus = Json.decode(oracle_file:read("*a")); assert(oracle_file:close())
local expected
for _, entry in ipairs(corpus.cases) do if entry.id == scenario then expected = entry end end
assert(expected, "one exact finite Manager scenario is required")

-- No Reader, Hook, Manager or keylogger import precedes the actual daemon.
local checks, failures, completed = 0, 0, 0
local sources, successors, journal = {}, {}, {}
local Reader, Hook, Manager, Layout, Combinations
local output_owner, output_node, output_cap, fixture_timer
local port_census, prefix_reservations = {}, 0
local original_emit, original_acquire = Writer.transaction_emit, Writer.acquire_transaction
local original_find, original_keyboard = Finder.find_devices, Finder.find_keyboard
local original_classify, original_pointers, original_pointer = Finder.physical_sources, Finder.find_pointers, Finder.find_pointer
local ack_control, adversary, inverse_bitmap, down_bitmap, callback_failure
local task, task_failure, native_origins
local OUTPUT_SLOT = "manager-supplement-observer"
local stage_timeout_ms, publication_timeout_ms = 5000, 5000
local corpus_rows, extra_rows = {}, false

pcall(ffi.cdef, [[
	int usleep(unsigned int usec);
	long readlink(const char *path, char *buffer, unsigned long size);
]])





-- ===========================================
-- ===========================================
-- ======= 1/ Native Fixture Ownership =======
-- ===========================================
-- ===========================================

--- Records a finite check without hiding wrong-but-nonthrowing results.
--- @param condition boolean
--- @param label string
local function check(condition, label)
	checks = checks + 1
	if condition == true then print("  ok   " .. label)
	else failures = failures + 1; print("  FAIL " .. label) end
end

--- Resolves only one exact fixture name and rejects ambiguous kernel nodes.
--- @param name string
--- @return string|nil
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
	assert(#nodes <= 1, "duplicate exact native fixture device name")
	return nodes[1]
end

--- Waits for initial native publication before the production loop starts.
--- @param predicate function
--- @return any
local function initial_wait(predicate)
	local deadline = uv.hrtime() / 1000000 + publication_timeout_ms
	repeat
		local found = predicate()
		if found then return found end
		assert(ffi.C.usleep(100000) == 0, "native publication wait refused")
	until uv.hrtime() / 1000000 >= deadline
	error("owned kernel node publication exceeded its finite deadline", 0)
end

--- Creates a genuine independently owned Writer instance without a backend facade.
--- @param name string
local function create_source(name)
	assert(node_for(name) == nil, "exact owned source name must be absent")
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = name
	local loaded, writer = pcall(function() return assert(loadfile("adapters/uinput_writer.lua"))() end)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, writer)
	local source = { name = name, writer = writer }
	sources[#sources + 1] = source
	assert(writer.use_ffi_backend() == true and writer.open() == true, "actual source uinput allocation")
	source.cap = assert(writer.capture_output())
	source.node = initial_wait(function() return node_for(name) end)
end

--- Observes the one actual descriptor without granting native FD authority.
--- @param node string
--- @return integer
local function descriptor_for(node)
	local descriptors, buffer = {}, ffi.new("char[4096]")
	for descriptor = 0, 1023 do
		local count = tonumber(ffi.C.readlink("/proc/self/fd/" .. descriptor, buffer, 4096))
		if count >= 0 and count < 4096 and ffi.string(buffer, count) == node then
			descriptors[#descriptors + 1] = descriptor
		end
	end
	assert(#descriptors == 1, "one exact original Reader descriptor must be observed")
	return descriptors[1]
end

--- Journals actual reports before a bitmap query may flush pending key rows.
local function journal_output()
	assert(output_owner and Reader.source_owner_current(output_owner) == true, "original output observer must remain current")
	local invalid
	Reader.drain(function(event)
		local genuine
		if event.type == 1 then
			local receipt = Reader.capture_event(event, OUTPUT_SLOT)
			local view = receipt and Reader.event_view(receipt)
			genuine = view and view.origin == "native-evdev" and view.source == output_node
		elseif event.type == 0 and event.code == 0 and event.value == 0 then
			-- Reader issues KEY receipts only. SYN_REPORT still comes from its
			-- original native read/decoder on this exact current grabbed lifetime.
			genuine = Reader.source_owner_current(output_owner) == true
		end
		if genuine ~= true then
			invalid = true; return
		end
		journal[#journal + 1] = { event.type, event.code, event.value }
	end, OUTPUT_SLOT)
	-- Reader.drain protects its handler with pcall. Publish a rejected row outside
	-- that boundary so an unexpected report cannot silently disappear.
	assert(not invalid, "each observed KEY/SYN row requires genuine original native transport")
end

--- Captures a real native bitmap immediately after journaling queued output.
--- @return table
local function held_bitmap()
	journal_output()
	local receipt = assert(Reader.capture_pressed_keys(OUTPUT_SLOT), "real output key bitmap receipt")
	local view = assert(Reader.pressed_keys_view(receipt))
	assert(view.origin == "native-evdev", "bitmap must originate from actual evdev")
	return view.down
end

--- Records the finite lifetime adversary only after the genuine Shift ACK.
--- @param code integer
--- @param value integer
local function observe_ack(code, value)
	if not Reader or not output_owner then return end
	if ack_control and code == 42 and value == 1 then
		ack_control = false
		local target = scenario == "manager-replace-frame-original-source" and sources[1] or sources[2]
		local slot = "keyboard:" .. target.node
		adversary = { old = assert(Reader.capture_source_owner(slot)), target = target, acted = false }
		local descriptor = descriptor_for(target.node)
		assert(Reader.close(slot) == true, "actual original source descriptor close")
		if scenario ~= "manager-omit-other-original-source" then
			assert(Reader.open(target.node, slot) == true, "actual successor descriptor open")
			-- Keep cleanup authority as soon as open succeeds, before a failed grab.
			local cleanup = assert(Reader.capture_source_owner(slot))
			successors[#successors + 1] = cleanup
			assert(Reader.grab(slot) == true, "actual successor exclusive grab")
			adversary.successor = assert(Reader.capture_source_owner(slot))
			successors[#successors + 1] = adversary.successor
			adversary.same_fd = descriptor_for(target.node) == descriptor
		end
		adversary.acted = true
	end
	if code == 30 and value == 1 and scenario == "manager-saved-pair-shift-repeat-up" then
		down_bitmap = held_bitmap()
	elseif code == 42 and value == 0 then
		-- A refused source stops the real daemon on its next idle turn. Capture
		-- the native inverse bitmap before production destroys its own output.
		inverse_bitmap = held_bitmap()
	end
end

-- Install transport observation before production Hook.start seals the ports.
-- The real producer is called first; observation never invents an ACK or issuer.
Writer.transaction_emit = function(token, code, value)
	local accepted = original_emit(token, code, value)
	if accepted == true then
		local observed, reason = pcall(observe_ack, code, value)
		if not observed then callback_failure = tostring(reason) end
	end
	return accepted
end
Writer.acquire_transaction = function(...)
	local token = original_acquire(...)
	if token ~= nil then prefix_reservations = prefix_reservations + 1 end
	return token
end





-- ============================================
-- ============================================
-- ======= 2/ Production Loop Scenarios =======
-- ============================================
-- ============================================

--- Waits by yielding to the actual production event loop, without pumping Hook.
--- @param predicate function
--- @return any
local function await(predicate)
	local deadline = uv.hrtime() / 1000000 + stage_timeout_ms
	repeat
		if callback_failure then error(callback_failure, 0) end
		local found = predicate()
		if found then return found end
		coroutine.yield()
	until uv.hrtime() / 1000000 >= deadline
	error("finite native Manager scenario observation timed out", 0)
end

--- Compares strict dense report arrays against the separately authored literal.
--- @param rows table
--- @param literal table
--- @return boolean
local function rows_match(rows, literal)
	if #rows ~= #literal then return false end
	for index, row in ipairs(rows) do
		if #row ~= 3 then return false end
		for field = 1, 3 do if row[field] ~= literal[index][field] then return false end end
	end
	return true
end

--- Consumes a full independent segment and rejects any additional native row.
--- @param segment string
--- @param literal table
--- @return boolean
local function consume_rows(segment, literal)
	await(function() journal_output(); return #journal >= #literal end)
	local deadline = uv.hrtime() / 1000000 + 100
	repeat journal_output(); coroutine.yield() until uv.hrtime() / 1000000 >= deadline
	local exact = rows_match(journal, literal)
	if #journal ~= #literal then extra_rows = true end
	corpus_rows[segment] = journal
	journal = {}
	return exact
end

--- Emits exactly one native input edge and lets only the daemon dispatch it.
--- @param code integer
--- @param value integer
local function edge(code, value)
	assert(sources[1].writer.emit_owned(sources[1].cap, code, value) == true, "genuine source KEY/SYN acknowledgement")
	coroutine.yield()
end

--- Captures the real production-export census without replacing any authority API.
local function capture_ports()
	for _, entry in ipairs({
		{ Hook, { "capture_input_owner", "input_owner_current", "arm_one_shot", "set_remapper", "stop", "emergency_stop", "key_text" } },
		{ Reader, { "capture_event", "event_view", "event_current", "source_current", "capture_source_owner", "source_owner_current", "retire_source", "open", "close", "grab", "ungrab", "use_ffi_backend", "_set_backend", "_reset_backend", "read_event", "drain" } },
	}) do
		for _, name in ipairs(entry[2]) do
			port_census[#port_census + 1] = { receiver = entry[1], name = name, original = assert(rawget(entry[1], name)) }
		end
	end
end

--- Requires production bootstrap and authentic watchdog source reconciliation.
local function run_scenario()
	Hook = assert(package.loaded["adapters.keyboard_hook"])
	Reader = assert(package.loaded["adapters.evdev_reader"])
	Manager = assert(package.loaded["platform.remap.tap_hold_manager"])
	Layout = assert(package.loaded["adapters.keyboard_layout"])
	Combinations = assert(package.loaded["modules.shortcuts.key_combinations"])
	capture_ports()
	await(function()
		if not Hook.isRunning() or not Manager.is_active() then return nil end
		for _, source in ipairs(sources) do
			local lease = Reader.capture_source_owner("keyboard:" .. source.node)
			if not lease or Reader.source_owner_current(lease) ~= true then return nil end
			source.owner = lease
		end
		return Layout.is_ready() == true
	end)
	check(Manager.is_active() and Combinations.get_action("caps_lock_then_tab") == "one_shot_shift"
		and Combinations.has_bindings() == true, "production Manager consumes the genuine saved ordered pair")
	local genuine = true
	for _, source in ipairs(sources) do
		genuine = genuine and Reader.source_owner_current(source.owner) == true
		local slot = "manager-grab-probe:" .. source.name
		assert(Reader.open(source.node, slot) == true)
		local probe = assert(Reader.capture_source_owner(slot))
		genuine = genuine and Reader.grab(slot) == false
		assert(Reader.retire_source(probe) == true)
	end
	check(genuine, "two real original native source lifetimes and exclusive grabs are current")
	output_node = assert(node_for(Names.VIRTUAL_KEYBOARD))
	output_cap = assert(Writer.capture_output())
	assert(Reader.open(output_node, OUTPUT_SLOT) == true)
	output_owner = assert(Reader.capture_source_owner(OUTPUT_SLOT))
	assert(Reader.grab(OUTPUT_SLOT) == true)
	output_owner = assert(Reader.capture_source_owner(OUTPUT_SLOT))
	local plan = Layout.plan("A")
	check(Hook.key_text(30) == "a" and type(plan) == "table" and #plan == 1
		and plan[1].keycode == 30 and #plan[1].mods == 1 and plan[1].mods[1] == "shift",
		"actual selected libxkbcommon family maps a and Shift plus KEY_A")
	journal_output(); assert(#journal == 0, "native output must be clear before scenario input")
	local acquired_before = prefix_reservations
	for _, input in ipairs(corpus.pair_source_edges) do edge(input[1], input[2]) end
	check(consume_rows("pair", corpus.pair_prefix_rows), "exact native Ctrl hold lift restore and final release prefix")
	check(prefix_reservations - acquired_before == 4, "logical arm adds no extra native output reservation beyond the four pair frames")
	if scenario ~= "manager-saved-pair-shift-repeat-up" then ack_control = true end
	edge(30, 1)
	if scenario == "manager-saved-pair-shift-repeat-up" then
		await(function() return down_bitmap ~= nil end)
		edge(30, 2); edge(30, 0)
		check(consume_rows("character", expected.character_rows)
			and table.concat(down_bitmap, " ") == "30 42", "real shifted character DOWN repeat UP and inverse have exact wire order and down bitmap")
		edge(30, 1); edge(30, 0)
		check(consume_rows("following", expected.following_rows), "following native ordinary A remains unshifted")
		check(not extra_rows, "every positive native segment rejects extra KEY or SYN rows")
		completed = 1
	else
		-- The genuine Hook refusal causes production shutdown before this timer's
		-- next turn. Independent comparisons continue only after dofile returns.
		coroutine.yield()
	end
end

--- Stops only the fixture timer, then lets the actual daemon clean its own owners.
local function stop_fixture()
	if fixture_timer and not uv.is_closing(fixture_timer) then
		assert(uv.timer_stop(fixture_timer) == 0, "fixture timer stop acknowledgement")
		uv.close(fixture_timer)
	end
	local loop = package.loaded["adapters.event_loop"]
	if loop then loop.stop() end
end

--- Publishes failed timer work rather than letting luv swallow a callback error.
local function tick_fixture()
	if not task then task = coroutine.create(run_scenario) end
	local resumed, reason = coroutine.resume(task)
	if not resumed then task_failure = tostring(reason); stop_fixture()
	elseif coroutine.status(task) == "dead" then stop_fixture() end
end





-- ==============================================
-- ==============================================
-- ======= 3/ Cold Boot And Exact Cleanup =======
-- ==============================================
-- ==============================================

if not Writer.use_ffi_backend() or not Writer.is_available() then
	io.stderr:write("ENVIRONMENT: actual native uinput and input devices are mandatory; no Manager kernel scenario executed\n")
	os.exit(2)
end
check(package.loaded["adapters.evdev_reader"] == nil and package.loaded["adapters.keyboard_hook"] == nil
	and package.loaded["platform.remap.tap_hold_manager"] == nil and package.loaded["modules.keylogger.keylogger"] == nil,
	"actual production daemon owns the original cold keylogger Manager Hook Reader imports")

local prepared, prepare_failure = xpcall(function()
	assert(node_for(Names.VIRTUAL_KEYBOARD) == nil, "production output name must be absent before boot")
	local token = assert(os.getenv("TMPDIR")):match("([^/]+)$")
	create_source("Ergopti Manager supplement A " .. token)
	create_source("Ergopti Manager supplement B " .. token)
	native_origins = original_classify({ sources[1].node, sources[2].node })
	assert(#native_origins == 2 and native_origins[1].physical == false and native_origins[2].physical == false,
		"genuine physical discovery must reject both exact virtual sources")
	Finder.find_keyboard = function() return sources[1].node end
	Finder.find_devices = function() return { sources[1].node, sources[2].node }, {} end
	Finder.find_pointers = function() return {} end
	Finder.find_pointer = function() return nil end
	Finder.physical_sources = function(paths)
		local result = {}
		for _, path in ipairs(paths) do
			local original
			for _, entry in ipairs(native_origins) do if entry.path == path then original = entry end end
			assert(original, "controlled virtual census cannot admit an unrelated source")
			result[#result + 1] = { path = path, sysfs = original.sysfs, name = original.name, physical = true }
		end
		return result
	end
	local Paths = require("infra.config_paths")
	local Files = require("adapters.file_system")
	local Shell = require("adapters.shell_runner")
	assert(Shell.run("mkdir -p " .. Shell.quote(Paths.config())) == true, "private canonical configuration directory")
	assert(Files.write(Paths.config("config.toml"), '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "one_shot_shift"\n') == true)
	assert(Files.write(Paths.config("tap_hold.toml"), '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
		.. '[tap_hold.keys.caps_lock]\nenabled = true\ntap_action = "enter"\nhold_modifier = "ctrl"\ntime_activation_seconds = 0.3\n') == true)
	assert(package.loaded["adapters.evdev_reader"] == nil and package.loaded["platform.remap.tap_hold_manager"] == nil,
		"fixture preparation cannot preload production Reader or Manager")
	fixture_timer = assert(uv.new_timer())
	assert(uv.timer_start(fixture_timer, 5, 5, tick_fixture) == 0, "real finite fixture timer admission")
	arg = { [0] = "ergopti_hotstrings.lua", "--verbose", "--config", "tests/e2e/fixtures/daemon_keys.toml" }
	-- Actual imports/init/watchdog/capture publication execute inside this file.
	assert(loadfile("ergopti_hotstrings.lua"))()
end, debug.traceback)

if fixture_timer and not uv.is_closing(fixture_timer) then
	local stopped = uv.timer_stop(fixture_timer)
	if stopped ~= 0 then task_failure = "fixture timer retirement refused" end
	uv.close(fixture_timer)
end
if not prepared then task_failure = tostring(prepare_failure) end
if callback_failure then task_failure = callback_failure end
if task_failure then failures = failures + 1; print("  FAIL " .. task_failure) end

if scenario ~= "manager-saved-pair-shift-repeat-up" and Reader and output_owner and adversary then
	local finalized, final_failure = xpcall(function()
		journal_output()
		corpus_rows.character = journal; journal = {}
		check(adversary.acted == true and ack_control == false, "finite native source adversary acted only after the real Shift DOWN ACK")
		check(rows_match(corpus_rows.character, expected.character_rows), "source refusal emits the exact original Shift inverse and no character DOWN")
		local slot = "keyboard:" .. adversary.target.node
		if adversary.successor then
			check(adversary.same_fd == true and not Reader.source_owner_current(adversary.old)
				and Reader.source_owner_current(adversary.successor) == true, "same actual FD carries a distinct current successor lifetime")
			check(Reader.retire_source(adversary.old) == true and Reader.source_owner_current(adversary.successor) == true,
				"old exact source cleanup preserves the actual successor and its grab")
		else
			check(not Reader.is_open(slot) and not Reader.source_owner_current(adversary.old), "omitted original source remains physically closed and revoked")
			check(Reader.retire_source(adversary.old) == true and not Reader.is_open(slot), "old exact cleanup cannot reopen the omitted source")
		end
		completed = 1
	end, debug.traceback)
	if not finalized then failures = failures + 1; print("  FAIL " .. tostring(final_failure)) end
end

local ports_current = #port_census == 23
for _, port in ipairs(port_census) do ports_current = ports_current and rawget(port.receiver, port.name) == port.original end
check(ports_current, "original Hook and Reader authority ports remain unchanged through genuine daemon shutdown")
check(inverse_bitmap ~= nil and #inverse_bitmap == 0, "actual final Shift UP leaves the native output bitmap empty before device destruction")

local cleanup_ok, nodes_absent = true, true
local function cleanup(callback)
	local returned, acknowledged = pcall(callback)
	cleanup_ok = cleanup_ok and returned and acknowledged == true
end
if Reader then
	for _, owner in ipairs(successors) do cleanup(function() return Reader.retire_source(owner) end) end
	if output_owner then cleanup(function() return Reader.retire_source(output_owner) end) end
	for _, source in ipairs(sources) do
		if source.owner then cleanup(function() return Reader.retire_source(source.owner) end) end
		cleanup_ok = cleanup_ok and not Reader.is_open("keyboard:" .. source.node)
	end
	cleanup_ok = cleanup_ok and not Reader.is_open(OUTPUT_SLOT) and not Reader.has_native_origin_debt()
else cleanup_ok = false end
for _, source in ipairs(sources) do
	if source.cap then cleanup(function() return source.writer.close_owned(source.cap) end) end
end
cleanup_ok = cleanup_ok and (not Hook or not Hook.isRunning()) and not Writer.has_output_debt()
	and (not output_cap or not Writer.output_current(output_cap))
check(cleanup_ok, "every exact original successor observer and Writer lifetime retires with zero native debt")
local observed, absent = pcall(initial_wait, function()
	if node_for(Names.VIRTUAL_KEYBOARD) then return nil end
	for _, source in ipairs(sources) do if node_for(source.name) then return nil end end
	return true
end)
nodes_absent = observed and absent == true
check(nodes_absent, "all exact owned source and production output kernel nodes disappear")
Finder.find_devices, Finder.find_keyboard = original_find, original_keyboard
Finder.physical_sources, Finder.find_pointers, Finder.find_pointer = original_classify, original_pointers, original_pointer
Writer.transaction_emit, Writer.acquire_transaction = original_emit, original_acquire

for _, segment in ipairs({ "pair", "character", "following" }) do
	if corpus_rows[segment] then
		print("MANAGER_NATIVE_WIRE " .. Json.encode({ scenario = scenario, segment = segment, rows = corpus_rows[segment] }))
	end
end
local planned = scenario == "manager-saved-pair-shift-repeat-up" and 13 or 14
if checks ~= planned or completed ~= 1 then
	failures = failures + 1
	print("  FAIL exact independent scenario count or completion is missing")
end
print(string.format("MANAGER_INPUT_OWNER_SCENARIO %s %d %d %d", scenario, checks, failures, completed))
os.exit((failures > 0 or not cleanup_ok or not nodes_absent) and 1 or 0)
