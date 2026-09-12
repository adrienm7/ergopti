--- tests/support/profile_delete_fixture.lua

--- ==============================================================================
--- MODULE: Profile Deletion Transaction Fixture
--- DESCRIPTION:
--- Shares native hotkey and persistence doubles across shortcut and profile
--- deletion scenarios while owning the real consumers' module cache lifetime.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.hotkey_registrar",
	"adapters.timer_scheduler",
	"chord",
	"infra.app_picker",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_menu",
	"infra.notifications",
	"modules.llm",
	"ui.menu.menu_llm.profile_label",
	"ui.menu.menu_llm.model_switcher",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.menu_llm.trigger_orchestrator",
	"ui.menu.menu_llm.trigger_panel",
	"ui.menu.shortcut_utils",
	"ui.menu.preferences_transaction",
	"ui.prompt_editor",
}

--- Clones plain state so durable snapshots never alias the live candidate.
--- @param value any Value to clone.
--- @return any clone
local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key)] = clone(child) end
	return result
end

--- Returns the first menu row carrying the requested label.
--- @param rows table Menu rows.
--- @param label string Exact label.
--- @return table|nil row
local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if row.label == label then return row end
	end
	return nil
end

--- Builds one native-shaped hotkey backend shared by the scripted registrar
--- seam and the real registrar composition exercised below.
--- @return table backend
local function make_hotkey_backend()
	local backend = {
		entries = {},
		plans = {},
		calls = {},
		next_id = 0,
	}

--- Replaces the outcomes consumed by one registrar-seam or native operation.
	--- @param operation string Operation name.
	--- @param outcomes table Array of scripted terminal labels.
	function backend.plan(operation, outcomes)
		backend.plans[operation] = clone(outcomes or {})
	end

	--- Consumes one configured outcome, defaulting to success.
	--- @param operation string Operation name.
	--- @return string outcome
	local function next_outcome(operation)
		local queue = backend.plans[operation]
		if type(queue) == "table" and #queue > 0 then
			return table.remove(queue, 1)
		end
		return "ok"
	end

	--- Applies a configured exact registrar-seam terminal.
	--- @param operation string Operation name.
	--- @return boolean|nil result
	local function seam_terminal(operation)
		backend.calls[#backend.calls + 1] = operation
		local outcome = next_outcome(operation)
		if outcome == "throw" then error(operation .. " refused", 0) end
		if outcome == "false" then return false end
		if outcome == "nil" then return nil end
		return true
	end

	--- Allocates a native Hammerspoon-shaped handle. enable/disable return the
	--- exact hotkey object on success; enable returns nil on refusal; delete is void.
	--- @param callback function Press callback.
	--- @param enabled boolean Initial native delivery state.
	--- @param chord string Canonical chord held by the native registration.
	--- @return table handle
	local function allocate_native(callback, enabled, chord)
		backend.next_id = backend.next_id + 1
		local handle = {
			id = backend.next_id,
			callback = callback,
			chord = chord,
			enabled = enabled == true,
			deleted = false,
		}
		function handle:enable()
			backend.calls[#backend.calls + 1] = "native_enable"
			local outcome = next_outcome("native_enable")
			if outcome == "throw" then error("native enable refused", 0) end
			if outcome == "nil" then return nil end
			self.enabled = true
			return self
		end
		function handle:disable()
			backend.calls[#backend.calls + 1] = "native_disable"
			local outcome = next_outcome("native_disable")
			if outcome == "throw" then error("native disable refused", 0) end
			self.enabled = false
			return self
		end
		function handle:delete()
			backend.calls[#backend.calls + 1] = "native_delete"
			local outcome = next_outcome("native_delete")
			if outcome == "throw" then error("native delete refused", 0) end
			self.enabled = false
			self.deleted = true
			backend.entries[self] = nil
			return nil
		end
		backend.entries[handle] = handle
		backend.latest = handle
		return handle
	end

	--- Applies the hs.hotkey constructor contract: object, nil refusal, or throw.
	--- @param callback function Press callback.
	--- @param enabled boolean Initial native delivery state.
	--- @param chord string Canonical chord.
	--- @return table|nil handle
	function backend.create_native(callback, enabled, chord)
		backend.calls[#backend.calls + 1] = "native_new"
		local outcome = next_outcome("native_new")
		if outcome == "throw" then error("native new refused", 0) end
		if outcome == "nil" then return nil end
		return allocate_native(callback, enabled, chord)
	end

	--- Invokes a handle only when its native state still permits delivery.
	--- @param handle table Handle to fire.
	--- @return any result
	function backend.fire(handle)
		if not handle or handle.deleted or handle.enabled ~= true then return nil end
		return handle.callback()
	end

	backend.registrar = {
		bind = function(chord, callback)
			local result = seam_terminal("new")
			if result ~= true then return result end
			return allocate_native(callback, true, chord)
		end,
		setEnabled = function(handle, enabled)
			local operation = enabled and "enable" or "disable"
			local result = seam_terminal(operation)
			if result == true then handle.enabled = enabled == true end
			return result
		end,
		unbind = function(handle)
			local result = seam_terminal("delete")
			if result == true then
				handle.enabled = false
				handle.deleted = true
				backend.entries[handle] = nil
			end
			return result
		end,
	}

	return backend
end

--- Loads the real trigger owner with deterministic native and persistence ports.
--- @param options table|nil Fixture options.
--- @param body function Fixture callback.
local function with_trigger_fixture(options, body)
	options = options or {}
	local saved_hs = _G.hs
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end

	local ok, err = xpcall(function()
		-- Real transitive consumers must capture this fixture's native and logger
		-- boundaries rather than retaining a previous scenario's dependencies.
		for _, name in ipairs(MODULES) do package.loaded[name] = nil end
		local backend = make_hotkey_backend()
		local prediction_count = 0
		local runtime_profile = options.active_profile or "basic"
		local runtime_profiles = options.user_profiles or {
			{id = "user_p", label = "Profile P"},
		}
		local set_profiles_plan = {}
		local set_profiles_calls = {}

		if options.real_registrar then
			package.loaded["adapters.hotkey_registrar"] = nil
			package.loaded["chord"] = nil
		else
			package.loaded["adapters.hotkey_registrar"] = backend.registrar
			package.loaded["chord"] = {
				format = function(mods, key)
					if type(mods) ~= "table" or type(key) ~= "string" then return nil, "invalid" end
					return table.concat(mods, "+") .. "+" .. key
				end,
			}
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {llm_num_predictions = 1},
			BUILTIN_PROFILES = {
				{id = "basic", label = "Basic"},
				{id = "advanced", label = "Advanced"},
				{id = "raw", label = "Raw"},
			},
			set_active_profile = function(profile_id)
				runtime_profile = profile_id
				return true
			end,
			get_active_profile = function() return {id = runtime_profile} end,
			set_user_profiles = function(profiles)
				local outcome = table.remove(set_profiles_plan, 1) or "ok"
				set_profiles_calls[#set_profiles_calls + 1] = profiles
				if outcome == "throw" then error("set_user_profiles refused", 0) end
				if outcome == "false" then return false end
				if outcome == "nil" then return nil end
				runtime_profiles = profiles
				return true
			end,
			get_all_profiles = function()
				local all = {
					{id = "basic", label = "Basic"},
					{id = "advanced", label = "Advanced"},
					{id = "raw", label = "Raw"},
				}
				for _, profile in ipairs(runtime_profiles) do all[#all + 1] = profile end
				return all
			end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {
			normalize_shortcut = function(mods, key)
				if type(mods) ~= "table" or #mods == 0 or type(key) ~= "string" or key == "" then
					return nil
				end
				return {mods = clone(mods), key = key}
			end,
			prompt_shortcut = function() return true end,
		}

		_G.hs = {
			hotkey = {
				bind = function(mods, key, callback)
					return backend.create_native(callback, true, table.concat(mods, "+") .. "+" .. key)
				end,
				new = function(mods, key, callback)
					return backend.create_native(callback, false, table.concat(mods, "+") .. "+" .. key)
				end,
			},
			timer = {doAfter = function(_, callback) callback(); return {} end},
		}

		local state = {
			llm_active_profile = options.active_profile or "basic",
			llm_trigger_shortcut = options.primary_shortcut or false,
			llm_profile_shortcuts = clone(options.profile_shortcuts or {}),
			llm_user_profiles = runtime_profiles,
			llm_num_predictions = 1,
		}
		local durable = clone(state)
		local menu_snapshot = clone(state)
		local save_plan = {}
		local save_count = 0
		local menu_plan = {}
		local menu_count = 0
		local trigger_hk = nil
		local profile_hks = {}
		local startup_silence = false
		local keymap = {
			trigger_prediction = function()
				prediction_count = prediction_count + 1
				return true
			end,
			reset_predictions = function() return true end,
		}

		local function save_prefs()
			save_count = save_count + 1
			local outcome = table.remove(save_plan, 1) or "ok"
			if outcome == "throw" then error("save refused", 0) end
			if outcome == "fire_all_ok" then
				for handle in pairs(backend.entries) do backend.fire(handle) end
				durable = clone(state)
				return true
			end
			if outcome == "restore_false" then
				local restored = clone(durable)
				for key in pairs(state) do state[key] = nil end
				for key, value in pairs(restored) do state[key] = value end
				return false
			end
			if outcome == "false" then return false end
			if outcome == "nil" then return nil end
			durable = clone(state)
			return true
		end

		local function update_menu()
			menu_count = menu_count + 1
			menu_snapshot = clone(state)
			local outcome = table.remove(menu_plan, 1) or "ok"
			if outcome == "throw" then error("menu refused", 0) end
			if outcome == "fire_all_ok" then
				for handle in pairs(backend.entries) do backend.fire(handle) end
				return true
			end
			if outcome == "false" then return false end
			if outcome == "nil" then return nil end
			return true
		end

		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = nil
		local orchestrator = require("ui.menu.menu_llm.trigger_orchestrator").new({
			state = state,
			keymap = keymap,
			save_prefs = save_prefs,
			update_menu = update_menu,
			get_startup_silence = function() return startup_silence end,
			set_startup_silence = function(value) startup_silence = value end,
			get_trigger_hk = function() return trigger_hk end,
			set_trigger_hk = function(value) trigger_hk = value end,
			get_profile_hks = function() return profile_hks end,
			set_profile_hk = function(profile_id, value) profile_hks[profile_id] = value end,
		})

		body({
			acknowledge = function()
				durable = clone(state)
				menu_snapshot = clone(state)
			end,
			backend = backend,
			durable = function() return durable end,
			fire = backend.fire,
			get_menu_count = function() return menu_count end,
			get_menu_snapshot = function() return menu_snapshot end,
			get_last_native_handle = function() return backend.latest end,
			get_prediction_count = function() return prediction_count end,
			get_profile_hk = function(profile_id) return profile_hks[profile_id] end,
			get_runtime_profile = function() return runtime_profile end,
			get_runtime_profiles = function() return runtime_profiles end,
			get_save_count = function() return save_count end,
			get_set_profiles_calls = function() return set_profiles_calls end,
			get_trigger_hk = function() return trigger_hk end,
			orchestrator = orchestrator,
			plan_profiles = function(outcomes) set_profiles_plan = clone(outcomes) end,
			plan_menu = function(outcomes) menu_plan = clone(outcomes) end,
			plan_save = function(outcomes) save_plan = clone(outcomes) end,
			save_prefs = save_prefs,
			reset_observations = function()
				backend.calls = {}
				menu_count = 0
				prediction_count = 0
				save_count = 0
				set_profiles_calls = {}
			end,
			set_runtime_profile = function(profile_id) runtime_profile = profile_id end,
			set_startup_silence = function(value) startup_silence = value == true end,
			state = state,
			update_menu = update_menu,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Runs the real ProfilesManager Delete action over the real trigger owner.
--- @param options table Scenario options.
--- @param body function Fixture callback.
local function with_delete_fixture(options, body)
	with_trigger_fixture({
		active_profile = options.active_profile or "basic",
		user_profiles = {{id = "user_p", label = "Profile P"}},
		profile_shortcuts = {user_p = {mods = {"ctrl"}, key = "p"}},
	}, function(fixture)
		local recommendation_dialog_count = 0
		package.loaded["infra.dialog_util"] = {
			block_alert = function(_, _, confirm_label)
				if confirm_label == "button.delete" then return "button.delete" end
				recommendation_dialog_count = recommendation_dialog_count + 1
				return "button.cancel"
			end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
		}
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
		}
		package.loaded["infra.notifications"] = {notify = function() return true end}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["ui.prompt_editor"] = {open = function() return true end}

		fixture.state.llm_backend = options.pending_model and "mlx" or "ollama"
		fixture.state.llm_enabled = true
		fixture.state.llm_model = "A"
		fixture.state.llm_model_power = 1
		fixture.state.llm_model_mlx = "A"
		fixture.state.llm_model_ollama = "A"
		fixture.state.llm_num_predictions = 1
		fixture.state.llm_profile_shortcuts = {}
		helpers.assert_eq(fixture.orchestrator.apply_llm_profile_shortcut(
			"user_p", {"ctrl"}, "p", {persist = false}), true)
		local old_handle = fixture.get_profile_hk("user_p")
		fixture.reset_observations()

		local pending = {}
		local models_mgr = {
			check_requirements = function(model_name, on_success, on_failure, opts)
				pending[model_name] = {
					success = on_success,
					failure = on_failure,
					opts = opts,
				}
				return true
			end,
			get_actual_model_name = function(model_name)
				return "actual:" .. tostring(model_name)
			end,
			get_model_info = function(model_name)
				if model_name == "starcoder2-3b" then
					return {type = "completion", params = 3}
				end
				return {params = 1}
			end,
			get_presets = function() return {} end,
		}
		local deps = {
			state = fixture.state,
			script_control = {is_paused = function() return false end},
			apply_llm_profile_shortcut = fixture.orchestrator.apply_llm_profile_shortcut,
			save_prefs = fixture.save_prefs,
			update_menu = fixture.update_menu,
		}
		local switcher = nil
		if options.real_switcher then
			package.loaded["ui.menu.menu_llm.model_switcher"] = nil
			switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = fixture.state,
				models_mgr = models_mgr,
				keymap = {
					set_llm_enabled = function() return true end,
					set_llm_model = function() return true end,
					set_llm_display_model_name = function() return true end,
				},
				save_prefs = fixture.save_prefs,
				update_menu = fixture.update_menu,
				profile_mutation_gate = function()
					local gate = deps.settle_profile_delete_recovery
					if gate == nil then return true end
					return gate()
				end,
			})
			deps.set_llm_profile = switcher.set_llm_profile
			deps.settle_llm_switcher_recovery = switcher.settle_recovery_debts
		else
			deps.set_llm_profile = function(profile_id, opts)
				opts = type(opts) == "table" and opts or {}
				fixture.state.llm_active_profile = profile_id
				fixture.set_runtime_profile(profile_id)
				if opts.persist == false then return true end
				return false
			end
		end

		-- The trigger fixture exposes its save through the orchestrator only for
		-- this real multi-owner transaction; production receives the same closure
		package.loaded["ui.menu.menu_llm.profiles_manager"] = nil
		local manager = require("ui.menu.menu_llm.profiles_manager").new(deps, models_mgr)
		local profile_rows = manager.get_menu_item().menu
		local custom = find_row(profile_rows, "Profile P")
		local advanced = find_row(profile_rows, "Advanced")
		local shortcut_row = find_row(custom and custom.items, "menu.profiles.shortcut_prefix")
		local delete_row = find_row(custom and custom.items, "menu.profiles.delete_profile")
		if options.real_switcher then
			helpers.assert_type(advanced and advanced.action, "function")
		end
		helpers.assert_type(shortcut_row and shortcut_row.action, "function")
		helpers.assert_type(delete_row and delete_row.action, "function")
		fixture.acknowledge()
		fixture.reset_observations()
		fixture.pending = pending
		fixture.switcher = switcher
		fixture.get_recommendation_dialog_count = function()
			return recommendation_dialog_count
		end
		body(fixture, delete_row.action, old_handle, shortcut_row.action,
			advanced and advanced.action)
	end)
end

return {
	with_trigger_fixture = with_trigger_fixture,
	with_delete_fixture = with_delete_fixture,
}
