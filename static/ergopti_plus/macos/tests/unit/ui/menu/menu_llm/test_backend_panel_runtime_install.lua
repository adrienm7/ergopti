--- tests/unit/ui/menu/menu_llm/test_backend_panel_runtime_install.lua

--- ==============================================================================
--- MODULE: Backend Rows Wait For Their Runtime Install
--- DESCRIPTION:
--- The first selection of a backend whose runtime is missing is also its only
--- install. The row must not switch the backend or check its model before that
--- install settles: a model check dispatched during the Ollama download probes
--- a daemon whose executable does not exist yet, posts "Failed to launch Ollama
--- daemon", and is never retried. These cases drive the real backend rows and
--- selection router against checker doubles whose install the test settles.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.llm", "infra.i18n", "infra.logger", "infra.manifest_menu",
	"infra.dialog_util", "infra.notifications", "modules.llm.ollama_binary",
	"modules.llm.mlx_deps_checker", "modules.llm.ollama_deps_checker",
	"ui.menu.menu_llm.runtime_install_offer", "ui.menu.menu_llm.backend_panel",
	"ui.menu.menu_llm.mlx_repair_offer", "modules.llm.mlx_bootstrap_diagnosis",
	"infra.deferred_work", "modules.llm.backend_detector",
}

local ROW = { mlx = 1, ollama = 2, api = 3 }

--- Builds a checker double whose install stays pending until finish().
--- The real Ollama checker delivers its completions before releasing its
--- pause-owner intent, so a check started from inside one is refused; the
--- MLX checker answers a ready runtime before acquiring any intent.
--- @param installed boolean Whether the runtime exists at the start.
--- @param refuses_while_completing boolean Models the Ollama checker's refusal.
--- @return table checker
local function new_checker(installed, refuses_while_completing)
	local checker = {
		installed = installed, running = false, completing = false,
		installs = 0, refusals = 0, waiters = {},
	}
	local function settle_or_queue(on_complete)
		if refuses_while_completing and checker.completing then
			checker.refusals = checker.refusals + 1
			return false
		end
		if type(on_complete) ~= "function" then return true end
		if checker.installed and not checker.running then
			on_complete(true)
		else
			checker.waiters[#checker.waiters + 1] = on_complete
		end
		return true
	end
	checker.check_and_install_deps = function(on_complete)
		return settle_or_queue(on_complete)
	end
	checker.install_for_selection = function(on_complete)
		if not checker.installed and not checker.running then
			checker.installs = checker.installs + 1
			checker.running = true
		end
		return settle_or_queue(on_complete)
	end
	checker.runtime_available = function() return checker.installed end
	checker.runtime_installed = function() return checker.installed end
	checker.is_task_running = function() return checker.running end
	checker.finish = function(ok)
		checker.running = false
		if ok then checker.installed = true end
		local waiters = checker.waiters
		checker.waiters = {}
		checker.completing = true
		for _, waiter in ipairs(waiters) do waiter(ok) end
		checker.completing = false
	end
	return checker
end

--- Runs one scenario with the real backend rows over the doubles.
--- @param opts table { backend, mlx_installed, ollama_installed, dialog_choice, arch }
--- @param scenario function Receives (rows, record, state).
local function with_rows(opts, scenario)
	helpers.with_fresh_modules(OWNED_MODULES, function()
		local record = {
			runtime_backend = opts.backend,
			switches = {},
			dialogs = 0, process_commands = 0,
			notices = {},
			mlx = new_checker(opts.mlx_installed ~= false),
			ollama = new_checker(opts.ollama_installed ~= false, true),
		}
		local state = {
			llm_backend = opts.backend,
			llm_enabled = opts.enabled ~= false,
			llm_model = "current-model",
			llm_model_mlx = "mlx-model",
			llm_model_ollama = "ollama-model",
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_model_mlx = "mlx-default", llm_model_ollama = "ollama-default" },
			get_backend = function() return record.runtime_backend end,
			set_backend = function(value)
				record.runtime_backend = value
				return true
			end,
			load_api_entries = function() return true end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			format = function(key) return key end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.manifest_menu"] = { render_rows = function(rows) return rows end }
		package.loaded["infra.notifications"] = {
			notify = function(title, body)
				record.notices[#record.notices + 1] = { title = title, body = body }
				return true
			end,
		}
		package.loaded["infra.dialog_util"] = {
			block_alert = function()
				record.dialogs = record.dialogs + 1
				return opts.dialog_choice or "ollama.offer_download"
			end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = record.mlx
		package.loaded["modules.llm.ollama_deps_checker"] = record.ollama

		local previous_execute = os.execute
		local previous_hs_execute = hs.execute
		os.execute = function()
			record.process_commands = record.process_commands + 1
			return true
		end
		hs.execute = function() return opts.arch or "arm64" end
		local ok, err = xpcall(function()
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			local _, rows = BackendPanel.build({
				state = state,
				keymap = { set_llm_backend_name = function() return true end },
				paused = false,
				models_mgr = { stop_mlx_server_if_needed = function(done)
					record.stops = (record.stops or 0) + 1
					return done()
				end },
				get_display_model_name = function(name) return name end,
				switch_model = function(model)
					record.switches[#record.switches + 1] = {
						model = model,
						ollama_installed = record.ollama.installed,
						mlx_installed = record.mlx.installed,
					}
					return true
				end,
				disable_model = function() return true end,
				save_prefs = function() return true end,
				update_menu = function() return true end,
				WarmupCtrl = { warmup = function() return true end },
				reset_llm_health_status = function() return true end,
			})
			scenario(rows, record, state)
		end, debug.traceback)
		os.execute = previous_execute
		hs.execute = previous_hs_execute
		if not ok then error(err, 0) end
	end)
end





-- =========================================
-- =========================================
-- ======= 1/ Ollama First Selection =======
-- =========================================
-- =========================================

helpers.describe("Ollama row waits for the accepted download (backend-runtime-install)", function()
	helpers.it("switches exactly once, only after the executable exists", function()
		with_rows({ backend = "api", ollama_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.ollama].action(), true)
			helpers.assert_eq(record.dialogs, 1)
			helpers.assert_eq(record.ollama.installs, 1)
			helpers.assert_eq(#record.switches, 0,
				"no model check may run while Ollama is still downloading")
			helpers.assert_eq(state.llm_backend, "api")
			helpers.assert_eq(record.runtime_backend, "api",
				"the backend must not change before the runtime exists")

			record.ollama.finish(true)
			helpers.assert_eq(#record.switches, 1)
			helpers.assert_eq(record.switches[1].model, "ollama-model")
			helpers.assert_true(record.switches[1].ollama_installed,
				"the model switch must see an installed Ollama")
			helpers.assert_eq(state.llm_backend, "ollama")
			helpers.assert_eq(record.runtime_backend, "ollama")
			helpers.assert_eq(record.ollama.installs, 1)
		end)
	end)

	helpers.it("keeps the current backend when the download fails", function()
		with_rows({ backend = "api", ollama_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.ollama].action(), true)
			record.ollama.finish(false)
			helpers.assert_eq(#record.switches, 0)
			helpers.assert_eq(state.llm_backend, "api")
			helpers.assert_eq(record.runtime_backend, "api")
		end)
	end)

	helpers.it("keeps the current backend when the offer is declined", function()
		with_rows({ backend = "api", ollama_installed = false,
			dialog_choice = "ollama.offer_website" }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.ollama].action(), false)
			helpers.assert_eq(record.ollama.installs, 0)
			helpers.assert_eq(#record.switches, 0)
			helpers.assert_eq(state.llm_backend, "api")
			helpers.assert_eq(#record.notices, 1)
			helpers.assert_eq(record.notices[1].body, "ollama.switch_declined_body",
				"the previous backend keeps running, so the notice must not say the AI is off")
		end)
	end)

	helpers.it("yields to a newer backend selection made during the download", function()
		with_rows({ backend = "api", ollama_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.ollama].action(), true)
			helpers.assert_eq(rows[ROW.mlx].action(), true)
			helpers.assert_eq(state.llm_backend, "mlx")
			helpers.assert_eq(#record.switches, 1)

			record.ollama.finish(true)
			helpers.assert_eq(#record.switches, 1,
				"a slow install must not override the user's newer choice")
			helpers.assert_eq(state.llm_backend, "mlx")
			helpers.assert_eq(record.runtime_backend, "mlx")
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 2/ MLX First Selection =======
-- ======================================
-- ======================================

helpers.describe("MLX row waits for its runtime install (backend-runtime-install)", function()
	helpers.it("switches exactly once, only after the runtime exists", function()
		with_rows({ backend = "api", mlx_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.mlx].action(), true)
			helpers.assert_eq(record.mlx.installs, 1)
			helpers.assert_eq(#record.switches, 0,
				"no MLX model check may run while its runtime installs")
			helpers.assert_eq(state.llm_backend, "api")

			record.mlx.finish(true)
			helpers.assert_eq(#record.switches, 1)
			helpers.assert_eq(record.switches[1].model, "mlx-model")
			helpers.assert_true(record.switches[1].mlx_installed)
			helpers.assert_eq(state.llm_backend, "mlx")
			helpers.assert_eq(record.mlx.installs, 1)
		end)
	end)

	helpers.it("switches at once when the runtime is already installed", function()
		with_rows({ backend = "api" }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.mlx].action(), true)
			helpers.assert_eq(record.mlx.installs, 0)
			helpers.assert_eq(#record.switches, 1)
			helpers.assert_eq(state.llm_backend, "mlx")
		end)
	end)
end)





-- ================================================
-- ================================================
-- ======= 3/ A Mac That Cannot Run MLX ===========
-- ================================================
-- ================================================

helpers.describe("The MLX row explains an unsupported Mac and offers Ollama (mlx-bootstrap-unsupported-row)", function()
	helpers.it("labels the disabled row and lets the repair offer select Ollama", function()
		with_rows({ backend = "api", arch = "x86_64" }, function(rows, record, state)
			local mlx_row = rows[ROW.mlx]
			helpers.assert_true(mlx_row.disabled == true, "MLX cannot run on an Intel Mac")
			helpers.assert_true(mlx_row.label:find("(menu.llm.backend_mlx_unsupported)", 1, true) ~= nil,
				"the disabled row must say why: " .. mlx_row.label)

			package.loaded["infra.deferred_work"] = {
				after = function(_, callback) callback(); return true end,
			}
			package.loaded["infra.dialog_util"].block_alert = function(_, _, primary)
				record.dialogs = record.dialogs + 1
				return primary
			end
			local offered = require("ui.menu.menu_llm.mlx_repair_offer").offer({
				kind = "unsupported", machine = "Intel", repairable = false,
			})
			helpers.assert_true(offered)
			helpers.assert_eq(record.dialogs, 1)
			helpers.assert_eq(#record.switches, 1, "« Use Ollama » runs the Ollama row's own selection")
			helpers.assert_eq(record.switches[1].model, "ollama-model")
			helpers.assert_eq(state.llm_backend, "ollama")
		end)
	end)
end)

helpers.describe("backend-before-enable configuration", function()
	helpers.it("selects absent Ollama from failed MLX while AI stays off", function()
		with_rows({ backend = "mlx", enabled = false, mlx_installed = false,
			ollama_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.ollama].action(), true)
			helpers.assert_eq(state.llm_backend, "ollama")
			helpers.assert_eq(record.runtime_backend, "ollama")
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(record.stops, 1, "the actual old-backend stop boundary remains required")
			helpers.assert_eq(record.dialogs, 0)
			helpers.assert_eq(record.ollama.installs, 0)
			helpers.assert_eq(record.mlx.installs, 0)
			helpers.assert_eq(#record.switches, 1)
			helpers.assert_eq(record.switches[1].model, "ollama-model")
			helpers.assert_eq(record.process_commands, 0, "configuration cannot stop a personal process")
		end)
	end)
	helpers.it("selects absent MLX preference without installing while AI is off", function()
		with_rows({ backend = "api", enabled = false, mlx_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.mlx].action(), true)
			helpers.assert_eq(state.llm_backend, "mlx")
			helpers.assert_eq(record.runtime_backend, "mlx")
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(record.mlx.installs, 0)
			helpers.assert_eq(record.dialogs, 0)
			helpers.assert_eq(#record.switches, 1)
			helpers.assert_eq(record.switches[1].model, "mlx-model")
			helpers.assert_eq(record.process_commands, 0, "configuration cannot stop a personal process")
		end)
	end)
	helpers.it("selects API while MLX is absent without repairing it", function()
		with_rows({ backend = "mlx", enabled = false, mlx_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.api].action(), true)
			helpers.assert_eq(state.llm_backend, "api")
			helpers.assert_eq(record.runtime_backend, "api")
			helpers.assert_eq(record.stops, 1)
			helpers.assert_eq(record.mlx.installs, 0)
			helpers.assert_eq(record.dialogs, 0)
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(record.process_commands, 0, "configuration cannot stop a personal process")
		end)
	end)
end)

helpers.describe("off-state current backend reselect", function()
	helpers.it("does not install an absent current runtime or stop processes", function()
		with_rows({ backend = "mlx", enabled = false, mlx_installed = false }, function(rows, record, state)
			helpers.assert_eq(rows[ROW.mlx].action(), true)
			helpers.assert_eq(state.llm_backend, "mlx")
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(record.mlx.installs, 0)
			helpers.assert_eq(record.process_commands, 0)
			helpers.assert_eq(#record.switches, 0)
		end)
	end)
end)


helpers.describe("provider checkmark owns its publication (backend-checkmark)", function()
	local modules = {}
	for _, name in ipairs(OWNED_MODULES) do modules[#modules + 1] = name end
	for _, name in ipairs({ "ui.menu.menu_llm.model_switcher", "ui.menu.menu_llm.prediction_lock_registry",
		"ui.menu.menu_llm.profile_label", "adapters.timer_scheduler", "llm.tone" }) do
		modules[#modules + 1] = name
	end
	local function fixture(target, rejects_menu, scenario)
		helpers.with_fresh_modules(modules, function()
			local source = target == "ollama" and "mlx" or "ollama"
			local state = { llm_backend = source, llm_enabled = true, llm_active_profile = "basic",
				llm_num_predictions = 1, llm_model = "old", llm_model_mlx = "candidate",
				llm_model_ollama = "candidate" }
			local observed = { backend = source, menus = {}, model_setters = 0 }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.dialog_util"] = { block_alert = function() error("dialog forbidden") end }
			package.loaded["infra.notifications"] = { notify = function() return true end }
			package.loaded["infra.manifest_menu"] = { render_rows = function(rows) return rows end }
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = { llm_num_predictions = 1, llm_model_mlx = "candidate", llm_model_ollama = "candidate" },
				get_backend = function() return observed.backend end,
				set_backend = function(value) observed.backend = value; return true end,
				load_api_entries = function() return true end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = new_checker(true)
			package.loaded["modules.llm.ollama_deps_checker"] = new_checker(true, true)
			local pending
			local models = {
				stop_mlx_server_if_needed = function(done) return done() end,
				check_requirements = function(_, success, failure)
					pending = { success = success, failure = failure }; return true
				end,
				get_presets = function() return {} end,
				get_model_info = function() return {} end,
				get_actual_model_name = function(name) return name end,
			}
			local keymap = {
				set_llm_backend_name = function() return true end,
				set_llm_model = function() observed.model_setters = observed.model_setters + 1; return true end,
				set_llm_display_model_name = function() return true end,
				set_llm_enabled = function() return true end,
			}
			local panel, context
			local function refresh()
				local _, rows = panel.build(context)
				local checks = {}
				for id, index in pairs(ROW) do checks[id] = rows[index].checked end
				observed.menus[#observed.menus + 1] = checks
				if rejects_menu and state.llm_backend == target then return false end
				return true
			end
			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state, models_mgr = models, keymap = keymap,
				save_prefs = function() return true end, update_menu = refresh,
			})
			panel = require("ui.menu.menu_llm.backend_panel")
			context = { state = state, keymap = keymap, models_mgr = models, paused = false,
				get_display_model_name = switcher.get_display_model_name,
				switch_model = switcher.switch_model, disable_model = switcher.disable_model,
				save_prefs = function() return true end, update_menu = refresh,
				WarmupCtrl = { warmup = function() return true end },
				reset_llm_health_status = function() return true end }
			local old_execute, old_hs_execute = os.execute, hs.execute
			os.execute = function() error("process forbidden") end
			hs.execute = function() return "arm64" end
			local ok, err = xpcall(function()
				refresh()
				local _, rows = panel.build(context)
				local accepted = rows[ROW[target]].action()
				scenario(accepted, observed, state, pending, source)
			end, debug.traceback)
			os.execute, hs.execute = old_execute, old_hs_execute
			if not ok then error(err, 0) end
		end)
	end
	helpers.it("(backend-checkmark) local backend renders while real model requirements are pending", function()
		for _, target in ipairs({ "ollama", "mlx" }) do
			fixture(target, false, function(accepted, observed, state, pending)
				helpers.assert_eq(accepted, true)
				helpers.assert_type(pending, "table", "the real model owner must retain its async completion")
				helpers.assert_eq(state.llm_backend, target)
				helpers.assert_eq(observed.backend, target)
				helpers.assert_eq(observed.model_setters, 0, "menu refresh cannot pretend the model completed")
				helpers.assert_eq(observed.menus[#observed.menus][target], true,
					"the real rebuilt row must show the committed provider before model success")
			end)
		end
	end)
	helpers.it("(backend-checkmark) failed real model requirements keep the committed provider visible", function()
		fixture("ollama", false, function(accepted, observed, state, pending)
			helpers.assert_eq(accepted, true)
			helpers.assert_type(pending, "table")
			pending.failure()
			helpers.assert_eq(state.llm_backend, "ollama")
			helpers.assert_eq(observed.model_setters, 0)
			helpers.assert_eq(observed.menus[#observed.menus].ollama, true)
		end)
	end)
	helpers.it("(backend-checkmark) refused menu ACK restores the prior provider and checkmark", function()
		fixture("ollama", true, function(accepted, observed, state, pending, source)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(state.llm_backend, source)
			helpers.assert_eq(observed.backend, source)
			helpers.assert_eq(observed.menus[#observed.menus][source], true)
			pending.failure()
			helpers.assert_eq(state.llm_backend, source)
		end)
	end)
end)
