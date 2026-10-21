--- tests/support/infra/scope/shortcuts_scope_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_shortcuts_scope
--- DESCRIPTION:
--- Prelude shared by the test_shortcuts_scope_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Filters this positive scenario to the actual canonical parent, retaining every field.
--- A copied id-only row no longer declares the parent that receives native children.
local function declared_parent(top, id)
	local selected
	for _, row in ipairs(top) do
		if row.id == id then
			assert(selected == nil, "canonical fixture parent must be unique")
			selected = row
		end
	end
	assert(type(selected) == "table" and selected.type == "group"
		and type(selected.i18n) == "string", "actual canonical fixture parent unavailable")
	return { selected }
end

local Sandbox = require("test.config_unused_keys_contract").sandbox

local Writer = require("toml_codec.writer")

local Codec = require("toml_codec")

local Manifest = require("infra.manifest_reader")

local SOURCE = '[shortcuts]\nenabled = true\nwrap_text_if_selected = true\nchatgpt_url = "https://old.example"\nunknown = "keep"\n'
	.. '[shortcuts.keyboard]\nctrl_j = "open_url"\nctrl_k = "enter"\nctrl_p = "script_reload"\nforeign_slot = "keep"\n'
	.. '[shortcuts.tap_keys]\nnumber_row_left = "send_text"\nunknown = "keep"\n'
	.. '[gesture_parameters]\nkeyboard__ctrl_j__open_url = "https://old.example"\ntap_key__number_row_left__send_text = "typed"\n'
	.. 'tap_3__open_url = "https://gesture.example"\ntap_hold__caps_lock__open_url = "https://hold.example"\nunknown = "keep"\n'
	.. '[linux.action_parameters]\nkeyboard__ctrl_k__open_url = "https://legacy.example"\nunknown = "keep"\n'
	.. '[gestures]\nenabled = false\ntap_3 = "enter"\n[metrics]\nenabled = true\n[llm]\nenabled = true\n[other]\nvalue = 42\n'

--- Uses real state owners and only controlled native/file publication ports.
--- @param body function Test body.
--- @param source string|nil config.toml content; SOURCE by default.
--- @param options table|nil Explicit uninitialized-pair negative fixture.
local function with_scope(body, source, options)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(source or SOURCE, function(path)
			for _, name in ipairs({ "modules.shortcuts.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
				"modules.shortcuts.chatgpt", "modules.shortcuts.script_chords", "modules.shortcuts.key_combinations", "modules.gestures.manager",
				"infra.shortcuts_scope", "ui.menu.menu_builder" }) do
				package.loaded[name] = nil
			end
			local controls = { backups = {}, queued = {}, executed = {}, paused = false, device_calls = 0, runtime_calls = 0, pair_changes = 0 }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = {
				get = function(_, default) return default end,
				set = function() error("shortcut scope must not write legacy storage") end,
			}
			package.loaded["adapters.evdev_reader"] = {
				TOUCHPAD = "touchpad", close = function() controls.device_calls = controls.device_calls + 1; return false end,
				open = function() controls.device_calls = controls.device_calls + 1; return false end,
			}
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end }
			package.loaded["adapters.shell_runner"] = {
				has_command = function() return true end,
				quote = function(value) return "'" .. value .. "'" end,
				run = function(command) controls.executed[#controls.executed + 1] = command; return true end,
			}
			local gestures = require("modules.gestures.manager")
			gestures.init({ persist = true, config_path = path, enabled = false })
			gestures.execute_action = function(action, binding)
				controls.executed[#controls.executed + 1] = action .. "@" .. binding
			end
			local manager = require("modules.shortcuts.manager")
			manager.init({ persist = true, config_path = path })
			local keyboard, taps = require("modules.shortcuts.keyboard_shortcuts"), require("modules.shortcuts.tap_keys")
			keyboard.get_assignments()
			taps.init({ is_active = function() return manager.is_enabled() and not controls.paused end,
				defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
			taps.get_action("number_row_left")
			local url = require("modules.shortcuts.chatgpt")
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional configuration publication") end,
				write_if_unchanged = function(target, content, expected)
					if target ~= path then controls.backups[#controls.backups + 1] = target end
					if controls.before_publish then controls.before_publish(target) end
					if controls.refuse == target then return false, "injected publication refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			package.loaded["adapters.file_system"] = files
			-- The global shortcut scope now includes the daemon's canonical pair
			-- owner. Build its actual policy from the physical catalogue; only
			-- native retirement/installation acknowledgements are controlled here.
			local combinations = require("modules.shortcuts.key_combinations")
			if not options or options.initialize_pairs ~= false then
				local Loader = require("platform.remap.tap_hold_loader")
				local defaults = require("infra.paths").shared("tap_hold/defaults.toml")
				local loaded_pairs = Loader.load_document(defaults,
					{ tap_hold = { enabled = false, inherit_defaults = true } }, nil, path .. ".tap_hold.toml")
				helpers.assert_true(combinations.install({ keys = loaded_pairs.catalog, hold_picker = loaded_pairs.hold_picker,
					files = files, route = function() return path end, is_paused = function() return controls.paused end,
					actions = { is_assignable = function(action)
						return action ~= "one_shot_shift" and gestures.is_assignable(action) == true
					end },
					changed = function() controls.pair_changes = controls.pair_changes + 1; return true end }))
			end
			local apply_keyboard = keyboard.apply_configuration
			keyboard.apply_configuration = function(token, state)
				controls.runtime_calls = controls.runtime_calls + 1
				local accepted = apply_keyboard(token, state)
				if controls.refuse_runtime then controls.refuse_runtime = false; return false end
				return accepted
			end
			local apply_parameters = gestures.apply_parameter_configuration
			gestures.apply_parameter_configuration = function(token, state)
				if controls.refuse_restore and state.keyboard__ctrl_j__open_url then return false end
				return apply_parameters(token, state)
			end
			local chords = require("modules.shortcuts.script_chords")
			chords.init({ is_paused = function() return controls.paused end,
				defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
			local backup = path .. ".shortcuts-test-backup"
			local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = backup,
				files = files, is_paused = function() return controls.paused end })
			controls.files = files
			local owners = { manager = manager, keyboard = keyboard, taps = taps, url = url, gestures = gestures,
				chords = chords, combinations = combinations }
			local passed, failure = pcall(body, scope, owners, controls, path, backup)
			for _, created in ipairs(controls.backups) do os.remove(created); os.remove(created .. ".tmp") end
			os.remove(backup)
			if not passed then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

-- script-chords-three-os-2026-09-30: an absent chord starts with its preset, so
-- every clear writes "none" in each slot and « Restaurer » deletes them; the
-- submenu's own restore and clear touch the chords and nothing else.
local SLOTS = { "script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape" }

local CHORDS_SOURCE = SOURCE .. '[shortcuts.script_control]\nchords_enabled = false\nscript_altgr_enter = "open_url"\n'
	.. 'script_altgr_escape = "none"\n'

local CHORD_PARAMETER = "script__script_altgr_enter__open_url"

--- Real configuration/claim owners; only the native map observation is modeled.
local function with_collision_scope(source, tap_config, body, navigation_text)
	with_scope(function(scope, owners, controls, path)
		local names = { "platform.remap.tap_hold_manager", "adapters.xkb_capture", "modules.shortcuts.physical_collisions",
			"modules.hotstrings.magic_key_source", "infra.hotstring_preferences" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local Manager, tap_path, hook, navigation_dir, navigation_made
		local ok, why = pcall(function()
			if navigation_text ~= nil then
				navigation_dir = os.tmpname()
				assert(os.remove(navigation_dir))
				local made = os.execute("mkdir " .. require("text_utils").shell_quote(navigation_dir))
				assert(made == true or made == 0)
				navigation_made = true
				tap_path = navigation_dir .. "/tap_hold.toml"
				controls.navigation_path = navigation_dir .. "/layers.toml"
				local handle = assert(io.open(controls.navigation_path, "wb"))
				local wrote, result = pcall(handle.write, handle, navigation_text)
				local closed, acknowledged = pcall(handle.close, handle)
				assert(wrote and result ~= nil and result ~= false); assert(closed and acknowledged == true)
				local verification = assert(io.open(controls.navigation_path, "rb"))
				local read_ok, bytes = pcall(verification.read, verification, "*a")
				local close_ok, verified_closed = pcall(verification.close, verification)
				assert(read_ok and bytes == navigation_text); assert(close_ok and verified_closed == true)
			else
				tap_path = os.tmpname()
			end
			Sandbox.write_bytes(tap_path, require("tests.support.tap_hold_fixture").with_preset(tap_config))
			hook = { calls = 0 }
			function hook.set_remapper(engine) hook.calls = hook.calls + 1; hook.engine = engine; return true end
			function hook.key_text() return nil end
			function hook.held_modifiers() return {} end
			function hook.held_text_modifier_codes() return {} end
			function hook.held_shortcut_modifier_codes() return {} end
			Manager = require("platform.remap.tap_hold_manager")
			helpers.assert_true(Manager.init({ keyboard_hook = hook, execute_action = function() error("no action during collision validation") end,
				action_names = owners.gestures.get_executable_action_names, on_text_injected = function() error("no output during validation") end,
				defaults_path = require("infra.paths").shared("tap_hold/defaults.toml"), user_path = tap_path }))
			controls.source_reads, controls.intentional_hook_changes = 0, 0
			-- This fixture acknowledges initial readiness solely to reach preflight.
			-- Restore the genuine false getter before any existing outcome assertion.
			local native_delivery = owners.keyboard.physical_delivery_available
			helpers.assert_eq(native_delivery(), false)
			local edit = scope.edit
			scope.edit = function(rows, receipt)
				controls.delivery_available = true
				owners.keyboard.physical_delivery_available = function() return controls.delivery_available end
				local called, accepted, reason = pcall(edit, rows, receipt)
				owners.keyboard.physical_delivery_available = native_delivery
				if not called then error(accepted, 0) end
				return accepted, reason
			end
			local tokens = setmetatable({}, { __mode = "k" })
			package.loaded["adapters.xkb_capture"] = {
				chord_sources = function(requests)
					controls.source_reads = controls.source_reads + 1
					local token, rows = {}, {}
					local identities = { [2] = "1", [3] = "2", [15] = "tab", [36] = controls.chord_j_identity or "j", [37] = "k", [41] = "grave", [58] = "caps_lock",
						[103] = "up", [105] = "left", [106] = "right", [108] = "down" }
					for _, request in ipairs(requests) do
						for _, caps in ipairs({ false, true }) do
							rows[#rows + 1] = { code = request.code, mods = request.mods, caps = caps,
								identity = identities[request.code], dead = false }
						end
					end
					tokens[token] = rows; return token
				end,
				chord_source_view = function(token) return tokens[token] and { generation = 7, chords = tokens[token] } or nil end,
				chord_source_current = function(token)
					if controls.on_source then controls.on_source() end
					return tokens[token] ~= nil and not controls.source_refused
				end,
			}
			local before = hook.calls
			body(scope, owners, controls, path, Manager)
			helpers.assert_eq(hook.calls, before + controls.intentional_hook_changes, "validation adds no native ownership change beyond the controlled fault injection")
		end)
		if Manager then Manager._reset_for_test() end
		if tap_path then
			local removed, detail = os.remove(tap_path)
			if navigation_made and removed ~= true then ok, why = false, (ok and "" or tostring(why) .. "; ") .. "Tap fixture cleanup refused: " .. tostring(detail) end
		end
		if navigation_made then
			local removed, detail = os.remove(navigation_dir .. "/layers.toml")
			if removed ~= true then ok, why = false, (ok and "" or tostring(why) .. "; ") .. "Navigation fixture cleanup refused: " .. tostring(detail) end
			local removed = os.execute("rmdir " .. require("text_utils").shell_quote(navigation_dir))
			if removed ~= true and removed ~= 0 then
				ok, why = false, (ok and "" or tostring(why) .. "; ") .. "Navigation fixture cleanup refused"
			end
		end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(why, 0) end
	end, source)
end

local COLLISION_BASE = '[shortcuts]\nenabled = true\n[shortcuts.keyboard]\nmagic_editor = "none"\n'

local NO_TAP_HOLDS = '[tap_hold]\nenabled = false\ninherit_defaults = false\n'

local magic_collision_file_read = require("adapters.file_system").read

--- Uses the real replacement owner and its actual cached preference document.
local function with_magic_source(scope, owners, controls, path, state, body)
	local names = { "modules.hotstrings.magic_key_source", "infra.hotstring_preferences" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local Source, choices, typed = nil, {}, {}
	local prior_read = controls.files.read
	controls.files.read = magic_collision_file_read
	local ok, why = pcall(function()
		local Preferences = require("infra.hotstring_preferences")
		helpers.assert_true(Preferences._set_file_for_test(path))
		Source = require("modules.hotstrings.magic_key_source")
		Source.init({
			is_active = function() return state.active ~= false end,
			replace_on = function() return state.replace ~= false end,
			magic_key = function() return "★" end,
			can_type = function() return state.typable ~= false end,
			type_text = function(text) typed[#typed + 1] = text; return true end,
			dispatch_char = function() error("preflight cannot dispatch a character") end,
			end_selection = function() error("preflight cannot change a selection") end,
			can_capture = function() return true end, key_text = function() return "j" end,
			defer = function(callback, delay) choices[#choices + 1] = { callback = callback, delay = delay }; return true end,
		})
		body(scope, owners, controls, path, Source, Preferences, choices)
		helpers.assert_eq(typed, {}, "claim capture and preflight never type output")
	end)
	if Source then Source._reset_for_test() end
	controls.files.read = prior_read
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(why, 0) end
end

--- Refusal scenarios retain their exact no-native-ownership-change guard.
local function with_magic_collision_scope(source, state, body)
	with_collision_scope(source, NO_TAP_HOLDS, function(scope, owners, controls, path)
		with_magic_source(scope, owners, controls, path, state, body)
	end)
end

--- None/removal use the original full publisher without readiness or map grants.
local function with_magic_publication_scope(source, body)
	with_scope(function(scope, owners, controls, path)
		with_magic_source(scope, owners, controls, path, {}, body)
	end, source)
end

local MAGIC_COLLISION_SOURCE = COLLISION_BASE .. '[hotstrings]\nmagic_key_source = "KeyJ"\n'

--- Uses the same actual file/runtime intake, with no UI/provider/service actors.
local function with_prediction_preflight(source, body)
	with_collision_scope(source, NO_TAP_HOLDS, function(scope, owners, controls, path)
		local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
		local ok, failure = pcall(function()
			for name in pairs(package.loaded) do
				if name:match("^modules%.llm%.") or name == "infra.llm_preferences" then package.loaded[name] = nil end
			end
			local prediction = require("modules.llm.prediction_engine")
			prediction.init({ scheduler = require("tests.fakes").timer_scheduler(), overlay = {
				move = function() return true end,
				hide = function() return true end,
				is_showing = function() error("configured preflight must not query an offer or UI") end,
			} })
			owners.prediction = prediction
			body(scope, owners, controls, path)
		end)
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(saved) do package.loaded[name] = value end
		if not ok then error(failure, 0) end
	end)
end

return {
	helpers = helpers,
	declared_parent = declared_parent,
	Sandbox = Sandbox,
	Writer = Writer,
	Codec = Codec,
	Manifest = Manifest,
	SOURCE = SOURCE,
	with_scope = with_scope,
	SLOTS = SLOTS,
	CHORDS_SOURCE = CHORDS_SOURCE,
	CHORD_PARAMETER = CHORD_PARAMETER,
	with_collision_scope = with_collision_scope,
	COLLISION_BASE = COLLISION_BASE,
	NO_TAP_HOLDS = NO_TAP_HOLDS,
	magic_collision_file_read = magic_collision_file_read,
	with_magic_source = with_magic_source,
	with_magic_collision_scope = with_magic_collision_scope,
	with_magic_publication_scope = with_magic_publication_scope,
	MAGIC_COLLISION_SOURCE = MAGIC_COLLISION_SOURCE,
	with_prediction_preflight = with_prediction_preflight,
}
