--- ui/menu/menu_llm/backend_panel.lua

--- ==============================================================================
--- MODULE: LLM Backend Panel
--- DESCRIPTION:
--- Builds the backend-switcher submenu (MLX, Ollama, API) for the LLM tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Isolated panel: all backend-switching logic lives here so init.lua stays
---    focused on top-level wiring; each backend entry is self-contained.
--- 2. Non-blocking transitions: on-demand deps checks fire in the background and
---    are idempotent, so switching backends never blocks the menu.
--- ==============================================================================

local M = {}

local llm_mod  = require("modules.llm")
local i18n     = require("lib.i18n")
local Logger   = require("lib.logger")

local LOG = "backend_panel"

local mlx_deps_checker    = require("lib.mlx_deps_checker")
local ollama_deps_checker = require("lib.ollama_deps_checker")

--- Returns whether the current machine has Apple Silicon.
--- Lazily evaluated once so the shell call does not repeat on every menu open.
local _is_apple_silicon = nil
local function is_apple_silicon()
	if _is_apple_silicon == nil then
		local ok, out = pcall(function() return hs.execute("uname -m") end)
		_is_apple_silicon = ok and (out or ""):find("arm64") ~= nil
	end
	return _is_apple_silicon
end

--- Triggers the deps checker matching the given backend name.
--- Safe to call repeatedly — each script is hash-gated and silent on the fast path.
--- @param backend string Either "mlx" or "ollama".
local function check_backend_deps(backend)
	if backend == "mlx" then
		pcall(mlx_deps_checker.check_and_install_deps)
	elseif backend == "ollama" then
		pcall(ollama_deps_checker.check_and_install_deps)
	end
end




-- ==============================
-- ==============================
-- ======= 1/ Public API =======
-- ==============================
-- ==============================

--- Builds the full backend-switcher submenu and returns it as two values:
--- the title string for the parent row and the menu table to embed in it.
--- @param ctx table Context with fields: state, keymap, paused, models_mgr,
---   get_display_model_name, switch_model, save_prefs, update_menu, WarmupCtrl.
--- @return string title   Title string for the backend parent menu row.
--- @return table  menu    Populated backend_menu table.
function M.build(ctx)
	local state                 = ctx.state
	local keymap                = ctx.keymap
	local paused                = ctx.paused
	local models_mgr            = ctx.models_mgr
	local get_display_model_name = ctx.get_display_model_name
	local switch_model          = ctx.switch_model
	local save_prefs            = ctx.save_prefs
	local update_menu           = ctx.update_menu
	local WarmupCtrl            = ctx.WarmupCtrl

	-- Title reflects current active backend
	local backend_title_str = "Moteur IA (Backend) : "
	if state.llm_backend == "mlx" then     backend_title_str = backend_title_str .. "MLX 🚀"
	elseif state.llm_backend == "ollama" then backend_title_str = backend_title_str .. "Ollama 🦙"
	elseif state.llm_backend == "api" then   backend_title_str = backend_title_str .. "API 🌐"
	else                                     backend_title_str = backend_title_str .. "Inconnu" end

	local backend_menu = {}


	-- =====================================================
	-- ===== 1.1) MLX entry =====
	-- =====================================================

	table.insert(backend_menu, {
		title    = "MLX 🚀 — " .. i18n.get("menu.llm.backend_mlx_suffix"),
		checked  = (state.llm_backend == "mlx"),
		disabled = (not is_apple_silicon()) or paused or nil,
		fn       = not paused and function()
			if state.llm_backend ~= "mlx" then
				Logger.info(LOG, "Activating MLX backend…")
				state.llm_backend = "mlx"
				llm_mod.set_backend("mlx")
				-- On-demand deps check: bootstrap the MLX venv if the user just
				-- switched and the engine is not ready — silent on the fast path.
				check_backend_deps("mlx")

				if keymap and type(keymap.set_llm_backend_name) == "function" then
					pcall(keymap.set_llm_backend_name, "MLX 🚀")
				end

				-- Kill any stray ollama to free RAM
				os.execute("pkill -f '[o]llama serve' 2>/dev/null || true")

				local target_model = get_display_model_name(state.llm_model_mlx or llm_mod.DEFAULT_STATE.llm_model_mlx or "")
				if target_model and target_model ~= "" then
					switch_model(target_model)
					-- Force server to start to be certain
					if type(models_mgr.force_mlx_check) == "function" then
						hs.timer.doAfter(0.5, function()
							models_mgr.force_mlx_check(target_model, nil, nil, { silent_notifications = true })
						end)
					end
				else
					state.llm_model = ""
					if keymap and type(keymap.set_llm_model) == "function" then
						pcall(keymap.set_llm_model, "")
					end
					if keymap and type(keymap.set_llm_display_model_name) == "function" then
						pcall(keymap.set_llm_display_model_name, "")
					end
					save_prefs()
					update_menu()
				end
			end
		end or nil
	})


	-- =====================================================
	-- ===== 1.2) Ollama entry =====
	-- =====================================================

	table.insert(backend_menu, {
		title    = "Ollama 🦙 — " .. i18n.get("menu.llm.backend_ollama_suffix"),
		checked  = (state.llm_backend == "ollama"),
		disabled = paused or nil,
		fn       = not paused and function()
			if state.llm_backend ~= "ollama" then
				Logger.info(LOG, "Deactivating MLX backend (switching to Ollama)…")
				state.llm_backend = "ollama"
				llm_mod.set_backend("ollama")
				-- On-demand deps check — silent on the fast path.
				check_backend_deps("ollama")
				if models_mgr.stop_mlx_server_if_needed then models_mgr.stop_mlx_server_if_needed() end
				-- Hard kill just in case
				os.execute("pids=$(lsof -tiTCP:8080 -sTCP:LISTEN 2>/dev/null); [ -n \"$pids\" ] && kill -9 $pids 2>/dev/null")
				Logger.debug(LOG, "MLX server stopped.")

				if keymap and type(keymap.set_llm_backend_name) == "function" then
					pcall(keymap.set_llm_backend_name, "Ollama 🦙")
				end

				local target_model = get_display_model_name(state.llm_model_ollama or llm_mod.DEFAULT_STATE.llm_model_ollama or "")
				if target_model and target_model ~= "" then
					switch_model(target_model)
				else
					state.llm_model = ""
					if keymap and type(keymap.set_llm_model) == "function" then
						pcall(keymap.set_llm_model, "")
					end
					if keymap and type(keymap.set_llm_display_model_name) == "function" then
						pcall(keymap.set_llm_display_model_name, "")
					end
					save_prefs()
					update_menu()
				end
			end
		end or nil
	})


	-- =====================================================
	-- ===== 1.3) Remote API entry =====
	-- =====================================================

	-- The actual entry CRUD (provider, URL, token, model) lives in api_panel.lua.
	-- This entry only flips the backend so the prediction engine routes through
	-- ApiRemote on the next request.
	table.insert(backend_menu, {
		title    = "API 🌐 — " .. i18n.get("menu.llm.backend_api_suffix"),
		checked  = (state.llm_backend == "api"),
		disabled = paused or nil,
		fn       = not paused and function()
			if state.llm_backend ~= "api" then
				Logger.info(LOG, "Activating remote API backend…")
				state.llm_backend = "api"
				llm_mod.set_backend("api")
				-- Kill any local server that would burn RAM / GPU for nothing
				if models_mgr.stop_mlx_server_if_needed then pcall(models_mgr.stop_mlx_server_if_needed) end
				os.execute("pkill -f '[o]llama serve' 2>/dev/null || true")
				if keymap and type(keymap.set_llm_backend_name) == "function" then
					pcall(keymap.set_llm_backend_name, "API 🌐")
				end
				-- Reload persisted entries (no-op when already in memory), then ping
				-- the active one so the health indicator reflects reality.
				if type(llm_mod.load_api_entries) == "function" then pcall(llm_mod.load_api_entries) end
				WarmupCtrl.warmup("api_backend_switch")
				save_prefs()
				update_menu()
			end
		end or nil
	})

	return backend_title_str, backend_menu
end

return M
