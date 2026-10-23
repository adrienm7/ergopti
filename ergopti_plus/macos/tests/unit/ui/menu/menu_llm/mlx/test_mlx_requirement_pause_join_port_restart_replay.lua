--- tests/unit/ui/menu/menu_llm/mlx/test_mlx_requirement_pause_join_port_restart_replay.lua

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
local observe_maintenance_registration = Fixture.observe_maintenance_registration
local start_script_control = Fixture.start_script_control
local with_fixture = Fixture.with_fixture





-- =========================================
-- =========================================
-- ======= 4/ Port-Restart Replay =========
-- =========================================
-- =========================================

helpers.describe("HS-012 MLX port requirement replay ownership", function()
	helpers.it("routes the real port caller through the ModelSwitcher owner", function()
		-- A unique declaration locates menu_llm/init.lua without pinning its path.
		-- The bounded function body prevents another manager call elsewhere in that
		-- file from making this wiring assertion ambiguous.
		local source = helpers.read_driver_source(
			"local mlx_port_transition_generation = 0")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"the uniquely anchored LLM menu source must be readable")
		local begin_at = source:find(
			"local function restart_mlx_for_current_port", 1, true)
		local end_at = begin_at and source:find(
			"switcher = ModelSwitcher.new", begin_at, true) or nil
		helpers.assert_not_nil(begin_at)
		helpers.assert_not_nil(end_at)
		local restart_body = source:sub(begin_at, end_at - 1)
		helpers.assert_true(restart_body:find(
			"switcher.dispatch_resumable_requirements", 1, true) ~= nil,
			"the committed port restart must enter the replayable model capability")
		helpers.assert_true(restart_body:find(
			"models_mgr.check_requirements(", 1, true) == nil,
			"the port restart must not dispatch an anonymous native probe")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("replays the exact port intent after " .. mode .. " rollback",
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
						disarm_shortcuts = function() return true end,
						prediction_locks = build_prediction_locks(),
					})

					helpers.assert_true(switcher.dispatch_resumable_requirements(
						"fixture-model", nil, nil, {
							silent_notifications = true,
							_mlx_port = 9090,
						}))
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_eq(manager_module._active_tasks[task], true)
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false,
						"failed PAUSE rollback must not publish or replay the port intent")
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(#native.tasks, 1)
					helpers.assert_eq(#native.replay_timers, 0,
						"ACTIVE rollback is not authority for a deferred restart")
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"port rollback retry must target the same native handle")
					helpers.assert_eq(#native.tasks, 1)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {},
						"late and duplicate revoked port terminals must stay inert")
					helpers.assert_eq(manager_module._active_tasks[task], nil)

					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#native.replay_timers, 1)
					local stale_stage = native.replay_timers[1]

					-- A newer PAUSE cancels the exact staged callback. Delivering its raw
					-- closure afterward proves identity/epoch fencing, then the matching
					-- RESUME obtains a distinct replay authorization.
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_eq(stale_stage.timer, nil)
					stale_stage.callback()
					helpers.assert_eq(#native.tasks, 1)
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#native.replay_timers, 2)
					helpers.assert_true(native.replay_timers[2]:fire())

					helpers.assert_eq(#native.tasks, 2)
					helpers.assert_eq(native.server_starts, {},
						"replay authorizes only a fresh probe, never an early server")
					native.tasks[2].on_done(0, "", "")
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" })
					helpers.assert_eq(native.server_ports, { 9090 },
						"the replay must retain the originally committed port identity")
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)





-- ========================================
-- ========================================
-- ======= 5/ Start-Refusal Cleanup =======
-- ========================================
-- ========================================

helpers.describe("HS-012 MLX requirement start-refusal ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a mutate-then-" .. mode .. " start until exact terminal",
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local manager, manager_module = build_manager()
					local requirement_owner = manager.create_requirement_owner(
						"start_refusal")
					helpers.assert_not_nil(requirement_owner)
					native.start_mode = mode
					native.cancel_mode = mode
					local cancellations = 0

					helpers.assert_eq(manager.check_requirements("fixture-model",
						function() return true end,
						function()
							cancellations = cancellations + 1
							return true
						end, { requirement_owner = requirement_owner }), false)
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_true(task.started,
						"the faithful start double must mutate before refusing")
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(manager_module._active_tasks[task], true,
						"ambiguous start refusal must keep the exact GC pin")
					helpers.assert_eq(cancellations, 1)

					helpers.assert_eq(manager.check_requirements("fixture-model",
						function() return true end,
						function() return true end,
						{ requirement_owner = requirement_owner }), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"successor preflight must retry cleanup on the same handle")
					helpers.assert_eq(#native.tasks, 1,
						"no successor may launch before native settlement")

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {},
						"a refused start's late terminal is permanently unauthorized")
					helpers.assert_eq(manager_module._active_tasks[task], nil)

					native.start_mode = "true"
					native.cancel_mode = "true"
					helpers.assert_true(manager.check_requirements("fixture-model",
						function() return true end,
						function() return true end,
						{ requirement_owner = requirement_owner }))
					helpers.assert_eq(#native.tasks, 2)
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" })
				end)
			end)
	end
end)





-- ========================================
-- ========================================
-- ======= 6/ Maintenance Ownership =======
-- ========================================
-- ========================================

helpers.describe("HS-012 MLX deletion pause ownership", function()
	helpers.it("blocks PAUSED until the exact deletion task reports terminal", function()
		with_fixture(function(native)
			install_subject_stubs(native)
			local script_control = start_script_control()
			local manager, manager_module = build_manager(script_control)
			manager._installed_cache_ts = 99
			native.cancel_mode = "false"

			helpers.assert_true(manager.delete_model("fixture-model"))
			helpers.assert_eq(#native.tasks, 1)
			local task = native.tasks[1]
			helpers.assert_eq(task.executable, "/bin/rm")
			helpers.assert_eq(task.args, { "-rf",
				(os.getenv("HOME") or "")
					.. "/.cache/huggingface/hub/models--fixture--fixture-model" })
			helpers.assert_eq(manager_module._active_tasks[task], true)

			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"PAUSED cannot publish while deletion termination is ambiguous")
			helpers.assert_eq(native.cancel_handles[1], task)
			helpers.assert_eq(manager._installed_cache_ts, 99)

			task.on_done(0, "", "")
			task.on_done(0, "", "")
			helpers.assert_eq(manager_module._active_tasks[task], nil)
			helpers.assert_eq(manager._installed_cache_ts, 99,
				"a pause-revoked deletion terminal cannot publish cache mutation")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains a mutate-then-" .. mode .. " deletion start refusal",
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local control, registration =
						observe_maintenance_registration(script_control)
					local manager, manager_module = build_manager(control)
					helpers.assert_eq(registration.owner_id,
						"mlx_model_maintenance")
					helpers.assert_true(registration.accepted)
					helpers.assert_type(registration.owner, "table")
					helpers.assert_type(registration.owner.pause, "function")
					helpers.assert_type(registration.owner.resume, "function")
					helpers.assert_eq(control.is_paused(), false)
					helpers.assert_eq(control.is_pause_transition_pending(), false)
					helpers.assert_eq(manager.get_mlx_repo("fixture-model"),
						"fixture/fixture-model")
					helpers.assert_eq(os.getenv("HOME"), "/Users/fixture")
					manager._installed_cache_ts = 99
					native.start_mode = mode
					native.cancel_mode = mode

					helpers.assert_eq(manager.delete_model("fixture-model"), false)
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_true(task.started)
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(task.terminate_calls, 1)
					helpers.assert_eq(manager_module._active_tasks[task], true)
					helpers.assert_eq(manager._installed_cache_ts, 99)

					helpers.assert_eq(manager.delete_model("fixture-model"), false)
					helpers.assert_eq(#native.tasks, 1,
						"cleanup debt must not construct a sibling deletion task")
					helpers.assert_eq(native.cancel_handles[2], task,
						"successor preflight must retry the identical retained task")
					helpers.assert_eq(task.terminate_calls, 2)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_eq(manager._installed_cache_ts, 99)
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)





-- ================================================
-- ================================================
-- ======= 5/ Import Probe Failure Messages =======
-- ================================================
-- ================================================

helpers.describe("MLX import probe failure names a working action (mlx-runtime-broken)", function()
	--- Runs one failed probe with the given runtime state and returns the record.
	--- @param runtime table { installed, running, failed }
	--- @param stderr string|nil The interpreter's error, a missing module by default.
	--- @return table record { notices, invalidations, causes, offers, probe_args }
	local function run_failed_probe(runtime, stderr)
		local record = { notices = {}, invalidations = 0, causes = {}, offers = {} }
		with_fixture(function(native)
			install_subject_stubs(native)
			package.loaded["infra.notifications"] = {
				notify = function(title, body, kind)
					record.notices[#record.notices + 1] = { title = title, body = body, kind = kind }
					return true
				end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				is_task_running = function() return runtime.running == true end,
				runtime_installed = function() return runtime.installed == true end,
				has_failed = function() return runtime.failed == true end,
				is_runtime_broken = function() return runtime.broken == true end,
				get_failure_message = function() return "fixture failure" end,
				reset_bootstrap_state = function() return true end,
				invalidate_runtime = function(cause)
					record.invalidations = record.invalidations + 1
					record.causes[#record.causes + 1] = cause
					runtime.installed = false
					return true
				end,
			}
			package.loaded["ui.menu.menu_llm.mlx_repair_offer"] = {
				offer = function(cause)
					record.offers[#record.offers + 1] = cause or "checker cause"
					return true
				end,
			}
			local script_control = start_script_control()
			local manager = build_manager(script_control)
			local capability = manager.create_requirement_owner("activation")
			local cancelled = nil
			helpers.assert_true(manager.check_requirements("fixture-model",
				function() return true end,
				function(reason) cancelled = reason return true end, {
					requirement_owner = capability,
					is_current = function() return true end,
				}))
			helpers.assert_eq(#native.tasks, 1)
			record.probe_args = native.tasks[1].args
			native.tasks[1].on_done(1, "",
				stderr or "Traceback (most recent call last):\nModuleNotFoundError: No module named 'mlx_lm'\n")
			helpers.assert_eq(cancelled, "dependency_probe_failed")
			helpers.assert_eq(native.server_starts, {})
			helpers.assert_true(script_control.stop())
		end)
		return record
	end

	helpers.it("invalidates an installed but broken runtime and offers the button that rebuilds it", function()
		local record = run_failed_probe({ installed = true })
		helpers.assert_eq(record.invalidations, 1,
			"an installed runtime that fails its imports must read as not installed")
		-- The notice used to ask for an MLX selection, which did nothing while
		-- MLX was already the selected backend: the repair dialog replaces it.
		helpers.assert_eq(#record.notices, 0,
			"no bootstrap runs on its own, so no notice may claim one is in progress")
		helpers.assert_eq(#record.offers, 1, "the failure offers its repair button")
		helpers.assert_eq(record.offers[1].kind, "import_failed")
		helpers.assert_eq(record.offers[1].repairable, true)
	end)

	helpers.it("keeps the in-progress message only while the selected install runs", function()
		local record = run_failed_probe({ installed = false, running = true })
		helpers.assert_eq(record.invalidations, 0)
		helpers.assert_eq(record.notices[1].body, "mlx.deps_missing_body")
	end)

	helpers.it("offers the install button for a missing runtime without touching it", function()
		local record = run_failed_probe({ installed = false })
		helpers.assert_eq(record.invalidations, 0)
		-- The notice used to name the menu row that installs the runtime, with
		-- no action of its own: the offer carries the install button.
		helpers.assert_eq(#record.notices, 0, "a missing runtime is not a notice without its fix")
		helpers.assert_eq(#record.offers, 1, "a missing runtime offers its install button")
		helpers.assert_eq(record.offers[1].kind, "missing")
		helpers.assert_eq(record.offers[1].repairable, true)
	end)

	helpers.it("offers the repair again when the flagged runtime fails once more", function()
		local record = run_failed_probe({ installed = false, broken = true })
		helpers.assert_eq(record.invalidations, 0)
		helpers.assert_eq(#record.notices, 0)
		helpers.assert_eq(record.offers, { "checker cause" },
			"a runtime already flagged broken offers its repair, not an install")
	end)

	helpers.it("probes every package the bootstrap fast path checks", function()
		local record = run_failed_probe({ installed = true })
		local command = record.probe_args[#record.probe_args]
		for _, package_name in ipairs({ "mlx_lm", "huggingface_hub", "jinja2",
			"safetensors", "truststore" }) do
			helpers.assert_true(command:find("import " .. package_name, 1, true) ~= nil,
				"the import probe must cover " .. package_name)
		end
	end)
end)





helpers.describe("A partial MLX venv is detected from its probe's own error (mlx-bootstrap-partial-venv)", function()
	--- Runs one failed probe on an installed runtime and returns what it flagged.
	--- @param stderr string The interpreter's error output.
	--- @return table record
	local function probe_installed(stderr)
		local record = { notices = {}, invalidations = 0, causes = {}, offers = {} }
		with_fixture(function(native)
			install_subject_stubs(native)
			package.loaded["infra.notifications"] = {
				notify = function(title, body, kind)
					record.notices[#record.notices + 1] = { title = title, body = body, kind = kind }
					return true
				end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				is_task_running = function() return false end,
				runtime_installed = function() return true end,
				has_failed = function() return false end,
				invalidate_runtime = function(cause)
					record.invalidations = record.invalidations + 1
					record.causes[#record.causes + 1] = cause
					return true
				end,
			}
			package.loaded["ui.menu.menu_llm.mlx_repair_offer"] = {
				offer = function(cause)
					record.offers[#record.offers + 1] = cause
					return true
				end,
			}
			local script_control = start_script_control()
			local manager = build_manager(script_control)
			local capability = manager.create_requirement_owner("activation")
			helpers.assert_true(manager.check_requirements("fixture-model",
				function() return true end, function() return true end, {
					requirement_owner = capability,
					is_current = function() return true end,
				}))
			native.tasks[1].on_done(1, "", stderr)
			helpers.assert_eq(native.server_starts, {}, "a broken runtime never starts the server")
			helpers.assert_true(script_control.stop())
		end)
		return record
	end

	helpers.it("flags the runtime broken with the missing module the probe printed", function()
		local record = probe_installed("Traceback (most recent call last):\n"
			.. "  File \"<string>\", line 1, in <module>\n"
			.. "ModuleNotFoundError: No module named 'mlx'\n")
		helpers.assert_eq(record.invalidations, 1)
		helpers.assert_eq(record.causes[1].kind, "import_failed")
		helpers.assert_eq(record.causes[1].line, "ModuleNotFoundError: No module named 'mlx'",
			"the probe's stderr used to be discarded; it names what is missing")
		helpers.assert_eq(record.offers[1], record.causes[1], "the offer shows the same cause")
	end)

	helpers.it("names a permission refusal on a library of the venv", function()
		local library = "/Users/fixture/Library/Application Support/Ergopti/mlx-venv/lib/python3.11/site-packages/mlx/core.cpython-311-darwin.so"
		local record = probe_installed("ImportError: dlopen(" .. library
			.. ", 0x0002): Operation not permitted\n")
		helpers.assert_eq(record.causes[1].kind, "permission")
		helpers.assert_eq(record.causes[1].path, library)
		helpers.assert_eq(record.offers[1].path, library)
	end)
end)





-- =========================================================
-- =========================================================
-- ======= 6/ One Owner For The MLX Interpreter Path =======
-- =========================================================
-- =========================================================

helpers.describe("MLX interpreter comes from the runtime owner (mlx-venv-single-owner)", function()
	-- Neither location is one the manager could derive on its own, so only a
	-- manager that asks mlx_deps_checker.venv_dir() probes them. The owner's
	-- own launcher/checkout rule is covered in test_ai_runtime_selection_install.
	for _, venv in ipairs({ "/fixture/owner/mlx-venv", "/fixture/other owner/.venv" }) do
		helpers.it("probes the venv mlx_deps_checker names (" .. venv .. ")", function()
			with_fixture(function(native)
				install_subject_stubs(native)
				package.loaded["modules.llm.mlx_deps_checker"] = {
					venv_dir = function() return venv end,
				}

				local script_control = start_script_control()
				local manager = build_manager(script_control)
				local capability = manager.create_requirement_owner("activation")
				helpers.assert_true(manager.check_requirements("fixture-model",
					function() return true end, function() return true end, {
						requirement_owner = capability,
						is_current = function() return true end,
					}))
				helpers.assert_eq(#native.tasks, 1)
				local command = native.tasks[1].args[#native.tasks[1].args]
				local expected = "\"" .. venv .. "/bin/python\" -c "
				helpers.assert_eq(command:sub(1, #expected), expected,
					"the probed interpreter must live in the venv the installed verdict reads")
				native.tasks[1].on_done(0, "", "")
				helpers.assert_true(script_control.stop())
			end)
		end)
	end
end)
