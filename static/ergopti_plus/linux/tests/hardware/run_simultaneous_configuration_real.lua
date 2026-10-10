--- tests/hardware/run_simultaneous_configuration_real.lua

--- ==============================================================================
--- MODULE: Saved Simultaneous Configuration Through Real Kernel Devices
--- DESCRIPTION:
--- Runs original Manager, configuration publisher and catalogue dispatch against
--- actual evdev/uinput. Virtual-source classification is CONTROLLED explicitly;
--- production physical discovery/readiness is UNPROVEN. Independent literal
--- KEY/SYN and kernel bitmap expectations never come from the new implementation.
--- Run through the existing run_native_subreaper.py with its unchanged 40s bound.
--- ==============================================================================

local ffi = require("ffi")
ffi.cdef([[
	int access(const char *path, int mode);
	char *mkdtemp(char *template);
	int setenv(const char *name, const char *value, int overwrite);
	int mkdir(const char *path, unsigned int mode);
	int getpid(void);
]])
if ffi.os ~= "Linux" or ffi.C.access("/dev/uinput", 6) ~= 0 or ffi.C.access("/dev/input", 5) ~= 0 then
	io.stderr:write("ENVIRONMENT: Linux LuaJIT FFI, writable /dev/uinput and readable /dev/input are mandatory\n")
	os.exit(2)
end

local template = (os.getenv("TMPDIR") or "/tmp") .. "/ergopti-simultaneous-XXXXXX"
local buffer = ffi.new("char[?]", #template + 1, template)
local created = ffi.C.mkdtemp(buffer)
assert(created ~= nil, "exclusive private native configuration namespace")
local namespace = ffi.string(created)
for _, row in ipairs({ {"HOME", namespace}, {"XDG_CONFIG_HOME", namespace .. "/.config"},
	{"XDG_DATA_HOME", namespace .. "/.data"}, {"XDG_STATE_HOME", namespace .. "/.state"},
	{"XDG_CACHE_HOME", namespace .. "/.cache"} }) do
	assert(ffi.C.setenv(row[1], row[2], 1) == 0, "owned fixture environment must be explicit")
end
for _, directory in ipairs({".config", ".config/ergopti", ".data", ".state", ".cache"}) do
	assert(ffi.C.mkdir(namespace .. "/" .. directory, 448) == 0, "private fixture directory creation")
end

-- Cold Hook pins the genuine Reader before observation/classification callbacks.
local Hook = require("adapters.keyboard_hook")
local Reader = require("adapters.evdev_reader")
local Writer = require("adapters.uinput_writer")
local Broker = require("adapters.modifier_broker")
local Finder = require("modules.hotstrings.device_finder")
local Names = require("infra.device_names")
local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")
local Manager = require("platform.remap.tap_hold_manager")
local Combinations = require("modules.shortcuts.key_combinations")
local Gestures = require("modules.gestures.manager")
local ScriptActions = require("modules.shortcuts.script_actions")
local Scope = require("infra.key_combinations_scope")
local Paths = require("infra.config_paths")
local SharedPaths = require("infra.paths")
local Files = require("adapters.file_system")
local Codec = require("toml_codec")
local Hotstrings = require("modules.hotstrings.engine")
local Monotonic = require("infra.monotonic")

local source_name = "Ergopti simultaneous controlled virtual source " .. tostring(ffi.C.getpid())
local output_slot = "simultaneous-native-output"
local original_find, original_classify, original_read = Finder.find_devices, Finder.physical_sources, Reader.read_event
local source, output, observer, source_owner, broker, script, hotstrings
local journal, facts = {}, {}
local checks, failures, completed = 0, 0, {}
local manager_initialized, output_close_attempted, source_close_attempted = false, false, false
local config_path = Paths.config("config.toml")
local tap_path = Paths.config("tap_hold.toml")
local COPY = "1:29:1 0:0:0 1:46:1 0:0:0 1:46:0 0:0:0 1:29:0 0:0:0"
local PASSTHROUGH = "1:58:1 0:0:0 1:15:1 0:0:0 1:15:0 0:0:0 1:58:0 0:0:0"

--- Records an assertion without replacing a native acknowledgement.
--- @param value boolean
--- @param label string
local function check(value, label)
	checks = checks + 1
	if value then print("  ok   " .. label)
	else failures = failures + 1; print("  FAIL " .. label) end
	return value == true
end

--- Uses the existing native publication bound, keeping Hook and output drained.
--- @param predicate function
--- @return any|nil observed
local function await(predicate)
	local deadline = Monotonic.now_ms() + 5000
	repeat
		local observed = predicate()
		if observed then return observed end
		os.execute("sleep 0.01")
	until Monotonic.now_ms() >= deadline
	return nil
end

--- Resolves only an exact owned virtual name; duplicates refuse admission.
--- @param name string
--- @return string|nil node
local function node_for(name)
	local file = assert(io.open("/proc/bus/input/devices", "r"))
	local bytes = file:read("*a"); assert(file:close())
	local found
	for _, device in ipairs(Finder.parse_devices(bytes)) do
		if device.name == name then
			for _, handler in ipairs(device.handlers) do
				if handler:match("^event%d+$") then
					assert(found == nil, "duplicate exact owned virtual source")
					found = "/dev/input/" .. handler
				end
			end
		end
	end
	return found
end

--- Journals genuine evdev output before querying its actual kernel bitmap.
local function drain()
	if Hook.isRunning() then Hook.pump() end
	if observer then Reader.drain(function(event) journal[#journal + 1] = event end, output_slot) end
end

--- Checks an independently handwritten full wire order and final held bitmap.
--- @param literal string
--- @param count integer
--- @param label string
local function expect(literal, count, label)
	assert(await(function() drain(); return #journal >= count end), "bounded native output observation")
	local encoded = {}
	for _, row in ipairs(journal) do encoded[#encoded + 1] = string.format("%d:%d:%d", row.type, row.code, row.value) end
	check(#journal == count and table.concat(encoded, " ") == literal, label)
	journal = {}
	check(not Reader.wait_readable(100, output_slot), label .. " has no extra native row")
	local pressed = assert(Reader.capture_pressed_keys(output_slot))
	local view = assert(Reader.pressed_keys_view(pressed))
	check(view.origin == "native-evdev" and #view.down == 0, label .. " clears actual kernel bitmap")
end

--- Sends one native burst; no scheduling sleep invents a simultaneous clock.
--- @param first integer
--- @param second integer
local function burst(first, second)
	local before = #facts
	for _, row in ipairs({{first,1},{second,1},{second,0},{first,0}}) do
		assert(source.writer.emit_owned(source.cap, row[1], row[2]), "actual source KEY/SYN acknowledgement")
	end
	assert(await(function() drain(); return #facts >= before + 4 end), "original Hook reads all four actual source edges")
	for index, row in ipairs({{first,1},{second,1},{second,0},{first,0}}) do
		local fact = facts[before + index]
		check(fact.origin == "native-evdev" and fact.source == source.node and fact.code == row[1] and fact.value == row[2],
			"original native receipt binds the exact burst edge")
	end
end

--- Captures the same original file/parameter currency the native menu uses.
--- @return table source
local function edit_source()
	local receipt = assert(Combinations.capture_edit_source(), "original Manager-owned canonical edit source")
	local document = assert(Codec.decode(receipt.content))
	local parameters = assert(Gestures.capture_parameter_source_guard(document, function() return true end))
	local guard = receipt.guard
	receipt.guard = function() return guard() == true and parameters() == true end
	assert(receipt.guard(), "original source and parameter owners are current")
	return receipt
end

--- Runs saved startup, symmetry, real publication/reload and real pause policy.
local function run()
	assert(type(Combinations.get_chord) == "function" and type(Manager.managed_pair_options_current) == "function",
		"reviewed simultaneous Manager/source-owner software bootstrap is mandatory")
	assert(Files.write(config_path, '[category_enabled]\nkey_combinations = true\n[shortcuts.key_combination_taps]\n'
		.. 'tab_then_caps_lock = "copy"\n[mod_combos]\nenabled = true\nsymmetric = true\nsimultaneous_threshold_ms = 87\n'
		.. '[mod_combos.config.tab_then_caps_lock]\ncombo = "copy"\n[mod_combos.config.future_keep]\ncombo = "unknown-kept"\n'))
	assert(Files.write(tap_path, '[tap_hold]\nenabled = false\ninherit_defaults = false\n'))
	assert(Writer.use_ffi_backend() and Reader.use_ffi_backend(), "original native transport is mandatory")
	assert(node_for(source_name) == nil and node_for(Names.VIRTUAL_KEYBOARD) == nil, "owned virtual names must be absent")
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = source_name
	local loaded, source_writer = pcall(function() return assert(loadfile("adapters/uinput_writer.lua"))() end)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, source_writer)
	source = {writer=source_writer}
	assert(source.writer.use_ffi_backend() and source.writer.open())
	source.cap = assert(source.writer.capture_output())
	source.node = assert(await(function() return node_for(source_name) end))
	local native = original_classify({source.node})
	assert(#native == 1 and native[1].path == source.node and native[1].physical == false,
		"production discovery must reject this real virtual fixture source")
	Finder.find_devices = function() return {source.node}, {} end
	Finder.physical_sources = function(paths)
		assert(#paths == 1 and paths[1] == source.node, "controlled classification admits only the exact owned virtual node")
		return {{path=source.node,sysfs=native[1].sysfs,name=native[1].name,physical=true}}
	end
	-- Observation forwards real transport; event/source/owner issuer ports retain
	-- their originals. No fixture creates an opaque native receipt or output ACK.
	Reader.read_event = function(slot)
		local event, status, reason = original_read(slot)
		if event and status == "event" and event.type == 1 and slot == "keyboard:" .. source.node then
			local receipt = assert(Reader.capture_event(event, slot))
			facts[#facts + 1] = assert(Reader.event_view(receipt))
		end
		return event, status, reason
	end
	assert(Writer.open()); output = assert(Writer.capture_output())
	local output_node = assert(await(function() return node_for(Names.VIRTUAL_KEYBOARD) end))
	assert(Reader.open(output_node, output_slot))
	observer = assert(Reader.capture_source_owner(output_slot))
	assert(Reader.grab(output_slot)); observer = assert(Reader.capture_source_owner(output_slot))
	broker = assert(Broker.attach(Writer))
	assert(Layout.refresh(), "actual X11/libxkbcommon layout must initialize")
	hotstrings = Hotstrings.new()
	script = ScriptActions.new({reset=function() hotstrings:reset() end,reload=Manager.reload,quit=Hook.stop,
		on_pause_change=function(paused)
			assert(Gestures.set_program_paused(paused)); assert(Gestures.set_window_switch_paused(paused))
			assert(Manager.set_paused(paused), "original Manager pause installation")
		end})
	Gestures.init({config_path=config_path,persist=true,enabled=false,is_paused=script.is_paused})
	assert(Manager.init({keyboard_hook=Hook,execute_action=Gestures.execute_action,
		action_names=Gestures.get_executable_action_names,on_text_injected=function() hotstrings:reset() end,
		defaults_path=SharedPaths.shared("tap_hold/defaults.toml"),user_path=tap_path}), "original saved Manager startup")
	manager_initialized = true
	Hook.start({intercept=true,requireOutputBroker=true,outputBroker=broker,onEmitRaw=Writer.emit})
	assert(Hook.isRunning() and Layout.publish_current_capture(), "actual grabbed session and current inverse publication")
	source_owner = assert(Reader.capture_source_owner("keyboard:" .. source.node))
	assert(Reader.source_owner_current(source_owner) and Combinations.get_chord("tab_then_caps_lock") == "copy")
	assert(Hook.key_text(30) == "a", "native fixture requires the actual Xvfb US keymap")

	burst(58,15); expect(COPY,8,"saved simultaneous pair dispatches the original copy action once")
	completed[#completed + 1] = "saved-copy"
	burst(15,58); expect(COPY,8,"saved symmetric reverse pair dispatches the original copy action once")
	completed[#completed + 1] = "symmetric-copy"

	assert(Scope.edit({{section="mod_combos.config.tab_then_caps_lock",key="combo",value="none"}}, script.is_paused, edit_source()),
		"original publisher clears only the known third slot")
	local before = assert(Writer.output_view(output))
	assert(Scope.copy_taps_to_chords(script.is_paused, edit_source()), "original owner copies real saved taps")
	local saved = assert(Files.read_with_status(config_path))
	local document = assert(Codec.decode(saved))
	check(document.category_enabled.key_combinations == true and document.mod_combos.enabled == true
		and document.mod_combos.symmetric == true and document.mod_combos.simultaneous_threshold_ms == 87,
		"copy preserves both masters and saved settings")
	check(document.mod_combos.config.tab_then_caps_lock.combo == "copy"
		and document.mod_combos.config.future_keep.combo == "unknown-kept", "copy persists its known slot and preserves unknown data")
	check(assert(Writer.output_view(output)).write_epoch == before.write_epoch and broker.view().busy == false,
		"configuration copy emits no native output and settles broker reservations")
	assert(Manager.reload(), "original Loader/Manager reread exact saved copied bytes")
	burst(58,15); expect(COPY,8,"reloaded copied slot dispatches through the original catalogue")
	completed[#completed + 1] = "published-reload-copy"

	script.toggle_pause()
	assert(script.is_paused() and not Manager.is_active(), "real script controller withdraws remapping")
	check(Scope.copy_taps_to_chords(script.is_paused) == false and Files.read_with_status(config_path) == saved,
		"paused original policy refuses copy and preserves exact saved bytes")
	burst(58,15); expect(PASSTHROUGH,8,"paused session forwards the original edges without business copy")
	script.toggle_pause(); assert(not script.is_paused() and Manager.is_active())
	burst(58,15); expect(COPY,8,"real resume restores the saved simultaneous route")
	check(Scope.retry_restore() and Combinations.configuration_pending() == false and broker.view().busy == false,
		"original configuration and delivery owners have no unsettled lease")
	completed[#completed + 1] = "pause-resume"
end

print("\nsimultaneous configuration: actual kernel; CONTROLLED virtual classification; physical UNPROVEN")
local ok, error_detail = xpcall(run, debug.traceback)
if not ok then check(false, tostring(error_detail)) end
local function cleanup(callback, label)
	local called, settled = pcall(callback)
	check(called and settled == true, label)
end
if manager_initialized then cleanup(function() return Manager.set_paused(true) end, "original Manager withdrawal") end
cleanup(function() return Scope.retry_restore() end, "original publisher retirement")
cleanup(function() return Gestures.stop_programs() and Gestures.stop_window_switches() end, "original action owners settle")
cleanup(function() Hook.stop(); return not Hook.isRunning() end, "original Hook and source-grab retirement")
if source_owner then check(not Reader.source_owner_current(source_owner), "original source lifetime is revoked") end
if observer then cleanup(function() return Reader.retire_source(observer) end, "exact native output observer retirement") end
if output and not output_close_attempted then
	output_close_attempted = true
	cleanup(function()
		if broker and broker.view().busy then return broker.retire() end
		return Writer.close_owned(output)
	end, "exact native output destroy/close acknowledgement")
end
if broker then check(not broker.has_debt() and broker.output_retired(), "original broker observes acknowledged output retirement") end
Broker.detach(Writer)
Finder.find_devices, Finder.physical_sources, Reader.read_event = original_find, original_classify, original_read
if source and source.cap and not source_close_attempted then
	source_close_attempted = true; cleanup(function() return source.writer.close_owned(source.cap) end, "exact native source destroy/close acknowledgement")
end
cleanup(function() Capture.clear(); return not Capture.is_ready() end, "layout readiness cleared without claiming native destroy")
check(not Reader.is_open(output_slot) and (not source or not Reader.is_open("keyboard:" .. source.node)), "owned native descriptors are closed")
check(not Reader.has_native_origin_debt() and not Writer.has_output_debt(), "original Reader/Writer have no retained native debt")
cleanup(function() return await(function() return not node_for(source_name) and not node_for(Names.VIRTUAL_KEYBOARD) end) == true end,
	"both exact owned kernel nodes disappear")
check(table.concat(completed," ") == "saved-copy symmetric-copy published-reload-copy pause-resume", "all four mandatory supplemental scenarios completed")
print("RETAINED private saved-source evidence: " .. namespace)
print(string.format("SIMULTANEOUS_CONFIGURATION_KERNEL %d %d %d CONTROLLED_VIRTUAL PHYSICAL_UNPROVEN",checks-failures,failures,#completed))
os.exit(failures > 0 and 1 or 0)
