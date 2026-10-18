--- tests/unit/platform/remap/tap_hold/test_tap_hold_manager_original_loader_export.lua

--- ==============================================================================
--- MODULE: Tap-Hold Manager Lifecycle
--- DESCRIPTION:
--- The feature switch, the file's own switch and the pause decide together
--- whether the engine is in the keyboard hook, and a change from the tray is
--- applied live by reload(). A tap action reaches the catalogue executor.
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_manager_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_manager_fixture")
local helpers, DEFAULTS, fake_hook, write, manager =
	Fixture.helpers, Fixture.DEFAULTS, Fixture.fake_hook, Fixture.write, Fixture.manager




helpers.describe("original loader export refusal preserves the installed engine",function()
 for _,spec in ipairs({{"load","reload"},{"load_document","apply_configuration"}}) do
  helpers.it("refuses a replaced "..spec[1].." before invoking or installing it",function()
   local Manager,hook,_,user_path=manager()
   local running,calls=hook.engine,hook.calls
   local Loader=require("platform.remap.tap_hold_loader")
   local original,foreign_calls=Loader[spec[1]],0
   Loader[spec[1]]=function(...)foreign_calls=foreign_calls+1;return original(...)end
   local original_open,source_reads=io.open,0
   io.open=function(path,...)
    if path==DEFAULTS or path==user_path then source_reads=source_reads+1 end
    return original_open(path,...)
   end
   local ok,failure=pcall(function()
    local accepted
    if spec[2]=="reload" then accepted=Manager.reload()
    else accepted=Manager.apply_configuration({tap_hold={enabled=false}}) end
    helpers.assert_eq(accepted,false)
    helpers.assert_eq(foreign_calls,0,"unknown live exports are never invoked")
    helpers.assert_eq(source_reads,0,"refused source exports are checked before any configuration file read")
    helpers.assert_eq(hook.engine,running,"original installation remains owned")
    helpers.assert_eq(hook.calls,calls,"no native install is attempted")
   end)
   io.open=original_open
   Loader[spec[1]]=original
   Manager._reset_for_test();os.remove(user_path)
   if not ok then error(failure,0) end
  end)
 end
end)




helpers.describe("loader currency after the last construction callback",function()
 helpers.it("retains the original tuple after catalogue callbacks replace the candidate loader",function()
  local Manager,hook,_,user_path=manager()
  Manager._reset_for_test()
  local Loader=require("platform.remap.tap_hold_loader")
  local original=Loader.load_document
  local original_names=require("modules.gestures.manager").get_executable_action_names
  local change=false
  Manager.init({keyboard_hook=hook,execute_action=function()end,on_text_injected=function()end,
   action_names=function()
    if change then change=false;Loader.load_document=function(...)return original(...)end end
    return original_names()
   end,defaults_path=DEFAULTS,user_path=user_path})
  local running,calls=hook.engine,hook.calls
  change=true
  local ok,failure=pcall(function()
   helpers.assert_eq(Manager.reload(),false)
   helpers.assert_eq(change,false,"the actual catalogue callback ran during construction")
   helpers.assert_eq(hook.engine,running)
   helpers.assert_eq(hook.calls,calls,"no partial new installation is delivered")
  end)
  Loader.load_document=original
  Manager._reset_for_test();os.remove(user_path)
  if not ok then error(failure,0) end
 end)
end)




-- Logical publication uses the actual loader and Manager constructor, with a
-- receiving hook double only. No hardware or installed-daemon claim is made.
helpers.describe("complete original-issuer combination binding publication", function()
	local owner_name = "platform.remap.tap_hold_manager"
	local combination_name = "modules.shortcuts.key_combinations"
	local function owned(body, delayed)
		local saved, undo = {}, {}
		for name, value in pairs(package.loaded) do saved[name] = value end
		local previous_open = io.open
		local paths = require("infra.config_paths")
		local previous_route = paths.config
		local user_path, config_path, Manager
		local owned_paths, cleanup = {}, {}
		local function defer(callback) undo[#undo + 1] = callback end
		local source = [[[_meta]
schema_version = 12
[category_enabled]
key_combinations = false
[gesture_parameters]
combination__space_then_tab__open_url = "https://current.example"
combination__removed_then_tab__open_url = "https://retired.example"
tap_hold__future_unjudged__open_url = "https://unjudged.example"
[foreign]
keep = true
]]
		local function stream(path, mode, content)
			local file, open_error = io.open(path, mode)
			if not file then error(open_error, 0) end
			local called, value, detail
			if content == nil then called, value, detail = pcall(file.read, file, "*a")
			else called, value, detail = pcall(file.write, file, content) end
			local close_called, closed, close_error = pcall(file.close, file)
			if not close_called or closed ~= true then
				cleanup[#cleanup + 1] = tostring(close_called and close_error or closed)
			end
			if not called then error(value, 0) end
			if content == nil and type(value) ~= "string" or content ~= nil and (value == nil or value == false) then
				error(detail or "owned real stream refused", 0)
			end
			if not close_called or closed ~= true then error(close_called and close_error or closed, 0) end
			return value
		end
		local function read() return stream(config_path, "rb") end
		local okay, primary = xpcall(function()
			user_path = os.tmpname(); owned_paths[#owned_paths + 1] = user_path
			config_path = os.tmpname(); owned_paths[#owned_paths + 1] = config_path
			stream(user_path, "wb", require("tests.support.tap_hold_fixture").with_preset("[tap_hold]\nenabled = false\n"))
			stream(config_path, "wb", source)
			paths.config = function() return config_path end
			package.loaded[combination_name], package.loaded[owner_name] = nil, nil
			local Combinations = require(combination_name)
			Manager = require(owner_name)
			local Gestures = helpers.load_module("modules.gestures.manager")
			local hook = fake_hook()
			local function start()
				return Manager.init({ keyboard_hook = hook, execute_action = Gestures.execute_action,
					action_names = Gestures.get_executable_action_names, on_text_injected = function() end,
					defaults_path = DEFAULTS, user_path = user_path })
			end
			if not delayed then helpers.assert_eq(start(), true) end
			body(Manager, Combinations, Gestures, hook, config_path, source, read, defer, start)
		end, function(primary_error) return primary_error end)
		io.open = previous_open
		for index = #undo, 1, -1 do
			local restored, detail = pcall(undo[index])
			if not restored then cleanup[#cleanup + 1] = tostring(detail) end
		end
		if Manager then
			local called, reset = pcall(Manager._reset_for_test)
			if not called or reset ~= true then cleanup[#cleanup + 1] = "owned Manager reset refused" end
		end
		paths.config = previous_route
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(saved) do package.loaded[name] = value end
		for _, path in ipairs(owned_paths) do
			local called, removed, detail = pcall(os.remove, path)
			if not called or removed ~= true then cleanup[#cleanup + 1] = tostring(called and detail or removed) end
		end
		if not okay then
			if #cleanup > 0 then pcall(io.stderr.write, io.stderr, "Owned cleanup failed: " .. table.concat(cleanup, "\n") .. "\n") end
			error(primary, 0)
		end
		if #cleanup > 0 then error(table.concat(cleanup, "\n"), 0) end
	end
	local function dry(body)
		local original, calls = io.open, 0
		io.open = function() calls = calls + 1; error("logical classification must not read or initialize", 0) end
		local okay, detail = xpcall(body, function(primary_error) return primary_error end)
		io.open = original
		if not okay then
			if calls ~= 0 then pcall(io.stderr.write, io.stderr, "Logical classification attempted IO before primary refusal\n") end
			error(detail, 0)
		end
		helpers.assert_eq(calls, 0)
	end
	local function current(Manager, Gestures)
		dry(function()
			helpers.assert_eq(Gestures.action_parameter_binding_fits("combination__space_then_tab"), true)
			helpers.assert_eq(Gestures.action_parameter_binding_fits("combination__tab_then_space"), true)
			helpers.assert_eq(Gestures.action_parameter_binding_fits("combination__removed_then_tab"), false)
			helpers.assert_nil(Gestures.action_parameter_binding_fits("tap_hold__future_unjudged"))
			helpers.assert_eq(Manager.managed_combination_catalogue_current(Manager.configuration_snapshot().combinations), true)
		end)
	end
	local function unavailable(Manager, Gestures, getter)
		dry(function()
			helpers.assert_nil(Gestures.action_parameter_binding_fits("combination__space_then_tab"))
			helpers.assert_nil(Gestures.action_parameter_binding_fits("combination__removed_then_tab"))
			helpers.assert_nil(getter(), "the genuine retained getter refuses withdrawn authority")
		end)
	end

	helpers.it("combination-source-identity: publishes complete detached pairs while assignments, pause and installation are inactive", function()
		owned(function(Manager, Combinations, Gestures, hook)
			local snapshot = Manager.configuration_snapshot()
			helpers.assert_eq(Gestures.action_parameter_binding_fits("combination__space_then_tab"), true, "the actual existing reader judges the complete source")
			local catalogue = Manager.published_binding_catalogue()
			local count = 0; for _ in pairs(catalogue.slots) do count = count + 1 end
			helpers.assert_eq(count, #snapshot.loaded.catalog * (#snapshot.loaded.catalog - 1))
			helpers.assert_eq(catalogue.slots.space_then_tab, true)
			helpers.assert_eq(catalogue.slots.tab_then_space, true)
			helpers.assert_nil(hook.engine, "the actual logical fixture installs no engine")
			helpers.assert_eq(Combinations.has_bindings(), false)
			catalogue.slots.space_then_tab = nil; catalogue.slots.removed_then_tab = true
			current(Manager, Gestures)
			helpers.assert_eq(Manager.set_paused(true), true)
			current(Manager, Gestures)
			helpers.assert_eq(Manager.set_enabled(false), true)
			current(Manager, Gestures)
			helpers.assert_nil(hook.engine)
		end)
	end)

	helpers.it("combination-source-identity: withdraws and exactly repairs original source, constructor, accessor and instance custody", function()
		owned(function(Manager, Combinations, Gestures, hook, _, _, _, defer)
			helpers.assert_eq(Gestures.action_parameter_binding_fits("combination__space_then_tab"), true, "the actual original constructor supplies current identity")
			local snapshot, getter = Manager.configuration_snapshot(), Manager.published_binding_catalogue
			local constructor, instance_current = Combinations.new, Combinations.instance_is_current
			local observer, calls = Manager.managed_combination_catalogue_current, 0
			local Loader = require("platform.remap.tap_hold_loader")
			local load = Loader.load
			local Engine = require("platform.remap.tap_hold_engine")
			local key_code = Engine.KEY_CODES.tab
			local PairPolicy = require("tap_hold.key_combinations")
			local pair = PairPolicy.pair
			local caption = snapshot.loaded.catalog[1].key
			local key = snapshot.loaded.keys.caps_lock
			helpers.assert_eq(type(key), "table", "the explicitly selected shipped preset has caps_lock settings")
			local timing = key.time_activation_seconds
			defer(function()
				Manager.published_binding_catalogue = getter; Manager.managed_combination_catalogue_current = observer
				Combinations.new = constructor; Combinations.instance_is_current = instance_current
				Loader.load = load; Engine.KEY_CODES.tab = key_code; PairPolicy.pair = pair
				snapshot.loaded.catalog[1].key = caption; key.time_activation_seconds = timing
				snapshot.loaded.hold_picker.foreign_probe = nil
				package.loaded[owner_name], package.loaded[combination_name] = Manager, Combinations
				setmetatable(Manager, nil); setmetatable(Combinations, nil)
				Combinations.set_instance(snapshot.combinations)
			end)
			local native_calls = hook.calls
			Manager.published_binding_catalogue = function() calls = calls + 1; return { prefix = "combination__", slots = {} } end
			unavailable(Manager, Gestures, getter)
			Manager.published_binding_catalogue = getter; current(Manager, Gestures)
			Manager.managed_combination_catalogue_current = function() calls = calls + 1; return true end
			unavailable(Manager, Gestures, getter)
			Manager.managed_combination_catalogue_current = observer; current(Manager, Gestures)
			Combinations.instance_is_current = function() calls = calls + 1; return true end
			unavailable(Manager, Gestures, getter)
			Combinations.instance_is_current = instance_current; current(Manager, Gestures)
			Combinations.new = function() calls = calls + 1; return snapshot.combinations end
			unavailable(Manager, Gestures, getter)
			Combinations.new = constructor; current(Manager, Gestures)
			Loader.load = function() calls = calls + 1; return snapshot.loaded end
			unavailable(Manager, Gestures, getter)
			Loader.load = load; current(Manager, Gestures)
			Engine.KEY_CODES.tab = key_code + 1
			unavailable(Manager, Gestures, getter)
			Engine.KEY_CODES.tab = key_code; current(Manager, Gestures)
			snapshot.loaded.catalog[1].key = caption .. "_withdrawn"
			unavailable(Manager, Gestures, getter)
			snapshot.loaded.catalog[1].key = caption; current(Manager, Gestures)
			key.time_activation_seconds = timing + 0.001
			unavailable(Manager, Gestures, getter)
			key.time_activation_seconds = timing; current(Manager, Gestures)
			snapshot.loaded.hold_picker.foreign_probe = true
			unavailable(Manager, Gestures, getter)
			snapshot.loaded.hold_picker.foreign_probe = nil; current(Manager, Gestures)
			setmetatable(Manager, { __index = function() calls = calls + 1 end })
			unavailable(Manager, Gestures, getter)
			setmetatable(Manager, nil); current(Manager, Gestures)
			package.loaded[owner_name] = { published_binding_catalogue = getter }
			unavailable(Manager, Gestures, getter)
			package.loaded[owner_name] = Manager; current(Manager, Gestures)
			package.loaded[combination_name] = { new = constructor, instance_is_current = instance_current }
			unavailable(Manager, Gestures, getter)
			package.loaded[combination_name] = Combinations; current(Manager, Gestures)
			local unissued = constructor({ keys = snapshot.loaded.catalog, hold_picker = snapshot.loaded.hold_picker,
				is_paused = function() return false end, changed = function() return true end,
				actions = { is_assignable = Gestures.is_assignable } })
			helpers.assert_eq(Manager.managed_combination_catalogue_current(unissued), false)
			helpers.assert_eq(Combinations.set_instance(unissued), true)
			unavailable(Manager, Gestures, getter)
			helpers.assert_eq(Combinations.set_instance(snapshot.combinations), true)
			current(Manager, Gestures)
			helpers.assert_eq(hook.calls, native_calls, "logical source withdrawals never install or remove hooks")
			PairPolicy.pair = function(first, second) return "foreign_" .. pair(first, second) end
			unavailable(Manager, Gestures, getter)
			-- The real constructor ran with this foreign dependency. Restoring the
			-- public function alone cannot bless its detached private known set.
			helpers.assert_eq(Manager.reload(), true)
			PairPolicy.pair = pair
			unavailable(Manager, Gestures, getter)
			helpers.assert_eq(Manager.reload(), true)
			current(Manager, Gestures)
			local equivalent_calls = 0
			PairPolicy.pair = function(first, second)
				equivalent_calls = equivalent_calls + 1
				return pair(first, second)
			end
			unavailable(Manager, Gestures, getter)
			helpers.assert_eq(Manager.reload(), true)
			helpers.assert_true(equivalent_calls > 0, "the genuine original constructor consumed the foreign equivalent dependency")
			PairPolicy.pair = pair
			local consumed = equivalent_calls
			unavailable(Manager, Gestures, getter)
			helpers.assert_eq(equivalent_calls, consumed, "read-only refusal never calls the foreign dependency")
			helpers.assert_eq(Manager.reload(), true)
			current(Manager, Gestures)
			helpers.assert_eq(calls, 0, "foreign accessors and metamethods never run")
			helpers.assert_nil(hook.engine, "explicit genuine reload still has no active assignments")
		end)
	end)

	helpers.it("combination-source-identity: actual cached reader, reporter and ordinary setter retain retired source until cleanup", function()
		owned(function(Manager, Combinations, Gestures, _, path, source, read, _, start)
			helpers.assert_nil(Gestures.action_parameter_binding_fits("combination__removed_then_tab"))
			Gestures.init({ persist = true, config_path = path, enabled = false })
			helpers.assert_eq(Gestures.get_action_parameter("combination__removed_then_tab", "open_url"), "https://retired.example")
			helpers.assert_eq(start(), true)
			helpers.assert_eq(Gestures.get_action_parameter("combination__space_then_tab", "open_url"), "https://current.example")
			helpers.assert_eq(Gestures.get_action_parameter("combination__removed_then_tab", "open_url"), "")
			helpers.assert_eq(Gestures.get_action_parameter("tap_hold__future_unjudged", "open_url"), "https://unjudged.example")
			local marks = {}
			local outdated = require("config_outdated")
			local reports = outdated.collect_reports(function()
				Gestures.mark_config_reads(require("toml_codec").decode(source), function(...)
					marks[table.concat({ ... }, ".")] = true
				end)
			end)
			helpers.assert_eq(reports["gesture_parameters.combination__removed_then_tab__open_url"], true)
			helpers.assert_eq(marks["gesture_parameters.combination__space_then_tab__open_url"], true)
			helpers.assert_nil(marks["gesture_parameters.combination__removed_then_tab__open_url"])
			local writer, writes = Gestures._persist_updates, 0
			Gestures._persist_updates = function(...) writes = writes + 1; return writer(...) end
			helpers.assert_eq(Gestures.set_action_parameter("combination__removed_then_tab", "open_url", "https://refused.example"), false)
			helpers.assert_nil(Gestures.action_parameter_update("combination__removed_then_tab", "open_url", "https://refused.example"))
			helpers.assert_eq(writes, 0)
			helpers.assert_eq(read(), source, "retired, unjudged and foreign source bytes remain exact")
		end, true)
	end)
end)




helpers.describe("native Manager collision claim source", function()
	helpers.it("captures actual enabled key reservations and revokes after native disable or file replacement", function()
		local Manager, _, _, path = manager('[tap_hold]\nenabled = true\ninherit_defaults = true\n')
		local ok, why = pcall(function()
			local frame = assert(Manager.capture_collision_inventory()); helpers.assert_true(frame.current())
			local caps = false
			for _, claim in ipairs(frame.claims) do
				if claim.binding == "tap_hold__caps_lock" then caps = claim.codes[1] == 58 end
			end
			helpers.assert_true(caps); helpers.assert_eq(frame.codes.caps_lock, 58)
			helpers.assert_true(Manager.set_enabled(false)); helpers.assert_eq(frame.current(), false)
			local disabled = assert(Manager.capture_collision_inventory()); helpers.assert_eq(#disabled.claims, 0)
			helpers.assert_true(Manager.set_enabled(true)); helpers.assert_eq(disabled.current(), false)
			local current = assert(Manager.capture_collision_inventory())
			write(path, '[tap_hold]\nenabled = false\ninherit_defaults = false\n')
			helpers.assert_eq(current.current(), false); helpers.assert_nil(Manager.capture_collision_inventory())
		end)
		Manager._reset_for_test(); os.remove(path); if not ok then error(why, 0) end
	end)
	helpers.it("pausing the genuine Manager cannot publish an empty complete claim inventory", function()
		local Manager, _, _, path = manager('[tap_hold]\nenabled = true\ninherit_defaults = true\n')
		local ok, why = pcall(function()
			local frame = assert(Manager.capture_collision_inventory()); Manager.set_paused(true)
			helpers.assert_eq(frame.current(), false); helpers.assert_nil(Manager.capture_collision_inventory())
			Manager.set_paused(false); helpers.assert_eq(frame.current(), false)
		end)
		Manager._reset_for_test(); os.remove(path); if not ok then error(why, 0) end
	end)
end)




helpers.describe("original Engine native passthrough is not a tap-hold claim", function()
	helpers.it("a native tap with no hold produces no collision reservation", function()
		local Manager, _, _, path = manager('[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.tab]\ntap_action = ""\nhold_modifier = ""\nhold_layer = ""\n')
		local ok, why = pcall(function()
			local frame = assert(Manager.capture_collision_inventory())
			helpers.assert_eq(#frame.claims, 0); helpers.assert_true(frame.current())
		end)
		Manager._reset_for_test(); os.remove(path); if not ok then error(why, 0) end
	end)
end)





helpers.describe("ordinary tap actions retain their Manager owner through logging", function()
	for _, transition in ipairs({ "pause", "disable", "reload", "pause/resume", "benign" }) do
		helpers.it("revalidates an actual Shift tap across a " .. transition .. " logging callback", function()
			local names = { "logger", "logger.shim", "platform.remap.nav_layer", "platform.remap.tap_hold_manager" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local Manager, path, Logger
			local ok, err = pcall(function()
				-- A fresh genuine logger preserves another test's sink and level.
				Logger = helpers.load_module("logger")
				Logger.set_level("DEBUG")
				package.loaded["logger.shim"] = Logger
				local hook, actions
				Manager, hook, actions, path = manager()
				local engine, dispatch = hook.engine, hook.on_tap
				engine:process(42, 1, 0)
				local _, action, binding = engine:process(42, 0, 100)
				helpers.assert_eq(action, "copy")
				helpers.assert_eq(binding, "tap_hold__left_shift")
				local observed, callback_ok, callback_error = false, false, nil
				Logger.set_sink(function(line)
					if observed or not line:find("Tap action 'copy'.", 1, true) then return end
					observed = true
					Logger.set_sink(nil)
					-- The real logger intentionally swallows sink errors. Retain the
					-- transition ACK so that cannot turn a broken fixture green.
					callback_ok, callback_error = pcall(function()
						if transition == "pause" then assert(Manager.set_paused(true))
						elseif transition == "disable" then assert(Manager.set_enabled(false))
						elseif transition == "reload" then assert(Manager.reload())
						elseif transition == "pause/resume" then
							assert(Manager.set_paused(true)); assert(Manager.set_paused(false))
						end
					end)
				end)
				dispatch(action, binding)
				Logger.set_sink(nil)
				helpers.assert_true(observed, "the real synchronous logger sink must be exercised")
				helpers.assert_true(callback_ok, tostring(callback_error))
				helpers.assert_eq(actions, transition == "benign" and { "copy@tap_hold__left_shift" } or {})
				if transition == "pause" or transition == "disable" then
					dispatch(action, binding)
					helpers.assert_eq(actions, {}, "an inactive entry cannot dispatch a retained callback")
				end
				if transition ~= "benign" then
					helpers.assert_true(Manager.set_paused(false))
					helpers.assert_true(Manager.set_enabled(true))
					helpers.assert_true(Manager.is_active())
					hook.engine:process(42, 1, 300)
					local _, fresh_action, fresh_binding = hook.engine:process(42, 0, 400)
					hook.on_tap(fresh_action, fresh_binding)
					helpers.assert_eq(actions, { "copy@tap_hold__left_shift" }, "a fresh active tap still executes once")
				end
			end)
			if Logger then Logger.set_sink(nil) end
			if Manager then Manager._reset_for_test() end
			if path then os.remove(path) end
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
	end
end)
