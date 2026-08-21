--- tests/unit/ui/menu/menu_llm/test_health_probe_generation.lua

--- ==============================================================================
--- MODULE: LLM Health Probe Generation Regression
--- DESCRIPTION:
--- Drives the real menu and backend actions with deferred HTTP completions.
--- A local probe loses write authority when its backend, enable state, or
--- lifecycle owner changes; only a probe for the current live MLX state commits.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"ui.menu.menu_llm",
	"ui.menu.menu_llm.backend_panel",
	"modules.llm",
	"ui.menu.shortcut_utils",
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"ui.menu.menu_llm.models_manager",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.menu_llm.settings_manager",
	"ui.menu.menu_llm.temperature_panel",
	"ui.menu.menu_llm.streaming_panel",
	"ui.menu.menu_llm.warmup_controller",
	"ui.menu.menu_llm.trigger_panel",
	"ui.menu.menu_llm.api_panel",
	"ui.menu.menu_llm.models_selector",
	"ui.menu.menu_llm.model_switcher",
	"modules.llm.api_mlx",
	"ui.menu.menu_llm.startup_controller",
	"ui.menu.menu_llm.trigger_orchestrator",
	"ui.menu.menu_llm.menu_layout",
	"infra.manifest_menu",
	"modules.llm.mlx_deps_checker",
	"modules.llm.ollama_deps_checker",
}

local function with_fixture(callback)
	return helpers.with_fresh_modules(MODULES, function()
		local noop = function() end
		local updates = 0
		local probes = {}
		local stop_mode = "sync"
		local pending_stop
		local last_stop
		local pending_stop_cancel
		local last_stop_cancel
		local pending_stop_kind
		local stop_kinds = {}
		local current_port = 3460
		local port_commits = 0
		local mlx_restarts = {}
		local state = {
			llm_enabled = true,
			llm_backend = "mlx",
			llm_model = "",
			llm_model_mlx = "",
			llm_model_ollama = "",
			llm_num_predictions = 1,
			llm_min_words = 1,
			llm_max_words = 16,
			llm_context_length = 2048,
			llm_temperature = 0.1,
			llm_reset_on_nav = true,
			llm_active_profile = "basic",
			llm_profile_shortcuts = {},
			llm_trigger_shortcut = false,
		}

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {
				llm_enabled = false,
				llm_debounce = 0.2,
				llm_model_mlx = "",
				llm_model_ollama = "",
				llm_context_length = 2048,
				llm_reset_on_nav = true,
				llm_temperature = 0.1,
				llm_num_predictions = 1,
				llm_arrow_nav_enabled = true,
				llm_nav_modifiers = {},
				llm_show_info_bar = true,
				llm_val_modifiers = {},
				llm_pred_indent = false,
				llm_active_profile = "basic",
				llm_after_hotstring = true,
				llm_auto_raise_temp = false,
				llm_min_words = 1,
				llm_streaming = true,
				llm_streaming_multi = false,
				llm_instant_on_word_end = false,
			},
			set_backend = noop,
			set_llm_model_mlx = noop,
			set_llm_model_ollama = noop,
			is_backend_ready = function() return false end,
			is_backend_load_failed = function() return false end,
			load_api_entries = noop,
		}

		local models = {
			get_presets = function() return {} end,
			get_actual_model_name = function(name) return name end,
			get_model_info = function() return {} end,
			get_model_ram = function() return 0 end,
			check_requirements = function(model, _, _, opts)
				mlx_restarts[#mlx_restarts + 1] = { model = model, opts = opts }
				return true
			end,
			stop_mlx_server_if_needed = function(on_stopped, opts)
				local kind = type(opts) == "table" and opts.kind or "stop"
				local on_cancel = type(opts) == "table" and opts.on_cancel or nil
				stop_kinds[#stop_kinds + 1] = kind
				if stop_mode == "throw" then error("fixture stop failure") end
				if stop_mode == "false" then return false end
				if stop_mode == "deferred" then
					pending_stop = on_stopped
					last_stop = on_stopped
					pending_stop_cancel = on_cancel
					last_stop_cancel = on_cancel
					pending_stop_kind = kind
					return true
				end
				if type(on_stopped) == "function" then on_stopped() end
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.models_manager"] = {
			new = function() return models end,
		}
		package.loaded["ui.menu.menu_llm.profiles_manager"] = {
			new = function()
				return { get_menu_item = function() return {} end }
			end,
		}
		package.loaded["ui.menu.menu_llm.settings_manager"] = {
			new = function()
				return {
					build_nav_modifier_menu = function() return {} end,
					build_val_modifier_menu = function() return {} end,
					set_mlx_port = function(on_applied)
						local committed = false
						local function commit_port()
							if committed then return true end
							committed = true
							current_port = 4567
							port_commits = port_commits + 1
							return true
						end
						return on_applied(4567, commit_port)
					end,
					reset_mlx_port = noop,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.temperature_panel"] = { build = noop }
		package.loaded["ui.menu.menu_llm.streaming_panel"] = {
			build = function() return {} end,
		}
		package.loaded["ui.menu.menu_llm.warmup_controller"] = { warmup = noop }
		package.loaded["ui.menu.menu_llm.trigger_panel"] = {
			build = function() return {} end,
		}
		package.loaded["ui.menu.menu_llm.api_panel"] = {
			build = function() return nil, nil end,
			build_model_picker = function() return {} end,
		}
		package.loaded["ui.menu.menu_llm.models_selector"] = {
			build = function() return {} end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = {
			new = function()
				return {
					switch_model = noop,
					disable_model = noop,
					set_llm_profile = noop,
					apply_recommended_prompt_profile = noop,
					get_display_model_name = function(name) return name end,
					get_model_power_level = function() return 1 end,
					guarded_check_requirements = noop,
				}
			end,
		}
		package.loaded["modules.llm.api_mlx"] = {
			get_base_url = function() return "http://127.0.0.1:3460" end,
			get_port = function() return current_port end,
			get_default_port = function() return 3460 end,
		}
		package.loaded["ui.menu.menu_llm.startup_controller"] = {
			new = function() return noop end,
		}
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = {
			new = function()
				return {
					bind_hotkey = noop,
					activate_hotkey = noop,
					apply_llm_shortcut = noop,
					apply_llm_profile_shortcut = noop,
					restore_shortcuts = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.menu_layout"] = {
			row_ids = function() return { "llm_backend", "llm_model" } end,
			row_disabled = function() return false end,
			has_health_dot = function(id) return id == "llm_model" end,
		}
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
			build = function(_, _, handlers)
				local items = {}
				handlers.llm_backend(items)
				handlers.llm_model(items)
				return items
			end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = {
			check_and_install_deps = noop,
		}
		package.loaded["modules.llm.ollama_deps_checker"] = {
			check_and_install_deps = noop,
		}

		local previous_async_get = hs.http.asyncGet
		local previous_hs_execute = hs.execute
		local previous_os_execute = os.execute
		hs.http.asyncGet = function(url, _, completion)
			probes[#probes + 1] = { url = url, completion = completion }
		end
		hs.execute = function() return "arm64" end
		os.execute = function() return true end

		local ok, err = xpcall(function()
			package.loaded["ui.menu.menu_llm.backend_panel"] = nil
			local MenuLLM = require("ui.menu.menu_llm")
			local handler = MenuLLM.create({
				state = state,
				keymap = {
					set_llm_enabled = noop,
					set_llm_model = noop,
					set_llm_display_model_name = noop,
					set_llm_backend_name = noop,
				},
				save_prefs = function() return true end,
				update_menu = function() updates = updates + 1 end,
				active_tasks = {},
			})
			callback({
				MenuLLM = MenuLLM,
				handler = handler,
				state = state,
				probes = probes,
				updates = function() return updates end,
				set_stop_mode = function(mode) stop_mode = mode end,
				settle_stop = function()
					local callback = pending_stop
					pending_stop = nil
					pending_stop_cancel = nil
					pending_stop_kind = nil
					if type(callback) == "function" then return callback() end
				end,
				refuse_stop = function(reason)
					local callback = pending_stop_cancel
					pending_stop = nil
					pending_stop_cancel = nil
					pending_stop_kind = nil
					if type(callback) == "function" then return callback(reason) end
				end,
				repeat_stop = function()
					if type(last_stop) == "function" then return last_stop() end
				end,
				repeat_stop_cancel = function(reason)
					if type(last_stop_cancel) == "function" then return last_stop_cancel(reason) end
				end,
				pending_stop = function() return pending_stop end,
				pending_stop_cancel = function() return pending_stop_cancel end,
				pending_stop_kind = function() return pending_stop_kind end,
				stop_kinds = stop_kinds,
				port = function() return current_port end,
				port_commits = function() return port_commits end,
				mlx_restarts = mlx_restarts,
			})
		end, debug.traceback)

		hs.http.asyncGet = previous_async_get
		hs.execute = previous_hs_execute
		os.execute = previous_os_execute
		if not ok then error(err, 0) end
	end)
end

local function build_and_assert_red(fixture)
	local item = fixture.handler.build_item()
	local model_row = item.submenu[2]
	helpers.assert_true(model_row.title:find("🔴 ", 1, true) == 1,
		"an invalidated health cache must render the current backend as unprobed")
	return item
end

helpers.describe("LLM health probe ownership", function()
	helpers.it("rejects stale local health completions after backend, disable, and teardown changes (hs-018)", function()
		for _, target in ipairs({ "api", "ollama" }) do
			with_fixture(function(fixture)
				local item = fixture.handler.build_item()
				helpers.assert_eq(#fixture.probes, 1)
				local backend_index = target == "api" and 3 or 2
				item.submenu[1].menu[backend_index].action()
				local updates_before_stale = fixture.updates()
				fixture.probes[1].completion(200)
				helpers.assert_eq(fixture.updates(), updates_before_stale,
					"a stale MLX completion must not repaint after switching to " .. target)
				build_and_assert_red(fixture)
			end)
		end

		with_fixture(function(fixture)
			local item = fixture.handler.build_item()
			local stale_probe = fixture.probes[1]
			item.action()
			local updates_before_stale = fixture.updates()
			stale_probe.completion(200)
			helpers.assert_eq(fixture.updates(), updates_before_stale,
				"a probe dispatched before disable must not repaint")
			fixture.state.llm_enabled = true
			build_and_assert_red(fixture)
		end)

		with_fixture(function(fixture)
			fixture.handler.build_item()
			local stale_probe = fixture.probes[1]
			fixture.MenuLLM.stop_mlx_server()
			local updates_before_stale = fixture.updates()
			stale_probe.completion(200)
			helpers.assert_eq(fixture.updates(), updates_before_stale,
				"a probe dispatched before teardown must not repaint")
			build_and_assert_red(fixture)
		end)

		with_fixture(function(fixture)
			local item = build_and_assert_red(fixture)
			helpers.assert_true(item.submenu[2].title:find("🔴 ", 1, true) == 1)
			local updates_before_current = fixture.updates()
			fixture.probes[1].completion(200)
			helpers.assert_eq(fixture.updates(), updates_before_current + 1,
				"the current MLX probe must commit and repaint exactly once")
			local refreshed = fixture.handler.build_item()
			helpers.assert_true(refreshed.submenu[2].title:find("🟡 ", 1, true) == 1,
				"a committed current MLX response must render the reachable state")
		end)
	end)

	helpers.it("reports shutdown settled only from the exact stop callback (HS-008)", function()
		for _, mode in ipairs({ "false", "throw" }) do
			with_fixture(function(fixture)
				fixture.handler.build_item()
				fixture.set_stop_mode(mode)
				local settlements = 0
				helpers.assert_eq(fixture.MenuLLM.stop_mlx_server(function()
					settlements = settlements + 1
				end), false)
				helpers.assert_eq(fixture.pending_stop(), nil)
				helpers.assert_eq(settlements, 0)
			end)
		end

		with_fixture(function(fixture)
			fixture.handler.build_item()
			local stale_probe = fixture.probes[1]
			fixture.set_stop_mode("deferred")
			local settlements = 0
			helpers.assert_eq(fixture.MenuLLM.stop_mlx_server(function(settled)
				helpers.assert_eq(settled, true)
				settlements = settlements + 1
			end), true,
				"accepted SIGTERM must transfer exact callback ownership")
			helpers.assert_eq(type(fixture.pending_stop()), "function")
			helpers.assert_eq(fixture.pending_stop_kind(), "shutdown")
			helpers.assert_eq(settlements, 0)
			helpers.assert_eq(fixture.settle_stop(), true)
			helpers.assert_eq(settlements, 1)
			fixture.repeat_stop()
			helpers.assert_eq(settlements, 1,
				"a duplicate native completion cannot publish shutdown twice")
			local updates_before_stale = fixture.updates()
			stale_probe.completion(200)
			helpers.assert_eq(fixture.updates(), updates_before_stale)
		end)

		with_fixture(function(fixture)
			fixture.handler.build_item()
			fixture.set_stop_mode("deferred")
			local terminals = {}
			helpers.assert_eq(fixture.MenuLLM.stop_mlx_server(function(settled, detail)
				terminals[#terminals + 1] = { settled = settled, detail = detail }
			end), true)
			helpers.assert_eq(type(fixture.pending_stop_cancel()), "function",
				"shutdown must own the exact cleanup-refusal terminal")
			helpers.assert_eq(fixture.refuse_stop("cleanup_refused"), false)
			helpers.assert_eq(#terminals, 1)
			helpers.assert_eq(terminals[1].settled, false)
			helpers.assert_eq(terminals[1].detail, "cleanup_refused")
			helpers.assert_eq(fixture.repeat_stop_cancel("cleanup_refused"), false)
			helpers.assert_eq(#terminals, 1,
				"a duplicate cleanup refusal cannot publish shutdown twice")
		end)
	end)

	helpers.it("routes real port and backend actions through one latest intent (HS-008)", function()
		with_fixture(function(fixture)
			fixture.state.llm_model = "A"
			fixture.state.llm_model_mlx = "A"
			fixture.set_stop_mode("deferred")
			local item = fixture.handler.build_item()
			local port_action = item.submenu[2].menu[2].action
			local backend_action = item.submenu[1].menu[3].action
			helpers.assert_eq(type(port_action), "function")
			helpers.assert_eq(type(backend_action), "function")

			helpers.assert_eq(port_action(), true)
			helpers.assert_eq(fixture.pending_stop_kind(), "port")
			helpers.assert_eq(fixture.port(), 3460)
			helpers.assert_eq(backend_action(), true)
			helpers.assert_eq(fixture.pending_stop_kind(), "backend")
			helpers.assert_eq(fixture.state.llm_backend, "mlx")
			helpers.assert_eq(fixture.settle_stop(), true)
			helpers.assert_eq(fixture.state.llm_backend, "api")
			helpers.assert_eq(fixture.port(), 3460,
				"a superseded port callback cannot publish its candidate")
			helpers.assert_eq(fixture.port_commits(), 0)
			helpers.assert_eq(#fixture.mlx_restarts, 0)
			helpers.assert_eq(fixture.stop_kinds, { "port", "backend" })
		end)

		with_fixture(function(fixture)
			fixture.state.llm_model = "A"
			fixture.state.llm_model_mlx = "A"
			fixture.set_stop_mode("deferred")
			local item = fixture.handler.build_item()
			local port_action = item.submenu[2].menu[2].action
			local backend_action = item.submenu[1].menu[3].action

			helpers.assert_eq(backend_action(), true)
			helpers.assert_eq(fixture.pending_stop_kind(), "backend")
			helpers.assert_eq(port_action(), true)
			helpers.assert_eq(fixture.pending_stop_kind(), "port")
			helpers.assert_eq(fixture.settle_stop(), true)
			helpers.assert_eq(fixture.state.llm_backend, "mlx",
				"a superseded backend callback cannot publish")
			helpers.assert_eq(fixture.port(), 4567)
			helpers.assert_eq(fixture.port_commits(), 1)
			helpers.assert_eq(#fixture.mlx_restarts, 1)
			helpers.assert_eq(fixture.mlx_restarts[1].model, "A")
			helpers.assert_eq(fixture.mlx_restarts[1].opts._mlx_port, 4567)
			helpers.assert_eq(fixture.stop_kinds, { "backend", "port" })
		end)
	end)
end)

return true
