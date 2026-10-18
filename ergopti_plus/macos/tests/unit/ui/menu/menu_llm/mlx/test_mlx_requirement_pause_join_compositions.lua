--- tests/unit/ui/menu/menu_llm/mlx/test_mlx_requirement_pause_join_compositions.lua

--- ==============================================================================
--- MODULE: MLX Requirement Pause-Join Regression
--- DESCRIPTION:
--- Composes the real ScriptControl transaction, ModelSwitcher or Startup
--- owner, TaskLifecycle adapter, and MLX requirements manager around one exact
--- native import-probe task.
---
--- FEATURES & RATIONALE:
--- 1. Pause settlement: callback fencing alone cannot publish PAUSED while the
---    native probe remains live, pinned, or ambiguously cancelled.
--- 2. Exact retry: false, nil, and throwing termination retry the same handle;
---    a late terminal settles it without entering start_server.
--- 3. Start refusal: mutate-then-false/nil/throw retains cleanup ownership and
---    refuses a successor until the original native callback proves exit.
--- 4. Port replay: the real menu caller routes through the model capability;
---    rollback stays fenced and only the matching post-RESUME epoch can replay.
--- 5. Provenance: activation, model switch, and startup each join only their own
---    opaque capability even when all three real ScriptControl owners coexist.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.mlx.mlx_requirement_pause_join_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.mlx.mlx_requirement_pause_join_fixture")
local build_manager = Fixture.build_manager
local build_prediction_locks = Fixture.build_prediction_locks
local install_subject_stubs = Fixture.install_subject_stubs
local newest_live_timer = Fixture.newest_live_timer
local start_script_control = Fixture.start_script_control
local with_fixture = Fixture.with_fixture





-- ==========================================
-- ==========================================
-- ======= 2/ Pause Join Compositions =======
-- ==========================================
-- ==========================================

helpers.describe("HS-012 MLX requirement-task pause joins", function()
	helpers.it("refuses an anonymous probe when ScriptControl can pause", function()
		with_fixture(function(native)
			install_subject_stubs(native)
			local script_control = start_script_control()
			local manager = build_manager(script_control)
			local reason = nil
			helpers.assert_eq(manager.check_requirements("fixture-model",
				function() return true end,
				function(value) reason = value return true end), false)
			helpers.assert_eq(reason, "missing_requirement_owner")
			helpers.assert_eq(native.tasks, {},
				"an app-owned manager must not construct an unpausable native probe")
			helpers.assert_true(script_control.stop())
		end)
	end)

	helpers.it("rejects a nil shared system-check admission", function()
		with_fixture(function(native)
			install_subject_stubs(native)
			local script_control = start_script_control()
			local shared_calls = 0
			local manager = build_manager(script_control, function()
				shared_calls = shared_calls + 1
				return nil
			end)
			manager.get_installed_models = function() return {} end
			local capability = manager.create_requirement_owner("activation")
			local terminal = { success = 0, cancel = 0 }
			helpers.assert_true(manager.check_requirements("fixture-model", function()
				terminal.success = terminal.success + 1
				return true
			end, function()
				terminal.cancel = terminal.cancel + 1
				return true
			end, {
				requirement_owner = capability,
				is_current = function() return true end,
			}))
			helpers.assert_eq(#native.tasks, 1)
			native.tasks[1].on_done(0, "", "")
			helpers.assert_eq(shared_calls, 1)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(native.server_starts, {})
			helpers.assert_eq(#native.tasks, 1,
				"nil must not be normalized into a committed download successor")
			helpers.assert_true(script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins model-switch requirement cancellation after " .. mode,
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "old-model",
						llm_model_mlx = "old-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					local switcher = require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = {},
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						runtime_installed = function() return true end,
						deps = { script_control = script_control },
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_profile_hks = function() return {} end,
						prediction_locks = build_prediction_locks(),
					})

					helpers.assert_true(switcher.switch_model("fixture-model"))
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_eq(manager_module._active_tasks[task], true)
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false,
						"an unsettled exact task must prevent PAUSED publication")
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(manager_module._active_tasks[task], true)
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"pause retry must target the same native handle")
					helpers.assert_eq(#native.tasks, 1,
						"cleanup debt must refuse a successor requirement task")

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {},
						"late and duplicate revoked terminals must stay inert")
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)

					native.cancel_mode = "true"
					helpers.assert_true(switcher.switch_model("fixture-model"))
					helpers.assert_eq(#native.tasks, 2)
					helpers.assert_eq(native.server_starts, {})
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" },
						"only a fresh post-RESUME authorization may start the server")
					helpers.assert_true(script_control.stop())
				end)
			end)

		helpers.it("joins startup requirement cancellation after " .. mode,
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "fixture-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					local startup_locks = build_prediction_locks()
					local check_startup = require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = { set_llm_backend_name = function() return true end },
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						runtime_installed = function() return true end,
						deps = {
							script_control = script_control,
							update_menu = function() return true end,
						},
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_profile_hks = function() return {} end,
						prediction_locks = startup_locks,
					})

					helpers.assert_true(check_startup())
					local primary = newest_live_timer(native, 1)
					helpers.assert_not_nil(primary)
					primary:fire()
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_eq(manager_module._active_tasks[task], true)
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_true(startup_locks.ensure_calls > 0,
						"the fixed owner order must reach the true startup owner")
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task)
					helpers.assert_eq(#native.tasks, 1)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {})
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)

					native.cancel_mode = "true"
					local resumed_primary = newest_live_timer(native, 1)
					helpers.assert_not_nil(resumed_primary)
					resumed_primary:fire()
					helpers.assert_eq(#native.tasks, 2)
					helpers.assert_eq(native.server_starts, {})
					local resumed_backup = newest_live_timer(native, 3)
					helpers.assert_not_nil(resumed_backup)
					resumed_backup:fire()
					helpers.assert_eq(#native.tasks, 3,
						"primary and backup may overlap below one startup capability")
					native.cancel_mode = mode
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" },
						"startup may dispatch the server only after committed RESUME")
					local losing_task = native.tasks[3]
					helpers.assert_eq(losing_task.terminate_calls, 1,
						"the winning terminal must join its losing requirement sibling")
					helpers.assert_eq(startup_locks.release_calls, 0,
						"predictions stay locked until the losing task physically settles")
					losing_task.on_done(0, "", "")
					losing_task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" },
						"the revoked loser cannot publish a second server start")
					native.cancel_mode = "true"
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(startup_locks.release_calls, 1,
						"the winning cycle releases its lock once after sibling settlement")

					-- A requirement task whose start mutates then refuses is born below
					-- the startup timer. Aborting that cycle must join the same task and
					-- retain the prediction lock until exact physical settlement.
					native.start_mode = mode
					native.cancel_mode = mode
					helpers.assert_true(check_startup())
					local refused_primary = newest_live_timer(native, 1)
					helpers.assert_not_nil(refused_primary)
					refused_primary:fire()
					helpers.assert_eq(#native.tasks, 4)
					local refused_task = native.tasks[4]
					helpers.assert_eq(refused_task.terminate_calls, 2,
						"manager rollback and startup abort must join one exact task")
					helpers.assert_eq(startup_locks.release_calls, 1,
						"an unsettled requirement task must keep predictions locked")
					helpers.assert_eq(check_startup(), false,
						"abort cleanup debt must refuse a successor startup cycle")
					helpers.assert_eq(#native.tasks, 4)
					helpers.assert_eq(refused_task.terminate_calls, 3)

					refused_task.on_done(0, "", "")
					refused_task.on_done(0, "", "")
					native.start_mode = "true"
					native.cancel_mode = "true"
					helpers.assert_true(check_startup())
					helpers.assert_eq(startup_locks.release_calls, 2,
						"the old prediction lock releases once after exact task settlement")
					helpers.assert_eq(startup_locks.acquire_calls, 3,
						"the fresh startup cycle acquires its own lock only after cleanup")
					helpers.assert_eq(#native.tasks, 4,
						"preflight and rearm must not create a native task synchronously")
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)





-- ========================================
-- ========================================
-- ======= 3/ Activation Provenance =======
-- ========================================
-- ========================================

helpers.describe("HS-012 MLX activation requirement ownership", function()
	helpers.it("wires a dedicated capability into the real activation caller", function()
		local source = helpers.read_driver_source("local activation_generation = 0")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"the uniquely anchored LLM activation source must be readable")
		local setup_begin = source:find("local activation_generation = 0", 1, true)
		local setup_end = setup_begin and source:find(
			"local function build_item", setup_begin, true) or nil
		helpers.assert_not_nil(setup_begin)
		helpers.assert_not_nil(setup_end)
		local setup = source:sub(setup_begin, setup_end - 1)
		helpers.assert_true(setup:find(
			"models_mgr.create_requirement_owner", 1, true) ~= nil
			and setup:find("\"llm_activation\"", 1, true) ~= nil,
			"activation must create its own opaque manager capability")
		helpers.assert_true(source:find(
			"requirement_owner = activation_requirement_owner", 1, true) ~= nil,
			"activation requirements must carry the activation capability")
		helpers.assert_true(setup:find(
			"models_mgr.pause_requirements", 1, true) ~= nil
			and setup:find("activation_requirement_owner", 1, true) ~= nil,
			"the llm_activation pause owner must join that same capability")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps activation in its own owner after " .. mode,
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "fixture-model",
						llm_model_mlx = "fixture-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					local activation_capability = manager.create_requirement_owner(
						"llm_activation")
					helpers.assert_not_nil(activation_capability)
					local activation = require(
						"ui.menu.menu_llm.activation_pause_owner").new({
						script_control = script_control,
						pause_join = function()
							return manager.pause_requirements(activation_capability)
						end,
					})
					require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = {},
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						runtime_installed = function() return true end,
						deps = { script_control = script_control },
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_profile_hks = function() return {} end,
						prediction_locks = build_prediction_locks(),
					})

					local token
					local function dispatch_activation()
						local authorization = activation.capture(token)
						if authorization == nil then return false end
						return manager.check_requirements("fixture-model", function()
							return activation.complete(token)
						end, function()
							return activation.complete(token)
						end, {
							requirement_owner = activation_capability,
							is_current = function()
								return activation.is_current(token, authorization)
							end,
						})
					end
					token = activation.begin(function(_, replay_revoked_requirements)
						if replay_revoked_requirements ~= true then return true end
						return dispatch_activation()
					end)
					helpers.assert_not_nil(token)
					helpers.assert_true(dispatch_activation())
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[1], task,
						"llm_activation must cancel its own exact native handle")
					helpers.assert_eq(#native.replay_timers, 0,
						"failed-PAUSE rollback must not dispatch a sibling probe")
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"activation retry must retain the same requirement handle")
					helpers.assert_eq(#native.tasks, 1)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {})
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#native.replay_timers, 1)
					helpers.assert_true(native.replay_timers[1]:fire())
					helpers.assert_eq(#native.tasks, 2,
						"only the dedicated activation intent may replay after RESUME")
					helpers.assert_eq(native.server_starts, {})
					native.tasks[2].on_done(0, "", "")
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" })
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)
