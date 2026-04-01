--- ui/menu/menu_llm/models_manager_ollama.lua

--- ==============================================================================
--- MODULE: Ollama Models Manager
--- DESCRIPTION:
--- Manages Ollama models: installation status and downloads via the CLI.
--- ==============================================================================

local M = {}
local notifications = require("lib.notifications")

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end





-- ==============================
-- ==============================
-- ======= 1/ CLI Helpers =======
-- ==============================
-- ==============================

--- Finds the absolute path to the Ollama binary.
--- @return string|nil The path or nil if not found.
local function get_ollama_path()
	local ok, p = pcall(hs.execute, "which ollama 2>/dev/null")
	if ok and type(p) == "string" and p ~= "" then return p:gsub("%s+", "") end
	local candidates = {"/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"}
	for _, c in ipairs(candidates) do
		local attr_ok, attr = pcall(hs.fs.attributes, c)
		if attr_ok and attr then return c end
	end
	return nil
end





-- ===================================
-- ===================================
-- ======= 2/ Manager Factory ========
-- ===================================
-- ===================================

function M.new(deps, presets, ram_getter)
	local obj = {}

	function obj.get_installed_models()
		local installed = {}
		local bin = get_ollama_path() or "/usr/local/bin/ollama"
		local ok, output = pcall(hs.execute, bin .. " list 2>/dev/null")
		if ok and type(output) == "string" then
			for line in output:gmatch("[^\r\n]+") do
				local name = line:match("^(%S+)")
				if name and name ~= "NAME" then installed[name] = true end
			end
		end
		return installed
	end

	function obj.check_requirements(target_model, on_success, on_cancel)
		if not target_model or target_model == "" then return end
		local installed = obj.get_installed_models()
		
		if installed[target_model] or installed[target_model .. ":latest"] then
			if type(on_success) == "function" then on_success() end
		else
			if type(deps.shared_system_check) == "function" then
				deps.shared_system_check(target_model, "Ollama", nil, function()
					if get_ollama_path() then require("ui.menu.menu_llm.models_manager_ollama").pull_model(target_model, deps)
					else require("ui.menu.menu_llm.models_manager_ollama").install_ollama_then_pull(target_model, deps) end
				end, on_cancel)
			end
		end
	end

	-- Suppression d'un modèle téléchargé via Ollama
	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return end
		local bin = get_ollama_path() or "/usr/local/bin/ollama"
		local ok, output = pcall(hs.execute, bin .. " rm " .. model_name .. " 2>&1")
		if ok then
			pcall(notifications.notify, "🗑️ Supprimé (Ollama)", model_name)
			if deps.update_menu then pcall(deps.update_menu) end
		else
			pcall(notifications.notify, "❌ Échec suppression Ollama", model_name .. "\n" .. tostring(output))
		end
	end
	return obj
end

return M
