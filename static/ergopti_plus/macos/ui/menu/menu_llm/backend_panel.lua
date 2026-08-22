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
local i18n     = require("infra.i18n")
local ManifestMenu  = require("infra.manifest_menu")
local Logger   = require("infra.logger")

local LOG = "backend_panel"

local mlx_deps_checker    = require("modules.llm.mlx_deps_checker")
local ollama_deps_checker = require("modules.llm.ollama_deps_checker")

-- Survives menu rebuilds so a deferred settlement callback from an older row
-- cannot publish a backend after a newer selection has taken ownership.
local _backend_transition_generation = 0
-- Changes only after the previous debt has settled and a new selection has
-- actually acquired the publication boundary. Reentrant successors invalidate
-- stale callers without letting a refused sibling revoke an in-flight MLX stop.
local _backend_action_generation = 0
-- Opaque setters and preference writers can resume and mutate after a nested
-- action returns. Do not let a sibling acquire while any such callback is on
-- the stack; post-call CAS alone cannot undo the outer callback's tail.
local _backend_boundary_depth = 0
-- A rejected setter may still have changed the runtime identity. Keep the exact
-- prior state/runtime pair until every compensating boundary returns true.
local _backend_recovery_debt = nil

--- Runs an opaque callback while nested backend selections are fenced.
--- @param callback function
--- @param ... any Arguments forwarded to callback.
--- @return boolean ok
--- @return any result
local function run_backend_boundary(callback, ...)
	_backend_boundary_depth = _backend_boundary_depth + 1
	local ok, result = xpcall(callback, debug.traceback, ...)
	_backend_boundary_depth = math.max(0, _backend_boundary_depth - 1)
	return ok, result
end

--- Returns whether a transition still owns the global compensation slot.
--- @param debt table Transition ledger.
--- @return boolean current
local function owns_backend_debt(debt)
	return _backend_recovery_debt == debt
end

--- Invokes one required backend boundary with an exact-true contract.
--- @param label string Boundary label used for diagnostics.
--- @param callback function|nil Required callback.
--- @param ... any Arguments forwarded to callback.
--- @return boolean committed
local function invoke_backend_boundary(label, callback, ...)
	if type(callback) ~= "function" then
		Logger.error(LOG, "%s refused because its callback is unavailable.", label)
		return false
	end
	local ok, result = run_backend_boundary(callback, ...)
	if not ok or result ~= true then
		Logger.error(LOG, "%s refused: %s.", label, tostring(result))
		return false
	end
	return true
end

--- Reads the independently observable core backend identity.
--- @return boolean observed
--- @return string|nil backend
local function read_runtime_backend()
	if type(llm_mod.get_backend) ~= "function" then
		Logger.error(LOG, "Cannot snapshot the core backend: getter is unavailable.")
		return false, nil
	end
	local ok, backend = run_backend_boundary(llm_mod.get_backend)
	if not ok or type(backend) ~= "string" or backend == "" then
		Logger.error(LOG, "Cannot snapshot the core backend: %s.", tostring(backend))
		return false, nil
	end
	return true, backend
end

--- Restores an uncommitted backend transition without losing partial debt.
--- @param debt table Exact transition ledger.
--- @return boolean settled
local function restore_backend_transition(debt)
	if not owns_backend_debt(debt) or debt.settlement_active == true then
		return false
	end
	debt.settlement_active = true
	local failures = {}
	local runtime_failed = false
	debt.state.llm_backend = debt.previous_state

	local function lost_ownership()
		if owns_backend_debt(debt) then return false end
		debt.settlement_active = false
		return true
	end

	local function restore_runtime(label)
		if debt.runtime_touched ~= true then return true end
		local committed = invoke_backend_boundary(label, llm_mod.set_backend,
			debt.previous_runtime)
		if lost_ownership() then return false end
		if committed then
			if runtime_failed ~= true then debt.runtime_pending = false end
			return true
		end
		runtime_failed = true
		debt.runtime_pending = true
		failures[#failures + 1] = label
		return false
	end

	if debt.runtime_pending == true then
		restore_runtime("Backend runtime rollback")
	end
	if debt.persistence_pending == true then
		debt.state.llm_backend = debt.previous_state
		local committed = invoke_backend_boundary(
			"Backend preference rollback", debt.save_prefs)
		if lost_ownership() then return false end
		if committed then
			debt.persistence_pending = false
		else
			failures[#failures + 1] = "preferences"
		end
		debt.state.llm_backend = debt.previous_state
		restore_runtime("Backend post-preference runtime reassertion")
		if lost_ownership() then return false end
	end
	if debt.backend_label_pending == true then
		local committed = invoke_backend_boundary(
			"Backend label rollback", debt.set_backend_label,
			debt.previous_backend_label)
		if lost_ownership() then return false end
		if committed then
			debt.backend_label_pending = false
		else
			failures[#failures + 1] = "backend label"
		end
	end
	if debt.menu_pending == true then
		local committed = invoke_backend_boundary(
			"Backend menu rollback", debt.update_menu)
		if lost_ownership() then return false end
		if committed then
			debt.menu_pending = false
		else
			failures[#failures + 1] = "menu"
		end
	end
	if lost_ownership() then return false end
	debt.state.llm_backend = debt.previous_state
	if runtime_failed then debt.runtime_pending = true end

	if #failures > 0 or debt.runtime_pending == true
		or debt.persistence_pending == true
		or debt.backend_label_pending == true
		or debt.menu_pending == true then
		_backend_recovery_debt = debt
		debt.settlement_active = false
		Logger.error(LOG, "Backend rollback remains unsettled at: %s.",
			table.concat(failures, ", "))
		return false
	end
	if owns_backend_debt(debt) then _backend_recovery_debt = nil end
	debt.settlement_active = false
	return true
end

--- Settles retained backend compensation before any sibling selection.
--- @return boolean settled
local function settle_backend_recovery()
	if _backend_recovery_debt == nil then return true end
	if _backend_recovery_debt.stop_pending == true
		or _backend_recovery_debt.settlement_active == true then
		Logger.warn(LOG, "Backend recovery is already inside a terminal boundary.")
		return false
	end
	Logger.warn(LOG, "Retrying retained backend rollback before a new selection.")
	return restore_backend_transition(_backend_recovery_debt)
end

--- Acquires a new publication attempt after any older debt settles. A callback
--- that reenters during settlement may itself acquire the slot; the generation
--- check then fences this stale caller before it can publish anything.
--- @return integer|nil token
local function acquire_backend_attempt()
	if _backend_boundary_depth > 0 then
		Logger.warn(LOG, "Refusing a reentrant backend selection inside a boundary.")
		return nil
	end
	local observed_generation = _backend_action_generation
	if not settle_backend_recovery() then return nil end
	if observed_generation ~= _backend_action_generation then return nil end
	_backend_action_generation = _backend_action_generation + 1
	return _backend_action_generation
end

--- Returns whether a caller still owns the active publication generation.
--- @param token integer
--- @return boolean current
local function owns_backend_attempt(token)
	return token == _backend_action_generation
end

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
		return invoke_backend_boundary(
			"MLX dependency bootstrap", mlx_deps_checker.check_and_install_deps)
	elseif backend == "ollama" then
		return invoke_backend_boundary(
			"Ollama dependency bootstrap", ollama_deps_checker.check_and_install_deps)
	end
	return false
end





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Builds the full backend-switcher submenu and returns it as two values:
--- the title string for the parent row and the menu table to embed in it.
--- @param ctx table Context with fields: state, keymap, paused, models_mgr,
---   get_display_model_name, switch_model, disable_model, save_prefs, update_menu, WarmupCtrl,
---   reset_llm_health_status.
--- @return string title   Title string for the backend parent menu row.
--- @return table  menu    Populated backend_menu table.
function M.build(ctx)
	local state                 = ctx.state
	local keymap                = ctx.keymap
	local paused                = ctx.paused
	local models_mgr            = ctx.models_mgr
	local get_display_model_name = ctx.get_display_model_name
	local switch_model          = ctx.switch_model
	local disable_model         = ctx.disable_model
	local save_prefs            = ctx.save_prefs
	local update_menu           = ctx.update_menu
	local WarmupCtrl            = ctx.WarmupCtrl
	-- Revokes pending health callbacks whenever the backend identity changes.
	local reset_llm_health_status = ctx.reset_llm_health_status
	local function invalidate_llm_health()
		if type(reset_llm_health_status) ~= "function" then
			Logger.error(LOG, "Cannot invalidate LLM health status: reset hook is unavailable.")
			return false
		end
		local ok, err = run_backend_boundary(reset_llm_health_status)
		if not ok or err ~= true then
			Logger.error(LOG, "Cannot invalidate LLM health status: %s.", tostring(err))
			return false
		end
		return true
	end

	local function transition_is_current(token, debt)
		return owns_backend_attempt(token) and owns_backend_debt(debt)
	end

	local function backend_runtime_label(backend)
		if backend == "mlx" then return "MLX 🚀" end
		if backend == "ollama" then return "Ollama 🦙" end
		if backend == "api" then return "API 🌐" end
		return nil
	end

	local function publish_backend_label(debt, target_backend)
		local target_label = backend_runtime_label(target_backend)
		local previous_label = backend_runtime_label(debt.previous_state)
		local setter = keymap and keymap.set_llm_backend_name or nil
		if type(setter) ~= "function" or target_label == nil or previous_label == nil then
			return invoke_backend_boundary("Backend label publication", setter, target_label)
		end
		debt.set_backend_label = setter
		debt.previous_backend_label = previous_label
		debt.backend_label_pending = true
		return invoke_backend_boundary("Backend label publication", setter, target_label)
	end

	local function publish_backend_menu(debt)
		if type(update_menu) ~= "function" then
			return invoke_backend_boundary("Backend menu publication", update_menu)
		end
		debt.update_menu = update_menu
		debt.menu_pending = true
		return invoke_backend_boundary("Backend menu publication", update_menu)
	end

	local function resolve_backend_model(model_name)
		if type(get_display_model_name) ~= "function" then
			Logger.error(LOG, "Backend model identity resolver is unavailable.")
			return false, nil
		end
		local ok, display_name = run_backend_boundary(
			get_display_model_name, model_name)
		if not ok or type(display_name) ~= "string" then
			Logger.error(LOG, "Backend model identity resolution was refused: %s.",
				tostring(display_name))
			return false, nil
		end
		return true, display_name
	end

	--- Acquires the core identity before any state, preference, or health
	--- publication. The returned debt remains the only authority to compensate.
	local function begin_runtime_transition(target_backend, token)
		local previous_backend = state.llm_backend
		local runtime_ok, previous_runtime = read_runtime_backend()
		if not owns_backend_attempt(token) then return nil end
		if not runtime_ok then return nil end
		local preflight_ok = invoke_backend_boundary(
			"Backend preference preflight", save_prefs)
		if not owns_backend_attempt(token) then return nil end
		if not preflight_ok then
			state.llm_backend = previous_backend
			return nil
		end
		state.llm_backend = previous_backend

		local debt = {
			state = state,
			previous_state = previous_backend,
			previous_runtime = previous_runtime,
			runtime_touched = true,
			runtime_pending = true,
			persistence_pending = false,
			save_prefs = save_prefs,
			token = token,
		}
		_backend_recovery_debt = debt
		local runtime_committed = invoke_backend_boundary(
			"Backend runtime publication", llm_mod.set_backend, target_backend)
		if not transition_is_current(token, debt) then return nil end
		if not runtime_committed then
			restore_backend_transition(debt)
			return nil
		end
		return debt
	end

	--- Publishes the state and preferences for an already acquired core identity.
	local function finish_backend_transition(target_backend, token, debt, on_committed)
		if not transition_is_current(token, debt) then return false end
		state.llm_backend = target_backend
		debt.persistence_pending = true
		local persistence_committed = invoke_backend_boundary(
			"Backend preference publication", save_prefs)
		if not transition_is_current(token, debt) then return false end
		if not persistence_committed then
			restore_backend_transition(debt)
			return false
		end
		debt.persistence_pending = false

		local current_ok, current_runtime = read_runtime_backend()
		if not transition_is_current(token, debt) then return false end
		if current_ok ~= true or current_runtime ~= target_backend
			or state.llm_backend ~= target_backend then
			debt.persistence_pending = true
			restore_backend_transition(debt)
			return false
		end
		local health_invalidated = invalidate_llm_health()
		if not transition_is_current(token, debt) then return false end
		if not health_invalidated then
			debt.persistence_pending = true
			restore_backend_transition(debt)
			return false
		end
		current_ok, current_runtime = read_runtime_backend()
		if not transition_is_current(token, debt) then return false end
		if current_ok ~= true or current_runtime ~= target_backend
			or state.llm_backend ~= target_backend then
			debt.persistence_pending = true
			restore_backend_transition(debt)
			return false
		end
		if type(on_committed) ~= "function" then
			Logger.error(LOG, "Backend successor transaction is unavailable.")
			debt.persistence_pending = true
			restore_backend_transition(debt)
			return false
		end
		local successor_committed = invoke_backend_boundary(
			"Backend successor transaction", on_committed, debt)
		if not transition_is_current(token, debt) then return false end
		if not successor_committed then
			debt.persistence_pending = true
			restore_backend_transition(debt)
			return false
		end
		debt.runtime_pending = false
		if owns_backend_debt(debt) then _backend_recovery_debt = nil end
		return true
	end

	local function publish_backend(target_backend, on_committed)
		local token = acquire_backend_attempt()
		if token == nil then return false end
		local debt = begin_runtime_transition(target_backend, token)
		if debt == nil then return false end
		return finish_backend_transition(target_backend, token, debt, on_committed)
	end

	--- Acquires the target core identity before stopping MLX, then retains that
	--- transaction until listener absence is proven. Sibling selections cannot
	--- settle or supersede a server stop whose terminal callback is still pending.
	local function leave_mlx(target_backend, on_committed)
		local token = acquire_backend_attempt()
		if token == nil then return false end
		local debt = begin_runtime_transition(target_backend, token)
		if debt == nil then return false end
		if type(models_mgr.stop_mlx_server_if_needed) ~= "function" then
			Logger.error(LOG, "Cannot switch MLX to %s: exact stop primitive is unavailable.",
				tostring(target_backend))
			restore_backend_transition(debt)
			return false
		end
		_backend_transition_generation = _backend_transition_generation + 1
		local generation = _backend_transition_generation
		local stop_returned = false
		local terminal_buffered = false
		local terminal_result = nil
		debt.stop_pending = true

		local function finish_terminal()
			if generation ~= _backend_transition_generation then return false end
			if not transition_is_current(token, debt) then return false end
			debt.stop_pending = false
			Logger.debug(LOG, "MLX server cleanup proved before %s publication.",
				tostring(target_backend))
			if not finish_backend_transition(target_backend, token, debt, on_committed) then
				Logger.error(LOG, "Cannot publish backend %s after MLX settlement.",
					tostring(target_backend))
				return false
			end
			return true
		end

		local ok_stop, accepted = run_backend_boundary(function()
			return models_mgr.stop_mlx_server_if_needed(function()
				terminal_buffered = true
				if not stop_returned then return true end
				terminal_result = finish_terminal()
				return terminal_result
			end, { kind = "backend" })
		end)
		stop_returned = true
		if not transition_is_current(token, debt) then return false end
		if not ok_stop or accepted ~= true then
			Logger.error(LOG, "Cannot switch MLX to %s: stop signal was refused (%s).",
				tostring(target_backend), tostring(ok_stop and accepted or accepted))
			if terminal_buffered then return finish_terminal() end
			debt.stop_pending = false
			restore_backend_transition(debt)
			return false
		end
		if terminal_buffered then return finish_terminal() end
		return true
	end

	-- Title reflects current active backend
	local backend_title_str = i18n.get("menu.llm.backend_title")
	if state.llm_backend == "mlx" then     backend_title_str = backend_title_str .. "MLX 🚀"
	elseif state.llm_backend == "ollama" then backend_title_str = backend_title_str .. "Ollama 🦙"
	elseif state.llm_backend == "api" then   backend_title_str = backend_title_str .. "API 🌐"
	else                                     backend_title_str = backend_title_str .. i18n.get("menu.llm.backend_unknown") end

	local rows = {}


	-- =====================================================
	-- ===== 1.1) MLX entry =====
	-- =====================================================

	table.insert(rows, {
		label    = "MLX 🚀 — " .. i18n.get("menu.llm.backend_mlx_suffix"),
		checked  = (state.llm_backend == "mlx"),
		disabled = (not is_apple_silicon()) or paused or nil,
		action       = not paused and function()
			if state.llm_backend ~= "mlx" then
				Logger.info(LOG, "Activating MLX backend…")
				local committed = publish_backend("mlx", function(debt)
					if check_backend_deps("mlx") ~= true then return false end
					if not publish_backend_label(debt, "mlx") then return false end
					local model_ok, target_model = resolve_backend_model(
						state.llm_model_mlx or llm_mod.DEFAULT_STATE.llm_model_mlx or "")
					if not model_ok then return false end
					if target_model ~= "" then
						if not invoke_backend_boundary(
							"MLX model successor", switch_model, target_model) then
							return false
						end
					elseif not invoke_backend_boundary(
						"MLX No Model successor", disable_model) then
						return false
					end
					return true
				end)
				if committed then
					pcall(os.execute, "pkill -f '[o]llama serve' 2>/dev/null || true")
				end
				return committed
			end
		end or nil
	})


	-- =====================================================
	-- ===== 1.2) Ollama entry =====
	-- =====================================================

	table.insert(rows, {
		label    = "Ollama 🦙 — " .. i18n.get("menu.llm.backend_ollama_suffix"),
		checked  = (state.llm_backend == "ollama"),
		disabled = paused or nil,
		action       = not paused and function()
			if state.llm_backend ~= "ollama" then
				Logger.info(LOG, "Deactivating MLX backend (switching to Ollama)…")
				local function finish_ollama_switch(debt)
					if check_backend_deps("ollama") ~= true then return false end
					if not publish_backend_label(debt, "ollama") then return false end
					local model_ok, target_model = resolve_backend_model(
						state.llm_model_ollama or llm_mod.DEFAULT_STATE.llm_model_ollama or "")
					if not model_ok then return false end
					if target_model ~= "" then
						if not invoke_backend_boundary(
							"Ollama model successor", switch_model, target_model) then
							return false
						end
					elseif not invoke_backend_boundary(
						"Ollama No Model successor", disable_model) then
						return false
					end
					return true
				end
				if state.llm_backend == "mlx" then
					return leave_mlx("ollama", finish_ollama_switch)
				end
				return publish_backend("ollama", finish_ollama_switch)
			end
		end or nil
	})


	-- =====================================================
	-- ===== 1.3) Remote API entry =====
	-- =====================================================

	-- The actual entry CRUD (provider, URL, token, model) lives in api_panel.lua.
	-- This entry only flips the backend so the prediction engine routes through
	-- ApiRemote on the next request.
	table.insert(rows, {
		label    = "API 🌐 — " .. i18n.get("menu.llm.backend_api_suffix"),
		checked  = (state.llm_backend == "api"),
		disabled = paused or nil,
		action       = not paused and function()
			if state.llm_backend ~= "api" then
				Logger.info(LOG, "Activating remote API backend…")
				local function finish_api_switch(debt)
					if not publish_backend_label(debt, "api") then return false end
					if not invoke_backend_boundary(
						"API entries reload", llm_mod.load_api_entries) then
						return false
					end
					if not publish_backend_menu(debt) then return false end
					if not invoke_backend_boundary(
						"API backend warmup", WarmupCtrl and WarmupCtrl.warmup,
						"api_backend_switch") then
						return false
					end
					-- The old local server is expendable only after every exact target
					-- successor has committed.
					pcall(os.execute, "pkill -f '[o]llama serve' 2>/dev/null || true")
					return true
				end
				if state.llm_backend == "mlx" then
					return leave_mlx("api", finish_api_switch)
				end
				return publish_backend("api", finish_api_switch)
			end
		end or nil
	})

	return backend_title_str, ManifestMenu.render_rows(rows, "llm_backend")
end

return M
