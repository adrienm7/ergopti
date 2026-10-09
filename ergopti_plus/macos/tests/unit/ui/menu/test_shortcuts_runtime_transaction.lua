--- tests/unit/ui/menu/test_shortcuts_runtime_transaction.lua

--- ==============================================================================
--- MODULE: Shortcuts Menu Runtime Transaction Regression
--- DESCRIPTION:
--- Drives the real Shortcuts master menu action and menu-state synchronizer.
--- A returned/raised binding lifecycle failure must restore runtime and state,
--- and must never persist or announce a preference the runtime did not commit.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads the real menu builder around one controllable shortcut lifecycle.
--- @param shortcuts table Runtime shortcut double.
--- @param enabled boolean Initial persisted state.
--- @return table fixture Built action and side-effect counters.
local function load_menu_fixture(shortcuts, enabled, options)
	options = options or {}
	local noop = function() end
	helpers.load_with_stubs("infra.logger")
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.fs_dir"] = { entries = function() return {} end }
	package.loaded["infra.dialog_util"] = {}
	package.loaded["modules.shortcuts"] = {
		DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
	}
	package.loaded["modules.shortcuts.actions.text"] = {
		WRAP_GROUPS = {},
		build_active_wrap_pairs = function() return {} end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		decorate_section = function(value) return value end,
	}
	package.loaded["ui.menu.menu_utils"] = {}
	-- The switch is the command registered for the manifest's shortcuts_toggle
	-- row, captured where the menu hands it to the renderer.
	local render_ctx = nil
	package.loaded["infra.manifest_menu"] = { build = function(_, _, _, _, ctx)
		render_ctx = ctx
		return {}
	end }
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["ui.menu.menu_keyboard_slots"] = { provide_rows = function() return {} end }
	package.loaded["infra.manifest_reader"] = { default_for = function() return "★" end }
	package.loaded["ui.menu.menu_shortcuts"] = nil
	local MenuShortcuts = require("ui.menu.menu_shortcuts")

	local state = {
		shortcuts = enabled,
		chatgpt_url = "https://example.test",
		wrap_symbol_states = {},
		custom_wrap_symbols = {},
	}
	local counters = { saves = 0, notifications = 0, updates = 0 }
	local item = MenuShortcuts.build({
		shortcuts = shortcuts,
		state = state,
		paused = false,
		applyTriggerChar = function(value) return value end,
		save_prefs = function()
			counters.saves = counters.saves + 1
			if options.save_mode == "false" then return false end
			if options.save_mode == "nil" then return nil end
			if options.save_mode == "throw" then error("synthetic save refusal") end
			return true
		end,
		notify_feature = function() counters.notifications = counters.notifications + 1 end,
		updateMenu = function() counters.updates = counters.updates + 1 end,
		commands = {},
		state_getters = {},
	})
	helpers.assert_nil(item.action, "the Shortcuts parent opens a submenu and must carry no action")
	local toggle = render_ctx and render_ctx.commands and render_ctx.commands["shortcuts_toggle"]
	helpers.assert_type(toggle, "function", "the real master toggle command must be reachable")
	helpers.assert_true(MenuShortcuts.scope_idle())
	return { action = toggle, state = state, counters = counters, noop = noop, scope_idle = MenuShortcuts.scope_idle }
end


--- Minimal dependency bag for exercising the real menu-state synchronizer.
--- @param shortcuts table Shortcut lifecycle double.
--- @return table deps
local function state_sync_deps(shortcuts)
	return {
		keymap = { set_llm_model = function() return true end },
		hotstring_editor = {},
		core_mods = { shortcuts_mod = shortcuts },
		apply_metrics_shortcut = function() return true end,
		apply_apps_time_shortcut = function() return true end,
		save_prefs = function() return true end,
	}
end





-- ============================================
-- ============================================
-- ======= 1/ Master Toggle Transaction =======
-- ============================================
-- ============================================

helpers.describe("Shortcuts master menu toggle commits runtime before persistence", function()
	helpers.it("rolls back activate-then-false without saving or announcing success", function()
		local running = false
		local calls = {}
		local fixture = load_menu_fixture({
			resume_bindings = function()
				calls[#calls + 1] = "resume"
				running = true
				return false
			end,
			pause_bindings = function()
				calls[#calls + 1] = "pause"
				running = false
				return true
			end,
		}, false)

		local call_ok, committed = pcall(fixture.action)
		helpers.assert_true(call_ok, "native refusal must remain inside the menu callback")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(calls, { "resume", "pause" },
			"the inverse lifecycle must roll a partially activated runtime back")
		helpers.assert_true(not running)
		helpers.assert_eq(fixture.state.shortcuts, false,
			"menu state must still describe the committed runtime")
		helpers.assert_eq(fixture.counters.saves, 0,
			"persistence is forbidden before exact runtime commitment")
		helpers.assert_eq(fixture.counters.notifications, 0)
		helpers.assert_eq(fixture.counters.updates, 0)
	end)

	helpers.it("contains activate-then-throw and applies the same rollback", function()
		local running = false
		local calls = {}
		local fixture = load_menu_fixture({
			resume_bindings = function()
				calls[#calls + 1] = "resume"
				running = true
				error("RESUME_THROW", 0)
			end,
			pause_bindings = function()
				calls[#calls + 1] = "pause"
				running = false
				return true
			end,
		}, false)

		local call_ok, committed = pcall(fixture.action)
		helpers.assert_true(call_ok)
		helpers.assert_eq(committed, false)
		helpers.assert_eq(calls, { "resume", "pause" })
		helpers.assert_true(not running)
		helpers.assert_eq(fixture.state.shortcuts, false)
		helpers.assert_eq(fixture.counters.saves, 0)
	end)

	helpers.it("persists and publishes only after exact runtime success", function()
		local calls = {}
		local fixture = load_menu_fixture({
			resume_bindings = function() calls[#calls + 1] = "resume"; return true end,
			pause_bindings = function() calls[#calls + 1] = "pause"; return true end,
		}, false)

		helpers.assert_eq(fixture.action(), true)
		helpers.assert_eq(calls, { "resume" })
		helpers.assert_eq(fixture.state.shortcuts, true)
		helpers.assert_eq(fixture.counters.saves, 1)
		helpers.assert_eq(fixture.counters.notifications, 1)
		helpers.assert_eq(fixture.counters.updates, 1)
	end)

	for _, previous in ipairs({ false, true }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls back a mutate-then-" .. mode .. " shortcut edge", function()
				local running = previous
				local calls = {}
				local function boundary(name, desired, result_mode)
					return function(claim)
						calls[#calls + 1] = { name = name, claim = claim }
						running = desired
						if result_mode == "false" then return false end
						if result_mode == "nil" then return nil end
						if result_mode == "throw" then error("synthetic lifecycle refusal") end
						return true
					end
				end
				local fixture = load_menu_fixture({
					resume_bindings = boundary("resume", true,
						previous and "true" or mode),
					pause_bindings = boundary("pause", false,
						previous and mode or "true"),
				}, previous)
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(running, previous)
				helpers.assert_eq(fixture.state.shortcuts, previous)
				helpers.assert_eq(#calls, 2)
				for _, call in ipairs(calls) do
					helpers.assert_eq(call.claim, "feature_toggle")
				end
				helpers.assert_eq(fixture.counters.saves, 0)
				helpers.assert_eq(fixture.counters.notifications, 0)
			end)
		end

		for _, inverse_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("blocks on shortcut inverse " .. inverse_mode .. " debt", function()
				local running = previous
				local calls = {}
				local call_index = 0
				local function edge(name, desired)
					return function(claim)
						call_index = call_index + 1
						calls[#calls + 1] = { name = name, claim = claim }
						if call_index == 1 then running = desired; return false end
						if inverse_mode == "throw" then error("inverse refusal") end
						if inverse_mode == "nil" then return nil end
						return false
					end
				end
				local fixture = load_menu_fixture({
					resume_bindings = edge("resume", true),
					pause_bindings = edge("pause", false),
				}, previous)
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(fixture.scope_idle(), false, "a retained master inverse blocks scope capture")
				helpers.assert_eq(fixture.action(), false,
					"the next click must retry only the retained inverse")
				helpers.assert_eq(#calls, 3)
				for _, call in ipairs(calls) do
					helpers.assert_eq(call.claim, "feature_toggle")
				end
				helpers.assert_eq(fixture.state.shortcuts, previous)
				helpers.assert_eq(fixture.counters.saves, 0)
			end)
		end

		for _, save_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls runtime back when shortcut save returns " .. save_mode, function()
				local running = previous
				local calls = {}
				local fixture = load_menu_fixture({
					resume_bindings = function(claim)
						calls[#calls + 1] = claim; running = true; return true
					end,
					pause_bindings = function(claim)
						calls[#calls + 1] = claim; running = false; return true
					end,
				}, previous, { save_mode = save_mode })
				helpers.assert_eq(fixture.action(), false)
				helpers.assert_eq(running, previous)
				helpers.assert_eq(fixture.state.shortcuts, previous)
				helpers.assert_eq(calls, { "feature_toggle", "feature_toggle" })
				helpers.assert_eq(fixture.counters.notifications, 0)
				helpers.assert_eq(fixture.counters.updates, 0)
			end)

			for _, inverse_mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("retains shortcut debt when save " .. save_mode
					.. " and inverse " .. inverse_mode, function()
					local running = previous
					local calls = {}
					local call_index = 0
					local function edge(name, desired)
						return function(claim)
							call_index = call_index + 1
							calls[#calls + 1] = { name = name, claim = claim }
							if call_index == 1 then running = desired; return true end
							if inverse_mode == "throw" then error("inverse refusal") end
							if inverse_mode == "nil" then return nil end
							return false
						end
					end
					local fixture = load_menu_fixture({
						resume_bindings = edge("resume", true),
						pause_bindings = edge("pause", false),
					}, previous, { save_mode = save_mode })
					helpers.assert_eq(fixture.action(), false)
					helpers.assert_eq(fixture.state.shortcuts, previous)
					helpers.assert_eq(running, not previous,
						"the adverse inverse remains explicit runtime debt")
					helpers.assert_eq(fixture.action(), false,
						"the next click retries only retained save rollback debt")
					helpers.assert_eq(#calls, 3)
					for _, call in ipairs(calls) do
						helpers.assert_eq(call.claim, "feature_toggle")
					end
					helpers.assert_eq(fixture.counters.saves, 1,
						"debt settlement may not repeat the failed preference write")
					helpers.assert_eq(fixture.counters.notifications, 0)
					helpers.assert_eq(fixture.counters.updates, 0)
				end)
			end
		end
	end
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Menu-State Exact Result Gate =======
-- ===============================================
-- ===============================================

helpers.describe("menu-state shortcut synchronization requires exact lifecycle success", function()
	helpers.it("returns false when resume_bindings returns false", function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["modules.keylogger.text_cipher"] = { set_enabled = function() end }
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")

		local state = {
			shortcuts = true,
			hotstrings = {},
			keymap = false,
			keylogger_enabled = false,
		}
		local result = MenuState.sync_state_to_modules(state, {}, false,
			state_sync_deps({ resume_bindings = function() return false end }))
		helpers.assert_eq(result, false,
			"a contained native refusal is still a failed runtime synchronization")
	end)

	helpers.it("returns true only for an exact true pause result", function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["modules.keylogger.text_cipher"] = { set_enabled = function() end }
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")

		local state = {
			shortcuts = false,
			hotstrings = {},
			keymap = false,
			keylogger_enabled = false,
		}
		local result = MenuState.sync_state_to_modules(state, {}, false,
			state_sync_deps({ pause_bindings = function() return true end }))
		helpers.assert_eq(result, true)
	end)
end)


-- The chord switch uses the same global and canonical preference owners as the
-- menubar. Only the logical native gate is controllable; no Karabiner deployment
-- or physical input acknowledgement is inferred from that Boolean receipt.
local function with_chord_fixture(mode, body)
	return helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger",
		"infra.dialog_util", "infra.i18n", "infra.manifest_menu", "infra.fs_dir", "infra.notifications",
		"ui.menu.menu_shortcuts", "ui.menu.script_chords_transaction", "ui.menu.preferences_transaction",
		"ui.menu.global_actions_transaction", "ui.menu.menu_state", "modules.shortcuts",
		"modules.shortcuts.actions.text", "ui.menu.menu_utils", "ui.menu.shortcut_utils",
		"ui.menu.menu_keyboard_slots", "ui.menu.menu_tap_keys", "infra.manifest_reader",
		"adapters.json_codec", "menu.renderer", "logger.shim" }, function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		local Transaction = require("ui.menu.preferences_transaction")
		local Global = require("ui.menu.global_actions_transaction")
		local Chords = require("ui.menu.script_chords_transaction")
		local MenuState = require("ui.menu.menu_state")
		local old_rename = os.rename
		local FileSystem = require("adapters.file_system")
		local old_write = FileSystem.write_if_unchanged
		local failure, inverse_blocked, paused, terminal = mode, false, false, false
		local called, result = xpcall(function()
			return require("tests.support.toml_output_fixture").with_output(function(path)
				local source = '# retained chord header\n[shortcuts]\nenabled = false\n[shortcuts.script_control]\nchords_enabled = true\nfuture = "retain" # neighbor\n[foreign]\nflag = false # independent\n'
				local file = assert(io.open(path, "wb")); assert(file:write(source)); file:close()
				local loaded, status = Preferences.load(path)
				helpers.assert_eq(status, "ok")
				local state = { script_control_enabled = loaded.script_control_enabled, shortcuts = loaded.shortcuts,
					script_control_shortcuts = {}, custom_wrap_symbols = {}, wrap_symbol_states = {}, chatgpt_url = "https://example.test" }
				local slots = state.script_control_shortcuts
				local calls = { native = 0, saves = 0, writes = 0, updates = 0, forward_after_write = 0 }
				local runtime, after_native, reentry = true, nil, nil
				local facade = { ACTIONS = {}, script_chord_slots = function() return {} end,
					pause_bindings = function() return true end, resume_bindings = function() return true end }
				function facade.script_chords_enabled()
					if failure == "getter_throw" then error("injected getter refusal", 0) end
					if failure == "getter_invalid" then return 2 end
					return runtime
				end
				function facade.set_script_chords_enabled(value)
					calls.native = calls.native + 1
					if calls.writes > 0 and value == true then calls.forward_after_write = calls.forward_after_write + 1 end
					if value == true and inverse_blocked then return false end
					if value == false then
						if failure == "setter_false" then return false end
						if failure == "setter_nil" then return nil end
						if failure == "setter_truthy" then runtime = value; return 2 end
						if failure == "setter_throw" then runtime = value; error("injected setter refusal", 0) end
						if failure == "setter_unapplied" then return true end
					end
					runtime = value
					if after_native then local fn = after_native; after_native = nil; reentry = fn() end
					return true
				end
				local native_setter, native_getter = facade.set_script_chords_enabled, facade.script_chords_enabled
				if failure == "getter_missing" then facade.script_chords_enabled = nil end
				if failure == "setter_missing" then facade.set_script_chords_enabled = nil end
				os.rename = function(from, to)
					if to == path then
						calls.writes = calls.writes + 1
						if failure == "write_false" or failure == "inverse_debt" then
							if failure == "inverse_debt" then inverse_blocked = true end
							return false, "controlled canonical publication refusal"
						end
						if failure == "write_nil" then return nil end
						if failure == "write_throw" then error("controlled canonical publication exception", 0) end
					end
					return old_rename(from, to)
				end
				FileSystem.write_if_unchanged = function(target, content, expected_source)
					if target == path and failure == "write_truthy" then calls.writes = calls.writes + 1; return 2 end
					return old_write(target, content, expected_source)
				end
				local owner
				local save = Transaction.bind(Preferences, { path = path, state = state,
					initial_state = Transaction.clone(state), initial_preferences = Transaction.clone(state),
					hotfiles = {}, core_modules = {}, restore_runtime = function(snapshot)
						if owner.pending() and owner.restore_runtime() ~= true then return false end
						local modules = owner.rollback_modules({ shortcuts_mod = facade })
						if type(modules) ~= "table" then return false end
						local acknowledged, report = MenuState.sync_state_to_modules(state, snapshot, false, { core_mods = modules, hotstring_editor = {} })
						calls.rollback = acknowledged; calls.rollback_report = report
						if acknowledged ~= true then return false end
						return not owner.pending() or owner.restore_runtime() == true
					end })
				local function accepted() return true end
				local global = assert(Global.create({ state = state,
					capture_preferences = function() return Transaction.clone(state) end, sync_runtime = accepted,
					restore_state = accepted, settings = { get = function() return nil end, set = accepted, get_keys = function() return {} end },
					file_mover = { capture = accepted, move = accepted, restore = accepted },
					reset_journal = { prepare = accepted, mark_commit = accepted, mark_prepared = accepted, clear = accepted },
					gestures = { get_action = accepted, set_action = accepted, enable_all = accepted, disable_all = accepted },
					shortcuts = { set_shortcut_action = accepted, get_keyboard_action = accepted, set_keyboard_action = accepted, get_keyboard_assignments = accepted },
					karabiner = { snapshot_settings = accepted, reset_to_defaults = accepted, restore_settings = accepted },
					request_reload = accepted, terminal_pending = function() return terminal end }))
				local function raw_save() calls.saves = calls.saves + 1; return save() end
				owner = Chords.new({ state = state, script_control = facade, admission = global.run_exclusive,
					paused = function() return paused end, save_prefs = raw_save })
				package.loaded["infra.i18n"] = { get = function(key) return key end, section = function(key) return key end, decorate_section = function(value) return value end }
				package.loaded["modules.shortcuts"] = { DEFAULT_STATE = { shortcuts = true, chatgpt_url = "https://example.test" } }
				package.loaded["modules.shortcuts.actions.text"] = { WRAP_GROUPS = {}, build_active_wrap_pairs = function() return {} end }
				package.loaded["infra.fs_dir"] = { entries = function() return {} end }
				package.loaded["infra.dialog_util"] = {}
				package.loaded["ui.menu.menu_utils"] = {}
				package.loaded["ui.menu.shortcut_utils"] = {}
				package.loaded["ui.menu.menu_keyboard_slots"] = { provide_rows = function() return {} end }
				package.loaded["ui.menu.menu_tap_keys"] = { provide_rows = function() return {} end }
				local renderer = assert(require("menu.renderer").new({ platform = "hs",
					manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
					json_decode = require("adapters.json_codec").decode, i18n = package.loaded["infra.i18n"], logger = require("infra.logger") }))
				package.loaded["infra.manifest_menu"] = renderer
				local context = { state = state, shortcuts = {}, script_control = facade, paused = false,
					commit_script_chords = owner.toggle, save_prefs = function() return global.run_exclusive("Legacy chord save", raw_save) end,
					updateMenu = function() calls.updates = calls.updates + 1 end, notify_feature = accepted, commands = {}, state_getters = {} }
				local function find(rows)
					for _, row in ipairs(rows or {}) do
						if row.title == "menu.shortcuts.script_shortcuts_enable" then return row.fn end
						local nested = find(row.menu or row.submenu)
						if nested then return nested end
					end
				end
				local menu = require("ui.menu.menu_shortcuts").build(context)
				local action = assert(find(menu.submenu), "actual shared script-chord row missing")
				local function read()
					local input = assert(io.open(path, "rb")); local data = input:read("*a"); input:close(); return data
				end
				body({ action = action, owner = owner, global = global, state = state, slots = slots,
					calls = calls, runtime = function() return runtime end, read = read, source = source,
					preferences = Preferences, path = path, facade = facade,
					set_pause = function(value) paused = value end, set_terminal = function(value) terminal = value end,
					set_runtime = function(value) runtime = value end, set_after_native = function(fn) after_native = fn end,
					reentry = function() return reentry end,
					clear_failure = function() failure = "ok"; inverse_blocked = false;
						facade.script_chords_enabled = native_getter; facade.set_script_chords_enabled = native_setter end })
			end)
		end, debug.traceback)
		os.rename = old_rename
		FileSystem.write_if_unchanged = old_write
		if not called then error(result, 0) end
		return result
	end)
end

local function assert_chord_retained(f)
	helpers.assert_eq(f.state.script_control_enabled, true)
	helpers.assert_eq(f.runtime(), true)
	helpers.assert_eq(f.read(), f.source)
	helpers.assert_eq(f.state.shortcuts, false)
	helpers.assert_true(rawequal(f.state.script_control_shortcuts, f.slots))
	helpers.assert_eq(f.calls.updates, 0)
end

helpers.describe("script chord logical mutation admission", function()
	helpers.it("refuses global admission before native, RAM or private writer entry", function()
		with_chord_fixture("ok", function(f)
			local observed
			local outer = f.global.run_exclusive("Held independent owner", function() observed = f.action(); return true end)
			helpers.assert_eq({ outer, observed }, { true, false })
			helpers.assert_eq(f.calls.native, 0)
			helpers.assert_eq(f.calls.saves, 0)
			assert_chord_retained(f)
		end)
	end)
	for _, mode in ipairs({ "getter_missing", "getter_invalid", "getter_throw", "setter_missing", "setter_false", "setter_nil", "setter_truthy", "setter_throw", "setter_unapplied" }) do
		helpers.it("refuses unacknowledged native gate " .. mode .. " without durable publication", function()
			with_chord_fixture(mode, function(f)
				local called, result = pcall(f.action)
				f.clear_failure()
				helpers.assert_eq({ called, result }, { true, false })
				helpers.assert_eq(f.calls.saves, 0)
				assert_chord_retained(f)
			end)
		end)
	end
	for _, mode in ipairs({ "write_false", "write_nil", "write_truthy", "write_throw" }) do
		helpers.it("compensates real canonical publication " .. mode .. " and retries the held row", function()
			with_chord_fixture(mode, function(f)
				local called, result = pcall(f.action)
				helpers.assert_eq({ called, result }, { true, false })
				helpers.assert_true(f.calls.writes > 0)
				helpers.assert_eq(f.calls.rollback, true)
				assert_chord_retained(f)
				f.clear_failure()
				helpers.assert_eq(f.action(), true)
				helpers.assert_eq(f.state.script_control_enabled, false)
				helpers.assert_eq(f.runtime(), false)
				helpers.assert_eq(f.calls.updates, 1)
				local saved, status = f.preferences.load(f.path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(saved.script_control_enabled, false)
				helpers.assert_eq(saved.shortcuts, nil)
				helpers.assert_eq(require("infra.manifest_reader").default_for("shortcuts.enabled"), false)
				helpers.assert_true(f.read():find('future = "retain" # neighbor', 1, true) ~= nil)
				helpers.assert_true(f.read():find('flag = false # independent', 1, true) ~= nil)
			end)
		end)
	end
	helpers.it("uses the fresh native gate for a retained callback and keeps neutral true sparse", function()
		with_chord_fixture("ok", function(f)
			f.set_runtime(false); f.state.script_control_enabled = false
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.runtime(), true)
			helpers.assert_eq(f.state.script_control_enabled, true)
			local saved, status = f.preferences.load(f.path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(saved.script_control_enabled, nil)
			helpers.assert_eq(require("infra.manifest_reader").default_for("shortcuts.script_control.chords_enabled"), true)
			local decoded = require("infra.toml.codec").decode(f.read())
			helpers.assert_eq(decoded.shortcuts.script_control.chords_enabled, nil)
			helpers.assert_eq(f.calls.updates, 1)
		end)
	end)
	helpers.it("revokes a held row on actual pause and after native admission", function()
		with_chord_fixture("ok", function(f)
			f.set_pause(true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.native, 0)
			f.set_pause(false); f.set_after_native(function() f.set_pause(true) end)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.saves, 0)
			assert_chord_retained(f)
		end)
	end)
	helpers.it("retains failed inverse debt and blocks a successor until actual readback recovery", function()
		with_chord_fixture("inverse_debt", function(f)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.owner.pending(), true)
			local previous_saves = f.calls.saves
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(f.calls.saves, previous_saves)
			helpers.assert_eq(f.read(), f.source)
			f.clear_failure()
			helpers.assert_eq(f.owner.retry_restore(), true)
			helpers.assert_eq(f.owner.pending(), false)
			assert_chord_retained(f)
		end)
	end)
	helpers.it("keeps the observed native inverse across actual whole-preference rollback", function()
		with_chord_fixture("write_false", function(f)
			f.set_runtime(false)
			local called, result = pcall(f.action)
			helpers.assert_eq({ called, result }, { true, false })
			helpers.assert_eq(f.calls.rollback, true)
			helpers.assert_eq(f.calls.forward_after_write, 0)
			helpers.assert_eq(f.runtime(), false)
			helpers.assert_eq(f.state.script_control_enabled, true)
			helpers.assert_eq(f.read(), f.source)
			helpers.assert_eq(f.calls.updates, 0)
		end)
	end)
	helpers.it("retains debt instead of applying the inverse through a foreign native setter", function()
		with_chord_fixture("ok", function(f)
			local captured = f.facade.set_script_chords_enabled
			local foreign_calls = 0
			f.set_after_native(function()
				f.facade.set_script_chords_enabled = function() foreign_calls = foreign_calls + 1; return true end
			end)
			local called, result = pcall(f.action)
			helpers.assert_eq({ called, result }, { true, false })
			helpers.assert_eq(f.owner.pending(), true)
			helpers.assert_eq(f.action(), false)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(f.calls.saves, 0)
			helpers.assert_eq(f.read(), f.source)
			f.facade.set_script_chords_enabled = captured
			helpers.assert_eq(f.owner.retry_restore(), true)
			assert_chord_retained(f)
		end)
	end)
	helpers.it("refuses reentry during the acknowledged native setter", function()
		with_chord_fixture("ok", function(f)
			f.set_after_native(f.action)
			helpers.assert_eq(f.action(), true)
			helpers.assert_eq(f.reentry(), false)
			helpers.assert_eq(f.calls.saves, 1)
			helpers.assert_eq(f.calls.updates, 1)
		end)
	end)
end)

helpers.describe("script chord fixture borrowed cache ownership", function()
	for _, populated in ipairs({ false, true }) do
		helpers.it("restores borrowed renderer cache " .. (populated and "present" or "absent"), function()
			local names = { "adapters.json_codec", "menu.renderer", "logger.shim" }
			helpers.with_fresh_modules(names, function()
				local previous, previous_hs = {}, rawget(_G, "hs")
				for _, name in ipairs(names) do
					if populated then package.loaded[name] = { cache_owner = name } end
					previous[name] = package.loaded[name]
				end
				local observed
				with_chord_fixture("ok", function(f) observed = f.action() end)
				helpers.assert_eq(observed, true)
				for _, name in ipairs(names) do
					helpers.assert_true(rawequal(package.loaded[name], previous[name]))
				end
				helpers.assert_true(rawequal(rawget(_G, "hs"), previous_hs))
			end)
		end)
	end
end)

return true
