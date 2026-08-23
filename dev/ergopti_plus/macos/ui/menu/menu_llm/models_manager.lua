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
local Logger    = require("infra.logger")
local dialog    = require("infra.dialog_util")
local llm_mod   = require("modules.llm")
local i18n      = require("infra.i18n")
local Paths     = require("infra.paths")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "menu_llm.models"

--- Loads _shared/modules/llm/models.json via lib.paths (configdir + script-relative walk).
--- Missing or invalid file → error (fail fast).
--- @return table Provider list parsed from models.json.
local function load_models_presets()
	local path = Paths.shared_llm_path("models.json")
	if not path then
		error("[menu_llm.models] static/ergopti_plus/_shared/modules/llm/models.json not found")
	end
	local fh = io.open(path, "r")
	if not fh then
		error("[menu_llm.models] cannot open models.json: " .. path)
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" or #data == 0 then
		error("[menu_llm.models] models.json invalid or empty: " .. path)
	end
	Logger.done(LOG, "Loaded models catalogue (%d providers) from %s.", #data, path)
	return data
end

local _model_ram_cache = nil





-- ==============================
-- ==============================
-- ======= 1/ Extraction ========
-- ==============================
-- ==============================

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
--- @param display_name string The display name from _shared/modules/llm/models.json.
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
-- ======= 2/ Logic And Cache Utilities =======
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
						break
					end
				end
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
					local hw = is_mlx and (req.mlx or {}) or (req.ollama or {})
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
	
	return 8
end

--- Extracts explicit size metadata for a model when available.
--- @param model_name string Name of the model.
--- @param presets table Global models presets.
--- @param is_mlx boolean True if MLX is the active engine.
--- @return table Size metadata with download_gb and ram_gb fields.
local function get_model_size_logic(model_name, presets, is_mlx)
	local out = { download_gb = nil, ram_gb = nil }
	if type(model_name) ~= "string" or model_name == "" or type(presets) ~= "table" then return out end

	for _, provider in ipairs(presets) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				if type(m) == "table" and (m.name == model_name or m.name .. ":latest" == model_name) then
					local req = m.hardware_requirements or {}
					local hw = is_mlx and (req.mlx or {}) or (req.ollama or {})
					if type(hw.download_gb) == "number" then out.download_gb = hw.download_gb end
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
-- ======= 3/ Manager Initialization =======
-- =========================================
-- =========================================

--- Factory function to create the Models Manager.
--- @param deps table Module dependencies.
function M.new(deps)
	local obj = {}

	local presets = load_models_presets()

	-- Injecting a cross-engine hardware check for dynamic scaling.
	deps.shared_system_check = function(target_model, engine_name, repo_info, do_download, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local requirement_lifecycle = type(opts) == "table"
			and opts._requirement_lifecycle or nil
		local cancellation_sent = false
		local function cancel_once(label)
			if cancellation_sent then return false end
			cancellation_sent = true
			if type(on_cancel) ~= "function" then return true end
			local ok, result = Logger.callback(LOG, label, on_cancel)
			return ok and result ~= false
		end
		local function still_current()
			local ok, current = Logger.callback(LOG,
				"Model system-check freshness check", is_current)
			return ok == true and current == true
		end
		local function current_or_cancel()
			if still_current() then return true end
			cancel_once("Stale model system-check cancellation")
			return false
		end
		local is_mlx   = engine_name:lower():find("mlx") ~= nil
		local ram_req  = get_model_ram_logic(target_model, presets, is_mlx)
		local size     = get_model_size_logic(target_model, presets, is_mlx)
		local dl_req   = math.ceil((size.download_gb or (ram_req * 0.4)) * 10) / 10
		if type(requirement_lifecycle) ~= "table"
			or type(requirement_lifecycle.adopt) ~= "function"
			or type(requirement_lifecycle.settle) ~= "function" then
			Logger.error(LOG,
				"Model system-check timer has no exact requirement lifecycle.")
			cancel_once("Unowned model system-check cancellation")
			return false
		end

		local owner = {
			handle = nil,
			authorized = true,
			committed = false,
			installing = true,
			native_settled = false,
			callback_pending = false,
			callback_running = false,
			callback_consumed = false,
			requirement_registered = false,
		}

		local function release_owner()
			if owner.requirement_registered ~= true then return false end
			-- The native one-shot settles before TimerScheduler invokes its business
			-- callback.  Keep the requirement child registered across that callback so
			-- a re-entrant PAUSE cannot publish while a dialog/download boundary is on
			-- the stack.  A revoked, never-committed callback may release immediately.
			if owner.installing == true or owner.native_settled ~= true
				or owner.callback_running == true then
				return false
			end
			if owner.authorized == true and owner.committed == true
				and owner.callback_consumed ~= true then
				return false
			end
			local ok, released = xpcall(function()
				return requirement_lifecycle.settle(owner)
			end, debug.traceback)
			if ok ~= true or released ~= true then return false end
			owner.requirement_registered = false
			return true
		end

		local function pause_join()
			owner.authorized = false
			owner.committed = false
			if owner.handle == nil then
				if owner.installing == true then return false end
				owner.native_settled = true
				if owner.requirement_registered ~= true then return true end
				return release_owner() == true
			end
			local cancel_ok, settled_or_error = xpcall(function()
				return TimerScheduler.cancel(owner.handle)
			end, debug.traceback)
			if cancel_ok ~= true or settled_or_error ~= true then
				Logger.error(LOG,
					"Model system-check cancellation remains unsettled: %s.",
					tostring(settled_or_error))
				return false
			end
			owner.native_settled = true
			-- TimerScheduler.cancel() can synchronously deliver onSettled(), which
			-- releases this exact child before control returns here. That is already a
			-- committed join, not a second release failure.
			if owner.requirement_registered ~= true then return true end
			return release_owner() == true
		end

		local adopt_ok, adopted = xpcall(function()
			return requirement_lifecycle.adopt(owner, pause_join,
				"Model system-check timer")
		end, debug.traceback)
		if adopt_ok ~= true or adopted ~= true then
			Logger.error(LOG, "Model system-check timer adoption was refused.")
			cancel_once("Unadopted model system-check cancellation")
			return false
		end
		owner.requirement_registered = true

		local function settle_before_timer()
			owner.installing = false
			owner.committed = false
			owner.native_settled = true
			if owner.requirement_registered == true and release_owner() ~= true then
				Logger.error(LOG,
					"Model system-check probe owner settlement was refused.")
			end
			return false
		end

		local function probe_owner_current()
			if owner.authorized ~= true
				or owner.requirement_registered ~= true then
				return false
			end
			if current_or_cancel() ~= true then return false end
			return owner.authorized == true
				and owner.requirement_registered == true
		end

		if not probe_owner_current() then return settle_before_timer() end
		local _, mem_str = pcall(hs.execute, "sysctl -n hw.memsize")
		if not probe_owner_current() then return settle_before_timer() end
		local sys_ram_gb = math.ceil((tonumber(mem_str) or 0) / (1024^3))

		local _, df_str = pcall(hs.execute, "df -g / | awk 'NR==2 {print $4}'")
		if not probe_owner_current() then return settle_before_timer() end
		local free_disk_gb = tonumber(df_str) or 0

		local prepared_ok, prepared = xpcall(function()
			local warnings, is_critical = {}, false
			if sys_ram_gb > 0 and sys_ram_gb < ram_req then
				table.insert(warnings, string.format(i18n.get("menu.llm.req_ram_low"), ram_req, sys_ram_gb))
			else
				table.insert(warnings, string.format(i18n.get("menu.llm.req_ram_ok"), ram_req, sys_ram_gb))
			end

			if free_disk_gb > 0 then
				local rem = free_disk_gb - dl_req
				if rem < 2 then
					is_critical = true
					table.insert(warnings, string.format(i18n.get("menu.llm.req_disk_insufficient"), dl_req, free_disk_gb))
				elseif rem < 15 then
					table.insert(warnings, string.format(i18n.get("menu.llm.req_disk_tight"), dl_req, free_disk_gb))
				else
					table.insert(warnings, string.format(i18n.get("menu.llm.req_disk_ok"), dl_req, free_disk_gb))
				end
			end

			return {
				is_critical = is_critical,
				msg = string.format(i18n.get("menu.llm.model_label"), target_model)
					.. "\n\n" .. table.concat(warnings, "\n"),
			}
		end, debug.traceback)
		if prepared_ok ~= true then
			Logger.error(LOG, "Model system-check preparation raised: %s.",
				tostring(prepared))
			cancel_once("System-check preparation failure")
			return settle_before_timer()
		end
		local is_critical = prepared.is_critical
		local msg = prepared.msg
		if not probe_owner_current() then return settle_before_timer() end

		local function deliver_system_check()
			if owner.callback_pending ~= true or owner.callback_consumed == true
				or owner.native_settled ~= true or owner.committed ~= true
				or owner.requirement_registered ~= true then
				return false
			end
			owner.callback_consumed = true
			owner.callback_pending = false
			owner.callback_running = true

			local function run_system_check()
				local function owner_current_or_cancel()
					if owner.authorized ~= true or owner.committed ~= true
						or owner.requirement_registered ~= true then
						return false
					end
					if current_or_cancel() ~= true then return false end
					return owner.authorized == true and owner.committed == true
						and owner.requirement_registered == true
				end
				if not owner_current_or_cancel() then return true end
				local app_ok, hs_app = xpcall(function()
					local application = hs.application
					local app = application and application.get
						and application.get("Hammerspoon") or nil
					if not app and application and application.find then
						app = application.find("Hammerspoon")
					end
					return app
				end, debug.traceback)
				if app_ok ~= true then
					Logger.error(LOG, "Model system-check application lookup raised: %s.",
						tostring(hs_app))
					cancel_once("System-check application lookup failure")
					return false
				end
				if not owner_current_or_cancel() then return true end
				if hs_app and type(hs_app.activate) == "function" then
					pcall(function() hs_app:activate(true) end)
				else
					pcall(hs.focus)
				end
				-- Hammerspoon activation/focus can synchronously re-enter ScriptControl.
				-- Revalidate the exact adopted owner before crossing the dialog boundary.
				if not owner_current_or_cancel() then return true end
				if is_critical then
					pcall(dialog.block_alert, i18n.get("menu.llm.download_failed"), msg, i18n.get("common.close"), nil, "critical")
					cancel_once("System-check cancellation")
					return true
				end
				
				local sep  = string.rep("─", 25)
				local body = sep .. "\n" .. msg .. "\n" .. sep .. "\n\n" .. i18n.get("menu.llm.not_installed_body")
				if repo_info and repo_info ~= "" then
					body = body .. "\n ➜ " .. repo_info
				end
				body = body .. "\n\n" .. i18n.get("menu.llm.launch_download_prompt")

				if not owner_current_or_cancel() then return true end
				local ok_c, choice = pcall(dialog.block_alert,
					string.format(i18n.get("menu.llm.hw_header"), engine_name),
					body, i18n.get("menu.llm.btn_download"), i18n.get("common.cancel"), msg:find("⚠️") and "warning" or "informational")
				if not owner_current_or_cancel() then return true end

				if ok_c and choice == i18n.get("menu.llm.btn_download") then
					-- Clear any stale abort flag from a previous cancelled download so
					-- update_icon() calls in the new download are not silently no-oped.
					if type(deps.clear_download_abort) == "function" then
						local ok_clear, cleared = Logger.callback(LOG,
							"Download-abort reset", deps.clear_download_abort)
						if not ok_clear or cleared ~= true then
							Logger.error(LOG, "Download refused because its prior abort state could not be reset.")
							cancel_once("Download reset failure")
							return false
						end
					end
					if not owner_current_or_cancel() then return true end
					local download_ok, accepted = Logger.callback(LOG,
						"Approved model download", do_download)
					if download_ok ~= true or accepted ~= true then
						cancel_once("Model download dispatch failure")
						return false
					end
				else
					cancel_once("Download prompt cancellation")
				end
				return true
			end

			local callback_ok, callback_result = xpcall(run_system_check,
				debug.traceback)
			owner.committed = false
			if callback_ok ~= true then
				Logger.error(LOG, "Model system-check continuation raised: %s.",
					tostring(callback_result))
				cancel_once("System-check continuation failure")
			end
			owner.callback_running = false
			release_owner()
			return callback_ok == true and callback_result ~= false
		end

		local function timer_callback()
			if owner.callback_consumed == true or owner.callback_pending == true then
				return false
			end
			owner.callback_pending = true
			if owner.installing == true then return true end
			deliver_system_check()
			return true
		end

		local schedule_ok, handle_or_error, timer_committed = xpcall(function()
			return TimerScheduler.after(0.1, timer_callback)
		end, debug.traceback)
		if schedule_ok == true and type(handle_or_error) == "table" then
			owner.handle = handle_or_error
			local observed_ok, observed = xpcall(function()
				return TimerScheduler.onSettled(handle_or_error, function()
					owner.native_settled = true
					deliver_system_check()
					release_owner()
				end)
			end, debug.traceback)
			if observed_ok ~= true or observed ~= true then
				owner.authorized = false
				owner.committed = false
				local cancel_ok, settled = xpcall(function()
					return TimerScheduler.cancel(handle_or_error)
				end, debug.traceback)
				if cancel_ok == true and settled == true then
					owner.native_settled = true
				end
				Logger.error(LOG,
					"Model system-check settlement observation failed: %s.",
					tostring(observed))
				cancel_once("System-check settlement-observer failure")
				owner.installing = false
				release_owner()
				return false
			end
		end
		if schedule_ok ~= true or type(handle_or_error) ~= "table"
			or timer_committed ~= true then
			owner.authorized = false
			owner.committed = false
			if owner.handle ~= nil then
				pause_join()
			else
				owner.native_settled = true
			end
			Logger.error(LOG, "Model system-check timer could not be armed: %s.",
				tostring(schedule_ok and timer_committed or handle_or_error))
			cancel_once("System-check timer refusal")
			owner.installing = false
			release_owner()
			return false
		end
		if owner.authorized ~= true then
			pause_join()
			owner.installing = false
			release_owner()
			return false
		end
		owner.committed = true
		owner.installing = false
		deliver_system_check()
		return true
	end

	-- Inject minimal wrappers into deps to centralize download abort/reset
	do
		deps._orig_update_icon = deps.update_icon
		deps._orig_reset_menubar = deps.reset_menubar
		local download_aborted = false

		deps.mark_download_aborted = function()
			download_aborted = true
			local settled = true
			if type(deps._orig_reset_menubar) == "function" then
				local ok, result = Logger.callback(LOG,
					"Download abort menubar reset", deps._orig_reset_menubar)
				settled = ok and result ~= false and settled
			end
			if type(deps._orig_update_icon) == "function" then
				local ok, result = Logger.callback(LOG,
					"Download abort icon reset", deps._orig_update_icon)
				settled = ok and result ~= false and settled
			end
			return settled
		end

		deps.clear_download_abort = function()
			download_aborted = false
			return true
		end

		deps.update_icon = function(text)
			if download_aborted then return end
			if type(deps._orig_update_icon) == "function" then
				local ok, result = Logger.callback(LOG,
					"Download icon update", deps._orig_update_icon, text)
				return ok and result ~= false
			end
			return true
		end

		deps.reset_menubar = function()
			if type(deps._orig_reset_menubar) == "function" then
				local ok, result = Logger.callback(LOG,
					"Menubar reset", deps._orig_reset_menubar)
				if ok and result ~= false then return true end
			end
			if type(deps._orig_update_icon) == "function" then
				local ok, result = Logger.callback(LOG,
					"Menubar icon fallback reset", deps._orig_update_icon)
				return ok and result ~= false
			end
			return false
		end
	end

	-- Expose global hooks so the download_window can notify us on user cancel or retry.
	package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"] = function()
		if deps and type(deps.mark_download_aborted) == "function" then
			local ok, result = Logger.callback(LOG,
				"Download-window abort hook", deps.mark_download_aborted)
			return ok and result ~= false
		end
		return false
	end
	package.loaded["ui.menu.menu_llm.models_manager.download_retry_hook"] = function()
		if deps and type(deps.clear_download_abort) == "function" then
			local ok, result = Logger.callback(LOG,
				"Download-window retry hook", deps.clear_download_abort)
			return ok and result ~= false
		end
		return false
	end

	local ollama = OllamaMgr.new(deps, presets, get_model_ram_logic)
	local mlx    = MlxMgr.new(deps, presets)
	local requirement_capabilities = {}

	local function get_active()
		local active_backend = llm_mod.get_backend()
		if active_backend == "mlx" then
			return mlx
		end
		return ollama
	end

	local function requirement_opts_for(backend, opts)
		if type(opts) ~= "table" then return opts end
		local translated = {}
		for key, value in pairs(opts) do translated[key] = value end
		local public = opts.requirement_owner
		if public ~= nil then
			local owned = requirement_capabilities[public]
			translated.requirement_owner = type(owned) == "table"
				and owned[backend] or public
		end
		return translated
	end

	function obj.get_presets()
		local active_backend = llm_mod.get_backend()
		if active_backend ~= "mlx" then return presets end
		
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
	
	function obj.get_model_ram(name) 
		local active_backend = llm_mod.get_backend()
		return get_model_ram_logic(name, presets, active_backend == "mlx") 
	end
	
	function obj.get_model_emojis(name) return get_model_info_logic(name, presets).emojis end
	
	--- Gets the actual backend-specific model name.
	--- @param display_name string The display name from _shared/modules/llm/models.json.
	--- @return string The real model name for the active backend.
	function obj.get_actual_model_name(display_name)
		local active_backend = llm_mod.get_backend()
		return get_actual_model_name(display_name, presets, active_backend == "mlx")
	end
	
	--- Checks if a display model name is installed, by converting to real backend name.
	--- @param display_name string The display name from _shared/modules/llm/models.json.
	--- @return boolean True if installed, false otherwise.
	function obj.is_model_installed(display_name)
		local installed = obj.get_installed_models()
		if installed[display_name] then return true end
		
		local active_backend = llm_mod.get_backend()
		local actual_name = get_actual_model_name(display_name, presets, active_backend == "mlx")
		return installed[actual_name] or installed[actual_name .. ":latest"] or false
	end
	
	function obj.get_installed_models()
		local active_backend = llm_mod.get_backend()
		if active_backend == "mlx" then
			return mlx.get_installed_models() or {}
		else
			return ollama.get_installed_models() or {}
		end
	end

	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		local backend = llm_mod.get_backend() == "mlx" and "mlx" or "ollama"
		local manager = backend == "mlx" and mlx or ollama
		return manager.check_requirements(target_model, on_success, on_cancel,
			requirement_opts_for(backend, opts))
	end
	--- Creates one public capability with distinct backend-local provenance.
	--- @param label string Stable owner label.
	--- @return table|nil capability Exact owner token, or nil on refusal.
	function obj.create_requirement_owner(label)
		if type(label) ~= "string" or label == "" then
			Logger.error(LOG, "Requirement-owner creation requires a label.")
			return nil
		end
		if type(mlx.create_requirement_owner) ~= "function"
			or type(ollama.create_requirement_owner) ~= "function" then
			Logger.error(LOG, "Backend requirement-owner factory is unavailable.")
			return nil
		end
		local mlx_owner = mlx.create_requirement_owner(label .. ":mlx")
		local ollama_owner = ollama.create_requirement_owner(label .. ":ollama")
		if mlx_owner == nil or ollama_owner == nil then return nil end
		local public = {}
		requirement_capabilities[public] = {
			mlx = mlx_owner,
			ollama = ollama_owner,
		}
		return public
	end
	--- Joins both backend-local descendants because the active backend can change
	--- after dispatch while the original requirement operation is still live.
	--- @param capability table Opaque token returned by create_requirement_owner().
	--- @return boolean settled True only after every retained task completed.
	--- @return boolean had_tasks True when this call observed an exact task.
	function obj.pause_requirements(capability)
		local owned = requirement_capabilities[capability]
		if type(owned) ~= "table"
			or type(mlx.pause_requirements) ~= "function"
			or type(ollama.pause_requirements) ~= "function" then
			Logger.error(LOG, "Backend requirement pause primitive is unavailable.")
			return false, false
		end
		local mlx_ok, mlx_settled, mlx_had = xpcall(function()
			return mlx.pause_requirements(owned.mlx)
		end, debug.traceback)
		local ollama_ok, ollama_settled, ollama_had = xpcall(function()
			return ollama.pause_requirements(owned.ollama)
		end, debug.traceback)
		if not mlx_ok then
			Logger.error(LOG, "MLX requirement pause raised: %s.", tostring(mlx_settled))
		end
		if not ollama_ok then
			Logger.error(LOG, "Ollama requirement pause raised: %s.", tostring(ollama_settled))
		end
		return mlx_ok == true and mlx_settled == true
			and ollama_ok == true and ollama_settled == true,
			mlx_had == true or ollama_had == true
	end
	function obj.delete_model(name) return get_active().delete_model(name) end
	function obj.force_mlx_check(target_model, on_success, on_cancel, opts)
		return mlx.check_requirements(target_model, on_success, on_cancel,
			requirement_opts_for("mlx", opts))
	end

	--- Reattaches an MLX download discovered by the startup controller.
	--- These lifecycle methods deliberately bypass the active-backend router: the
	--- persisted session file names an MLX process even if preferences changed.
	--- @param session table Persisted MLX download session.
	--- @param opts table|nil Freshness and terminal callbacks.
	--- @return boolean accepted
	function obj.reattach_download(session, opts)
		if type(mlx.reattach_download) ~= "function" then return false end
		return mlx.reattach_download(session, opts)
	end

	--- Reports exact retained MLX reattachment work.
	--- @return boolean active
	function obj.has_reattached_download()
		if type(mlx.has_reattached_download) ~= "function" then return false end
		return mlx.has_reattached_download()
	end

	--- Joins the exact retained MLX reattachment work for PAUSE.
	--- @return boolean settled
	function obj.pause_reattached_download()
		if type(mlx.pause_reattached_download) ~= "function" then return false end
		return mlx.pause_reattached_download()
	end

	--- Resumes only the exact MLX reattachment intent captured before PAUSE.
	--- @param opts table|nil Freshness and terminal callbacks.
	--- @return boolean committed
	function obj.resume_reattached_download(opts)
		if type(mlx.resume_reattached_download) ~= "function" then return false end
		return mlx.resume_reattached_download(opts)
	end
	
	function obj.open_model_source_page(name)
		local active_backend = llm_mod.get_backend()
		if active_backend == "mlx" and type(mlx.open_model_source_page) == "function" then
			return mlx.open_model_source_page(name)
		end
		return false
	end
	
	function obj.prompt_hf_login(on_done)
		if type(mlx.prompt_hf_login) == "function" then
			return mlx.prompt_hf_login(on_done)
		end
		if type(on_done) == "function" then
			Logger.callback(LOG, "Unavailable HuggingFace prompt", on_done, false)
		end
		return false
	end
	
	function obj.stop_mlx_server_if_needed(on_stopped, opts)
		if type(mlx.stop_server_if_needed) ~= "function" then
			Logger.error(LOG, "MLX server stop refused: lifecycle primitive is unavailable.")
			return false
		end
		local ok, accepted = xpcall(function()
			return mlx.stop_server_if_needed(function()
				Logger.info(LOG, "MLX server stopped safely.")
				if type(on_stopped) == "function" then
					local callback_ok, callback_result = Logger.callback(
						LOG, "MLX public stop settlement", on_stopped)
					return callback_ok == true and callback_result ~= false
				end
				return true
			end, opts)
		end, debug.traceback)
		if not ok then
			Logger.error(LOG, "MLX server stop raised before signal acceptance: %s.",
				tostring(accepted))
			return false
		end
		return accepted == true
	end

	return obj
end

return M
