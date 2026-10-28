--- ui/menu/menu_llm/model_selector_page.lua

--- ==============================================================================
--- MODULE: Model Selector Page Owner
--- DESCRIPTION:
--- The tray's one AI model button and the page it opens. The button reads the
--- backend's emoji and the model it runs; the page (ui/model_browser) is where
--- the user picks the backend and the model in one place, downloads, deletes,
--- adds and removes models, and adds and configures API providers.
---
--- FEATURES & RATIONALE:
--- 1. The menu builds no list: on 2026-10-27 the maintainer moved the backend
---    chooser, the model list, the API options and the custom-model option to
---    this page (the model submenu cost ~354 ms per rebuild). The button costs
---    one caption; the payload is built only while the page is open.
--- 2. Same code paths as the tray: the page runs the exact actions the Backend
---    and API panels build (collected, never copied), the model switcher, the
---    models manager's pulls and deletes, custom_models.lua and the settings
---    owner's MLX port transaction.
--- 3. Only what works now is selectable: a backend whose runtime is missing,
---    failed or unsupported, and an API entry without its key, are sent
---    unavailable with their reason, read from the existing runtime owners.
--- 4. Each local group carries "Install <backend>" (install_state): greyed
---    once the runtime runs or where it cannot (MLX on Intel); its click runs
---    the tray's owned-runtime install (runtime_install_offer), whose
---    progress the download window reports into the group header, and the
---    refresh that settles it unlocks the group's rows.
--- ==============================================================================

local M = {}

local i18n           = require("infra.i18n")
local Logger         = require("infra.logger")
local DeferredWork   = require("infra.deferred_work")
local dialog         = require("infra.dialog_util")
local BackendLabels  = require("ui.menu.menu_llm.backend_labels")
local CustomModels   = require("ui.menu.menu_llm.custom_models")
local ModelCatalogue = require("llm.model_catalogue")
local ModelIdentifier = require("llm.model_identifier")
local ApiModelListing = require("llm.api_model_listing")
local TextUtils      = require("text_utils")

local LOG = "model_selector_page"

-- The local backends the page lists on macOS, then the remote API.
local LOCAL_BACKENDS = { "ollama", "mlx" }

-- The context of the last menu build; the page acts through it.
local _ctx = nil

-- Downloads the page started, by "<backend>\0<name>", until they settle.
local _pending = {}

-- Runtime installs the page started, by backend, until they settle:
-- { percent = integer|nil }.
local _installing = {}





-- =======================================
-- =======================================
-- ======= 1/ Backend Availability =======
-- =======================================
-- =======================================

--- Whether a local backend can run a model now, read from its runtime owner.
--- @param backend string "ollama" or "mlx".
--- @param probes table { is_apple_silicon, mlx_deps, ollama_deps } (injected for tests).
--- @return boolean available
--- @return string|nil reason_key Locale key of why it cannot.
function M.backend_availability(backend, probes)
	if backend == "mlx" then
		if probes.is_apple_silicon() ~= true then return false, "model_browser.reason_mlx_intel" end
		local deps = probes.mlx_deps()
		if deps.runtime_installed() ~= true or deps.has_failed() == true or deps.is_runtime_broken() == true then
			return false, "model_browser.reason_mlx_missing"
		end
		return true, nil
	end
	if backend == "ollama" then
		local deps = probes.ollama_deps()
		if deps.runtime_available() ~= true or deps.has_failed() == true then
			return false, "model_browser.reason_ollama_missing"
		end
		return true, nil
	end
	error("model_selector_page.backend_availability: unknown local backend " .. tostring(backend))
end

--- Where a local backend's "Install <backend>" button stands: unsupported on
--- this Mac (MLX on Intel) or while config.toml refuses writes, running while
--- its install runs, installed once its runtime can run, else available.
--- @param backend string "ollama" or "mlx".
--- @param available boolean What backend_availability answered.
--- @param probes table The runtime probes.
--- @param blocked string|nil The config.toml refusal reason.
--- @return table install { state, reason_key?, percent? }
function M.install_state(backend, available, probes, blocked)
	if blocked ~= nil then return { state = "unsupported", reason_key = blocked } end
	if backend == "mlx" and probes.is_apple_silicon() ~= true then
		return { state = "unsupported", reason_key = "model_browser.reason_mlx_intel" }
	end
	local held = _installing[backend]
	local deps = backend == "mlx" and probes.mlx_deps() or probes.ollama_deps()
	if held ~= nil or deps.is_task_running() == true then
		return { state = "running", percent = held and held.percent or nil }
	end
	return { state = available and "installed" or "available" }
end

local DEFAULT_PROBES = {
	is_apple_silicon = function() return require("ui.menu.menu_llm.backend_panel").is_apple_silicon() end,
	mlx_deps = function() return require("modules.llm.mlx_deps_checker") end,
	ollama_deps = function() return require("modules.llm.ollama_deps_checker") end,
	-- The owned-runtime installs the tray's own entries run: the install
	-- button press is the user's consent, and each settles with on_complete.
	install_runtime = function(backend, on_complete)
		local Offer = require("ui.menu.menu_llm.runtime_install_offer")
		if backend == "ollama" then return Offer.install_ollama(on_complete) end
		return Offer.select_mlx(on_complete)
	end,
}





-- =================================
-- =================================
-- ======= 2/ Button Caption =======
-- =================================
-- =================================

--- The tray button: "🦙 qwen3:4b", "🚀 <mlx model>", "🌐 OpenAI/gpt-4o-mini".
--- @param state table Preference state (llm_backend, llm_model).
--- @param display_model string|nil Display name of the local model.
--- @param api_entry_name string|nil The active API entry's "<provider>/<model>".
--- @return string caption
function M.caption(state, display_model, api_entry_name)
	local backend = state.llm_backend
	local text
	if backend == "api" then
		text = api_entry_name
	elseif type(state.llm_model) == "string" and state.llm_model ~= "" then
		text = display_model or state.llm_model
	end
	if type(text) ~= "string" or text == "" then text = i18n.get("menu.llm.no_model_none") end
	return BackendLabels.selector_caption(backend, text)
end





-- ==========================================
-- ==========================================
-- ======= 3/ Collected Panel Actions =======
-- ==========================================
-- ==========================================

--- Runs the Backend and API panel builders in collection mode, so the page
--- holds the very closures their rows would hold, built against live state.
--- @param ctx table The bound context.
--- @return table collected { select, local_rows, entries, api_select, add, providers, test_active, remove_active }
local function collect(ctx)
	local BackendPanel = require("ui.menu.menu_llm.backend_panel")
	local ApiPanel = require("ui.menu.menu_llm.api_panel")
	local LocalServerPanel = require("ui.menu.menu_llm.local_server_panel")
	local backend_collect, api_collect = {}, {}
	local paused = ctx.is_paused() ~= false
	local function panel_ctx(extra)
		local out = {
			state = ctx.state, keymap = ctx.keymap, paused = paused, is_paused = ctx.is_paused,
			models_mgr = ctx.models_mgr, get_display_model_name = ctx.get_display_model_name,
			switch_model = ctx.switch_model, disable_model = ctx.disable_model, save_prefs = ctx.save_prefs,
			update_menu = ctx.update_menu, WarmupCtrl = ctx.WarmupCtrl,
			reset_llm_health_status = ctx.reset_llm_health_status,
		}
		for k, v in pairs(extra) do out[k] = v end
		return out
	end
	BackendPanel.build(panel_ctx({
		collect = backend_collect,
		local_server_rows = function(activate_api)
			backend_collect.local_ctx = {
				state = ctx.state, paused = paused, keymap = ctx.keymap, update_menu = ctx.update_menu,
				is_paused = ctx.native_is_paused, WarmupCtrl = ctx.WarmupCtrl, activate_api = activate_api,
			}
			return LocalServerPanel.rows(backend_collect.local_ctx)
		end,
	}))
	ApiPanel.build(panel_ctx({ collect = api_collect }))
	return {
		select = backend_collect.select or {}, local_ctx = backend_collect.local_ctx,
		entries = api_collect.entries or {}, api_select = api_collect.select or {}, add = api_collect.add or {},
		providers = api_collect.providers or {}, test_active = api_collect.test_active,
		remove_active = api_collect.remove_active,
	}
end





-- ===============================
-- ===============================
-- ======= 4/ Page Payload =======
-- ===============================
-- ===============================

local function pending_key(backend, name) return backend .. "\0" .. name end

--- The group tools of one local backend after its install button: its settings.
local function local_actions(ctx, backend)
	local actions = {}
	if backend == "mlx" then
		local token_caption = ctx.hf_token_set() and i18n.get("menu.llm.hf_token_set") or i18n.get("menu.llm.hf_token_unset")
		actions[#actions + 1] = { id = "hf_token", text = string.format(i18n.get("menu.llm.hf_token_label"), token_caption) }
		local ok_api, ApiMlx = pcall(require, "modules.llm.api_mlx")
		if ok_api and type(ApiMlx.get_port) == "function" then
			actions[#actions + 1] = { id = "mlx_port",
				text = string.format(i18n.get("menu.llm.server_port_label"), "MLX", tostring(ApiMlx.get_port())) }
			if ApiMlx.get_port() ~= ApiMlx.get_default_port() then
				-- The menu label's leading tree indent has no place on a button.
				actions[#actions + 1] = { id = "mlx_port_reset", text = TextUtils.trim(string.format(
					i18n.get("menu.llm.reset_label"), tostring(ApiMlx.get_default_port()))) }
			end
		end
	end
	return actions
end

--- The provider fields api_model_listing.plan reads for one entry.
local function entry_view(api_remote, e)
	local provider = type(api_remote.PROVIDERS) == "table" and api_remote.PROVIDERS[e.provider] or nil
	local extras = {}
	for id in pairs(type(provider) == "table" and type(provider.model_extras) == "table" and provider.model_extras or {}) do
		extras[#extras + 1] = id
	end
	return { model = e.model, default_model = type(provider) == "table" and provider.default_model or "", extras = extras,
		format = type(provider) == "table" and provider.format or nil }
end

--- The rows of the remote API group: one per model each entry's provider
--- lists, or its known models and a typed-id row while that listing is
--- pending, refused or unavailable (llm.api_model_listing), then the local
--- servers. An entry without its key keeps its configured model, greyed.
local function api_rows(ctx, collected)
	local rows, named, later = {}, {}, {}
	-- Two entries of one provider and host can share a model name: each
	-- entry's own model wins, then the first entry keeps a shared known model
	-- or typed-id row (find_row finds one row per name).
	local function push(row)
		if named[row.name] then return end
		named[row.name] = true
		rows[#rows + 1] = row
	end
	local api_remote = require("modules.llm").api_remote
	for _, e in ipairs(collected.entries) do
		local plan = e.key_missing and { models = { { model = e.model } } }
			or ApiModelListing.plan(entry_view(api_remote, e), api_remote.listing_state(e.id))
		local prefix, suffix = ApiModelListing.name_parts(e.name, e.model)
		for _, item in ipairs(plan.models) do
			local model = item.model
			local actions = { { id = "other_model", text = i18n.get("model_browser.api_other_model") } }
			if e.active and model == e.model then
				actions[#actions + 1] = { id = "test", text = i18n.get("menu.llm.api_test_entry") }
				actions[#actions + 1] = { id = "remove", text = i18n.get("menu.llm.api_remove_entry") }
			end
			local row = {
				name = prefix .. "/" .. model .. suffix, runtime_name = model, provider = prefix, installed = true,
				entry_id = e.id, model = model, available = not e.key_missing, actions = actions,
				hint_key = e.key_missing and "model_browser.hint_api_no_key" or nil,
			}
			if model == e.model then push(row) else later[#later + 1] = row end
		end
		if plan.typed then
			-- Not a model: the place to type one the provider serves, with
			-- the reason its list is missing. Named by the provider (and the
			-- entry's host), it cannot collide with a "<provider>/<model>" row.
			later[#later + 1] = {
				name = prefix .. suffix, provider = prefix, installed = true, entry_id = e.id,
				model = e.model, typed = true, available = false, hint_key = plan.typed.hint_key,
				actions = { { id = "other_model", text = i18n.get("model_browser.api_other_model") } },
			}
		end
	end
	for _, row in ipairs(later) do push(row) end
	-- Discovered local servers (oMLX, LM Studio…) are API providers: one row
	-- per model a server that answers lists, the server alone when it wants
	-- its key (api_remote.local_server_views, the AI menu's own source).
	for _, view in ipairs(api_remote.local_server_views()) do
		if view.status == "up" then
			for _, model in ipairs(view.models or {}) do
				rows[#rows + 1] = { name = view.display_name .. "/" .. model, runtime_name = model,
					provider = view.display_name, installed = true, local_server = view.id, model = model }
			end
		elseif view.status == "needs_key" then
			rows[#rows + 1] = { name = view.display_name, provider = view.display_name, installed = true,
				local_server = view.id, available = false, hint_key = "model_browser.hint_api_no_key",
				actions = { { id = "set_key", text = i18n.get("menu.llm.local_servers.api_key") } } }
		end
	end
	return rows
end

--- Builds the page payload: Ollama and MLX on this Mac, then the API.
--- @param ctx table The bound context.
--- @param probes table|nil Runtime probes; the live owners by default.
--- @param collected table|nil Collected panel actions (built when nil).
--- @return table payload
function M.build_payload(ctx, probes, collected)
	probes = probes or DEFAULT_PROBES
	collected = collected or collect(ctx)
	local state, models_mgr = ctx.state, ctx.models_mgr
	local backends = {}
	for _, backend in ipairs(LOCAL_BACKENDS) do
		local available, reason = M.backend_availability(backend, probes)
		local extra = {}
		for _, entry in ipairs(ctx.custom.list_for_backend(backend)) do
			local ok, installed = pcall(models_mgr.backend_model_installed, backend, entry.name)
			extra[#extra + 1] = { name = entry.name, runtime_name = entry.name, custom = true,
				installed = ok and installed == true, deletable = false }
		end
		backends[#backends + 1] = {
			id = backend, kind = "local", emoji = BackendLabels.emoji(backend),
			brand = BackendLabels.name(backend),
			available = available, reason_key = reason,
			is_installed = function(display_name)
				return models_mgr.backend_model_installed(backend, display_name) == true
			end,
			default_model = backend == "mlx" and ctx.DEFAULT_STATE.llm_model_mlx or ctx.DEFAULT_STATE.llm_model_ollama,
			extra_rows = extra,
			add_model = available or nil,
			actions = local_actions(ctx, backend),
		}
	end
	backends[#backends + 1] = {
		id = "api", kind = "remote", emoji = BackendLabels.emoji("api"),
		brand = BackendLabels.name("api"), available = true,
		extra_rows = api_rows(ctx, collected),
		providers = collected.providers,
		actions = { { id = "rescan", text = i18n.get("menu.llm.local_servers.rescan") } },
	}
	local active_model = state.llm_model
	if state.llm_backend == "api" then
		for _, row in ipairs(backends[#backends].extra_rows) do
			if row.entry_id ~= nil then
				for _, e in ipairs(collected.entries) do
					if e.active and e.id == row.entry_id and e.model == row.model then active_model = row.name end
				end
			end
		end
	end
	-- A config.toml that refuses writes greys every backend with that cause.
	local blocked = ctx.config_reason()
	if blocked ~= nil then
		for _, b in ipairs(backends) do b.available, b.reason_key = false, blocked end
	end
	local install = {}
	for index, backend in ipairs(LOCAL_BACKENDS) do
		install[backend] = M.install_state(backend, backends[index].available == true and blocked == nil, probes, blocked)
	end
	local payload = ModelCatalogue.build_selector(models_mgr.get_all_presets(), {
		active_backend = state.llm_backend,
		active_model = active_model,
		backends = backends,
		capabilities = { disable = true },
	})
	-- The page draws the group tools and provider list; it never sees closures.
	for index, backend in ipairs(payload.backends) do
		backend.actions = backends[index].actions
		backend.install = install[backend.id]
		backend.add_model = backends[index].add_model
		backend.providers = backends[index].providers
	end
	for _, row in ipairs(payload.models) do
		local held = _pending[pending_key(row.backend, row.name)]
		if held then
			row.pending = "download"
			row.progress = held.percent
		end
	end
	return payload
end

--- Finds one row of the current payload by backend and name.
local function find_row(payload, backend, name)
	for _, row in ipairs(payload.models) do
		if row.name == name and (backend == nil or row.backend == backend) then return row end
	end
	return nil
end

local function backend_entry(payload, id)
	for _, b in ipairs(payload.backends) do if b.id == id then return b end end
	return nil
end





-- ===============================
-- ===============================
-- ======= 5/ Page Actions =======
-- ===============================
-- ===============================

--- Starts one download and keeps its row pending until it settles.
local function start_download(ctx, backend, name, custom)
	local key = pending_key(backend, name)
	if _pending[key] then return false end
	local function settled()
		_pending[key] = nil
		M.refresh()
	end
	_pending[key] = { backend = backend, name = name }
	Logger.info(LOG, "Model download requested via the selector page: %s/%s.", backend, name)
	local ok, accepted
	if backend == "mlx" then
		if custom then
			ok, accepted = Logger.callback(LOG, "MLX repository download", ctx.models_mgr.pull_mlx_repo, name, settled, settled)
		else
			ok, accepted = Logger.callback(LOG, "MLX model download", ctx.models_mgr.pull_mlx_model, name, settled, settled)
		end
	else
		local tag = custom and name or ctx.models_mgr.backend_actual_model_name("ollama", name)
		ok, accepted = Logger.callback(LOG, "Ollama model download", ctx.models_mgr.pull_ollama_model, tag, settled, settled)
	end
	if not ok or accepted ~= true then
		_pending[key] = nil
		Logger.error(LOG, "Model download of %s/%s was refused.", backend, name)
		return false
	end
	return true
end

-- The download window kind of each local backend's model downloads.
local DOWNLOAD_KINDS = { ollama_model = "ollama", mlx_model = "mlx" }
local INSTALL_KINDS = { ollama_install = "ollama", mlx_install = "mlx" }

--- Shows a download window percentage on the page's row of that download:
--- the window holds one download at a time, so the one pending row of its
--- backend is the one it reports.
--- @param kind string Download window kind.
--- @param percent integer Whole percentage.
function M.on_download_percent(kind, percent)
	local installing = INSTALL_KINDS[kind]
	if installing and type(percent) == "number" then
		local held = _installing[installing]
		if not held then return false end
		held.percent = percent
		local browser = package.loaded["ui.model_browser"]
		if type(browser) ~= "table" or type(browser.inject_install_progress) ~= "function" then return false end
		return browser.inject_install_progress({ backend = installing, percent = percent }) == true
	end
	local backend = DOWNLOAD_KINDS[kind]
	if not backend or type(percent) ~= "number" then return false end
	local held, count = nil, 0
	for _, entry in pairs(_pending) do
		if entry.backend == backend then held, count = entry, count + 1 end
	end
	if count ~= 1 then return false end
	held.percent = percent
	local browser = package.loaded["ui.model_browser"]
	if type(browser) ~= "table" or type(browser.inject_progress) ~= "function" then return false end
	return browser.inject_progress({ backend = backend, name = held.name, percent = percent }) == true
end

--- Makes a local model active, switching the backend first when needed. The
--- backend's own selection resolves its model slot through the switcher.
local function select_local(ctx, collected, row)
	local state = ctx.state
	local name = row.custom and row.runtime_name or row.name
	if row.backend == state.llm_backend then
		Logger.info(LOG, "Model selected via the selector page: %s/%s.", row.backend, name)
		return ctx.switch_model(name) ~= false
	end
	local select = collected.select[row.backend]
	if type(select) ~= "function" then
		Logger.warn(LOG, "Backend %s cannot be selected now.", row.backend)
		return false
	end
	local slot = "llm_model_" .. row.backend
	local previous = state[slot]
	state[slot] = name
	Logger.info(LOG, "Backend and model selected via the selector page: %s/%s.", row.backend, name)
	local ok, accepted = Logger.callback(LOG, "Backend selection", select)
	if not ok or accepted == false then
		if state[slot] == name then state[slot] = previous end
		return false
	end
	return true
end

--- Makes an API row active: its local server, or its entry with that model.
local function select_api(ctx, collected, row)
	local function run()
		if row.local_server then
			return require("ui.menu.menu_llm.local_server_panel").select_model(
				collected.local_ctx, row.local_server, row.model) == true
		end
		for _, e in ipairs(collected.entries) do
			if e.id == row.entry_id then
				if e.model == row.model then
					local select = collected.api_select[e.id]
					return type(select) == "function" and select() == true
				end
				return require("ui.menu.menu_llm.api_panel").set_entry_model(ctx, e.id, row.model) == true
			end
		end
		return false
	end
	-- A local server's selection switches the backend itself.
	if ctx.state.llm_backend == "api" or row.local_server then return run() end
	local activate = collected.select.api
	if type(activate) ~= "function" then return false end
	Logger.info(LOG, "API backend selected via the selector page for %s.", row.name)
	local ok, accepted = Logger.callback(LOG, "API backend selection", activate, run)
	return ok and accepted ~= false
end

--- Asks for a model id the provider serves but does not list.
local function prompt_api_model(ctx, row)
	local ok_label = i18n.get("button.ok")
	local ok, a, b = pcall(dialog.text_prompt, row.provider, i18n.get("menu.llm.api_prompt_model"),
		row.model or "", ok_label, i18n.get("button.cancel"))
	if not ok then return false end
	local button, text = a, b
	if a ~= ok_label and a ~= i18n.get("button.cancel") then button, text = b, a end
	if button ~= ok_label then return false end
	return require("ui.menu.menu_llm.api_panel").set_entry_model(ctx, row.entry_id, text) == true
end

--- Runs a local backend's owned-runtime install for its "Install" button;
--- the page shows it running, then the outcome on the refresh that settles it.
local function install_runtime(ctx, backend, probes)
	if backend ~= "ollama" and backend ~= "mlx" then return false end
	local available = M.backend_availability(backend, probes)
	if M.install_state(backend, available, probes, ctx.config_reason()).state ~= "available" then
		Logger.warn(LOG, "Refused installing the %s runtime from the page: it is not offered now.", backend)
		return false
	end
	local held = {}
	_installing[backend] = held
	Logger.start(LOG, "Installing the %s runtime from the model selector page…", backend)
	local function settle(ok)
		if _installing[backend] ~= held then return end
		_installing[backend] = nil
		if ok == true then
			Logger.success(LOG, "The %s runtime installed from the model selector page.", backend)
		else
			Logger.error(LOG, "The %s runtime install from the model selector page failed.", backend)
		end
		M.refresh()
	end
	local accepted = probes.install_runtime(backend, settle) == true
	if not accepted and _installing[backend] == held then
		_installing[backend] = nil
		Logger.error(LOG, "The %s runtime install from the model selector page was not started.", backend)
		M.refresh()
	end
	return accepted
end

--- Runs one group tool through the owner that answered it in the tray.
local function group_action(ctx, collected, backend, id, probes)
	if id == "install" then return install_runtime(ctx, backend, probes or DEFAULT_PROBES) end
	if id == "hf_token" then
		local save_prefs = ctx.save_prefs
		return ctx.models_mgr.prompt_hf_login(function()
			if save_prefs() ~= true then return false end
			ctx.update_menu()
			M.refresh()
		end) ~= false
	end
	if id == "mlx_port" then return ctx.settings_mgr.set_mlx_port(ctx.restart_mlx_for_current_port) ~= false end
	if id == "mlx_port_reset" then return ctx.settings_mgr.reset_mlx_port(ctx.restart_mlx_for_current_port) ~= false end
	if id == "rescan" then
		return require("ui.menu.menu_llm.local_server_panel").rescan(collected.local_ctx, function() M.refresh() end) == true
	end
	Logger.warn(LOG, "Unknown model selector group action '%s'.", tostring(id))
	return false
end

--- Runs one page action through the tray's own code path.
--- @param ctx table The bound context.
--- @param body table The page message (action, backend, name, id, provider).
--- @param probes table|nil Runtime probes (tests).
--- @param collected table|nil Collected panel actions (tests).
--- @return boolean accepted True when the action was dispatched.
function M.handle_action(ctx, body, probes, collected)
	local action = body.action
	if ctx.is_paused() ~= false then
		Logger.warn(LOG, "Model selector action '%s' refused while paused.", tostring(action))
		return false
	end
	local blocked = ctx.config_reason()
	if blocked ~= nil then
		Logger.warn(LOG, "Model selector action '%s' refused: config.toml refuses writes (%s).", tostring(action), blocked)
		return false
	end
	if action == "disable_model" then
		-- The API backend's "no model" clears its active entry; a local one runs the switcher's.
		if ctx.state.llm_backend == "api" then
			return require("ui.menu.menu_llm.api_panel").clear_active_entry(ctx) == true
		end
		return ctx.disable_model() == true
	end
	collected = collected or collect(ctx)
	if action == "add_provider" then
		local add = collected.add[body.provider]
		if type(add) ~= "function" then
			Logger.warn(LOG, "API provider '%s' cannot be added now.", tostring(body.provider))
			return false
		end
		if ctx.state.llm_backend == "api" then return add() ~= false end
		local activate = collected.select.api
		if type(activate) ~= "function" then return false end
		local ok, accepted = Logger.callback(LOG, "API backend selection", activate, add)
		return ok and accepted ~= false
	end
	local payload = M.build_payload(ctx, probes, collected)
	local b = backend_entry(payload, body.backend)
	if action == "group_action" then
		if not b then return false end
		return group_action(ctx, collected, b.id, body.id, probes)
	end
	if action == "add_model" then
		if not b or b.kind ~= "local" or not b.available then return false end
		if not ModelIdentifier.valid(b.id, body.name) then
			Logger.warn(LOG, "Refused adding '%s': not a valid %s identifier.", tostring(body.name), b.id)
			return false
		end
		if ctx.custom.add(b.id, body.name) ~= true then return false end
		if ctx.models_mgr.backend_model_installed(b.id, body.name) then return true end
		return start_download(ctx, b.id, body.name, true)
	end
	local row = type(body.name) == "string" and find_row(payload, body.backend, body.name) or nil
	if not row then
		Logger.warn(LOG, "Refused model selector action '%s' for an unknown row '%s'.", tostring(action), tostring(body.name))
		return false
	end
	local row_backend = backend_entry(payload, row.backend)
	local ready = row_backend ~= nil and row_backend.available == true and row.available ~= false and row.pending == nil
	if action == "select_model" then
		if not ready or row.installed ~= true then
			Logger.warn(LOG, "Refused selecting '%s': it cannot run now or it is not installed.", row.name)
			return false
		end
		if row_backend.kind == "remote" then return select_api(ctx, collected, row) end
		return select_local(ctx, collected, row)
	end
	if action == "download_model" then
		if not ready or row.installed == true or row_backend.kind ~= "local" then return false end
		return start_download(ctx, row.backend, row.custom and row.runtime_name or row.name, row.custom == true)
	end
	if action == "delete_model" then
		if not ready or row.installed ~= true or row.custom or row_backend.kind ~= "local" then return false end
		local ok, choice = pcall(dialog.block_alert,
			i18n.get("menu.llm.delete_model_title"),
			string.format(i18n.get("menu.llm.delete_model_body"), row.name),
			i18n.get("button.delete"), i18n.get("button.cancel"), "warning")
		if not ok or choice ~= i18n.get("button.delete") then return false end
		local deleted
		if row.backend == "mlx" then
			deleted = ctx.models_mgr.delete_mlx_model(row.name)
		else
			deleted = ctx.models_mgr.delete_ollama_model(ctx.models_mgr.backend_actual_model_name("ollama", row.name))
		end
		M.refresh()
		return deleted == true
	end
	if action == "remove_custom_model" then
		if not row.custom then return false end
		return ctx.custom.remove(row.backend, row.runtime_name) == true
	end
	if action == "row_action" then
		if row_backend == nil or row_backend.available ~= true then return false end
		if body.id == "set_key" and row.local_server then
			return require("ui.menu.menu_llm.local_server_panel").prompt_key(collected.local_ctx, row.local_server) == true
		end
		if not row.entry_id or (row.available == false and not row.typed) then return false end
		if body.id == "other_model" then return prompt_api_model(ctx, row) end
		if row.typed then return false end
		if body.id == "test" and type(collected.test_active) == "function" then return collected.test_active() ~= false end
		if body.id == "remove" and type(collected.remove_active) == "function" then return collected.remove_active() ~= false end
		return false
	end
	Logger.warn(LOG, "Unknown model selector action '%s'.", tostring(action))
	return false
end





-- =============================
-- =============================
-- ======= 6/ Public API =======
-- =============================
-- =============================

local REQUIRED = {
	"switch_model", "disable_model", "save_prefs", "update_menu", "is_paused",
	"get_display_model_name", "hf_token_set", "restart_mlx_for_current_port", "config_reason",
}

--- Records the context of the current menu build; refreshes an open page.
--- @param ctx table { state, keymap, models_mgr, settings_mgr, WarmupCtrl, DEFAULT_STATE,
---   switch_model, disable_model, save_prefs, update_menu, is_paused, get_display_model_name,
---   reset_llm_health_status, hf_token_set, restart_mlx_for_current_port }.
function M.bind(ctx)
	for _, name in ipairs(REQUIRED) do
		if type(ctx[name]) ~= "function" then error("model_selector_page.bind requires ctx." .. name) end
	end
	for _, name in ipairs({ "state", "models_mgr", "settings_mgr", "DEFAULT_STATE" }) do
		if type(ctx[name]) ~= "table" then error("model_selector_page.bind requires ctx." .. name) end
	end
	ctx.custom = ctx.custom or CustomModels.new({
		state = ctx.state, disable_model = ctx.disable_model,
		save_prefs = ctx.save_prefs, update_menu = ctx.update_menu,
		on_changed = function() M.refresh() end,
	})
	_ctx = ctx
	require("ui.download_window").set_percent_listener(M.on_download_percent)
	-- The MLX repair offer proposes Ollama on a Mac that cannot run MLX: the
	-- Ollama selection the page runs, collected when the offer is accepted.
	require("ui.menu.menu_llm.mlx_repair_offer").set_alternative(function()
		local select = collect(ctx).select.ollama
		return type(select) == "function" and select() or false
	end)
end

--- Makes a local server's model the backend from outside the page (the
--- unreachable-backend error offers it), through the same selection.
--- @param id string Server id.
--- @param model string Model id.
--- @param on_selected function|nil Receives whether the API backend serves it.
--- @return boolean started
function M.use_local_server(id, model, on_selected)
	if not _ctx then
		Logger.error(LOG, "Local server '%s' cannot be selected: the AI menu was never built.", tostring(id))
		return false
	end
	local collected = collect(_ctx)
	return require("ui.menu.menu_llm.local_server_panel").select_model(
		collected.local_ctx, id, model, on_selected) == true
end

--- Whether an AI menu build has bound the page to this session.
--- @return boolean bound
function M.is_bound() return _ctx ~= nil end

--- The Backend and API panel actions the page runs, collected against the
--- bound context's live state (nil before the menu bound one).
--- @return table|nil collected
function M.collected()
	if not _ctx then return nil end
	return collect(_ctx)
end

--- Runs one group tool (install, hf_token, mlx_port, mlx_port_reset, rescan)
--- with the page's pause and configuration checks.
--- @param backend string Backend whose group offers the tool.
--- @param id string Tool id.
--- @return boolean accepted
function M.group_action(backend, id)
	if not _ctx or _ctx.is_paused() ~= false or _ctx.config_reason() ~= nil then return false end
	return group_action(_ctx, collect(_ctx), backend, id, DEFAULT_PROBES)
end

--- Re-sends the payload to an open page, after a runtime or model change.
--- @return boolean refreshed
function M.refresh()
	local browser = package.loaded["ui.model_browser"]
	if not _ctx or type(browser) ~= "table" or type(browser.refresh) ~= "function" then return false end
	return browser.refresh() == true
end

--- Asks the active API entry's provider for its models, then refreshes.
local function list_api_models()
	local llm = require("modules.llm")
	local api_remote = llm.api_remote
	if type(api_remote) ~= "table" or type(api_remote.list_active_models) ~= "function" then return end
	if type(api_remote.get_active_entry) ~= "function" or api_remote.get_active_entry() == nil then return end
	api_remote.list_active_models(function() M.refresh() end)
end

--- Opens the page on the next runloop tick, once the menu has closed.
--- @return boolean scheduled
function M.open()
	local ctx = _ctx
	if not ctx then
		Logger.error(LOG, "Model selector page opened before the menu bound its context.")
		return false
	end
	Logger.info(LOG, "Model selector page requested (backend=%s).", tostring(ctx.state.llm_backend))
	-- A window shown from inside the still-open menu callback can silently fail
	-- to appear, so the page opens on the next tick.
	DeferredWork.after(0, function()
		if _ctx ~= ctx or ctx.is_paused() ~= false then return false end
		local ModelBrowser = require("ui.model_browser")
		local opened = ModelBrowser.open({
			build_payload = function() return M.build_payload(ctx) end,
			on_action = function(body) return M.handle_action(ctx, body) end,
		})
		if opened ~= true then
			Logger.error(LOG, "Model selector page could not open.")
			return false
		end
		list_api_models()
		return true
	end, "model_selector_page.open")
	return true
end

return M
