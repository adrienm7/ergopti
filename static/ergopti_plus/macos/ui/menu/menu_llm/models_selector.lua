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




-- ==============================
-- ==============================
-- ======= 1/ Public API =======
-- ==============================
-- ==============================

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

	--- Prompts the user for a custom model identifier and persists it.
	local function prompt_add_user_model()
		local hint = (active_backend == "mlx")
			and i18n.get("menu.llm.mlx_model_hint")
			or  i18n.get("menu.llm.ollama_model_hint")
		local ok, ret_a, ret_b = pcall(dialog.text_prompt,
			i18n.get("menu.llm.add_custom_model"),
			hint,
			"", i18n.get("button.add"), i18n.get("button.cancel"))
		if not ok then
			Logger.warn(LOG, "Custom model dialog raised — aborting add.")
			return
		end
		-- hs.dialog.textPrompt return order varies across macOS builds — handle both
		local picked_btn, picked_text
		if ret_a == i18n.get("button.add") or ret_a == i18n.get("button.cancel") then
			picked_btn, picked_text = ret_a, ret_b
		else
			picked_text, picked_btn = ret_a, ret_b
		end
		if picked_btn ~= i18n.get("button.add") then return end
		local name = (type(picked_text) == "string" and picked_text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			pcall(dialog.alert, i18n.get("menu.llm.custom_model_title"), i18n.get("menu.llm.empty_model_id"), "OK")
			return
		end
		add_user_model(active_backend, name)
		save_prefs()
		switch_model(name)
	end


	-- =====================================================
	-- ===== 1.3) Header rows =====
	-- =====================================================

	-- "No model" option so the user can explicitly disable predictions
	table.insert(menu, {
		title   = i18n.get("menu.llm.no_model"),
		checked = (not state.llm_model or state.llm_model == ""),
		fn      = function()
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
			title   = string.format(i18n.get("menu.llm.backend_default_model"), backend_default),
			checked = (active_display_model == backend_default),
			fn      = function()
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
			title = string.format(i18n.get("menu.llm.hf_token_label"), token_status),
			fn = function()
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
				title   = i18n.get("menu.llm.select_model"),
				checked = (state.llm_model == m_name),
				fn      = function() switch_model(m_name) end
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
				title   = prefix .. m_name,
				menu    = model_submenu,
				fn      = function() pcall(function() switch_model(m_name) end) end
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
				local type_str       = (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]"
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
					title   = i18n.get("menu.llm.select_model"),
					checked = (active_display_model == m_name),
					fn      = function() switch_model(m_name) end
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
				local type_label = (m_type == "completion") and "📝 Complétion" or "💬 Chat"
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
						title    = "— " .. string.format(i18n.get("menu.llm.hw_header"), display_backend) .. " —",
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
					title = title,
					menu  = model_submenu,
					-- Clicking the model row title selects it directly (same as "Select model")
					fn    = function() pcall(function() switch_model(m_name) end) end
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
	-- ===== 1.6) Add custom model =====
	-- =====================================================

	-- Power-user entry at the bottom — sits below the curated list so the
	-- standard presets remain the first-seen, discoverable choice.
	table.insert(menu, { title = "-" })
	table.insert(menu, {
		title = i18n.get("menu.llm.add_model_entry"),
		fn    = function() prompt_add_user_model() end,
	})

	return menu
end

return M
