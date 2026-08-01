--- ui/menu/menu_llm/models_selector.lua

--- ==============================================================================
--- MODULE: LLM Models Selector
--- DESCRIPTION:
--- Builds the model-selection submenu for the LLM tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: user-added models, curated presets, HuggingFace token
---    management, and the custom-model prompt all live here so init.lua stays
---    free of the selection-tree logic.
--- 2. No captured closures: every dependency arrives through the ctx table,
---    making the module testable without a full init.lua context.
--- ==============================================================================

local M = {}

local i18n   = require("lib.i18n")
local Logger = require("lib.logger")
local dialog = require("lib.dialog_util")

local LOG = "models_selector"

-- hs.chooser objects are garbage-collected as soon as no Lua reference remains.
-- The "browse all models" chooser was held only in a local inside the click
-- handler, so it could be collected before macOS finished presenting it — the
-- window flashed or never appeared. Retain it at module scope for the session.
local _model_browser_chooser = nil





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the model-selection menu and returns it as a flat table.
--- @param ctx table Context with fields:
---   state              table   Shared preference state.
---   models_mgr         table   Models manager instance (get_presets, get_model_info, …).
---   switch_model       function Called with a model name to activate it.
---   save_prefs         function Persists state to disk.
---   update_menu        function Redraws the tray menu.
---   DEFAULT_STATE      table   Module-level defaults (llm_model_mlx, llm_model_ollama).
--- @return table menu Populated model-selection menu.
function M.build(ctx)
	local state         = ctx.state
	local models_mgr    = ctx.models_mgr
	local switch_model  = ctx.switch_model
	local save_prefs    = ctx.save_prefs
	local update_menu   = ctx.update_menu
	local DEFAULT_STATE = ctx.DEFAULT_STATE
	-- Disable all model-switch rows while the driver is paused so a model
	-- click cannot trigger backend loading mid-pause (M-16).
	local paused        = ctx.paused or false

	Logger.debug(LOG, "Building models selection menu…")
	local menu = {}
	local installed      = models_mgr.get_installed_models()
	local installed_count = 0
	for _ in pairs(installed) do installed_count = installed_count + 1 end
	Logger.debug(LOG, string.format("Installed models detected: %d", installed_count))
	local presets        = models_mgr.get_presets()
	local active_backend = state.llm_backend


	-- =====================================================
	-- ===== 1.1) Display name resolution helper =====
	-- =====================================================

	-- Resolve a backend-native model name to its human-readable display name
	-- by scanning the presets tree. Falls back to the raw name when no match.
	local function get_display_model_name(model_name, preset_list)
		if type(model_name) ~= "string" or model_name == "" then return model_name end
		preset_list = type(preset_list) == "table" and preset_list or models_mgr.get_presets()
		if type(preset_list) ~= "table" then return model_name end
		for _, provider in ipairs(preset_list) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					local display_name = m.name or m.repo
					if type(display_name) == "string" then
						if display_name == model_name then return display_name end
						local actual_name = models_mgr.get_actual_model_name(display_name)
						if actual_name == model_name then return display_name end
					end
				end
			end
		end
		return model_name
	end

	local active_display_model = get_display_model_name(state.llm_model, presets)


	-- =====================================================
	-- ===== 1.2) User-model helpers =====
	-- =====================================================

	--- Returns the user-added models that match the given backend.
	--- @param backend string Either "ollama" or "mlx".
	--- @return table List of { name = string } entries.
	local function list_user_models_for_backend(backend)
		local out = {}
		local raw = state.llm_user_models
		if type(raw) ~= "table" then return out end
		for _, entry in ipairs(raw) do
			if type(entry) == "table" and type(entry.name) == "string"
				and entry.name ~= "" and entry.backend == backend then
				table.insert(out, { name = entry.name })
			end
		end
		return out
	end

	--- Adds a user model to the persisted list, deduplicating on (backend, name).
	--- @param backend string Either "ollama" or "mlx".
	--- @param name string Backend-native identifier.
	local function add_user_model(backend, name)
		if type(state.llm_user_models) ~= "table" then state.llm_user_models = {} end
		for _, entry in ipairs(state.llm_user_models) do
			if type(entry) == "table" and entry.backend == backend and entry.name == name then
				Logger.debug(LOG, string.format("User model already present (%s/%s) — no-op.", backend, name))
				return
			end
		end
		table.insert(state.llm_user_models, { backend = backend, name = name })
		Logger.info(LOG, string.format("User model added: %s/%s.", backend, name))
	end

	--- Removes a user model from the persisted list.
	--- @param backend string Either "ollama" or "mlx".
	--- @param name string Backend-native identifier.
	local function remove_user_model(backend, name)
		if type(state.llm_user_models) ~= "table" then return end
		for i, entry in ipairs(state.llm_user_models) do
			if type(entry) == "table" and entry.backend == backend and entry.name == name then
				table.remove(state.llm_user_models, i)
				Logger.info(LOG, string.format("User model removed: %s/%s.", backend, name))
				return
			end
		end
	end

	--- Opens a wide webview dialog so the full model URL fits without truncation.
	--- hs.dialog.textPrompt is too narrow for long HuggingFace identifiers; this
	--- webview replacement gives the input field the full window width.
	local function prompt_add_user_model()
		local hint  = (active_backend == "mlx")
			and i18n.get("menu.llm.mlx_model_hint")
			or  i18n.get("menu.llm.ollama_model_hint")
		local title = i18n.get("menu.llm.add_custom_model")

		local ok_uc, uc = pcall(hs.webview.usercontent.new, "addCustomModel")
		if not ok_uc or not uc then
			Logger.error(LOG, "Failed to create usercontent bridge for custom model dialog.")
			return
		end

		local _wv = nil

		local function close_wv()
			if _wv then
				pcall(function() _wv:delete() end)
				_wv = nil
			end
		end

		uc:setCallback(function(message)
			local body = message and message.body
			if type(body) ~= "table" then return end
			if body.action == "cancel" then
				close_wv()
			elseif body.action == "add" then
				local name = type(body.value) == "string" and body.value:gsub("^%s+", ""):gsub("%s+$", "") or ""
				close_wv()
				if name == "" then
					pcall(dialog.alert, i18n.get("menu.llm.custom_model_title"), i18n.get("menu.llm.empty_model_id"), "OK")
					return
				end
				add_user_model(active_backend, name)
				save_prefs()
				switch_model(name)
			end
		end)

		local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
		if not ok_ui or not ui_builder then
			Logger.error(LOG, "Failed to load ui_builder for custom model dialog.")
			return
		end

		-- Escape a string for HTML attribute and text content
		local function he(s)
			return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
		end

		local css = table.concat({
			"*{box-sizing:border-box;margin:0;padding:0;}",
			"body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;",
			"background:#f5f5f7;display:flex;flex-direction:column;justify-content:center;",
			"height:100vh;padding:18px 20px;gap:10px;}",
			"label{font-weight:600;color:#1a1a1a;font-size:13px;}",
			"input{width:100%;padding:7px 10px;font-size:13px;border:1px solid #c6c6c8;",
			"border-radius:6px;outline:none;background:#fff;}",
			"input:focus{border-color:#0078d4;box-shadow:0 0 0 2px rgba(0,120,212,.2);}",
			".row{display:flex;gap:8px;justify-content:flex-end;}",
			"button{padding:6px 18px;font-size:13px;border-radius:6px;border:none;cursor:pointer;}",
			".btn-cancel{background:#e5e5ea;color:#1a1a1a;}",
			".btn-cancel:hover{background:#d1d1d6;}",
			".btn-add{background:#0078d4;color:#fff;}",
			".btn-add:hover{background:#106ebe;}",
		}, "")

		local html = "<!DOCTYPE html><html><head><meta charset='utf-8'>"
			.. "<style>" .. css .. "</style></head><body>"
			.. "<label>" .. he(title) .. "</label>"
			.. "<input id='inp' type='text' placeholder='" .. he(hint) .. "' autofocus />"
			.. "<div class='row'>"
			.. "<button class='btn-cancel' id='btnCancel'>" .. he(i18n.get("button.cancel")) .. "</button>"
			.. "<button class='btn-add'    id='btnAdd'>"    .. he(i18n.get("button.add"))    .. "</button>"
			.. "</div>"
			.. "<script>"
			.. "var uc=window.webkit.messageHandlers.addCustomModel;"
			.. "function submit(){uc.postMessage({action:'add',value:document.getElementById('inp').value});}"
			.. "function cancel(){uc.postMessage({action:'cancel'});}"
			.. "document.getElementById('btnAdd').onclick=submit;"
			.. "document.getElementById('btnCancel').onclick=cancel;"
			.. "document.getElementById('inp').addEventListener('keydown',function(e){"
			.. "if(e.key==='Enter')submit();"
			.. "if(e.key==='Escape')cancel();"
			.. "});"
			.. "</script>"
			.. "</body></html>"

		local masks = hs.webview.windowMasks
		local geo = ui_builder.get_app_geometry("token_prompt")
		if not geo then return end
		_wv = ui_builder.show_webview({
			frame       = ui_builder.get_centered_frame(geo.width, geo.height),
			title       = title,
			style_masks = (masks["titled"] or 1) + (masks["closable"] or 2),
			usercontent = uc,
			html_string = html,
			inject_i18n = false,
			on_close    = function() _wv = nil end,
			on_navigation = function(action)
				if action == "didFinishNavigation" then
					-- Focus the input field after the page loads
					hs.timer.doAfter(0.05, function()
						if _wv then
							pcall(function()
								_wv:evaluateJavaScript("document.getElementById('inp').focus();")
							end)
						end
					end)
				end
				return true
			end,
		})
		if not _wv then
			Logger.error(LOG, "show_webview returned nil for custom model dialog.")
		end
	end


	-- =====================================================
	-- ===== 1.3) Header rows =====
	-- =====================================================

	-- "No model" option so the user can explicitly disable predictions
	table.insert(menu, {
		title    = i18n.get("menu.llm.no_model"),
		checked  = (not state.llm_model or state.llm_model == ""),
		disabled = paused or nil,
		fn       = function()
			Logger.info(LOG, "Switching model to None (disabled).")
			state.llm_model = ""
			save_prefs(); update_menu()
		end
	})

	local backend_default_raw = (active_backend == "mlx")
		and DEFAULT_STATE.llm_model_mlx
		or  DEFAULT_STATE.llm_model_ollama
	local backend_default = get_display_model_name(backend_default_raw, presets)
	if backend_default and backend_default ~= "" then
		table.insert(menu, {
			title    = string.format(i18n.get("menu.llm.backend_default_model"), backend_default),
			checked  = (active_display_model == backend_default),
			disabled = paused or nil,
			fn       = function()
				Logger.info(LOG, string.format("Restoring backend default model -> %s", backend_default))
				switch_model(backend_default)
			end
		})
	end

	-- HuggingFace token row — only meaningful for the MLX backend which downloads from HF
	if active_backend == "mlx" then
		local hf_token_file = (os.getenv("HOME") or "") .. "/.huggingface/token"
		local has_hf_token = false
		local fh = io.open(hf_token_file, "r")
		if fh then
			local raw = fh:read("*a"); fh:close()
			has_hf_token = type(raw) == "string" and raw:match("^%s*(.-)%s*$") ~= ""
		end
		local token_status = has_hf_token
			and i18n.get("menu.llm.hf_token_set")
			or  i18n.get("menu.llm.hf_token_unset")
		table.insert(menu, {
			title    = string.format(i18n.get("menu.llm.hf_token_label"), token_status),
			disabled = paused or nil,
			fn       = function()
				if models_mgr and type(models_mgr.prompt_hf_login) == "function" then
					models_mgr.prompt_hf_login(function()
						save_prefs(); update_menu()
					end)
				end
			end
		})
	end

	table.insert(menu, { title = "-" })


	-- =====================================================
	-- ===== 1.4) User-added models =====
	-- =====================================================

	-- User models appear as their own provider group above the curated presets
	-- so they are easy to find without polluting the JSON preset tree.
	local user_models_for_backend = list_user_models_for_backend(active_backend)
	if #user_models_for_backend > 0 then
		local user_sub = {}
		for _, entry in ipairs(user_models_for_backend) do
			local m_name = entry.name
			local prefix = (state.llm_model == m_name) and "✓ " or "  "
			local model_submenu = {}
			table.insert(model_submenu, {
				title    = i18n.get("menu.llm.select_model"),
				checked  = (state.llm_model == m_name),
				disabled = paused or nil,
				fn       = function() switch_model(m_name) end
			})
			table.insert(model_submenu, {
				title = i18n.get("menu.llm.remove_user_model"),
				fn = function()
					local ok, choice = pcall(dialog.block_alert,
						i18n.get("menu.llm.remove_model_title"),
						string.format(i18n.get("menu.llm.remove_model_body"), m_name),
						i18n.get("button.remove"), i18n.get("button.cancel"), "warning")
					if ok and choice == i18n.get("button.remove") then
						remove_user_model(active_backend, m_name)
						if state.llm_model == m_name then state.llm_model = "" end
						save_prefs(); update_menu()
					end
				end
			})
			table.insert(user_sub, {
				title    = prefix .. m_name,
				menu     = model_submenu,
				disabled = paused or nil,
				fn       = function() pcall(function() switch_model(m_name) end) end
			})
		end
		table.insert(menu, { title = i18n.get("menu.llm.my_models"), menu = user_sub })
	end


	-- =====================================================
	-- ===== 1.5) Curated presets =====
	-- =====================================================

	for _, provider in ipairs(presets) do
		local sub = {}
		for _, family in ipairs(provider.families or {}) do
			local family_sub = {}
			for _, m in ipairs(family.models or {}) do
				local m_name   = m.name or m.repo or "Inconnu"
				local info     = models_mgr.get_model_info(m_name) or {}
				local ram      = models_mgr.get_model_ram(m_name) or 0
				local is_inst  = models_mgr.is_model_installed(m_name)

				local prefix         = (active_display_model == m_name) and "✓ " or "  "
				local status         = is_inst and "🟢 " or ""
				local type_str       = " [" .. i18n.get((info.type == "completion")
					and "menu.llm.model_type_completion"
					or  "menu.llm.model_type_chat") .. "]"
				local params_ram_str = (info.params and info.params > 0)
					and string.format(" (%gB params, ~%d Go RAM)", math.ceil(info.params * 10) / 10, math.ceil(ram))
					or  string.format(" (~%d Go RAM)", math.ceil(ram))
				local title = string.format("%s%s%s%s%s", prefix, status, m_name, type_str, params_ram_str)

				local hw            = m.hardware_requirements or {}
				local hw_active     = hw[active_backend] or {}
				local display_backend = (active_backend == "mlx") and "MLX" or "Ollama"
				local active_source = m.urls and m.urls[active_backend]
				local has_active_source = (type(active_source) == "string" and active_source ~= "")

				if not has_active_source then
					goto continue_model
				end

				local model_submenu = {}

				table.insert(model_submenu, {
					title    = i18n.get("menu.llm.select_model"),
					checked  = (active_display_model == m_name),
					disabled = paused or nil,
					fn       = function() switch_model(m_name) end
				})

				if is_inst then
					table.insert(model_submenu, {
						title = i18n.get("menu.llm.delete_model_cache"),
						fn = function()
							local ok, choice = pcall(dialog.block_alert,
								i18n.get("menu.llm.delete_model_title"),
								string.format(i18n.get("menu.llm.delete_model_body"), m_name),
								i18n.get("button.delete"), i18n.get("button.cancel"), "warning")
							if ok and choice == i18n.get("button.delete") then
								models_mgr.delete_model(m_name)
							end
						end
					})
				end

				table.insert(model_submenu, { title = "-" })
				table.insert(model_submenu, {
					title = string.format(i18n.get("menu.llm.model_backend"), display_backend),
					fn    = function() end
				})
				table.insert(model_submenu, {
					title = string.format(i18n.get("menu.llm.model_source"), active_source),
					fn    = function()
						local hs = hs  -- luacheck: ignore — intentional global access
						pcall(hs.urlevent.openURL, active_source)
					end
				})

				table.insert(model_submenu, { title = "-" })
				table.insert(model_submenu, { title = i18n.section("menu.llm.specs_header"), disabled = true })

				local m_type    = m.type or info.type or "Inconnu"
				local type_label = i18n.get((m_type == "completion")
					and "menu.llm.model_type_completion"
					or  "menu.llm.model_type_chat")
				table.insert(model_submenu, {
					title = string.format(i18n.get("menu.llm.model_type"), type_label),
					fn    = function() end
				})

				if m.last_updated and m.last_updated ~= "Unknown" then
					local y, mo, d = m.last_updated:match("^(%d+)%-(%d+)%-(%d+)$")
					local formatted_date = (y and mo and d) and (d .. "/" .. mo .. "/" .. y) or m.last_updated
					table.insert(model_submenu, {
						title = string.format(i18n.get("menu.llm.model_date"), formatted_date),
						fn    = function() end
					})
				end

				if m.parameters then
					if m.parameters.total and m.parameters.total ~= "N/A" then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.model_params_total"), m.parameters.total),
							fn    = function() end
						})
					end
					if m.parameters.active and m.parameters.active ~= "N/A" then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.model_params_active"), m.parameters.active),
							fn    = function() end
						})
					end
				end

				if m.capabilities then
					table.insert(model_submenu, { title = "-" })
					table.insert(model_submenu, { title = i18n.section("menu.llm.caps_header"), disabled = true })
					if m.capabilities.speed_tok_s then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.model_speed"), m.capabilities.speed_tok_s),
							fn    = function() end
						})
					end
					local tags = m.capabilities.tags
					if tags and type(tags) == "table" and #tags > 0 then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.model_tags"), table.concat(tags, ", ")),
							fn    = function() end
						})
					end
				end

				if hw_active.download_gb or hw_active.disk_gb or hw_active.ram_gb then
					table.insert(model_submenu, { title = "-" })
					table.insert(model_submenu, {
						title    = i18n.decorate_section(string.format(i18n.get("menu.llm.hw_header"), display_backend)),
						disabled = true
					})
					if hw_active.download_gb then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.hw_download"), hw_active.download_gb),
							fn    = function() end
						})
					end
					if hw_active.disk_gb then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.hw_disk"), hw_active.disk_gb),
							fn    = function() end
						})
					end
					if hw_active.ram_gb then
						table.insert(model_submenu, {
							title = string.format(i18n.get("menu.llm.hw_ram"), hw_active.ram_gb),
							fn    = function() end
						})
					end
				end

				table.insert(family_sub, {
					title    = title,
					menu     = model_submenu,
					disabled = paused or nil,
					-- Clicking the model row title selects it directly (same as "Select model")
					fn       = function() pcall(function() switch_model(m_name) end) end
				})

				::continue_model::
			end

			if #family_sub > 0 then
				if #sub > 0 then table.insert(sub, { title = "-" }) end
				for _, model_entry in ipairs(family_sub) do
					table.insert(sub, model_entry)
				end
			end
		end
		if #sub > 0 then
			table.insert(menu, { title = provider.label, menu = sub })
		end
	end


	-- =====================================================
	-- ===== 1.6) Browse + add custom model =====
	-- =====================================================

	local function present_model_chooser()
		if type(hs.chooser) ~= "table" or type(hs.chooser.new) ~= "function" then
			Logger.error(LOG, "Model browser: hs.chooser is unavailable — cannot present the window.")
			return
		end
		local choices = {}
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					local m_name = m.name or m.repo
					local active_source = m.urls and m.urls[active_backend]
					if m_name and type(active_source) == "string" and active_source ~= "" then
						local ram = models_mgr.get_model_ram(m_name) or 0
						table.insert(choices, {
							text    = m_name,
							subText = string.format("%s · %s · ~%d Go",
								provider.label or "", family.label or "", math.ceil(ram)),
							m_name  = m_name,
						})
					end
				end
			end
		end
		if #choices == 0 then
			Logger.warn(LOG, "Model browser: catalogue empty for backend '%s'.", tostring(active_backend))
			return
		end
		table.sort(choices, function(a, b) return a.text < b.text end)
		-- Delete the previous instance before creating a new one; without this,
		-- every call to present_model_chooser leaks one C-backed chooser object
		-- onto the heap because the old _model_browser_chooser reference is simply
		-- overwritten without releasing the native panel.
		if _model_browser_chooser then
			local stale = _model_browser_chooser
			_model_browser_chooser = nil
			pcall(function() stale:delete() end)
		end
		local chooser = hs.chooser.new(function(choice)
			if choice and choice.m_name then
				switch_model(choice.m_name)
			end
		end)
		chooser:width(72)
		chooser:placeholderText(i18n.get("menu.llm.browse_models_filter"))
		chooser:queryChangedCallback(function(query)
			local q = (query or ""):lower()
			if q == "" then
				chooser:choices(choices)
				return
			end
			local filtered = {}
			for _, c in ipairs(choices) do
				if c.text:lower():find(q, 1, true)
					or (c.subText and c.subText:lower():find(q, 1, true)) then
					table.insert(filtered, c)
				end
			end
			chooser:choices(filtered)
		end)
		chooser:choices(choices)
		-- Retain at module scope so the chooser survives until macOS presents it.
		_model_browser_chooser = chooser
		Logger.info(LOG, "Model browser: presenting %d model(s) (backend=%s).", #choices, tostring(active_backend))
		chooser:show()
		Logger.info(LOG, "Model browser: chooser shown (visible=%s).",
			tostring(pcall(function() return chooser:isVisible() end)))
	end

	local function open_model_browser()
		Logger.info(LOG, "Model browser: open requested (backend=%s).", tostring(active_backend))
		-- Defer to the next runloop tick so the menubar menu fully closes first: a
		-- window shown synchronously from inside the still-open menu callback can
		-- silently fail to appear. pcall surfaces any error to the log instead of
		-- letting the menubar callback swallow it.
		hs.timer.doAfter(0, function()
			-- Prefer the shared web table (sortable, filterable, cross-platform);
			-- fall back to the legacy hs.chooser list when hs.webview is absent
			-- (headless / stripped builds) so the entry never silently no-ops.
			local ok_mb, ModelBrowser = pcall(require, "ui.model_browser")
			if ok_mb and type(hs.webview) == "table" then
				local ok, err = pcall(ModelBrowser.open, {
					presets        = presets,
					active_backend = active_backend,
					active_model   = state.llm_model,
					models_mgr     = models_mgr,
					on_select      = function(name) switch_model(name) end,
				})
				if ok then return end
				Logger.error(LOG, "Model browser (web) failed — falling back to chooser: %s", tostring(err))
			end
			local ok2, err2 = pcall(present_model_chooser)
			if not ok2 then
				Logger.error(LOG, "Model browser: failed to present — %s", tostring(err2))
			end
		end)
	end

	table.insert(menu, { title = "-" })
	table.insert(menu, {
		title    = i18n.get("menu.llm.browse_models_entry"),
		disabled = paused or nil,
		fn       = function() open_model_browser() end,
	})
	table.insert(menu, {
		title    = i18n.get("menu.llm.add_model_entry"),
		disabled = paused or nil,
		fn       = function() prompt_add_user_model() end,
	})

	return menu
end

return M
