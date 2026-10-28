--- tests/unit/ui/menu/menu_llm/models/test_model_selector_page.lua

--- ==============================================================================
--- MODULE: Model Selector Page Owner
--- DESCRIPTION:
--- Regression model-selector-page. The maintainer moved the backend chooser,
--- the model list, the API options and the custom-model option from the tray
--- to one page on 2026-10-27. These cases drive the real owner with doubles at
--- its outer boundaries and prove it: greys each unusable backend with its
--- reason (Intel Mac, MLX missing or broken, Ollama missing or failed, API
--- without key), refuses activating a model that is not installed, runs the
--- tray's own switch (same backend) or the Backend panel's selection with the
--- model slot (other backend), validates and downloads an added model, and
--- switches to the API backend before an API action.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"ui.menu.menu_llm.model_selector_page", "ui.menu.menu_llm.custom_models",
	"ui.menu.menu_llm.backend_labels", "infra.dialog_util", "infra.deferred_work",
	"modules.llm", "modules.llm.api_mlx",
	"ui.menu.menu_llm.mlx_repair_offer", "ui.menu.menu_llm.api_panel", "ui.download_window", "ui.model_browser",
}

--- One runtime checker double.
local function deps(fields)
	return {
		runtime_installed = function() return fields.installed ~= false end,
		runtime_available = function() return fields.installed ~= false end,
		has_failed = function() return fields.failed == true end,
		is_runtime_broken = function() return fields.broken == true end,
		is_task_running = function() return fields.running == true end,
	}
end

--- The probes a case runs with.
local function probes(opts)
	return {
		is_apple_silicon = function() return opts.apple ~= false end,
		mlx_deps = function() return deps(opts.mlx or {}) end,
		ollama_deps = function() return deps(opts.ollama or {}) end,
		install_runtime = function(backend, on_complete)
			opts.installs = opts.installs or {}
			opts.installs[#opts.installs + 1] = { backend = backend, on_complete = on_complete }
			return opts.install_refused ~= true
		end,
	}
end

local CATALOGUE = { { label = "Alibaba", families = { { label = "Qwen", models = {
	{ name = "Qwen-A", parameters = { total = "4B" },
		hardware_requirements = { ollama = { download_gb = 2.5, ram_gb = 3 }, mlx = { download_gb = 2.2, ram_gb = 2.8 } },
		urls = { ollama = "https://ollama.com/library/qwen-a:4b", mlx = "https://huggingface.co/mlx/Qwen-A" } },
	{ name = "Qwen-B", parameters = { total = "8B" },
		hardware_requirements = { ollama = { download_gb = 5, ram_gb = 6 } },
		urls = { ollama = "https://ollama.com/library/qwen-b:8b", mlx = "https://huggingface.co/mlx/Qwen-B" } },
} } } } }

--- Runs one case with the real owner and the doubles it talks to.
--- @param opts table { backend, installed = { [backend] = { [name] = true } }, entries }
--- @param body function Receives (Page, ctx, calls).
local function with_page(opts, body)
	helpers.with_fresh_modules(OWNED, function()
		local calls = { switch = {}, select = {}, pulls = {}, saves = 0, api = {} }
		package.loaded["infra.dialog_util"] = { block_alert = function() return "OK" end,
			text_prompt = function() return "OK", opts.typed_model or "" end }
		package.loaded["infra.deferred_work"] = { after = function(_, fn) fn(); return true end }
		package.loaded["ui.menu.menu_llm.mlx_repair_offer"] = { set_alternative = function() end }
		package.loaded["ui.download_window"] = { set_percent_listener = function(fn) calls.percent_listener = fn end }
		package.loaded["ui.model_browser"] = { inject_progress = function(update)
			calls.progress = calls.progress or {}
			calls.progress[#calls.progress + 1] = update
			return true
		end, inject_install_progress = function(update)
			calls.install_progress = calls.install_progress or {}
			calls.install_progress[#calls.install_progress + 1] = update
			return true
		end }
		package.loaded["modules.llm.api_mlx"] = { get_port = function() return 3460 end, get_default_port = function() return 3460 end }
		package.loaded["modules.llm"] = { api_remote = {
			listing_state = function(id)
				local ids = (opts.listed or {})[id]
				if ids then return { state = "listed", ids = ids } end
				return (opts.listing or {})[id]
			end,
			PROVIDERS = { openai = { default_model = "gpt-4o-mini", model_extras = { ["o-extra"] = {} } },
				groq = { default_model = "llama", model_extras = {} } },
			local_server_views = function() return opts.local_views or {} end,
			get_active_entry = function() return nil end,
		} }
		package.loaded["ui.menu.menu_llm.api_panel"] = {
			set_entry_model = function(_, id, model) calls.api[#calls.api + 1] = "model:" .. id .. ":" .. model; return true end,
			clear_active_entry = function() calls.api[#calls.api + 1] = "clear"; return true end,
		}
		local Page = require("ui.menu.menu_llm.model_selector_page")
		local state = { llm_backend = opts.backend or "ollama", llm_model = opts.model or "Qwen-A", llm_user_models = {} }
		local installed = opts.installed or { ollama = { ["Qwen-A"] = true }, mlx = { ["Qwen-A"] = true } }
		local ctx = {
			state = state, keymap = {}, settings_mgr = {}, WarmupCtrl = {},
			DEFAULT_STATE = { llm_model_ollama = "Qwen-A", llm_model_mlx = "Qwen-A" },
			models_mgr = {
				get_all_presets = function() return CATALOGUE end,
				backend_model_installed = function(backend, name) return installed[backend][name] == true end,
				backend_actual_model_name = function(_, name) return name:lower() end,
				pull_ollama_model = function(tag, done) calls.pulls[#calls.pulls + 1] = "ollama:" .. tag; calls.done = done; return true end,
				pull_mlx_repo = function(repo, done) calls.pulls[#calls.pulls + 1] = "mlx-repo:" .. repo; calls.done = done; return true end,
				pull_mlx_model = function(name, done) calls.pulls[#calls.pulls + 1] = "mlx:" .. name; calls.done = done; return true end,
			},
			switch_model = function(name) calls.switch[#calls.switch + 1] = name; return true end,
			disable_model = function() calls.disabled = true; return true end,
			save_prefs = function() calls.saves = calls.saves + 1; return opts.save_fails ~= true end,
			update_menu = function() end,
			is_paused = function() return opts.paused == true end,
			get_display_model_name = function(name) return name end,
			hf_token_set = function() return false end,
			restart_mlx_for_current_port = function() end,
			config_reason = function() return opts.read_only end,
		}
		Page.bind(ctx)
		local collected = {
			select = {
				ollama = function() calls.select[#calls.select + 1] = "ollama:" .. tostring(state.llm_model_ollama); return true end,
				mlx = function() calls.select[#calls.select + 1] = "mlx:" .. tostring(state.llm_model_mlx); return true end,
				api = function(after)
					calls.select[#calls.select + 1] = "api"
					state.llm_backend = "api"
					if after then return after() end
					return true
				end,
			},
			entries = opts.entries or {}, api_select = {
				e1 = function() calls.api[#calls.api + 1] = "select:e1"; return true end,
			},
			add = { openai = function() calls.api[#calls.api + 1] = "add:openai:" .. state.llm_backend; return true end },
			providers = { { id = "openai", label = "OpenAI" } },
		}
		body(Page, ctx, calls, collected, probes(opts))
	end)
end

--- The payload's backend entry by id.
local function backend_of(payload, id)
	for _, b in ipairs(payload.backends) do if b.id == id then return b end end
end

local function row_of(payload, backend, name)
	for _, r in ipairs(payload.models) do if r.backend == backend and r.name == name then return r end end
end

helpers.describe("model selector page owner", function()
	helpers.it("greys each unusable backend with its own reason", function()
		local cases = {
			{ opts = { apple = false }, backend = "mlx", reason = "model_browser.reason_mlx_intel" },
			{ opts = { mlx = { installed = false } }, backend = "mlx", reason = "model_browser.reason_mlx_missing" },
			{ opts = { mlx = { broken = true } }, backend = "mlx", reason = "model_browser.reason_mlx_missing" },
			{ opts = { mlx = { failed = true } }, backend = "mlx", reason = "model_browser.reason_mlx_missing" },
			{ opts = { ollama = { installed = false } }, backend = "ollama", reason = "model_browser.reason_ollama_missing" },
			{ opts = { ollama = { failed = true } }, backend = "ollama", reason = "model_browser.reason_ollama_missing" },
		}
		for _, case in ipairs(cases) do
			with_page(case.opts, function(Page, ctx, _, collected, p)
				local payload = Page.build_payload(ctx, p, collected)
				local b = backend_of(payload, case.backend)
				helpers.assert_eq(b.available, false, case.reason)
				helpers.assert_eq(b.reason_key, case.reason)
				helpers.assert_nil(b.add_model, "an unavailable backend offers no add field")
				helpers.assert_eq(backend_of(payload, "api").available, true, "the API stays available")
			end)
		end
	end)

	-- model-selector-install-button: each local group carries its install
	-- button, greyed once installed or where it cannot run, running while it runs.
	helpers.it("states each local backend's install: installed, available, unsupported or running", function()
		local cases = {
			{ opts = {}, backend = "ollama", install = { state = "installed" } },
			{ opts = {}, backend = "mlx", install = { state = "installed" } },
			{ opts = { ollama = { installed = false } }, backend = "ollama", install = { state = "available" } },
			{ opts = { ollama = { failed = true } }, backend = "ollama", install = { state = "available" } },
			{ opts = { mlx = { broken = true } }, backend = "mlx", install = { state = "available" } },
			{ opts = { apple = false }, backend = "mlx",
				install = { state = "unsupported", reason_key = "model_browser.reason_mlx_intel" } },
			{ opts = { read_only = "menu.read_only.newer_schema" }, backend = "ollama",
				install = { state = "unsupported", reason_key = "menu.read_only.newer_schema" } },
			{ opts = { ollama = { installed = false, running = true } }, backend = "ollama", install = { state = "running" } },
		}
		for _, case in ipairs(cases) do
			with_page(case.opts, function(Page, ctx, _, collected, p)
				local payload = Page.build_payload(ctx, p, collected)
				helpers.assert_eq(backend_of(payload, case.backend).install, case.install, case.backend)
				for _, a in ipairs(backend_of(payload, case.backend).actions) do
					helpers.assert_true(a.id ~= "install", "the install is the page's own button, not a tool")
				end
				helpers.assert_nil(backend_of(payload, "api").install, "the API installs nothing")
			end)
		end
	end)

	helpers.it("installs a missing runtime from its button, shows its progress and unlocks the rows", function()
		local opts = { ollama = { installed = false } }
		with_page(opts, function(Page, ctx, calls, collected, p)
			local payload = Page.build_payload(ctx, p, collected)
			helpers.assert_eq(backend_of(payload, "ollama").available, false, "no row is usable before the install")
			helpers.assert_true(Page.handle_action(ctx, { action = "group_action", backend = "ollama", id = "install" }, p, collected))
			helpers.assert_eq(#opts.installs, 1)
			helpers.assert_eq(opts.installs[1].backend, "ollama")
			helpers.assert_eq(#calls.select, 0, "the install switches no backend")
			helpers.assert_eq(backend_of(Page.build_payload(ctx, p, collected), "ollama").install, { state = "running" })
			helpers.assert_eq(Page.handle_action(ctx, { action = "group_action", backend = "ollama", id = "install" }, p, collected), false,
				"a running install is not started twice")
			helpers.assert_true(calls.percent_listener("ollama_install", 37))
			helpers.assert_eq(calls.install_progress, { { backend = "ollama", percent = 37 } })
			helpers.assert_eq(backend_of(Page.build_payload(ctx, p, collected), "ollama").install,
				{ state = "running", percent = 37 })
			opts.ollama.installed = true
			opts.installs[1].on_complete(true)
			payload = Page.build_payload(ctx, p, collected)
			helpers.assert_eq(backend_of(payload, "ollama").install, { state = "installed" })
			helpers.assert_eq(backend_of(payload, "ollama").available, true, "the installed runtime unlocks its rows")
			helpers.assert_eq(Page.handle_action(ctx, { action = "group_action", backend = "ollama", id = "install" }, p, collected), false,
				"an installed runtime is not installed again")
		end)
		with_page({ apple = false }, function(Page, ctx, _, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "group_action", backend = "mlx", id = "install" }, p, collected), false,
				"an Intel Mac cannot install MLX")
		end)
		local refused = { mlx = { installed = false }, install_refused = true }
		with_page(refused, function(Page, ctx, _, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "group_action", backend = "mlx", id = "install" }, p, collected), false)
			helpers.assert_eq(backend_of(Page.build_payload(ctx, p, collected), "mlx").install, { state = "available" },
				"an install that did not start is offered again")
		end)
	end)

	helpers.it("projects the catalogue columns per backend from one shared module", function()
		with_page({}, function(Page, ctx, _, collected, p)
			local payload = Page.build_payload(ctx, p, collected)
			local row = row_of(payload, "ollama", "Qwen-A")
			helpers.assert_eq(row.disk_gb, 2.5)
			helpers.assert_eq(row.ram_gb, 3)
			helpers.assert_eq(row.installed, true)
			helpers.assert_eq(row.is_default, true)
			helpers.assert_eq(row_of(payload, "mlx", "Qwen-A").disk_gb, 2.2)
			helpers.assert_eq(row_of(payload, "mlx", "Qwen-B").installed, false)
			helpers.assert_eq(payload.active, "Qwen-A")
		end)
	end)

	helpers.it("selects a model of the active backend through the tray switch", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "select_model", backend = "ollama", name = "Qwen-A" }, p, collected))
			helpers.assert_eq(calls.switch[1], "Qwen-A")
			helpers.assert_eq(#calls.select, 0, "no backend switch for the active backend")
		end)
	end)

	helpers.it("switches the backend with the chosen model in its slot", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "select_model", backend = "mlx", name = "Qwen-A" }, p, collected))
			helpers.assert_eq(calls.select[1], "mlx:Qwen-A", "the Backend selection resolves the page's model")
			helpers.assert_eq(#calls.switch, 0)
		end)
	end)

	helpers.it("refuses activating a model that is not installed or whose backend cannot run", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "select_model", backend = "ollama", name = "Qwen-B" }, p, collected), false)
		end)
		with_page({ apple = false }, function(Page, ctx, calls, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "select_model", backend = "mlx", name = "Qwen-A" }, p, collected), false)
			helpers.assert_eq(#calls.select + #calls.switch, 0)
		end)
		with_page({ paused = true }, function(Page, ctx, calls, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "select_model", backend = "ollama", name = "Qwen-A" }, p, collected), false)
		end)
	end)

	helpers.it("downloads a missing model without activating it", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "download_model", backend = "ollama", name = "Qwen-B" }, p, collected))
			helpers.assert_eq(calls.pulls[1], "ollama:qwen-b")
			helpers.assert_eq(row_of(Page.build_payload(ctx, p, collected), "ollama", "Qwen-B").pending, "download")
			calls.done()
			helpers.assert_nil(row_of(Page.build_payload(ctx, p, collected), "ollama", "Qwen-B").pending)
			helpers.assert_eq(#calls.switch, 0, "a download never activates the model")
		end)
	end)

	helpers.it("shows the download window's percentage on the downloading row", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_eq(calls.percent_listener, Page.on_download_percent, "the page observes the window")
			helpers.assert_eq(Page.on_download_percent("ollama_model", 10), false, "no page download, no row")
			helpers.assert_true(Page.handle_action(ctx, { action = "download_model", backend = "ollama", name = "Qwen-B" }, p, collected))
			helpers.assert_eq(Page.on_download_percent("mlx_model", 10), false, "another backend's download")
			helpers.assert_true(Page.on_download_percent("ollama_model", 42))
			helpers.assert_eq(calls.progress[1].name, "Qwen-B")
			helpers.assert_eq(calls.progress[1].percent, 42)
			helpers.assert_eq(row_of(Page.build_payload(ctx, p, collected), "ollama", "Qwen-B").progress, 42,
				"a refreshed payload keeps the percentage")
			calls.done()
			helpers.assert_nil(row_of(Page.build_payload(ctx, p, collected), "ollama", "Qwen-B").progress)
		end)
	end)

	helpers.it("validates, persists and downloads a model added by identifier", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "add_model", backend = "ollama", name = "Bad Name" }, p, collected), false)
			helpers.assert_eq(calls.saves, 0, "an invalid identifier is never persisted")
			helpers.assert_true(Page.handle_action(ctx, { action = "add_model", backend = "mlx", name = "mlx-community/X-4bit" }, p, collected))
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(ctx.state.llm_user_models[1].name, "mlx-community/X-4bit")
			helpers.assert_eq(calls.pulls[1], "mlx-repo:mlx-community/X-4bit")
			local custom = row_of(Page.build_payload(ctx, p, collected), "mlx", "mlx-community/X-4bit")
			helpers.assert_eq(custom.custom, true)
		end)
		with_page({ save_fails = true }, function(Page, ctx, calls, collected, p)
			helpers.assert_eq(Page.handle_action(ctx, { action = "add_model", backend = "ollama", name = "qwen3:4b" }, p, collected), false)
			helpers.assert_eq(#ctx.state.llm_user_models, 0, "a refused save rolls the list back")
			helpers.assert_eq(#calls.pulls, 0)
		end)
	end)

	helpers.it("lists one API row per listed model and greys an entry without its key", function()
		local entries = {
			{ id = "e1", name = "OpenAI/gpt-4o-mini", provider = "openai", model = "gpt-4o-mini", active = true, key_missing = false },
			{ id = "e2", name = "Groq/llama", provider = "groq", model = "llama", active = false, key_missing = true },
		}
		with_page({ entries = entries, listed = { e1 = { "gpt-4o", "gpt-4o-mini" } } }, function(Page, ctx, _, collected, p)
			local payload = Page.build_payload(ctx, p, collected)
			helpers.assert_not_nil(row_of(payload, "api", "OpenAI/gpt-4o"))
			helpers.assert_not_nil(row_of(payload, "api", "OpenAI/gpt-4o-mini"))
			local keyless = row_of(payload, "api", "Groq/llama")
			helpers.assert_eq(keyless.available, false)
			helpers.assert_eq(keyless.hint_key, "model_browser.hint_api_no_key")
		end)
	end)

	helpers.it("falls back to the provider's known models and a typed-id row with the listing's reason", function()
		local entries = {
			{ id = "e1", name = "OpenAI/gpt-4o", provider = "openai", model = "gpt-4o", active = true, key_missing = false },
		}
		local cases = {
			{ listing = { e1 = { state = "failed", reason = "refused" } }, hint = "model_browser.hint_api_listing_refused" },
			{ listing = { e1 = { state = "failed", reason = "unavailable" } }, hint = "model_browser.hint_api_listing_unavailable" },
			{ listing = { e1 = { state = "pending" } }, hint = "model_browser.hint_api_listing_pending" },
			{ listing = {}, hint = "model_browser.hint_api_listing_unavailable" },
		}
		for _, case in ipairs(cases) do
			with_page({ entries = entries, listing = case.listing, typed_model = "gpt-5" }, function(Page, ctx, calls, collected, p)
				local payload = Page.build_payload(ctx, p, collected)
				helpers.assert_not_nil(row_of(payload, "api", "OpenAI/gpt-4o"), "the configured model")
				helpers.assert_not_nil(row_of(payload, "api", "OpenAI/gpt-4o-mini"), "the provider's default model")
				helpers.assert_not_nil(row_of(payload, "api", "OpenAI/o-extra"), "the catalogue's model extras")
				local typed = row_of(payload, "api", "OpenAI")
				helpers.assert_not_nil(typed, "the typed-id row")
				helpers.assert_eq(typed.hint_key, case.hint)
				helpers.assert_eq(typed.available, false, "the typed-id row is no model to activate")
				helpers.assert_eq(Page.handle_action(ctx, { action = "select_model", backend = "api", name = "OpenAI" }, p, collected), false)
				helpers.assert_true(Page.handle_action(ctx, { action = "row_action", backend = "api", name = "OpenAI", id = "other_model" }, p, collected))
				helpers.assert_eq(calls.api[1], "model:e1:gpt-5", "the typed id becomes the entry's model")
			end)
		end
		with_page({ entries = entries, listed = { e1 = { "gpt-4.1" } } }, function(Page, ctx, _, collected, p)
			local payload = Page.build_payload(ctx, p, collected)
			helpers.assert_nil(row_of(payload, "api", "OpenAI"), "a listed provider needs no typed-id row")
			helpers.assert_nil(row_of(payload, "api", "OpenAI/o-extra"), "a listing replaces the known models")
			helpers.assert_not_nil(row_of(payload, "api", "OpenAI/gpt-4o"), "the configured model stays visible")
		end)
		-- A second entry whose own model is the first entry's known default keeps that row.
		local two = { entries[1], { id = "e2", name = "OpenAI/gpt-4o-mini", provider = "openai", model = "gpt-4o-mini",
			active = false, key_missing = false } }
		with_page({ entries = two, listing = {} }, function(Page, ctx, _, collected, p)
			local row = row_of(Page.build_payload(ctx, p, collected), "api", "OpenAI/gpt-4o-mini")
			helpers.assert_eq(row.entry_id, "e2", "an entry's own model wins over another entry's known one")
		end)
	end)

	helpers.it("lists a discovered local server as an API provider, one row per model", function()
		local views = {
			{ id = "omlx", display_name = "oMLX", status = "up", models = { "qwen3-4b", "gemma-3" } },
			{ id = "lmstudio", display_name = "LM Studio", status = "needs_key", reason = "needs_key" },
			{ id = "jan", display_name = "Jan", reason = "not_running" },
		}
		with_page({ local_views = views }, function(Page, ctx, _, collected, p)
			local payload = Page.build_payload(ctx, p, collected)
			helpers.assert_not_nil(row_of(payload, "api", "oMLX/qwen3-4b"))
			helpers.assert_not_nil(row_of(payload, "api", "oMLX/gemma-3"))
			local keyless = row_of(payload, "api", "LM Studio")
			helpers.assert_eq(keyless.available, false)
			helpers.assert_eq(keyless.hint_key, "model_browser.hint_api_no_key")
			helpers.assert_nil(row_of(payload, "api", "Jan"), "a server that does not run is not offered")
		end)
	end)

	helpers.it("switches to the API backend before an API selection or a provider add", function()
		local entries = { { id = "e1", name = "OpenAI/gpt-4o-mini", provider = "openai", model = "gpt-4o-mini", active = true } }
		with_page({ entries = entries, listed = { e1 = { "gpt-4o", "gpt-4o-mini" } } }, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "select_model", backend = "api", name = "OpenAI/gpt-4o" }, p, collected))
			helpers.assert_eq(calls.select[1], "api")
			helpers.assert_eq(calls.api[1], "model:e1:gpt-4o", "a listed model other than the configured one changes the entry")
		end)
		with_page({ entries = entries }, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "select_model", backend = "api", name = "OpenAI/gpt-4o-mini" }, p, collected))
			helpers.assert_eq(calls.api[1], "select:e1", "the configured model runs the entry selection")
		end)
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "add_provider", backend = "api", provider = "openai" }, p, collected))
			helpers.assert_eq(calls.api[1], "add:openai:api", "the provider is added once the API backend is selected")
		end)
	end)

	helpers.it("greys every backend and refuses every action while config.toml refuses writes", function()
		with_page({ read_only = "menu.read_only.newer_schema" }, function(Page, ctx, calls, collected, p)
			local payload = Page.build_payload(ctx, p, collected)
			for _, b in ipairs(payload.backends) do
				helpers.assert_eq(b.available, false, b.id)
				helpers.assert_eq(b.reason_key, "menu.read_only.newer_schema")
			end
			helpers.assert_eq(Page.handle_action(ctx, { action = "select_model", backend = "ollama", name = "Qwen-A" }, p, collected), false)
			helpers.assert_eq(Page.handle_action(ctx, { action = "disable_model" }, p, collected), false)
			helpers.assert_eq(#calls.switch, 0)
			helpers.assert_nil(calls.disabled)
		end)
	end)

	helpers.it("runs each backend's own no-model transaction", function()
		with_page({}, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "disable_model" }, p, collected))
			helpers.assert_true(calls.disabled, "a local backend runs the switcher's disable")
		end)
		with_page({ backend = "api" }, function(Page, ctx, calls, collected, p)
			helpers.assert_true(Page.handle_action(ctx, { action = "disable_model" }, p, collected))
			helpers.assert_eq(calls.api[1], "clear", "the API backend clears its active entry")
			helpers.assert_nil(calls.disabled)
		end)
	end)

	-- model-selector-single-emoji: the page writes the emoji before the brand,
	-- so a brand carrying it too drew « 🦙 Ollama 🦙 » on every group header.
	helpers.it("sends each backend's bare brand beside its emoji", function()
		with_page({}, function(Page, ctx, _, collected, p)
			local Labels = require("ui.menu.menu_llm.backend_labels")
			local payload = Page.build_payload(ctx, p, collected)
			for _, id in ipairs({ "ollama", "mlx", "api" }) do
				local b = backend_of(payload, id)
				helpers.assert_eq(b.emoji, Labels.emoji(id))
				helpers.assert_eq(b.brand, Labels.name(id))
				helpers.assert_nil(b.brand:find(b.emoji, 1, true), id .. " brand carries no emoji")
			end
		end)
	end)

	helpers.it("labels the tray button emoji first for each backend form", function()
		with_page({}, function(Page)
			local Labels = require("ui.menu.menu_llm.backend_labels")
			helpers.assert_eq(Page.caption({ llm_backend = "ollama", llm_model = "qwen3:4b" }, "qwen3:4b"),
				Labels.emoji("ollama") .. " qwen3:4b")
			helpers.assert_eq(Page.caption({ llm_backend = "mlx", llm_model = "x" }, "Qwen-A"), Labels.emoji("mlx") .. " Qwen-A")
			helpers.assert_eq(Page.caption({ llm_backend = "api", llm_model = "gpt" }, nil, "OpenAI/gpt-4o-mini"),
				Labels.emoji("api") .. " OpenAI/gpt-4o-mini")
		end)
	end)
end)
