--- ui/menu/menu_llm/models_manager.lua

--- ==============================================================================
--- MODULE: LLM Models Manager (Router)
--- DESCRIPTION:
--- Acts as a facade to dispatch models management to Ollama or MLX depending
--- on the user's settings. Handles shared JSON metadata parsing.
---
--- FEATURES & RATIONALE:
--- 1. Shared JSON Parsing: Provides a centralized way to query model metadata.
--- 2. Transparent Routing: Delegates actual actions to the correct engine.
--- 3. Engine-Aware Requirements: Parses specific MLX or Ollama hardware sizes.
--- ==============================================================================

local M = {}

local hs        = hs
local OllamaMgr = require("ui.menu.menu_llm.models_manager_ollama")
local MlxMgr    = require("ui.menu.menu_llm.models_manager_mlx")
local Logger    = require("lib.logger")

local LOG = "menu_llm.models"

local _model_ram_cache = nil

--- Extracts Ollama model name from ollama.com/library URL.
--- e.g., "https://ollama.com/library/gemma4:e2b" -> "gemma4:e2b"
--- @param url string The Ollama library URL.
--- @return string The model name.
local function extract_ollama_name(url)
	if type(url) ~= "string" or url == "" then return nil end
	return url:match("/library/([^/]+)$") or url:match("([^/]+)$")
end

--- Extracts MLX model name from huggingface.co URL.
--- e.g., "https://huggingface.co/mlx-community/gemma-4-e2b-it-mxfp4" -> "gemma-4-e2b-it-mxfp4"
--- @param url string The HuggingFace MLX URL.
--- @return string The model name.
local function extract_mlx_name(url)
	if type(url) ~= "string" or url == "" then return nil end
	return url:match("/([^/]+)$")
end

--- Resolves the actual backend-specific model name.
--- @param display_name string The display name from llm_models.json.
--- @param presets table The global models configuration.
--- @param is_mlx boolean True for MLX, false for Ollama.
--- @return string The actual model name for the backend.
local function get_actual_model_name(display_name, presets, is_mlx)
	if type(display_name) ~= "string" or display_name == "" then return display_name end
	if type(presets) ~= "table" then return display_name end
	
	for _, provider in ipairs(presets) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				if type(m) == "table" and m.name == display_name then
					if is_mlx then
						local mlx_url = m.urls and m.urls.mlx
						return extract_mlx_name(mlx_url) or display_name
					else
						local ollama_url = m.urls and m.urls.ollama
						return extract_ollama_name(ollama_url) or display_name
					end
				end
			end
		end
	end
	return display_name
end





-- ============================================
-- ============================================
-- ======= 1/ Logic And Cache Utilities =======
-- ============================================
-- ============================================

--- Extracts model metadata (type, parameters, tags) based on its name and presets.
--- @param model_name string The name of the model.
--- @param presets table The global models configuration.
--- @return table Detailed info object.
local function get_model_info_logic(model_name, presets)
	model_name = type(model_name) == "string" and model_name or ""
	local m_type = "chat"
	local p_count_total = 0
	local p_count_active = 0
	local m_tags = {}
	local found = false

	if type(presets) == "table" then
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if type(m) == "table" and (m.name == model_name or m.name .. ":latest" == model_name) then
						if m.type then m_type = m.type end
						if m.parameters then
							if type(m.parameters.total) == "string" then
								local total_num = m.parameters.total:match("([%d%.]+)")
								if total_num then p_count_total = tonumber(total_num) or 0 end
							end
							if type(m.parameters.active) == "string" then
								local active_num = m.parameters.active:match("([%d%.]+)")
								if active_num then p_count_active = tonumber(active_num) or 0 end
							end
						end
						if m.capabilities and type(m.capabilities.tags) == "table" then m_tags = m.capabilities.tags end
						found = true
						break
					end
				end
				if found then break end
			end
			if found then break end
		end
	end

	if not found and model_name ~= "" then
		if model_name:match("%-base$") or model_name:match("coder") then m_type = "completion" end
		local experts, size = model_name:lower():match("(%d+)x([%d%.]+)b")
		if experts and size then
			local experts_n = tonumber(experts) or 0
			local size_n = tonumber(size) or 0
			p_count_total = experts_n * size_n
			p_count_active = size_n
		else
			local num = model_name:lower():match("([%d%.]+)b")
			if num then
				p_count_total = tonumber(num) or 0
				p_count_active = p_count_total
			end
		end
	end

	if p_count_active <= 0 then p_count_active = p_count_total end
	local is_moe = p_count_total > 0 and p_count_active > 0 and p_count_active < p_count_total

	local is_thinking = model_name:lower():find("%-r1") or model_name:lower():find("thinking") or model_name:lower():find("reasoning")
	local seen_emojis = {}
	if is_thinking then seen_emojis["🧠💭"] = true end
	for _, t in ipairs(m_tags) do
		local em = ({best="⭐", reasoning="🧠", math="🧠", code="💻", completion="💻", fast="⚡", tiny="⚡",
					 ["ultra-tiny"]="⚡", edge="⚡", multilingual="🌐", chinese="🌐", korean="🌐",
					 multimodal="🖼️", ["high-quality"]="🏆", quality="🏆"})[t]
		if em == "🧠" and seen_emojis["🧠💭"] then em = nil end
		if em then seen_emojis[em] = true end
	end

	local tag_list = {}
	for em, _ in pairs(seen_emojis) do table.insert(tag_list, em) end
	local EMOJI_ORDER = { ["🏆"]=1, ["⚡"]=2, ["🧠💭"]=3, ["🧠"]=4, ["💻"]=5, ["🌐"]=6, ["🖼️"]=7, ["⭐"]=8 }
	table.sort(tag_list, function(a, b)
		local oa = EMOJI_ORDER[a] or 99; local ob = EMOJI_ORDER[b] or 99
		if oa == ob then return a < b end; return oa < ob
	end)
	
	local tag_str = #tag_list > 0 and (" " .. table.concat(tag_list, "")) or ""
	return {
		type = m_type,
		params = p_count_total,
		params_total = p_count_total,
		params_active = p_count_active,
		is_moe = is_moe,
		emojis = tag_str,
		tags = m_tags,
	}
end

--- Ensures the RAM requirements cache is populated for the active engine.
--- @param presets table Global models presets.
--- @param is_mlx boolean True if MLX is the active engine.
local function ensure_ram_cache(presets, is_mlx)
	if type(presets) ~= "table" then return end
	local cache_key = is_mlx and "mlx" or "ollama"
	
	_model_ram_cache = _model_ram_cache or {}
	if _model_ram_cache[cache_key] then return end
	
	_model_ram_cache[cache_key] = {}
	for _, provider in ipairs(presets) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				if type(m) == "table" and type(m.name) == "string" then
					local req = m.hardware_requirements or {}
					local hw = is_mlx and req.mlx or req.ollama or {}
					if type(hw.ram_gb) == "number" then
						_model_ram_cache[cache_key][m.name] = hw.ram_gb
						local base = m.name:match("^(.-):")
						if base and not _model_ram_cache[cache_key][base] then 
							_model_ram_cache[cache_key][base] = hw.ram_gb 
						end
					end
				end
			end
		end
	end
end

--- Estimates RAM needed for a specific model contextually.
--- @param model_name string Name of the model.
--- @param presets table Global models presets.
--- @param is_mlx boolean True if MLX is the active engine.
--- @return number Estimated GB of RAM.
local function get_model_ram_logic(model_name, presets, is_mlx)
	if type(model_name) ~= "string" or model_name == "" then return 8 end
	ensure_ram_cache(presets, is_mlx)
	
	local cache_key = is_mlx and "mlx" or "ollama"
	if _model_ram_cache[cache_key] and _model_ram_cache[cache_key][model_name] then 
		return _model_ram_cache[cache_key][model_name] 
	end
	
	local info = get_model_info_logic(model_name, presets)
	local total_b = tonumber(info.params_total) or tonumber(info.params) or 0
	if total_b == 0 then
		local name = model_name:lower()
		local experts, size = name:match("(%d+)x([%d%.]+)b")
		if experts and size then 
			total_b = tonumber(experts) * tonumber(size) 
		else 
			total_b = 8 
		end
	end
	return math.ceil(total_b * 0.7 + 2.0)
end

--- Extracts explicit size metadata for a model when available.
--- @param model_name string Name of the model.
--- @param presets table Global models presets.
--- @param is_mlx boolean True if MLX is the active engine.
--- @return table Size metadata with download_gb and disk_gb fields.
local function get_model_size_logic(model_name, presets, is_mlx)
	local out = { download_gb = nil, disk_gb = nil, ram_gb = nil }
	if type(model_name) ~= "string" or model_name == "" or type(presets) ~= "table" then return out end

	for _, provider in ipairs(presets) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				if type(m) == "table" and (m.name == model_name or m.name .. ":latest" == model_name) then
					local req = m.hardware_requirements or {}
					local hw = is_mlx and req.mlx or req.ollama or {}
					if type(hw.download_gb) == "number" then out.download_gb = hw.download_gb end
					if type(hw.disk_gb) == "number" then out.disk_gb = hw.disk_gb end
					if type(hw.ram_gb) == "number" then out.ram_gb = hw.ram_gb end
					return out
				end
			end
		end
	end

	return out
end





-- =========================================
-- =========================================
-- ======= 2/ Manager Initialization =======
-- =========================================
-- =========================================

--- Factory function to create the Models Manager.
--- @param deps table Module dependencies.
function M.new(deps)
	local obj = {}

	local candidates = {
		hs.configdir .. "/data/llm_models.json",
		hs.configdir .. "/../hammerspoon/data/llm_models.json",
	}
	local presets = {}
	for _, path in ipairs(candidates) do
		local ok, fh = pcall(io.open, path, "r")
		if ok and fh then
			local raw = fh:read("*a")
			pcall(function() fh:close() end)
			local dec_ok, data = pcall(hs.json.decode, raw)
			if dec_ok and type(data) == "table" then 
				presets = data; break 
			end
		end
	end

	-- Injecting a cross-engine hardware check for dynamic scaling.
	deps.shared_system_check = function(target_model, engine_name, repo_info, do_download, on_cancel)
		local is_mlx   = engine_name:lower():find("mlx") ~= nil
		local ram_req  = get_model_ram_logic(target_model, presets, is_mlx)
		local size     = get_model_size_logic(target_model, presets, is_mlx)
		local disk_req = math.ceil((size.disk_gb or (ram_req * 0.7)) * 10) / 10
		local dl_req   = math.ceil((size.download_gb or size.disk_gb or (ram_req * 0.4)) * 10) / 10
		
		local ok_mem, mem_str = pcall(hs.execute, "sysctl -n hw.memsize")
		local sys_ram_gb      = math.ceil((tonumber(mem_str) or 0) / (1024^3))
		
		local ok_df, df_str   = pcall(hs.execute, "df -g / | awk 'NR==2 {print $4}'")
		local free_disk_gb    = tonumber(df_str) or 0

		local warnings, is_critical = {}, false
		
		if sys_ram_gb > 0 and sys_ram_gb < ram_req then 
			table.insert(warnings, string.format("⚠️ RAM : requis ~%.1f Go (%d Go disponible) — risque de lenteur", ram_req, sys_ram_gb))
		else 
			table.insert(warnings, string.format("🟢 RAM : requis ~%.1f Go (%d Go disponible)", ram_req, sys_ram_gb)) 
		end
		
		if free_disk_gb > 0 then
			local rem = free_disk_gb - disk_req
			if rem < 2 then
				is_critical = true
				table.insert(warnings, string.format("❌ Disque : requis ~%.1f Go (%d Go disponible) — espace insuffisant", disk_req, free_disk_gb))
			elseif rem < 15 then 
				table.insert(warnings, string.format("⚠️ Disque : requis ~%.1f Go (%d Go disponible) — espace limité", disk_req, free_disk_gb))
			else 
				table.insert(warnings, string.format("🟢 Disque : requis ~%.1f Go (%d Go disponible)", disk_req, free_disk_gb)) 
			end
		end

		table.insert(warnings, string.format("📦 Taille du téléchargement (modèle compressé) : ~%.1f Go", dl_req))

		local msg = "Modèle : " .. target_model .. "\n\n" .. table.concat(warnings, "\n")
		
		hs.timer.doAfter(0.1, function()
			local hs_app = hs.application and hs.application.get and hs.application.get("Hammerspoon") or nil
			if not hs_app and hs.application and hs.application.find then
				hs_app = hs.application.find("Hammerspoon")
			end
			if hs_app and type(hs_app.activate) == "function" then
				pcall(function() hs_app:activate(true) end)
			else
				pcall(hs.focus)
			end
			if is_critical then
				pcall(hs.dialog.blockAlert, "Téléchargement impossible", msg, "Fermer", nil, "critical")
				if type(on_cancel) == "function" then pcall(on_cancel) end return
			end
			
			local sep  = string.rep("─", 25)
			local body = sep .. "\n" .. msg .. "\n" .. sep .. "\n\nCe modèle n’est pas encore installé."
			if repo_info and repo_info ~= "" then
				body = body .. "\n ➜ " .. repo_info
			end
			body = body .. "\n\nVoulez-vous lancer le téléchargement ?"

			local ok_c, choice = pcall(hs.dialog.blockAlert,
				"Configuration requise (" .. engine_name .. ")",
				body, "Télécharger", "Annuler", msg:find("⚠️") and "warning" or "informational")
				
			if ok_c and choice == "Télécharger" then
				do_download()
			else
				if type(on_cancel) == "function" then pcall(on_cancel) end
			end
		end)
	end

	local ollama = OllamaMgr.new(deps, presets, get_model_ram_logic)
	local mlx    = MlxMgr.new(deps, presets)

	local function get_active()
		return deps.state.llm_use_mlx and mlx or ollama
	end

	function obj.get_presets()
		if not deps.state.llm_use_mlx then return presets end
		local filtered = {}
		for _, provider in ipairs(presets) do
			local new_provider = { label = provider.label, families = {} }
			for _, family in ipairs(provider.families or {}) do
				local new_family = { label = family.label, models = {} }
				for _, m in ipairs(family.models or {}) do
					if m.urls and type(m.urls.mlx) == "string" and m.urls.mlx ~= "" then 
						table.insert(new_family.models, m) 
					end
				end
				if #new_family.models > 0 then table.insert(new_provider.families, new_family) end
			end
			if #new_provider.families > 0 then table.insert(filtered, new_provider) end
		end
		return filtered
	end
	
	function obj.get_mlx_repo(name) return mlx.get_mlx_repo(name) end
	function obj.get_model_info(name) return get_model_info_logic(name, presets) end
	function obj.get_model_ram(name) return get_model_ram_logic(name, presets, deps.state.llm_use_mlx) end
	function obj.get_model_emojis(name) return get_model_info_logic(name, presets).emojis end
	
	--- Gets the actual backend-specific model name.
	--- @param display_name string The display name from llm_models.json.
	--- @return string The real model name for the active backend.
	function obj.get_actual_model_name(display_name)
		return get_actual_model_name(display_name, presets, deps.state.llm_use_mlx)
	end
	
	--- Checks if a display model name is installed, by converting to real backend name.
	--- @param display_name string The display name from llm_models.json.
	--- @return boolean True if installed, false otherwise.
	function obj.is_model_installed(display_name)
		local installed = obj.get_installed_models()
		-- MLX stores by display name (m.name), try that first
		if installed[display_name] then return true end
		-- Ollama stores by actual backend name, convert and try
		local actual_name = get_actual_model_name(display_name, presets, deps.state.llm_use_mlx)
		return installed[actual_name] or installed[actual_name .. ":latest"] or false
	end
	
	function obj.get_installed_models()
		if deps.state.llm_use_mlx then
			return mlx.get_installed_models() or {}
		else
			return ollama.get_installed_models() or {}
		end
	end

	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		return get_active().check_requirements(target_model, on_success, on_cancel, opts)
	end
	function obj.delete_model(name) return get_active().delete_model(name) end
	function obj.force_mlx_check(...) return mlx.check_requirements(...) end
	function obj.open_model_source_page(name)
		if deps.state.llm_use_mlx and type(mlx.open_model_source_page) == "function" then
			return mlx.open_model_source_page(name)
		end
		return false
	end
	function obj.prompt_hf_login(on_done)
		if type(mlx.prompt_hf_login) == "function" then
			return mlx.prompt_hf_login(on_done)
		end
		if type(on_done) == "function" then pcall(on_done, false) end
		return false
	end
	
	function obj.stop_mlx_server_if_needed()
		if deps.active_tasks and deps.active_tasks["mlx_server"] then
			pcall(function() deps.active_tasks["mlx_server"]:terminate() end)
			deps.active_tasks["mlx_server"] = nil
			Logger.info(LOG, "MLX server stopped safely.")
		end
	end

	return obj
end

return M
