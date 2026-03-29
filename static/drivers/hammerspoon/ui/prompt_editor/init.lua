--- ui/prompt_editor/init.lua

--- ==============================================================================
--- MODULE: Prompt Editor UI
--- DESCRIPTION:
--- Provides a clean webview-based interface for users to create and edit
--- custom LLM prompt profiles. Employs a content-editable block to visually
--- render the "{context}" token as a chip.
--- 
--- FEATURES & RATIONALE:
--- 1. Singleton Preservation: Pressing the shortcut multiple times preserves the currently open window (and any ongoing text input) by bringing it to the front, creating a new window only if it is completely closed.
--- 2. Space Teleportation & Focus: Leverages the UI builder to natively teleport the window to the active macOS space and grant it focus, while allowing other apps to overlap it when clicked.
--- 3. Centralized Creation: Window properties are managed via the ui_builder factory.
--- ==============================================================================

local M = {}
local hs = hs
local ui_builder = require("ui.ui_builder")





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil

local WINDOW_WIDTH  = 550
local WINDOW_HEIGHT = 480

-- Determine absolute path to the assets directory
local _src  = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the Prompt Editor window.
--- @param existing table|nil An existing profile to edit, or nil for a new one.
--- @param on_save function Callback invoked when the user clicks "Save".
function M.open(existing, on_save)
	-- Early return: Reuse the webview if it is already open to strictly preserve user input and focus.
	if _webview then 
		ui_builder.force_focus(_webview)
		return
	end

	local default_name   = type(existing) == "table" and type(existing.label) == "string" and existing.label or ""
	local default_batch  = (existing == nil) or (type(existing) == "table" and existing.batch ~= false)
	local default_prompt = type(existing) == "table" and type(existing.raw_prompt) == "string" and existing.raw_prompt or "Voici un texte, continue-le : {context}"
	local title_str      = existing and "Modifier le profil" or "Nouveau profil"

	-- Setup the usercontent bridge
	local ok_uc, uc = pcall(hs.webview.usercontent.new, "prompt_bridge")
	if not ok_uc or not uc then
		print("[prompt_editor] Error creating usercontent bridge.")
		return
	end
	
	_usercontent = uc
	_usercontent:setCallback(function(msg)
		if type(msg) ~= "table" then return end
		local body = msg.body
		
		if type(body) == "table" then
			if body.action == "cancel" then
				M.close()
			elseif body.action == "save" then
				local id = (type(existing) == "table" and type(existing.id) == "string") 
						   and existing.id 
						   or ("custom_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))
						   
				if type(on_save) == "function" then
					pcall(on_save, {
						id          = id,
						label       = type(body.name) == "string" and body.name or "Profil personnalisé",
						batch       = (body.batch == true),
						raw_prompt  = type(body.prompt) == "string" and body.prompt or "",
					})
				end
				M.close()
			end
		end
	end)

	-- Request the webview creation/focus from the centralized UI builder
	_webview = ui_builder.show_webview({
		frame         = ui_builder.get_centered_frame(WINDOW_WIDTH, WINDOW_HEIGHT),
		title         = title_str,
		style_masks   = {"titled", "closable", "utility"},
		usercontent   = _usercontent,
		assets_dir    = ASSETS_DIR,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				local payload = {
					title  = title_str,
					name   = default_name,
					mode   = default_batch and "batch" or "parallel",
					prompt = default_prompt
				}
				local ok_enc, js_data = pcall(hs.json.encode, payload)
				if ok_enc and js_data then
					pcall(function() _webview:evaluateJavaScript("init(" .. js_data .. ")") end)
				end
			end
			return true
		end,
		on_close      = function()
			_webview     = nil
			_usercontent = nil
		end
	})
end

--- Closes and destroys the Prompt Editor window.
function M.close()
	if _webview and type(_webview.delete) == "function" then 
		pcall(function() _webview:delete() end)
	end
	_webview     = nil 
	_usercontent = nil
end

return M
