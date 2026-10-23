--- tests/support/ui/menu/menu_llm/profiles/profile_candidate_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_profile_candidate_transaction
--- DESCRIPTION:
--- Prelude shared by the test_profile_candidate_transaction_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.timer_scheduler",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_menu",
	"infra.notifications",
	"modules.llm",
	"ui.menu.menu_llm.model_switcher",
	"ui.menu.menu_llm.profile_label",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.shortcut_utils",
	"ui.menu.preferences_transaction",
	"ui.prompt_editor",
}

--- Clones plain state so durable and rendered snapshots cannot alias live tables.
--- @param value any Value to clone.
--- @return any clone
local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key)] = clone(child) end
	return result
end

--- Finds one exact rendered row.
--- @param rows table Menu rows.
--- @param label string Exact row label.
--- @return table|nil row
local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if row.label == label then return row end
	end
	return nil
end

--- Finds one exact child row below an exact rendered parent.
--- @param rows table Menu rows.
--- @param parent_label string Exact parent label.
--- @param child_label string Exact child label.
--- @return table|nil row
local function find_child_row(rows, parent_label, child_label)
	local parent = find_row(rows, parent_label)
	return parent and find_row(parent.items, child_label) or nil
end

--- Restores every singleton replaced by a fixture.
--- @param saved table Saved package entries.
local function restore_modules(saved)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
end

--- Loads real candidate/profile owners over deterministic runtime boundaries.
--- @param options table|nil Scenario options.
--- @param body function Fixture callback.
local function with_fixture(options, body)
	options = options or {}
	local saved_hs = _G.hs
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end

	local ok, err = xpcall(function()
		local builtins = {
			{id = "basic", label = "Basic"},
			{id = "advanced", label = "Advanced"},
		}
		local initial_profiles = options.initial_profiles or {}
		local runtime_profiles = initial_profiles
		local runtime_profile_id = "basic"
		local runtime_plan = {}
		local set_profiles_plan = {}
		local save_plan = {}
		local menu_plan = {}
		local runtime_calls = {}
		local set_profiles_calls = {}
		local timers = options.weak_timer_registry
			and setmetatable({}, {__mode = "v"}) or {}
		local timer_sequence = 0
		local editor_calls = {}
		local editor_open_count = 0
		local editor_reentry = nil
		local editor_reentrant_results = {}
		local notification_count = 0
		local shortcut_prompt_count = 0
		local shortcut_apply_count = 0
		local last_shortcut_spec = nil
		local delete_dialog_count = 0
		local requirements_count = 0
		local requirements_callbacks = {}
		local keymap_model_calls = {}
		local keymap_display_calls = {}
		local keymap_enabled_calls = {}
		local save_count = 0
		local menu_count = 0
		local created_profiles = options.created_profiles or {
			{id = "user_created", label = "Created"},
		}

		local state = {
			llm_active_profile = "basic",
			llm_backend = "ollama",
			llm_enabled = true,
			llm_model = "A",
			llm_model_ollama = "A",
			llm_model_power = 1,
			llm_num_predictions = 1,
			llm_profile_shortcuts = {},
			llm_user_profiles = initial_profiles,
		}
		local durable = clone(state)
		local rendered = clone(state)

		--- Resolves the exact runtime profile table from the published catalogue.
		--- @return table profile
		local function get_runtime_profile()
			for _, profile in ipairs(runtime_profiles) do
				if profile.id == runtime_profile_id then return profile end
			end
			for _, profile in ipairs(builtins) do
				if profile.id == runtime_profile_id then return profile end
			end
			return builtins[1]
		end

		package.loaded["infra.dialog_util"] = {
			block_alert = function()
				delete_dialog_count = delete_dialog_count + 1
				return options.delete_choice or "button.cancel"
			end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local renderer = assert(require("menu.renderer").new({
			platform = "hs",
			manifest_path = function()
				return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json"
			end,
			json_decode = function(text)
				local manifest = require("json").decode(text)
				if options.create_label_key then
					manifest.llm_profile_commands[1].i18n = options.create_label_key
				end
				if options.clone_label_key then
					for _, declaration in ipairs(manifest.llm_profile_commands) do
						if declaration.id == "llm_profile_clone" then declaration.i18n = options.clone_label_key end
					end
				end
				return manifest
			end,
			i18n = package.loaded["infra.i18n"],
			logger = package.loaded["infra.logger"],
		}))
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
			command_row = renderer.command_row,
			template_rows = renderer.template_rows,
		}
		package.loaded["infra.notifications"] = {
			notify = function()
				notification_count = notification_count + 1
				return true
			end,
		}
		package.loaded["modules.llm"] = {
			BUILTIN_PROFILES = builtins,
			DEFAULT_STATE = {llm_num_predictions = 1},
			get_active_profile = get_runtime_profile,
			set_active_profile = function(profile_id)
				local outcome = table.remove(runtime_plan, 1) or {mode = "ok"}
				runtime_calls[#runtime_calls + 1] = {
					profile_id = profile_id,
					outcome = outcome.mode,
				}
				if outcome.mutate ~= false then runtime_profile_id = profile_id end
				if outcome.mode == "throw" then error("runtime profile refused", 0) end
				if outcome.mode == "false" then return false end
				if outcome.mode == "nil" then return nil end
				return true
			end,
			set_user_profiles = function(profiles)
				local outcome = table.remove(set_profiles_plan, 1) or {mode = "ok"}
				set_profiles_calls[#set_profiles_calls + 1] = {
					profiles = profiles,
					outcome = outcome.mode,
				}
				if outcome.mutate ~= false then runtime_profiles = profiles end
				if outcome.mode == "throw" then error("runtime registry refused", 0) end
				if outcome.mode == "false" then return false end
				if outcome.mode == "nil" then return nil end
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {
			prompt_shortcut = function(spec)
				shortcut_prompt_count = shortcut_prompt_count + 1
				last_shortcut_spec = spec
				if options.shortcut_apply_immediately then
					return spec.on_apply({"ctrl"}, "k")
				end
				return false
			end,
		}
		package.loaded["ui.prompt_editor"] = {
			scope_idle = function() return options.editor_busy ~= true end,
			open = function(profile, callback)
				editor_open_count = editor_open_count + 1
				editor_calls[#editor_calls + 1] = profile or false
				if profile == nil then
					if options.before_editor_save then options.before_editor_save() end
					local candidate = table.remove(created_profiles, 1)
					local result = callback(candidate)
					if options.editor_double_callback then
						callback(table.remove(created_profiles, 1) or candidate)
					end
					if options.editor_returns_nil then return nil end
					return result
				end
				if options.editor_update then
					if options.editor_reentrant_callback then
						editor_reentry = function()
							return callback(options.editor_duplicate_update or options.editor_update)
						end
					end
					if options.before_clone_editor_save then options.before_clone_editor_save() end
					local result = callback(options.editor_update)
					if options.before_clone_editor_save then options.clone_save_result = result end
					if options.editor_double_callback then
						callback(options.editor_duplicate_update or options.editor_update)
					end
					if options.editor_returns_nil then return nil end
					return result
				end
				if options.editor_returns_nil then return nil end
				return true
			end,
		}
		local function make_timer(delay, callback)
			local timer = {
				delay = delay,
				callback = callback,
				running_state = false,
			}
			function timer:start()
				self.running_state = true
				if self.id == nil then
					timer_sequence = timer_sequence + 1
					self.id = timer_sequence
					timers[self.id] = self
				end
				return self
			end
			function timer:stop()
				self.running_state = false
				if self.id ~= nil then timers[self.id] = nil end
				return self
			end
			function timer:running() return self.running_state end
			function timer:fire()
				if self.running_state ~= true then return nil end
				self.running_state = false
				if self.id ~= nil then timers[self.id] = nil end
				local result = self.callback()
				if options.timer_double_callback then self.callback() end
				return result
			end
			return setmetatable(timer, {
				__gc = function(value) value.running_state = false end,
			})
		end

		_G.hs = {
			timer = {
				new = make_timer,
				doAfter = function(delay, callback)
					local timer = make_timer(delay, callback)
					timer:start()
					return timer
				end,
			},
		}

		local models_mgr = {
			check_requirements = function(_, on_ok, on_fail)
				requirements_count = requirements_count + 1
				requirements_callbacks[#requirements_callbacks + 1] = {
					on_ok = on_ok,
					on_fail = on_fail,
				}
				return true
			end,
			get_actual_model_name = function(name) return name end,
			get_model_info = function() return {params = 1} end,
			get_presets = function() return {} end,
		}
		package.loaded["ui.menu.preferences_transaction"] = nil
		local PreferencesTransaction = require("ui.menu.preferences_transaction")
		local preferences = {
			save = function()
				save_count = save_count + 1
				if editor_reentry then
					local reenter = editor_reentry
					editor_reentry = nil
					editor_reentrant_results[#editor_reentrant_results + 1] = reenter()
				end
				local outcome = table.remove(save_plan, 1) or {mode = "ok"}
				if outcome.mode == "throw" then error("preference save refused", 0) end
				if outcome.mode == "false" then return false end
				if outcome.mode == "nil" then return nil end
				durable = clone(state)
				return true, clone(state)
			end,
		}
		local transactional_save = PreferencesTransaction.bind(preferences, {
			state = state,
			initial_state = state,
			initial_preferences = state,
			restore_runtime = function(snapshot)
				runtime_profiles = state.llm_user_profiles
				runtime_profile_id = snapshot.llm_active_profile
				return true
			end,
		})
		local deps = {
			script_control = {is_paused = function() return options.paused or false end},
			state = state,
			save_prefs = transactional_save,
			update_menu = function()
				menu_count = menu_count + 1
				rendered = clone(state)
				local outcome = table.remove(menu_plan, 1) or {mode = "ok"}
				if outcome.mode == "throw" then error("menu refresh refused", 0) end
				if outcome.mode == "false" then return false end
				if outcome.mode == "nil" then return nil end
				return true
			end,
			apply_llm_profile_shortcut = function()
				shortcut_apply_count = shortcut_apply_count + 1
				return true
			end,
		}

		package.loaded["ui.menu.menu_llm.model_switcher"] = nil
		local switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = models_mgr,
			keymap = {
				set_llm_model = function(value)
					keymap_model_calls[#keymap_model_calls + 1] = value
					return true
				end,
				set_llm_display_model_name = function(value)
					keymap_display_calls[#keymap_display_calls + 1] = value
					return true
				end,
				set_llm_enabled = function(value)
					keymap_enabled_calls[#keymap_enabled_calls + 1] = value
					return true
				end,
			},
			save_prefs = deps.save_prefs,
			update_menu = deps.update_menu,
			profile_mutation_gate = function(switcher_recovery_capability)
				for _, key in ipairs({
					"settle_profile_delete_recovery",
					"settle_profile_candidate_recovery",
				}) do
					local gate = deps[key]
					if gate ~= nil then
						local capability = key == "settle_profile_candidate_recovery"
							and switcher_recovery_capability or nil
						if type(gate) ~= "function" or gate(capability) ~= true then
							return false
						end
					end
				end
				return true
			end,
		})
		deps.set_llm_profile = switcher.set_llm_profile
		deps.settle_llm_switcher_recovery = switcher.settle_recovery_debts

		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["ui.menu.menu_llm.profiles_manager"] = nil
		local manager = require("ui.menu.menu_llm.profiles_manager").new(deps, models_mgr)
		runtime_calls = {}
		set_profiles_calls = {}

		--- Replaces the exact runtime outcomes consumed by later setter calls.
		--- @param plan table Runtime outcome records.
		local function plan_runtime(plan)
			runtime_plan = clone(plan)
		end

		--- Replaces the exact runtime-registry outcomes consumed by later calls.
		--- @param plan table Runtime-registry outcome records.
		local function plan_set_profiles(plan)
			set_profiles_plan = clone(plan)
		end

		--- Replaces the exact preference outcomes consumed by later calls.
		--- @param plan table Preference outcome records.
		local function plan_save(plan)
			save_plan = clone(plan)
		end

		--- Replaces the exact menu outcomes consumed by later calls.
		--- @param plan table Menu outcome records.
		local function plan_menu(plan)
			menu_plan = clone(plan)
		end

		--- Fires the oldest retained timer callback.
		--- @return any result
		local function fire_timer()
			local selected_id = nil
			for id, timer in pairs(timers) do
				if timer.running_state == true and (selected_id == nil or id < selected_id) then
					selected_id = id
				end
			end
			local timer = selected_id and timers[selected_id] or nil
			helpers.assert_type(timer, "table")
			return timer:fire()
		end

		--- Counts native timers that remain capable of delivery.
		--- @return integer count
		local function timer_count()
			local count = 0
			for _, timer in pairs(timers) do
				if timer.running_state == true then count = count + 1 end
			end
			return count
		end

		body({
			deps = deps,
			collect_timers = function()
				collectgarbage("collect")
				collectgarbage("collect")
			end,
			delete_dialog_count = function() return delete_dialog_count end,
			durable = function() return durable end,
			editor_calls = editor_calls,
			editor_open_count = function() return editor_open_count end,
			editor_reentrant_results = editor_reentrant_results,
			fire_timer = fire_timer,
			get_runtime_profile = get_runtime_profile,
			keymap_display_calls = keymap_display_calls,
			keymap_enabled_calls = keymap_enabled_calls,
			keymap_model_calls = keymap_model_calls,
			last_shortcut_spec = function() return last_shortcut_spec end,
			manager = manager,
			menu_count = function() return menu_count end,
			notifications = function() return notification_count end,
			plan_menu = plan_menu,
			plan_runtime = plan_runtime,
			plan_save = plan_save,
			plan_set_profiles = plan_set_profiles,
			rendered = function() return rendered end,
			requirements_callbacks = requirements_callbacks,
			requirements_count = function() return requirements_count end,
			runtime_calls = function() return runtime_calls end,
			runtime_profiles = function() return runtime_profiles end,
			save_count = function() return save_count end,
			set_profiles_calls = function() return set_profiles_calls end,
			shortcut_apply_count = function() return shortcut_apply_count end,
			shortcut_prompt_count = function() return shortcut_prompt_count end,
			state = state,
			switcher = switcher,
			timer_count = timer_count,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	restore_modules(saved)
	if not ok then error(err, 0) end
end

--- Asserts that a refused candidate never reached durable or rendered state.
--- @param fixture table Candidate fixture.
--- @param expected table|nil Expected boundary counts and prior registry.
local function assert_clean_refusal(fixture, expected)
	expected = expected or {}
	local profiles = expected.profiles or {}
	helpers.assert_eq(#fixture.state.llm_user_profiles, #profiles)
	helpers.assert_eq(#fixture.runtime_profiles(), #profiles)
	for index, profile in ipairs(profiles) do
		helpers.assert_true(fixture.state.llm_user_profiles[index] == profile)
		helpers.assert_true(fixture.runtime_profiles()[index] == profile)
	end
	helpers.assert_eq(fixture.state.llm_active_profile, "basic")
	helpers.assert_eq(fixture.get_runtime_profile().id, "basic")
	helpers.assert_eq(#fixture.durable().llm_user_profiles, #profiles)
	helpers.assert_eq(fixture.durable().llm_active_profile, "basic")
	helpers.assert_eq(#fixture.rendered().llm_user_profiles, #profiles)
	helpers.assert_eq(fixture.rendered().llm_active_profile, "basic")
	helpers.assert_eq(fixture.save_count(), expected.saves or 0)
	helpers.assert_eq(fixture.menu_count(), expected.menus or 0)
	helpers.assert_eq(fixture.notifications(), 0)
end

--- Creates one candidate whose active-profile compensation remains retryable.
--- @param fixture table Candidate fixture.
--- @return table candidate Exact retained candidate table.
local function retain_clone_candidate(fixture)
	local prior_count = #fixture.state.llm_user_profiles
	fixture.plan_runtime({
		{mode = "throw"},
		{mode = "false", mutate = false},
	})
	local clone_row = find_row(fixture.manager.get_menu_item().menu,
		"menu.profiles.clone_builtin")
	helpers.assert_type(clone_row and clone_row.action, "function")
	helpers.assert_eq(clone_row.action(), false)
	helpers.assert_eq(#fixture.state.llm_user_profiles, prior_count + 1)
	return fixture.state.llm_user_profiles[prior_count + 1]
end

return {
	MODULES = MODULES,
	assert_clean_refusal = assert_clean_refusal,
	clone = clone,
	find_child_row = find_child_row,
	find_row = find_row,
	restore_modules = restore_modules,
	retain_clone_candidate = retain_clone_candidate,
	with_fixture = with_fixture,
}
