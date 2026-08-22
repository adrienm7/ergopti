--- tests/unit/ui/menu/menu_llm/test_profile_candidate_transaction.lua

--- ==============================================================================
--- MODULE: LLM Profile Candidate Transactions
--- DESCRIPTION:
--- Drives the real ProfilesManager and ModelSwitcher across Clone and Create.
--- Runtime doubles preserve exact profile-table identity and can mutate before
--- throwing so candidate cleanup, retained compensation, persistence, and menu
--- publication are observed behaviorally rather than inferred from source text.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
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
		local timers = {}
		local editor_calls = {}
		local editor_open_count = 0
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
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
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
			open = function(profile, callback)
				editor_open_count = editor_open_count + 1
				editor_calls[#editor_calls + 1] = profile or false
				if profile == nil then
					local candidate = table.remove(created_profiles, 1)
					local result = callback(candidate)
					if options.editor_double_callback then
						callback(table.remove(created_profiles, 1) or candidate)
					end
					if options.editor_returns_nil then return nil end
					return result
				end
				if options.editor_update then
					local result = callback(options.editor_update)
					if options.editor_returns_nil then return nil end
					return result
				end
				if options.editor_returns_nil then return nil end
				return true
			end,
		}
		_G.hs = {
			timer = {
				doAfter = function(_, callback)
					local handle = {stop = function() return true end}
					if options.timer_sync then
						callback()
						if options.timer_double_callback then callback() end
						return handle
					end
					timers[#timers + 1] = callback
					return handle
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
			script_control = {is_paused = function() return false end},
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
			local callback = table.remove(timers, 1)
			helpers.assert_type(callback, "function")
			return callback()
		end

		body({
			deps = deps,
			delete_dialog_count = function() return delete_dialog_count end,
			durable = function() return durable end,
			editor_calls = editor_calls,
			editor_open_count = function() return editor_open_count end,
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
			timer_count = function() return #timers end,
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

helpers.describe("HS-034 profile candidates are exact recoverable transactions", function()
	helpers.it("HS-034 removes a refused Clone candidate after clean runtime compensation", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "throw"},
				{mode = "ok"},
			})
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_type(clone_row and clone_row.action, "function")

			helpers.assert_eq(clone_row.action(), false)
			assert_clean_refusal(fixture)
			helpers.assert_eq(fixture.editor_open_count(), 0,
				"a refused Clone must not open its follow-up editor")
			helpers.assert_eq(fixture.timer_count(), 0)
		end)
	end)

	helpers.it("HS-034 removes a refused Create candidate inside the editor timer", function()
		local candidate = {id = "user_created", label = "Created"}
		with_fixture({created_profiles = {candidate}}, function(fixture)
			fixture.plan_runtime({
				{mode = "throw"},
				{mode = "ok"},
			})
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_type(create_row and create_row.action, "function")

			create_row.action()
			helpers.assert_eq(fixture.timer_count(), 1)
			fixture.fire_timer()
			assert_clean_refusal(fixture)
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(fixture.editor_calls[1], false,
				"Create must obtain the candidate from the nil-profile editor")
		end)
	end)

	helpers.it("HS-034 retains one live candidate until compensation settles before a sibling Create", function()
		local successor = {id = "user_successor", label = "Successor"}
		with_fixture({created_profiles = {successor}}, function(fixture)
			fixture.plan_runtime({
				{mode = "throw"},
				{mode = "false", mutate = false},
				{mode = "false", mutate = false},
				{mode = "ok"},
				{mode = "ok"},
			})
			local rows = fixture.manager.get_menu_item().menu
			local clone_row = find_row(rows, "menu.profiles.clone_builtin")
			local create_row = find_row(rows, "menu.profiles.create_profile")
			helpers.assert_type(clone_row and clone_row.action, "function")
			helpers.assert_type(create_row and create_row.action, "function")

			helpers.assert_eq(clone_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			local retained = fixture.state.llm_user_profiles[1]
			helpers.assert_true(fixture.get_runtime_profile() == retained,
				"the exact runtime-live candidate must remain owned")
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(fixture.menu_count(), 0)

			helpers.assert_eq(create_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained,
				"a refused entry gate must block the sibling candidate insertion")
			helpers.assert_true(fixture.get_runtime_profile() == retained)
			helpers.assert_eq(fixture.timer_count(), 0,
				"a blocked Create must not even acquire its editor timer")
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(fixture.menu_count(), 0)

			helpers.assert_eq(create_row.action(), true)
			fixture.fire_timer()
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == successor,
				"settlement must retire only the old candidate before the sibling commits")
			helpers.assert_true(fixture.state.llm_user_profiles[1] ~= retained)
			helpers.assert_true(fixture.get_runtime_profile() == successor)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.menu_count(), 1)
			helpers.assert_eq(fixture.notifications(), 1)
		end)
	end)

	local void_refusal_modes = {"false", "nil", "throw"}
	for _, mode in ipairs(void_refusal_modes) do
		helpers.it("HS-034 contains a " .. mode .. " runtime activation refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = mode},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture)
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)

		helpers.it("HS-034 contains a " .. mode .. " menu refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_menu({{mode = mode}})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture, {saves = 3, menus = 3})
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)
	end

	local strict_refusal_modes = {"false", "nil", "throw"}
	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 contains a " .. mode .. " preference refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_save({{mode = mode}})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture, {saves = 3})
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)

		helpers.it("HS-034 contains a " .. mode .. " runtime-registry publication refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_set_profiles({{mode = mode}})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture)
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)
	end

	helpers.it("HS-034 rejects nil from the strict public profile transaction", function()
		with_fixture({}, function(fixture)
			fixture.deps.set_llm_profile = function() return nil end
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			assert_clean_refusal(fixture)
			helpers.assert_eq(fixture.editor_open_count(), 0)
		end)
	end)

	for _, gate_key in ipairs({
		"settle_profile_delete_recovery",
		"settle_profile_candidate_recovery",
		"settle_profile_edit_recovery",
		"settle_llm_switcher_recovery",
	}) do
		helpers.it("HS-034 rejects nil from the strict " .. gate_key .. " gate", function()
			with_fixture({}, function(fixture)
				fixture.deps[gate_key] = function() return nil end
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture)
				helpers.assert_eq(fixture.timer_count(), 0)
			end)
		end)
	end

	helpers.it("HS-034 accepts nil only from the editor after exact runtime and menu commits", function()
		local candidate = {id = "user_void_success", label = "Void Success"}
		with_fixture({
			created_profiles = {candidate},
			editor_returns_nil = true,
		}, function(fixture)
			fixture.plan_runtime({{mode = "ok"}})
			fixture.plan_menu({{mode = "ok"}})
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			helpers.assert_eq(fixture.fire_timer(), true)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == candidate)
			helpers.assert_true(fixture.runtime_profiles()[1] == candidate)
			helpers.assert_eq(fixture.state.llm_active_profile, candidate.id)
			helpers.assert_eq(fixture.get_runtime_profile().id, candidate.id)
			helpers.assert_eq(fixture.durable().llm_user_profiles[1].id, candidate.id)
			helpers.assert_eq(fixture.rendered().llm_user_profiles[1].id, candidate.id)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.menu_count(), 1)
			helpers.assert_eq(fixture.notifications(), 1)
		end)
	end)

	helpers.it("HS-034 survives the real in-place preference rollback mutating its candidate table", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_save({{mode = "false"}})
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			local publication = fixture.set_profiles_calls()[1]
			helpers.assert_type(publication, "table")
			helpers.assert_eq(#publication.profiles, 0,
				"PreferencesTransaction must have restored the published table in place")
			assert_clean_refusal(fixture, {saves = 3})
		end)
	end)

	helpers.it("HS-034 removes only the exact same-ID candidate and preserves the prior table identity", function()
		local previous = {id = "user_created", label = "Previous"}
		local old_registry = {previous}
		local candidate = {id = "user_created", label = "Candidate"}
		with_fixture({
			initial_profiles = old_registry,
			created_profiles = {candidate},
		}, function(fixture)
			fixture.plan_set_profiles({{mode = "false"}})
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			fixture.fire_timer()
			assert_clean_refusal(fixture, {profiles = {previous}})
			helpers.assert_true(fixture.state.llm_user_profiles == old_registry)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == previous)
			helpers.assert_true(fixture.state.llm_user_profiles[1] ~= candidate)
		end)
	end)

	helpers.it("HS-034 latches synchronous duplicate timer and Create editor callbacks", function()
		local first = {id = "user_first", label = "First"}
		local duplicate = {id = "user_duplicate", label = "Duplicate"}
		with_fixture({
			created_profiles = {first, duplicate},
			timer_sync = true,
			timer_double_callback = true,
			editor_double_callback = true,
		}, function(fixture)
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			helpers.assert_eq(fixture.timer_count(), 0)
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == first)
			helpers.assert_true(fixture.state.llm_user_profiles[1] ~= duplicate)
			helpers.assert_eq(fixture.notifications(), 1)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.menu_count(), 1)
		end)
	end)

	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 retains registry debt when its cleanup save " .. mode
			.. " refuses, then retries exactly", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_save({
					{mode = "ok"},
					{mode = "ok"},
					{mode = mode},
					{mode = "ok"},
				})
				fixture.plan_menu({
					{mode = "false"},
					{mode = "ok"},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				helpers.assert_eq(#fixture.state.llm_user_profiles, 0,
					"live state is reasserted even while durable cleanup remains pending")
				helpers.assert_eq(#fixture.durable().llm_user_profiles, 1,
					"the failed cleanup save must remain visible as durable debt")
				helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
				assert_clean_refusal(fixture, {saves = 4, menus = 3})
			end)
		end)
	end

	helpers.it("HS-034 retains cleanup debt when the strict save callback returns nil", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_menu({
				{mode = "false"},
				{mode = "ok"},
				{mode = "ok"},
			})
			local transactional_save = fixture.deps.save_prefs
			fixture.deps.save_prefs = function() return nil end
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.durable().llm_user_profiles, 1)
			helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), false,
				"a literal nil cleanup result must retain the exact registry debt")
			fixture.deps.save_prefs = transactional_save
			helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
			assert_clean_refusal(fixture, {saves = 3, menus = 3})
		end)
	end)

	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 retries a " .. mode .. " exact runtime-registry rollback", function()
			with_fixture({}, function(fixture)
				fixture.plan_set_profiles({
					{mode = "false"},
					{mode = mode, mutate = false},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				helpers.assert_eq(#fixture.runtime_profiles(), 1,
					"a mutate-then-refuse publication remains the exact runtime debt")
				helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
				assert_clean_refusal(fixture)
			end)
		end)
	end

	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 retries a " .. mode
			.. " switcher preference compensation before candidate cleanup", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_save({
					{mode = "ok"},
					{mode = mode},
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_menu({
					{mode = "false"},
					{mode = "ok"},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
				helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
				assert_clean_refusal(fixture, {saves = 4, menus = 3})
			end)
		end)
	end

	helpers.it("HS-034 retries a refused switcher menu compensation before candidate cleanup", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_save({
				{mode = "ok"},
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_menu({
				{mode = "false"},
				{mode = "false"},
				{mode = "ok"},
				{mode = "ok"},
			})
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
			assert_clean_refusal(fixture, {saves = 3, menus = 4})
		end)
	end)

	local sibling_entry_specs = {
		{
			name = "built-in selection",
			invoke = function(_, rows)
				return find_row(rows, "Advanced").action()
			end,
		},
		{
			name = "Auto-detect",
			invoke = function(_, rows)
				return find_row(rows, "menu.profiles.auto_detect").action()
			end,
		},
		{
			name = "shortcut editor",
			invoke = function(_, rows, retained)
				return find_child_row(rows, retained.label,
					"menu.profiles.shortcut_prefix").action()
			end,
		},
		{
			name = "profile editor",
			invoke = function(_, rows, retained)
				return find_child_row(rows, retained.label,
					"menu.profiles.edit_profile").action()
			end,
		},
		{
			name = "Delete",
			invoke = function(_, rows, retained)
				return find_child_row(rows, retained.label,
					"menu.profiles.delete_profile").action()
			end,
		},
		{
			name = "Clone",
			invoke = function(_, rows)
				return find_row(rows, "menu.profiles.clone_builtin").action()
			end,
		},
		{
			name = "Create",
			invoke = function(_, rows)
				return find_row(rows, "menu.profiles.create_profile").action()
			end,
		},
	}
	for _, spec in ipairs(sibling_entry_specs) do
		helpers.it("HS-034 gates sibling " .. spec.name .. " before its first effect", function()
			with_fixture({}, function(fixture)
				local retained = retain_clone_candidate(fixture)
				fixture.plan_runtime({{mode = "false", mutate = false}})
				local rows = fixture.manager.get_menu_item().menu
				helpers.assert_eq(spec.invoke(fixture, rows, retained), false)
				helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
				helpers.assert_eq(fixture.shortcut_prompt_count(), 0)
				helpers.assert_eq(fixture.timer_count(), 0)
				helpers.assert_eq(fixture.delete_dialog_count(), 0)
				helpers.assert_eq(fixture.notifications(), 0)
				helpers.assert_eq(fixture.requirements_count(), 0)
			end)
		end)
	end

	helpers.it("HS-034 gates the deferred shortcut continuation", function()
		local custom = {id = "custom", label = "Custom"}
		with_fixture({initial_profiles = {custom}}, function(fixture)
			local shortcut_row = find_child_row(fixture.manager.get_menu_item().menu,
				"Custom", "menu.profiles.shortcut_prefix")
			helpers.assert_eq(shortcut_row.action(), false)
			local spec = fixture.last_shortcut_spec()
			helpers.assert_type(spec and spec.on_apply, "function")
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(spec.on_apply({"ctrl"}, "k"), false)
			helpers.assert_eq(fixture.shortcut_apply_count(), 0)
		end)
	end)

	helpers.it("HS-034 gates the deferred Edit continuation before opening the editor", function()
		local custom = {id = "custom", label = "Custom"}
		with_fixture({initial_profiles = {custom}}, function(fixture)
			local edit_row = find_child_row(fixture.manager.get_menu_item().menu,
				"Custom", "menu.profiles.edit_profile")
			helpers.assert_eq(edit_row.action(), true)
			helpers.assert_eq(fixture.timer_count(), 1)
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(fixture.fire_timer(), false)
			helpers.assert_eq(fixture.editor_open_count(), 0)
		end)
	end)

	helpers.it("HS-034 gates the deferred Create continuation before opening the editor", function()
		with_fixture({}, function(fixture)
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			helpers.assert_eq(fixture.timer_count(), 1)
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(fixture.fire_timer(), false)
			helpers.assert_eq(fixture.editor_open_count(), 0)
		end)
	end)

	helpers.it("HS-034 gates switch_model before requirements dispatch", function()
		with_fixture({}, function(fixture)
			local retained = retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(fixture.switcher.switch_model("B"), false)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
			helpers.assert_eq(fixture.requirements_count(), 0)
			helpers.assert_eq(#fixture.keymap_model_calls, 0)
			helpers.assert_eq(#fixture.keymap_display_calls, 0)
		end)
	end)

	helpers.it("HS-034 gates No Model before runtime publication", function()
		with_fixture({}, function(fixture)
			local retained = retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(fixture.switcher.disable_model(), false)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
			helpers.assert_eq(#fixture.keymap_model_calls, 0)
			helpers.assert_eq(#fixture.keymap_display_calls, 0)
		end)
	end)

	helpers.it("HS-034 gates a pending model success continuation", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			helpers.assert_eq(fixture.requirements_count(), 1)
			local callback = fixture.requirements_callbacks[1].on_ok
			local retained = retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(callback(), false)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_eq(#fixture.keymap_model_calls, 0)
			helpers.assert_eq(#fixture.keymap_display_calls, 0)
		end)
	end)

	helpers.it("HS-034 settles candidate recovery before a pending model continuation commits", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			local callback = fixture.requirements_callbacks[1].on_ok
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "ok"}})
			helpers.assert_eq(callback(), true)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.runtime_profiles(), 0)
			helpers.assert_eq(fixture.state.llm_model, "B")
			helpers.assert_eq(fixture.keymap_model_calls, {"B"})
			helpers.assert_eq(fixture.keymap_display_calls, {"B"})
		end)
	end)
end)

return true
