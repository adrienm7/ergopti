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

local mlx_deps_checker    = require("modules.llm.mlx_deps_checker")
local ollama_deps_checker = require("modules.llm.ollama_deps_checker")
-- Single source of truth for the MLX server port — used to free the right socket
-- when switching away from MLX. Never hardcode the port here.
local ApiMlx              = require("modules.llm.api_mlx")

--- Returns whether the current machine has Apple Silicon.
--- Lazily evaluated once so the shell call does not repeat on every menu open.
--- Single source of truth for Apple-Silicon detection across the LLM menu tree
--- (F-MED-4): exported as M.is_apple_silicon so ui/menu/menu_llm/init.lua's
--- DEFAULT_STATE.llm_backend seed reads the SAME uname-based detector instead
--- of duplicating a filesystem-existence heuristic (hs.fs.attributes("/opt/homebrew"))
--- that is wrong on a fresh arm64 Mac with no Homebrew installed yet.
local _is_apple_silicon = nil
local function is_apple_silicon()
	if _is_apple_silicon == nil then
		local ok, out = pcall(function() return hs.execute("uname -m") end)
		_is_apple_silicon = ok and (out or ""):find("arm64") ~= nil
	end
	return _is_apple_silicon
end
M.is_apple_silicon = is_apple_silicon

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
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- ==============================

--- Builds the full backend-switcher submenu and returns it as two values:
--- the title string for the parent row and the menu table to embed in it.
--- @param ctx table Context with fields: state, keymap, paused, models_mgr,
---   get_display_model_name, switch_model, save_prefs, update_menu, WarmupCtrl,
---   reset_llm_health_status (optional).
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
	-- Resets the shared _llm_health_status flag so a prior MLX/Ollama reading
	-- does not leak into the API backend's status-dot display (F-LOW-6).
	local reset_llm_health_status = ctx.reset_llm_health_status

	-- Title reflects current active backend
	local backend_title_str = i18n.get("menu.llm.backend_title")
	if state.llm_backend == "mlx" then     backend_title_str = backend_title_str .. "MLX 🚀"
	elseif state.llm_backend == "ollama" then backend_title_str = backend_title_str .. "Ollama 🦙"
	elseif state.llm_backend == "api" then   backend_title_str = backend_title_str .. "API 🌐"
	else                                     backend_title_str = backend_title_str .. i18n.get("menu.llm.backend_unknown") end

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
					-- switch_model already calls models_mgr.check_requirements, which starts
					-- the MLX server. A second redundant check 0.5 s later would race it and
					-- try to spawn a second server process against the same port.
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
				-- Hard kill just in case — target the configured MLX port (via the
				-- api_mlx getter, the single source of truth) so switching backends
				-- frees the right socket.
				os.execute("pids=$(lsof -tiTCP:" .. ApiMlx.get_port() .. " -sTCP:LISTEN 2>/dev/null); [ -n \"$pids\" ] && kill -9 $pids 2>/dev/null")
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
				-- probe_llm_health() intentionally skips the API backend (no local
				-- server to probe there); without resetting it here, a prior
				-- MLX/Ollama reading would leak into the API backend's status
				-- dot until the next full backend round-trip (F-LOW-6).
				if type(reset_llm_health_status) == "function" then pcall(reset_llm_health_status) end
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
