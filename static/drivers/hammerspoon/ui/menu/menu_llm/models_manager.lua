--- ui/menu/menu_llm/models_manager.lua

--- ===========================================================================
--- MODULE: LLM Models Manager (Router)
--- DESCRIPTION:
--- Acts as a facade to dispatch models management to Ollama or MLX depending
--- on the user's settings. Handles shared JSON metadata parsing.
--- ===========================================================================

local M = {}
local OllamaMgr = require("ui.menu.menu_llm.models_manager_ollama")
local MlxMgr    = require("ui.menu.menu_llm.models_manager_mlx")

local _model_ram_cache = nil





-- ==========================================
-- ==========================================
-- ======= 1/ Logic & Cache Helpers =======
-- ==========================================
-- ==========================================

--- Extracts model metadata (type, parameters, tags) based on its name and presets.
--- @param model_name string The name of the model.
--- @param presets table The global models configuration.
--- @return table Detailed info object.
local function get_model_info_logic(model_name, presets)
	model_name = type(model_name) == "string" and model_name or ""
	local m_type = "chat"
	local p_count = 0
	local m_tags = {}
	local found = false

	if type(presets) == "table" then
		for _, group in ipairs(presets) do
			if type(group.models) == "table" then
				for _, m in ipairs(group.models) do
					if type(m) == "table" and (m.name == model_name or m.name .. ":latest" == model_name) then
						if m.type then m_type = m.type end
						if type(m.params) == "string" then
							local num = m.params:match("([%d%.]+)")
							if num then p_count = tonumber(num) or 0 end
						end
						if type(m.tags) == "table" then m_tags = m.tags end
						found = true
						break
					end
				end
			end
			if found then break end
		end
	end

	if not found and model_name ~= "" then
		if model_name:match("%-base$") or model_name:match("coder") then m_type = "completion" end
		local num = model_name:match("([%d%.]+)b")
		if num then p_count = tonumber(num) or 0 end
	end

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
	return { type = m_type, params = p_count, emojis = tag_str, tags = m_tags }
end

--- Ensures the RAM requirements cache is populated.
--- @param presets table Global models presets.
local function ensure_ram_cache(presets)
	if _model_ram_cache or type(presets) ~= "table" then return end
	_model_ram_cache = {}
	for _, group in ipairs(presets) do
		if type(group.models) == "table" then
			for _, m in ipairs(group.models) do
				if type(m) == "table" and type(m.name) == "string" and type(m.ram_gb) == "number" then
					_model_ram_cache[m.name] = m.ram_gb
					local base = m.name:match("^(.-):")
					if base and not _model_ram_cache[base] then _model_ram_cache[base] = m.ram_gb end
				end
			end
		end
	end
end

--- Estimates RAM needed for a specific model.
--- @param model_name string Name of the model.
--- @param presets table Global models presets.
--- @return number Estimated GB of RAM.
local function get_model_ram_logic(model_name, presets)
	if type(model_name) ~= "string" or model_name == "" then return 8 end
	ensure_ram_cache(presets)
	if _model_ram_cache and _model_ram_cache[model_name] then return _model_ram_cache[model_name] end
	
	local info = get_model_info_logic(model_name, presets)
	local total_b = info.params
	if total_b == 0 then
		local name = model_name:lower()
		local experts, size = name:match("(%d+)x([%d%.]+)b")
		if experts and size then total_b = tonumber(experts) * tonumber(size) else total_b = 8 end
	end
	return math.ceil(total_b * 0.7 + 2.0)
end

--- Extracts explicit size metadata for a model when available.
--- @param model_name string Name of the model.
--- @param presets table Global models presets.
--- @return table Size metadata with download_gb and disk_gb fields.
local function get_model_size_logic(model_name, presets)
	local out = { download_gb = nil, disk_gb = nil, ram_gb = nil }
	if type(model_name) ~= "string" or model_name == "" or type(presets) ~= "table" then return out end

	for _, group in ipairs(presets) do
		if type(group.models) == "table" then
			for _, m in ipairs(group.models) do
				if type(m) == "table" and (m.name == model_name or m.name .. ":latest" == model_name) then
					if type(m.download_gb) == "number" then out.download_gb = m.download_gb end
					if type(m.disk_gb) == "number" then out.disk_gb = m.disk_gb end
					if type(m.ram_gb) == "number" then out.ram_gb = m.ram_gb end
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
			if dec_ok and type(data) == "table" and type(data.providers) == "table" then 
				presets = data.providers; break 
			end
		end
	end

	-- Shared system check logic injected into dependencies for engines to use.
	deps.shared_system_check = function(target_model, engine_name, repo_info, do_download, on_cancel)
		local ram_req  = get_model_ram_logic(target_model, presets)
		local size     = get_model_size_logic(target_model, presets)
		local disk_req = math.ceil((size.disk_gb or (ram_req * 0.7)) * 10) / 10
		local dl_req   = math.ceil((size.download_gb or size.disk_gb or (ram_req * 0.4)) * 10) / 10
		
		local ok_mem, mem_str = pcall(hs.execute, "sysctl -n hw.memsize")
		local sys_ram_gb      = math.ceil((tonumber(mem_str) or 0) / (1024^3))
		
		local ok_df, df_str   = pcall(hs.execute, "df -g / | awk 'NR==2 {print $4}'")
		local free_disk_gb    = tonumber(df_str) or 0

		local warnings, is_critical = {}, false
		
		if sys_ram_gb > 0 and sys_ram_gb < ram_req then 
			table.insert(warnings, string.format("⚠️ RAM : %d Go disponible (requis ~%d Go) — risque de lenteur", sys_ram_gb, ram_req))
		else 
			table.insert(warnings, string.format("🟢 RAM : %d Go disponible (requis ~%d Go)", sys_ram_gb, ram_req)) 
		end
		
		if free_disk_gb > 0 then
			local rem = free_disk_gb - disk_req
			if rem < 2 then
				is_critical = true
				table.insert(warnings, string.format("❌ Disque : %d Go disponible (requis ~%.1f Go) — espace insuffisant", free_disk_gb, disk_req))
			elseif rem < 15 then 
				table.insert(warnings, string.format("⚠️ Disque : %d Go disponible (requis ~%.1f Go) — espace limité", free_disk_gb, disk_req))
			else 
				table.insert(warnings, string.format("🟢 Disque : %d Go disponible (requis ~%.1f Go)", free_disk_gb, disk_req)) 
			end
		end

		table.insert(warnings, string.format("📦 Téléchargement estimé : ~%.1f Go", dl_req))

		local msg = "Modèle : " .. target_model .. "\n\n" .. table.concat(warnings, "\n")
		
		hs.timer.doAfter(0.1, function()
			pcall(hs.focus)
			if is_critical then
				pcall(hs.dialog.blockAlert, "Téléchargement impossible", msg, "Fermer", nil, "critical")
				if type(on_cancel) == "function" then pcall(on_cancel) end return
			end
			
			local sep  = string.rep("─", 25)
			local body = sep .. "\n" .. msg .. "\n" .. sep .. "\n\nCe modèle n'est pas encore installé."
			if repo_info and repo_info ~= "" then
				body = body .. "\n▸ " .. repo_info
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
		for _, group in ipairs(presets) do
			local new_group = { id = group.id, label = group.label, models = {} }
			for _, m in ipairs(group.models) do
				if m.mlx_repo then table.insert(new_group.models, m) end
			end
			if #new_group.models > 0 then table.insert(filtered, new_group) end
		end
		return filtered
	end
	
	function obj.get_mlx_repo(name) return mlx.get_mlx_repo(name) end
	function obj.get_model_info(name) return get_model_info_logic(name, presets) end
	function obj.get_model_ram(name) return get_model_ram_logic(name, presets) end
	function obj.get_model_emojis(name) return get_model_info_logic(name, presets).emojis end
	
	   function obj.get_installed_models()
		   if deps.state.llm_use_mlx then
			   return mlx.get_installed_models() or {}
		   else
			   return ollama.get_installed_models() or {}
		   end
	   end

	function obj.check_requirements(...) return get_active().check_requirements(...) end
	function obj.delete_model(name) return get_active().delete_model(name) end
	function obj.force_mlx_check(...) return mlx.check_requirements(...) end
	
	function obj.stop_mlx_server_if_needed()
		if deps.active_tasks and deps.active_tasks["mlx_server"] then
			pcall(function() deps.active_tasks["mlx_server"]:terminate() end)
			deps.active_tasks["mlx_server"] = nil
		end
	end

	return obj
end

return M
