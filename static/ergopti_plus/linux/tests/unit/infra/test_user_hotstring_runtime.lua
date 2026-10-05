--- tests/unit/infra/test_user_hotstring_runtime.lua

--- ==============================================================================
--- MODULE: Programmable Linux Runtime Tests
--- DESCRIPTION:
--- Runs source callbacks through the real matcher, daemon input/privacy owners
--- and libuv scheduler. Only filesystem contents and native peer replies are faked.
--- ==============================================================================

local helpers = require("tests.helpers")
local Atspi = require("adapters.atspi_focus")
local Detector = require("adapters.secure_field_detector")
local FocusGuard = require("modules.keylogger.focus_guard")
local CaptureGate = require("infra.input_capture_gate")
local Engine = require("modules.hotstrings.engine")
local Runtime = require("infra.user_hotstring_runtime")
local FileSystem = require("adapters.file_system")
local Timer = require("adapters.timer_scheduler")
local Injector = require("modules.hotstrings.injector")
local uv = require("luv")
local NativeConfigPaths = require("infra.config_paths")

-- Canonical source discovery also loads the installed-layout registry and its
-- updater/storage readers. They capture paths at require time, so fixture paths
-- and every such module owner must be scoped together, including false/nil caches.
local DISCOVERY_OWNERS = { "adapters.storage", "modules.updater.manager", "modules.keymap.layout_registry", "infra.i18n" }

local function drain()
	for _ = 1, 16 do
		uv.run("nowait")
		if Timer.activeCount() == 0 then return end
	end
	error("programmable libuv callback did not settle")
end

local function with_runtime(body)
	local owned = { "modules.dynamic_hotstrings.user_code", "infra.config_paths", "adapters.notifier" }
	for _, name in ipairs(DISCOVERY_OWNERS) do owned[#owned + 1] = name end
	local previous = {}
	for _, path in ipairs(owned) do previous[path] = package.loaded[path]; package.loaded[path] = nil end
	local read = FileSystem.read_with_status
	local write = FileSystem.write_if_unchanged
	local old_fixture = rawget(_G, "__LINUX_USER_HOTSTRING_FIXTURE")
	local f = { calls = 0, factories = 0, result = "0", path = "/org/a11y/atspi/accessible/7",
		app = "editor", title = "Document", outputs = {}, magic = "★", now = 1000, enabled = true }
	_G.__LINUX_USER_HOTSTRING_FIXTURE = f
	package.loaded["infra.config_paths"] = setmetatable({ get_config_dir = function() return "/owned" end },
		{ __index = NativeConfigPaths })
	package.loaded["adapters.notifier"] = { send = function() f.notified = true; return true end }
	f.content = [[return function(api)
		local f=__LINUX_USER_HOTSTRING_FIXTURE
		f.factories=f.factories+1
		if f.factory_mutate then f.factory_mutate() end
		return {{id="custom",suffix="@é",preview="Static",callback=function(ctx)
			f.calls=f.calls+1
			if f.mutate then f.mutate(ctx) end
			return f.result
		end}}
	end]]
	FileSystem.read_with_status = function(path)
		if path == "/owned/personal_dynamic_hotstrings.lua" then
			if f.read_hook then f.read_hook() end
			if f.unreadable then return nil, "error", "fixture unreadable" end
			if f.absent then return nil, "absent" end
			return f.content, "ok"
		end
		return read(path)
	end
	Atspi._set_backend_for_test(nil)
	Atspi._set_command_runner_for_test(function(command)
		helpers.assert_contains(command, "timeout -s KILL")
		if f.probe_hook then f.probe_hook() end
		return true, "FOCUS:" .. require("json").encode({ role = f.secure and 40 or 61, name = "Document",
			attributes = {}, native_bus_name = ":1.42", native_object_path = f.path, active_scope = true })
	end)
	Detector._set_probe_for_test(nil)
	local engine = Engine.new()
	local guard = FocusGuard.new({ detector = Detector, keylogger = { set_secure_field = function() end },
		now_ms = function() return f.now end, reset_text = function() engine:reset() end })
	local capture = CaptureGate.new()
	f.guard, f.capture_gate, f.engine = guard, capture, engine
	helpers.assert_true(guard.prime())
	local injector_port = { _is_injecting = Injector._is_injecting,
			_begin_injection = Injector._begin_injection, _end_injection = Injector._end_injection,
			inject = function(deletes, text, private)
				helpers.assert_true(Injector._is_injecting(), "the production input queue owns output")
				if f.output_hook then f.output_hook() end
				if f.output_throws then error("fixture output failure") end
				if f.output_refused then return { ok = false } end
				f.outputs[#f.outputs + 1] = { deletes = deletes, text = text, private = private }
				return { ok = true }
			end }
	f.injector_port = injector_port
	local native = Runtime.new({ engine = engine, injector = injector_port,
		magic = { get = function() return f.magic end }, detector = Detector,
		focus_guard = guard, capture_gate = capture, dynamic = { is_enabled = function()
			if f.dynamic then return f.dynamic.is_enabled() end
			return f.enabled
		end },
		window_info = { getFocused = function() return { appId = f.app, windowTitle = f.title } end },
		keylogger = { is_password_app = function(app) return app == "bitwarden" end,
			is_private_window = function(title) return title == "Private browsing" end },
		paused = function() return f.paused == true end,
		replay_input = function(queued)
			helpers.assert_eq(Injector._is_injecting(), false)
			helpers.assert_eq(engine:current_buffer(), "", "reset must precede replay")
			f.replayed = queued
			for _, event in ipairs(queued) do
				f.native.observe_input()
				engine:on_char(event.char, { typed_at_ms = f.now })
			end
			return true
		end })
	f.native = native
	local User = require("modules.dynamic_hotstrings.user_code")
	f.User = User
	helpers.assert_true(User.start(native))
	helpers.assert_eq(f.factories, 0, "closed boot never evaluates a user factory")
	helpers.assert_true(User.set_time_activation(0.5))
	helpers.assert_true(User.set_enabled(true))
	function f.type_suffix(gap)
		for _, ch in ipairs({ "@", "é", "★" }) do
			native.observe_input()
			engine:on_char(ch, { typed_at_ms = f.now })
			f.now = f.now + (gap or 10)
		end
	end
	local ok, problem = xpcall(function() body(f) end, debug.traceback)
	pcall(User.stop)
	Injector._end_injection()
	drain()
	pcall(User.stop)
	FileSystem.read_with_status = read
	FileSystem.write_if_unchanged = write
	Atspi._set_command_runner_for_test(nil)
	for _, path in ipairs(owned) do package.loaded[path] = previous[path] end
	_G.__LINUX_USER_HOTSTRING_FIXTURE = old_fixture
	if not ok then error(problem, 0) end
end

--- Uses the real multiphase injector with independently authored native wire replies.
--- @param f table Actual runtime and programmable owner fixture.
--- @param body function Scenario observing native output phases.
local function with_native_injector(f, body)
	local Layout = require("adapters.keyboard_layout")
	local Capture = require("adapters.xkb_capture")
	local ready, plan, caps = Layout.is_ready, Layout.plan, Capture.caps_locked
	local emitted = {}
	Layout.is_ready = function() return true end
	Layout.plan = function(text)
		if f.clipboard then return nil, "fixture clipboard-only character" end
		helpers.assert_eq(text, "0")
		return { { keycode = 11, mods = {} } }
	end
	Capture.caps_locked = function() return false end
	Injector._set_uinput({ is_open = function() return true end,
		emit = function(code, value)
			emitted[#emitted + 1] = { code = code, value = value }
			if f.native_emit_hook then f.native_emit_hook(code, value) end
			return true
		end })
	Injector._set_nanosleep_for_test(function()
		if f.phase_mutate then f.phase_mutate() end
	end)
	f.injector_port.inject = function(...)
		local result = Injector.inject(...)
		f.delivery = result
		return result
	end
	local ok, problem = xpcall(function() body(emitted) end, debug.traceback)
	Injector._set_uinput(nil); Injector._set_nanosleep_for_test(nil)
	Layout.is_ready, Layout.plan, Capture.caps_locked = ready, plan, caps
	if not ok then error(problem, 0) end
end

--- Runs actual global and dynamic scope owners around the native callback fixture.
local function with_configuration_scope(f, body)
	local modules = { "infra.hotstrings_scope", "infra.dynamic_hotstrings_scope", "modules.dynamic_hotstrings.manager",
		"modules.dynamic_hotstrings.prefix_rules", "dynamic_hotstrings", "modules.hotstrings.hotstrings_config",
		"modules.hotstrings.loader", "infra.hotstring_preferences", "modules.hotstrings.repeat_key",
		"modules.hotstrings.magic_key", "modules.hotstrings.terminator_settings", "modules.hotstrings.preview_settings" }
	for _, name in ipairs(DISCOVERY_OWNERS) do modules[#modules + 1] = name end
	local previous = {}
	for _, name in ipairs(modules) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local paths = package.loaded["infra.config_paths"]
	local directory = os.tmpname(); os.remove(directory)
	assert(os.execute("mkdir -p '" .. directory .. "'"))
	local config_path = directory .. "/config.toml"
	local source = '[hotstrings]\ntrigger_char="★"\n[hotstrings.dynamic]\nenabled=true\n'
		.. '[hotstrings.dynamic.user_code]\nenabled=true\ntime_activation_seconds=0.125\nneighbor="kept"\n'
		.. '[other]\nuntouched="foreign"\n'
	local file = assert(io.open(config_path, "w")); file:write(source); file:close()
	local ok, problem = xpcall(function()
		package.loaded["infra.config_paths"] = setmetatable({ get_config_dir = function() return "/owned" end,
			config = function(relative) return relative and directory .. "/" .. relative or directory end,
			home = function() return directory end, config_home = function() return directory end,
			data_home = function() return directory end }, { __index = NativeConfigPaths })
		package.loaded["modules.hotstrings.loader"] = { find_toml_files = function() return {} end,
			list_subdirs = function() return {} end, read_file = function() return nil end,
			load_catalogue = function() return { committed = true, errors = 0, categories = {}, mappings = {} } end }
		local Preferences = require("infra.hotstring_preferences")
		helpers.assert_true(Preferences.refresh())
		local Dynamic = require("modules.dynamic_hotstrings.manager")
		if f.zero_builtin then
			-- A refusing builtin registrar is the availability fault under test;
			-- the manager still derives its actual count from the real rule store.
			local builtin = require("dynamic_hotstrings")
			builtin.register_date_rules = function() builtin.reset_rules(); return false end
		end
		helpers.assert_true(Dynamic.init({ trigger_char = "★", personal_info_path = directory .. "/personal_info.toml" }))
		f.dynamic = Dynamic
		local Config = require("modules.hotstrings.hotstrings_config")
		helpers.assert_true(Config.init(f.engine, directory))
		local _, committed = Config.load_all(); helpers.assert_true(committed)
		local Repeat = require("modules.hotstrings.repeat_key")
		local Terminators = require("modules.hotstrings.terminator_settings")
		helpers.assert_true(Terminators.load())
		local scope = require("infra.hotstrings_scope").new({ path = config_path, backup_suffix = ".scope-test.bak",
			is_paused = function() return false end, config = Config, preferences = Preferences, dynamic = Dynamic,
			repeat_key = Repeat, magic_key = require("modules.hotstrings.magic_key"), terminators = Terminators,
			preview_settings = require("modules.hotstrings.preview_settings") })
		local dynamic_scope = require("infra.dynamic_hotstrings_scope").new({ path = config_path,
			backup_path = config_path .. ".dynamic-test.bak", config = Config, preferences = Preferences, dynamic = Dynamic })
		body({ scope = scope, dynamic_scope = dynamic_scope, Dynamic = Dynamic, path = config_path,
			original = source, Preferences = Preferences, Config = Config })
	end, debug.traceback)
	f.dynamic = nil
	package.loaded["infra.config_paths"] = paths
	for _, name in ipairs(modules) do package.loaded[name] = previous[name] end
	os.execute("rm -rf '" .. directory .. "'")
	if not ok then error(problem, 0) end
end

helpers.describe("programmable native Linux runtime", function()
	helpers.it("(user-hotstrings-native) admits the actual installed-source storage reader through its complete private path surface", function()
		local original = {}
		for _, name in ipairs(DISCOVERY_OWNERS) do original[name] = package.loaded[name] end
		with_runtime(function(f)
			with_configuration_scope(f, function(c)
				local paths = require("infra.config_paths")
				helpers.assert_eq(paths.config_home(), c.path:match("^(.*)/[^/]+$"))
				local storage = require("adapters.storage")
				helpers.assert_eq(type(storage), "table", "real discovery must never poison the LuaJIT require cache")
				helpers.assert_eq(type(storage.get), "function")
				helpers.assert_eq(type(require("modules.updater.manager").installed_channel), "function")
				helpers.assert_eq(type(require("modules.keymap.layout_registry").settings), "function")
				helpers.assert_eq(require("adapters.storage"), storage, "repeated require retains the actual admitted reader")
			end)
		end)
		for _, name in ipairs(DISCOVERY_OWNERS) do helpers.assert_eq(package.loaded[name], original[name], name) end
		local ok, storage = pcall(require, "adapters.storage")
		helpers.assert_true(ok, "the next production reader must load after fixture teardown")
		helpers.assert_eq(type(storage.get), "function")
		for _, name in ipairs(DISCOVERY_OWNERS) do package.loaded[name] = original[name] end
	end)

	for _, cached in ipairs({ "absent", "false", "existing" }) do
		helpers.it("(user-hotstrings-native) restores " .. cached .. " discovery owners after canonical scope replay", function()
			local original, expected = {}, {}
			for _, name in ipairs(DISCOVERY_OWNERS) do
				original[name] = package.loaded[name]
				if cached == "false" then expected[name] = false
				elseif cached == "existing" then expected[name] = { independent_owner = name } end
				package.loaded[name] = expected[name]
			end
			local ok, problem = xpcall(function()
				with_runtime(function(f)
					local outer = {}
					for _, name in ipairs(DISCOVERY_OWNERS) do outer[name] = package.loaded[name] end
					with_configuration_scope(f, function()
						helpers.assert_eq(type(require("adapters.storage").get), "function")
					end)
					for _, name in ipairs(DISCOVERY_OWNERS) do helpers.assert_eq(package.loaded[name], outer[name], "nested owner " .. name) end
				end)
				for _, name in ipairs(DISCOVERY_OWNERS) do helpers.assert_eq(package.loaded[name], expected[name], "outer owner " .. name) end
			end, debug.traceback)
			for _, name in ipairs(DISCOVERY_OWNERS) do package.loaded[name] = original[name] end
			if not ok then error(problem, 0) end
		end)
	end

	helpers.it("(user-hotstrings-native) restores actual discovery owners when the scoped callback throws", function()
		local original = {}
		for _, name in ipairs(DISCOVERY_OWNERS) do original[name] = package.loaded[name] end
		local ok, problem = pcall(function()
			with_runtime(function(f)
				with_configuration_scope(f, function()
					helpers.assert_eq(type(require("adapters.storage").get), "function")
					error("independent callback refusal after actual source discovery")
				end)
			end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(problem), "independent callback refusal after actual source discovery")
		for _, name in ipairs(DISCOVERY_OWNERS) do helpers.assert_eq(package.loaded[name], original[name], name) end
	end)

	for _, changed in ipairs({ "source", "disable", "focus", "input" }) do
		helpers.it("(user-hotstrings-native) fences actual injector text after native deletion and interphase " .. changed, function()
			with_runtime(function(f)
				with_native_injector(f, function(emitted)
					local changed_once = false
					f.phase_mutate = function()
						if changed_once then return end
						changed_once = true
						if changed == "source" then f.content = f.content .. "\n-- changed during actual interphase delay"
						elseif changed == "disable" then f.User.set_enabled(false)
						elseif changed == "focus" then f.path = "/org/a11y/atspi/accessible/8"
						else f.native.observe_input() end
					end
					f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
					helpers.assert_true(changed_once); helpers.assert_eq(f.calls, 1)
					helpers.assert_eq(f.delivery.ok, false); helpers.assert_true(f.delivery.cleanup_ok)
					local deletes = 0
					for _, event in ipairs(emitted) do
						if event.code == 14 and event.value == 1 then deletes = deletes + 1 end
						helpers.assert_true(event.code ~= 11, "replacement cannot follow revoked admission")
					end
					helpers.assert_eq(deletes, 3)
				end)
			end)
		end)
	end
	helpers.it("(user-hotstrings-native) rechecks actual clipboard settle before paste and restores its original bytes", function()
		with_runtime(function(f)
			local Shell, Display = require("adapters.shell_runner"), require("infra.display_server")
			local old = { has = Shell.has_command, read = Shell.exec_checked, stdin = Shell.with_exact_stdin,
				run = Shell.run, wayland = Display.is_wayland, x11 = Display.is_x11 }
			local writes = {}
			Shell.has_command = function() return true end
			Shell.exec_checked = function() return true, "owned original clipboard" end
			Shell.with_exact_stdin = function(command, content)
				writes[#writes + 1] = content; return command
			end
			Shell.run = function() return true end
			Display.is_wayland, Display.is_x11 = function() return false end, function() return true end
			local ok, problem = xpcall(function()
				f.clipboard = true; f.result = "∞"
				with_native_injector(f, function(emitted)
					local sleeps = 0
					f.phase_mutate = function()
						sleeps = sleeps + 1
						if sleeps == 2 then f.content = f.content .. "\n-- changed during clipboard settle" end
					end
					f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
					helpers.assert_eq(sleeps, 2); helpers.assert_eq(f.delivery.ok, false)
					helpers.assert_true(f.delivery.cleanup_ok)
					helpers.assert_eq(writes, { "∞", "owned original clipboard" })
					for _, event in ipairs(emitted) do
						helpers.assert_true(event.code ~= 29 and event.code ~= 47, "stale paste chord must not reach native wire")
					end
				end)
			end, debug.traceback)
			Shell.has_command, Shell.exec_checked, Shell.with_exact_stdin, Shell.run = old.has, old.read, old.stdin, old.run
			Display.is_wayland, Display.is_x11 = old.wayland, old.x11
			if not ok then error(problem, 0) end
		end)
	end)
	helpers.it("(user-hotstrings-native) releases the actual output transaction's key after admission closes midstroke", function()
		with_runtime(function(f)
			with_native_injector(f, function(emitted)
				local changed_once = false
				f.native_emit_hook = function(code, value)
					if code == 14 and value == 1 and not changed_once then
						changed_once = true; f.User.set_enabled(false)
					end
				end
				f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
				helpers.assert_eq(f.delivery.ok, false); helpers.assert_true(f.delivery.cleanup_ok)
				helpers.assert_eq(emitted[1], { code = 14, value = 1 })
				helpers.assert_eq(emitted[2], { code = 14, value = 0 })
				for _, event in ipairs(emitted) do helpers.assert_true(event.code ~= 11) end
			end)
		end)
	end)
	helpers.it("(user-hotstrings-native) refuses absent enable then admits explicit creation without automatic execution", function()
		with_runtime(function(f)
			helpers.assert_true(f.User.stop()); f.absent = true
			helpers.assert_true(f.User.start(f.native)); helpers.assert_true(f.User.set_time_activation(0.5))
			helpers.assert_eq(f.User.set_enabled(true), false); helpers.assert_eq(f.User.is_enabled(), false)
			helpers.assert_true(f.notified)
			FileSystem.write_if_unchanged = function(path, content, expected)
				helpers.assert_eq(path, f.User.source_path()); helpers.assert_eq(expected.status, "absent")
				f.content, f.absent = content, false; return true
			end
			helpers.assert_true(f.User.create_example()); helpers.assert_eq(f.User.is_enabled(), false)
			helpers.assert_true(f.User.set_enabled(true)); helpers.assert_eq(f.User.count(), 1)
			for char in ("@clock★"):gmatch("[\1-\127\194-\244][\128-\191]*") do
				f.native.observe_input(); f.engine:on_char(char, { typed_at_ms = f.now }); f.now = f.now + 10
			end
			helpers.assert_true(f.User.request("@clock")); drain()
			helpers.assert_eq(#f.outputs, 1); helpers.assert_true(f.outputs[1].text:match("^%d%d:%d%d$") ~= nil)
			helpers.assert_eq(f.outputs[1].deletes, 7)
		end)
	end)
	helpers.it("(user-hotstrings-native) admits a present valid empty factory without inventing callbacks", function()
		with_runtime(function(f)
			f.content = "return function() return {} end"
			helpers.assert_true(f.User.reload()); helpers.assert_true(f.User.is_enabled())
			helpers.assert_eq(f.User.count(), 0); helpers.assert_nil(f.User.preview("@é"))
		end)
	end)
	for _, unavailable in ipairs({ "absent", "unreadable" }) do
		helpers.it("(user-hotstrings-native) quarantines old callbacks after " .. unavailable .. " source and restores only closed intent", function()
			with_runtime(function(f)
				local callback = f.User.scope_snapshot().policy.rules[1].callback
				f[unavailable] = true
				helpers.assert_eq(f.User.reload(), false); helpers.assert_eq(f.User.is_enabled(), false)
				local snapshot = assert(f.User.scope_snapshot())
				helpers.assert_true(snapshot.closed_only); helpers.assert_true(snapshot.desired)
				helpers.assert_eq(snapshot.policy.ready, false)
				helpers.assert_eq(f.User.count(), 0)
				helpers.assert_eq(#snapshot.policy.rules, 1, "quarantined inverse retains metadata without reporting admission")
				helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false)); helpers.assert_true(f.User.scope_restore(snapshot))
				local restored = assert(f.User.scope_snapshot())
				helpers.assert_true(restored.desired); helpers.assert_eq(restored.policy.ready, false)
				helpers.assert_eq(restored.policy.rules[1].callback, callback)
				helpers.assert_eq(f.User.count(), 0)
				helpers.assert_eq(f.User.is_enabled(), false); helpers.assert_eq(f.factories, 1)
			end)
		end)
	end
	for _, changed in ipairs({ "absent", "edit" }) do
		helpers.it("(user-hotstrings-native) refuses retained admitted checkpoint at a closed gate after " .. changed, function()
			with_runtime(function(f)
				helpers.assert_true(f.User.set_enabled(false))
				if changed == "edit" then f.content = f.content .. "\n-- foreign edit" else f.absent = true end
				helpers.assert_nil(f.User.scope_snapshot())
			end)
		end)
	end
	helpers.it("(user-hotstrings-native) does not relabel an admitted empty factory as unavailable until strict quarantine", function()
		with_runtime(function(f)
			f.content = "return function() return {} end"
			helpers.assert_true(f.User.reload())
			helpers.assert_true(f.User.set_enabled(false))
			f.absent = true
			helpers.assert_nil(f.User.scope_snapshot())
			helpers.assert_eq(f.User.reload(), false)
			local snapshot = assert(f.User.scope_snapshot())
			helpers.assert_true(snapshot.closed_only); helpers.assert_eq(snapshot.policy.ready, false)
			helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
			helpers.assert_true(f.User.scope_restore(snapshot))
			helpers.assert_eq(f.User.is_enabled(), false)
		end)
	end)
	helpers.it("(user-hotstrings-native) refuses an active checkpoint over callbacks from edited source", function()
		with_runtime(function(f)
			f.content = f.content .. "\n-- foreign source edit"
			helpers.assert_nil(f.User.scope_snapshot())
		end)
	end)
	helpers.it("(user-hotstrings-native) keeps the mutator's receipt across a foreign factory scalar change", function()
		with_runtime(function(f)
			local snapshot = assert(f.User.scope_snapshot())
			helpers.assert_true(f.User.scope_adopt(snapshot, 0.125, false))
			f.factory_mutate = function()
				f.factory_mutate = nil
				helpers.assert_true(f.User.set_time_activation(0.75))
			end
			helpers.assert_eq(f.User.scope_adopt(snapshot, 0.125, true), false)
			helpers.assert_eq(f.User.scope_restore(snapshot), false)
			helpers.assert_eq(f.User.time_activation(), 0.75)
			helpers.assert_eq(f.User.is_enabled(), false)
		end)
	end)
	for _, changed in ipairs({ "absent", "unreadable", "edit" }) do
		helpers.it("(user-hotstrings-native) re-proves admitted source on repeated enable after " .. changed, function()
			with_runtime(function(f)
				if changed == "edit" then f.content = "not valid Lua !" else f[changed] = true end
				helpers.assert_eq(f.User.set_enabled(true), false); helpers.assert_eq(f.User.is_enabled(), false)
				helpers.assert_eq(f.User.scope_snapshot().policy.ready, false)
			end)
		end)
	end
	for _, selected in ipairs({ "global", "dynamic" }) do
		helpers.it("(user-hotstrings-native) refuses foreign inverse at zero builtin rules in actual " .. selected .. " scope", function()
			with_runtime(function(f)
				f.zero_builtin = true
				with_configuration_scope(f, function(c)
					helpers.assert_eq(c.Dynamic.get_rules_count(), 0)
					local scope = selected == "global" and c.scope or c.dynamic_scope
					helpers.assert_true(scope.apply(selected == "global" and "recommended" or false))
					helpers.assert_true(f.User.reload())
					helpers.assert_eq(scope.revert(), false)
					helpers.assert_true(scope.pending(), "strict programmable refusal retains the inverse despite zero builtins")
					helpers.assert_eq(f.User.is_enabled(), false)
				end)
			end)
		end)
	end
	helpers.it("(user-hotstrings-native) restores acknowledged unavailable builtin posture at zero rules without masking user refusal", function()
		with_runtime(function(f)
			f.zero_builtin = true
			with_configuration_scope(f, function(c)
				helpers.assert_true(f.User.set_enabled(false))
				helpers.assert_true(c.Preferences.set("hotstrings.dynamic.user_code.enabled", false))
				helpers.assert_eq(c.Dynamic.get_rules_count(), 0)
				helpers.assert_true(c.scope.apply("recommended")); helpers.assert_true(c.scope.revert())
				helpers.assert_eq(c.Dynamic.is_enabled(), false); helpers.assert_eq(f.User.is_enabled(), false)
			end)
		end)
	end)
	for _, mode in ipairs({ "recommended", "clear" }) do
		helpers.it("(user-hotstrings-native) applies actual global " .. mode .. " and restores retained callbacks and source", function()
			with_runtime(function(f)
				with_configuration_scope(f, function(c)
					helpers.assert_true(f.User.set_time_activation(0.125))
					local callback = f.User.scope_snapshot().policy.rules[1].callback
					local factories = f.factories
					helpers.assert_true(c.scope.apply(mode))
					helpers.assert_eq(f.User.is_enabled(), false); helpers.assert_eq(f.User.time_activation(), 0.5)
					helpers.assert_true(c.scope.revert())
					helpers.assert_true(f.User.is_enabled()); helpers.assert_eq(f.User.time_activation(), 0.125)
					helpers.assert_eq(f.User.scope_snapshot().policy.rules[1].callback, callback)
					helpers.assert_eq(f.factories, factories, "an inverse must not execute the source factory")
					local file = assert(io.open(c.path, "r")); local bytes = file:read("*a"); file:close()
					helpers.assert_eq(bytes, c.original)
					f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
					helpers.assert_eq(f.outputs, { { deletes = 3, text = "0", private = true } })
				end)
			end)
		end)
		for _, unavailable in ipairs({ "absent", "unreadable" }) do
			helpers.it("(user-hotstrings-native) keeps actual " .. unavailable .. " closed source valid through global " .. mode, function()
				with_runtime(function(f)
					with_configuration_scope(f, function(c)
						helpers.assert_true(f.User.stop()); f[unavailable] = true
						helpers.assert_true(f.User.start(f.native)); helpers.assert_true(f.User.set_time_activation(0.5))
						helpers.assert_true(c.scope.apply(mode)); helpers.assert_true(c.scope.revert())
						helpers.assert_eq(f.User.is_enabled(), false); helpers.assert_eq(f.User.count(), 0)
						helpers.assert_eq(f.factories, 1)
					end)
				end)
			end)
		end
	end
	helpers.it("(user-hotstrings-native) replays production queued physical metadata after replacement commits", function()
		with_runtime(function(f)
			f.output_hook = function()
				for _, event in ipairs({ { char = "x", scancode = 45 }, { char = "y", scancode = 21 } }) do
					f.native.observe_input(); Injector._queue_char(event)
				end
				helpers.assert_eq(f.engine:current_buffer(), "@é★")
			end
			f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
			helpers.assert_eq(f.outputs, { { deletes = 3, text = "0", private = true } })
			helpers.assert_eq(f.replayed, { { char = "x", scancode = 45 }, { char = "y", scancode = 21 } })
			helpers.assert_eq(f.engine:current_buffer(), "xy")
			helpers.assert_eq(Injector._is_injecting(), false)
		end)
	end)
	for _, failure in ipairs({ "output_throws", "output_refused" }) do
		helpers.it("(user-hotstrings-native) retires the production input queue after " .. failure, function()
			with_runtime(function(f)
				f[failure] = true
				f.output_hook = function() Injector._queue_char({ char = "x", scancode = 45 }) end
				f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
				helpers.assert_eq(f.outputs, {}); helpers.assert_nil(f.replayed)
				helpers.assert_eq(f.engine:current_buffer(), "")
				helpers.assert_eq(Injector._is_injecting(), false)
				helpers.assert_eq(Injector._end_injection(), {})
				helpers.assert_true(f.notified)
			end)
		end)
	end
	for _, changed in ipairs({ "source", "generation" }) do
		helpers.it("(user-hotstrings-native) fences " .. changed .. " changed by the final bounded destination probe", function()
			with_runtime(function(f)
				f.mutate = function()
					local probes = 0
					f.probe_hook = function()
						probes = probes + 1
						if probes ~= 3 then return end
						if changed == "source" then f.content = f.content .. "\n-- changed before emission"
						else helpers.assert_true(f.User.invalidate("external lifecycle")) end
					end
				end
				f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
				helpers.assert_eq(f.calls, 1); helpers.assert_eq(f.outputs, {})
				helpers.assert_true(f.notified)
			end)
		end)
	end
	helpers.it("(user-hotstrings-native) defers user text through actual libuv then replaces suffix and delivered magic", function()
		with_runtime(function(f)
			f.type_suffix()
			helpers.assert_eq(f.User.preview("@é").preview, "Static")
			helpers.assert_eq(f.calls, 0)
			helpers.assert_true(f.User.request("@é"))
			helpers.assert_eq(f.calls, 0, "character delivery must not execute user code")
			drain()
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, { { deletes = 3, text = "0", private = true } })
			helpers.assert_eq(f.engine:current_buffer(), "")
		end)
	end)
	for _, result in ipairs({ true, false }) do
		helpers.it("(user-hotstrings-native) acknowledges action/cancellation without extra driver text " .. tostring(result), function()
			with_runtime(function(f)
				f.result = result; f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
				helpers.assert_eq(f.calls, 1); helpers.assert_eq(f.outputs, {})
			end)
		end)
	end
	local transitions = {
		input = function(f) f.native.observe_input(); f.engine:on_char("x", { typed_at_ms = f.now }) end,
		focus = function(f) f.path = "/org/a11y/atspi/accessible/8" end,
		privacy = function(f) f.secure = true; f.guard.prime() end,
		navigation = function(f) f.guard.invalidate() end,
		capture = function(f) helpers.assert_true(f.capture_gate.acquire("editor", 1)) end,
		pause = function(f) f.paused = true; f.User.invalidate("pause") end,
		source = function(f) f.content = f.content .. "\n-- replaced externally" end,
		reload = function(f) helpers.assert_true(f.User.reload()) end,
		master = function(f) f.enabled = false end,
		unknown_app = function(f) f.app = "" end,
		private_window = function(f) f.title = "Private browsing" end,
	}
	for name, transition in pairs(transitions) do
		helpers.it("(user-hotstrings-native) rejects pending callback after actual " .. name .. " owner changes", function()
			with_runtime(function(f)
				f.type_suffix(); helpers.assert_true(f.User.request("@é")); transition(f); drain()
				helpers.assert_eq(f.calls, 0); helpers.assert_eq(f.outputs, {})
			end)
		end)
	end
	helpers.it("(user-hotstrings-native) rejects text returned after the callback moves the actual native field", function()
		with_runtime(function(f)
			f.mutate = function() f.path = "/org/a11y/atspi/accessible/8" end
			f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
			helpers.assert_eq(f.calls, 1); helpers.assert_eq(f.outputs, {})
		end)
	end)
	helpers.it("(user-hotstrings-native) saves source controls then reloads disk preferences into the real runtime", function()
		with_runtime(function(f)
			local path = os.tmpname()
			local previous_preferences = package.loaded["infra.hotstring_preferences"]
			local previous_menu = package.loaded["ui.menu.programmatic_hotstrings"]
			local output = assert(io.open(path, "w"))
			output:write('[other]\nuntouched="foreign"\n[hotstrings.dynamic.user_code]\nneighbor="kept"\n')
			output:close()
			local ok, problem = xpcall(function()
				package.loaded["infra.hotstring_preferences"] = nil
				local Preferences = require("infra.hotstring_preferences")
				helpers.assert_true(Preferences._set_file_for_test(path))
				local facade = { is_enabled = function() return f.enabled end,
					set_user_code_time_activation = f.User.set_time_activation,
					set_user_code_enabled = f.User.set_enabled, reload_user_code = f.User.reload,
					user_code_source_path = f.User.source_path, create_user_code_example = f.User.create_example }
				package.loaded["ui.menu.programmatic_hotstrings"] = nil
				local rows = require("ui.menu.programmatic_hotstrings").build({ dyn_hotstrings = facade,
					is_paused = function() return false end, on_menu_changed = function() end })
				helpers.assert_true(rows[1].menu[1].fn())
				helpers.assert_true(f.User.is_enabled())
				helpers.assert_true(Preferences.set("hotstrings.dynamic.user_code.time_activation_seconds", 0.125))
				local input = assert(io.open(path, "r")); local bytes = input:read("*a"); input:close()
				local decoded = require("toml_codec").decode(bytes)
				helpers.assert_eq(decoded.other.untouched, "foreign")
				helpers.assert_eq(decoded.hotstrings.dynamic.user_code.neighbor, "kept")
				package.loaded["infra.hotstring_preferences"] = nil
				local restarted = require("infra.hotstring_preferences")
				helpers.assert_true(restarted._set_file_for_test(path))
				helpers.assert_true(f.User.set_enabled(false))
				helpers.assert_true(f.User.set_time_activation(restarted.get("hotstrings.dynamic.user_code.time_activation_seconds")))
				helpers.assert_true(f.User.set_enabled(restarted.get("hotstrings.dynamic.user_code.enabled")))
				helpers.assert_eq(f.User.time_activation(), 0.125)
				f.type_suffix(); helpers.assert_true(f.User.request("@é")); drain()
				helpers.assert_eq(f.outputs, { { deletes = 3, text = "0", private = true } })
			end, debug.traceback)
			package.loaded["infra.hotstring_preferences"] = previous_preferences
			package.loaded["ui.menu.programmatic_hotstrings"] = previous_menu
			os.remove(path)
			if not ok then error(problem, 0) end
		end)
	end)
	helpers.it("(user-hotstrings-native) uses retained physical timestamps and does not expire an admitted slow callback", function()
		with_runtime(function(f)
			f.type_suffix(501); helpers.assert_eq(f.User.request("@é"), false)
			f.engine:reset(); f.type_suffix(500)
			helpers.assert_eq(f.engine:tail_timing_receipt(3), { max_interkey_gap_ms = 500 })
			for _, bad in ipairs({ 0, -1, 1.5, 4, math.huge }) do helpers.assert_nil(f.engine:tail_timing_receipt(bad)) end
			helpers.assert_true(f.User.request("@é")); f.now = f.now + 5000; drain()
			helpers.assert_eq(f.calls, 1); helpers.assert_eq(#f.outputs, 1)
		end)
	end)
end)
