--- ui/menu/menu_llm/model_switcher.lua

--- ==============================================================================
--- MODULE: LLM Model Switcher
--- DESCRIPTION:
--- Encapsulates all model-switching logic for the LLM tray menu: power-level
--- inference, profile recommendation, profile mismatch detection, and the
--- guarded async switch flow.
---
--- FEATURES & RATIONALE:
--- 1. Power inference: derives a model's "power level" from its parameter count
---    and MoE topology without any hard-coded model names.
--- 2. Profile recommendation: maps power level to the optimal profile and offers
---    a dialog so the user can accept or decline the change.
--- 3. MLX lock: disables predictions during a server restart so stale callbacks
---    never reach a dead port.
--- 4. Zero UI coupling: no menu-building code lives here — only domain logic and
---    side-effect calls through injected deps, making this testable in isolation.
--- ==============================================================================

local M = {}

local llm_mod       = require("modules.llm")
local i18n          = require("lib.i18n")
local Logger        = require("lib.logger")
local dialog        = require("lib.dialog_util")
local notifications = require("lib.notifications")

local LOG = "model_switcher"

-- Minimum parameter thresholds (in billions) that trigger a profile upgrade.
local MODEL_ADVANCED_PARAMS_THRESHOLD_B    = 2
local MODEL_BATCH_PARAMS_THRESHOLD_B       = 4

-- Numeric power levels — higher means the model can handle more complex prompts.
local PROFILE_POWER_RAW            = 0
local PROFILE_POWER_BASIC          = 1
local PROFILE_POWER_ADVANCED       = 2
local PROFILE_POWER_BATCH_ADVANCED = 3

local PROFILE_POWER_LEVELS = {
	raw           = PROFILE_POWER_RAW,
	basic         = PROFILE_POWER_BASIC,
	advanced      = PROFILE_POWER_ADVANCED,
	batch_advanced = PROFILE_POWER_BATCH_ADVANCED,
	batch         = PROFILE_POWER_ADVANCED,
	parallel      = PROFILE_POWER_BASIC,
}




-- ==============================
-- ==============================
-- ======= 1/ Public API =======
-- ==============================
-- ==============================

--- Creates and returns a model-switcher instance bound to the given context.
--- @param ctx table Context with fields:
---   state         table    Shared preference state.
---   models_mgr    table    Models manager instance.
---   keymap        table    Keymap module (optional).
---   save_prefs    function Persists state to disk.
---   update_menu   function Redraws the tray menu.
--- @return table Instance with fields: switch_model, set_llm_profile,
---   apply_recommended_prompt_profile, get_display_model_name, get_model_power_level.
function M.new(ctx)
	local state       = ctx.state
	local models_mgr  = ctx.models_mgr
	local keymap      = ctx.keymap
	local save_prefs  = ctx.save_prefs
	local update_menu = ctx.update_menu

	-- Monotonically-increasing token so stale async callbacks from a previous
	-- switch attempt are silently discarded when a new switch is initiated.
	local req_token = 0


	-- =====================================================
	-- ===== 1.1) Model parameter helpers =====
	-- =====================================================

	--- Extracts and normalises the effective parameter counts from a model info table.
	--- @param info table Model info dict (params, params_total, params_active, is_moe).
	--- @return number effective_params  Active params (or total when not MoE).
	--- @return boolean is_moe           True when the topology is Mixture-of-Experts.
	--- @return number active_params     Raw active parameter count.
	--- @return number total_params      Raw total parameter count.
	local function get_effective_model_params(info)
		if type(info) ~= "table" then return 0, false, 0, 0 end
		local total_params  = tonumber(info.params_total) or tonumber(info.params) or 0
		local active_params = tonumber(info.params_active) or total_params
		if active_params <= 0 then active_params = total_params end
		local is_moe = info.is_moe == true
			or (total_params > 0 and active_params > 0 and active_params < total_params)
		local effective_params = is_moe and active_params or total_params
		return effective_params, is_moe, active_params, total_params
	end

	--- Builds a set of lowercased model names from the preset tree.
	--- @param presets table Preset tree (array of providers).
	--- @return table Set keyed by lowercased name.
	local function build_model_name_set(presets)
		local names = {}
		if type(presets) ~= "table" then return names end
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					local n = m and m.name
					if type(n) == "string" and n ~= "" then names[n:lower()] = true end
				end
			end
		end
		return names
	end

	--- Infers whether a model is a completion model by checking for -it / -base suffixes
	--- relative to counterpart names that exist in the preset tree.
	--- Returns true (instruction-tuned/chat), false (base/completion), or nil (unknown).
	--- @param model_name string Model display name.
	--- @return boolean|nil
	local function infer_completion_from_name_pairs(model_name)
		if type(model_name) ~= "string" or model_name == "" then return nil end
		local presets = models_mgr.get_presets()
		local names   = build_model_name_set(presets)
		local name_l  = model_name:lower()
		local base_no_it = name_l:gsub("[-_]it$", "")
		if base_no_it ~= name_l and names[base_no_it] then return false end
		if names[name_l .. "-it"] or names[name_l .. "_it"] then return true end
		local base_no_base = name_l:gsub("[-_]base$", "")
		if base_no_base ~= name_l and names[base_no_base] then return true end
		if names[name_l .. "-base"] or names[name_l .. "_base"] then return false end
		return nil
	end

	--- Maps the legacy/aliased profile id to its canonical power-level key.
	--- @param profile_id string Raw profile id from state.
	--- @return string Canonical key suitable for PROFILE_POWER_LEVELS lookup.
	local function normalize_profile_power_key(profile_id)
		if type(profile_id) ~= "string" then return "basic" end
		if profile_id == "raw" or profile_id == "base_completion" then return "raw" end
		if profile_id == "basic" then return "basic" end
		if profile_id == "advanced" then return "advanced" end
		if profile_id == "batch_advanced" then return "batch_advanced" end
		if profile_id:match("^batch_") or profile_id == "batch" then return "batch" end
		if profile_id:match("^parallel_") or profile_id == "parallel" then return "parallel" end
		return "basic"
	end

	--- Returns the currently active profile id, collapsing legacy aliases.
	--- @return string Normalised profile id.
	local function get_normalized_active_profile_id()
		local pid = state.llm_active_profile or "basic"
		if pid == "parallel" or pid == "parallel_simple" then return "basic" end
		if pid == "batch"    or pid == "batch_simple"    then return "batch_advanced" end
		if pid == "parallel_advanced" then return "advanced" end
		if pid == "base_completion"   then return "raw" end
		return pid
	end


	-- =====================================================
	-- ===== 1.2) Power level & profile recommendation =====
	-- =====================================================

	--- Computes the numeric power level for a model.
	--- @param model_name string Model display name.
	--- @return number Power level constant.
	local function get_model_power_level(model_name)
		if type(model_name) ~= "string" or model_name == "" then return PROFILE_POWER_BASIC end
		local info              = models_mgr.get_model_info(model_name) or {}
		local effective_params  = (get_effective_model_params(info))
		local inferred          = infer_completion_from_name_pairs(model_name)
		local is_completion     = (inferred ~= nil) and inferred or (info.type == "completion")
		if is_completion then return PROFILE_POWER_RAW end
		if effective_params >= MODEL_BATCH_PARAMS_THRESHOLD_B    then return PROFILE_POWER_BATCH_ADVANCED end
		if effective_params >= MODEL_ADVANCED_PARAMS_THRESHOLD_B then return PROFILE_POWER_ADVANCED end
		return PROFILE_POWER_BASIC
	end

	--- Returns the recommended profile id and its power level for a model.
	--- @param model_name string Model display name.
	--- @return string  rec_profile  Recommended profile id.
	--- @return number  power_level  Numeric power level of that profile.
	local function get_recommended_profile_info(model_name)
		if type(model_name) ~= "string" or model_name == "" then
			return "basic", PROFILE_POWER_BASIC
		end
		local info             = models_mgr.get_model_info(model_name) or {}
		local effective_params = (get_effective_model_params(info))
		local inferred         = infer_completion_from_name_pairs(model_name)
		local is_completion    = (inferred ~= nil) and inferred or (info.type == "completion")
		local rec = "basic"
		if is_completion then
			rec = "raw"
		elseif effective_params >= MODEL_BATCH_PARAMS_THRESHOLD_B then
			rec = "batch_advanced"
		elseif effective_params >= MODEL_ADVANCED_PARAMS_THRESHOLD_B then
			rec = "advanced"
		end
		return rec, PROFILE_POWER_LEVELS[rec] or PROFILE_POWER_BASIC
	end

	--- Returns the i18n-localised label for a profile id.
	--- @param profile_id string Profile id.
	--- @return string Human-readable label.
	local function get_profile_label(profile_id)
		local n = tonumber(state.llm_num_predictions) or llm_mod.DEFAULT_STATE.llm_num_predictions
		local s = n > 1 and "s" or ""
		local labels = {
			raw              = i18n.get("llm.profile.raw.label"),
			basic            = i18n.get("llm.profile.basic.label"),
			advanced         = i18n.get("llm.profile.advanced.label"),
			batch_advanced   = string.format(i18n.get("llm.profile.batch_advanced.label"), n, s),
			parallel_simple  = i18n.get("llm.profile.basic.label"),
			parallel         = i18n.get("llm.profile.basic.label"),
			batch_simple     = i18n.get("llm.profile.basic.label"),
			batch            = string.format(i18n.get("llm.profile.batch_advanced.label"), n, s),
			parallel_advanced = i18n.get("llm.profile.advanced.label"),
			base_completion  = i18n.get("llm.profile.raw.label"),
		}
		return labels[profile_id] or tostring(profile_id)
	end


	-- =====================================================
	-- ===== 1.3) Display name resolution =====
	-- =====================================================

	--- Resolves a backend-native model name to its human-readable display name.
	--- @param model_name string Backend model name or display name.
	--- @param preset_list table|nil Optional pre-fetched preset tree.
	--- @return string Display name (falls back to model_name on no match).
	local function get_display_model_name(model_name, preset_list)
		if type(model_name) ~= "string" or model_name == "" then return model_name end
		preset_list = type(preset_list) == "table" and preset_list or models_mgr.get_presets()
		if type(preset_list) ~= "table" then return model_name end
		for _, provider in ipairs(preset_list) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					local dn = m.name or m.repo
					if type(dn) == "string" then
						if dn == model_name then return dn end
						if models_mgr.get_actual_model_name(dn) == model_name then return dn end
					end
				end
			end
		end
		return model_name
	end


	-- =====================================================
	-- ===== 1.4) Guarded requirements check =====
	-- =====================================================

	--- Wraps models_mgr.check_requirements with a generation counter so stale
	--- callbacks from superseded switch attempts are silently discarded.
	--- @param model_name string Model to check.
	--- @param on_ok function Callback when requirements are satisfied.
	--- @param on_fail function Callback when requirements cannot be met.
	--- @param opts table|nil Options forwarded to check_requirements.
	local function guarded_check_requirements(model_name, on_ok, on_fail, opts)
		req_token = req_token + 1
		local my_token = req_token
		models_mgr.check_requirements(model_name,
			function(...)
				if my_token ~= req_token then
					Logger.debug(LOG, string.format("Stale ok-callback discarded (model=%s).", tostring(model_name)))
					return
				end
				if type(on_ok) == "function" then on_ok(...) end
			end,
			function(...)
				if my_token ~= req_token then
					Logger.debug(LOG, string.format("Stale fail-callback discarded (model=%s).", tostring(model_name)))
					return
				end
				if type(on_fail) == "function" then on_fail(...) end
			end,
			opts)
	end


	-- =====================================================
	-- ===== 1.5) Profile management =====
	-- =====================================================

	--- Warns when the selected profile demands significantly more than the model can give.
	--- @param selected_profile_id string Profile the user just activated.
	--- @param model_name string Currently active model.
	local function check_profile_power_mismatch(selected_profile_id, model_name)
		local model_power    = tonumber(state.llm_model_power) or PROFILE_POWER_BASIC
		local selected_power = PROFILE_POWER_LEVELS[normalize_profile_power_key(selected_profile_id)] or PROFILE_POWER_BASIC
		Logger.debug(LOG, string.format(
			"Profile power check: selected=%d vs model=%d.", selected_power, model_power))
		-- One level of mismatch is tolerated (user may intentionally experiment)
		if selected_power > model_power + 1 then
			local rec_profile, _ = get_recommended_profile_info(model_name)
			local msg = string.format(
				i18n.get("menu.llm.profile_power_warning"),
				get_profile_label(rec_profile),
				get_profile_label(selected_profile_id))
			pcall(notifications.notify, msg, nil, "warning")
		end
	end

	--- Activates a profile and triggers a power-mismatch check.
	--- @param profile_id string Profile to activate.
	local function set_llm_profile(profile_id)
		if type(profile_id) ~= "string" then return end
		state.llm_active_profile = profile_id
		llm_mod.set_active_profile(profile_id)
		check_profile_power_mismatch(profile_id, state.llm_model)
		save_prefs(); update_menu()
	end

	--- Offers to switch to the recommended profile when it differs from the current one.
	--- Completion models are switched silently; chat models prompt the user.
	--- @param model_name string The newly selected model name.
	--- @param opts table|nil Optional { dialog_title, force_dialog }.
	local function apply_recommended_prompt_profile(model_name, opts)
		if type(model_name) ~= "string" or model_name == "" then return end
		opts = type(opts) == "table" and opts or {}

		local rec_profile, _   = get_recommended_profile_info(model_name)
		local rec_label        = get_profile_label(rec_profile)
		local model_info       = models_mgr.get_model_info(model_name) or {}
		local inferred         = infer_completion_from_name_pairs(model_name)
		local is_completion    = (inferred ~= nil) and inferred or (model_info.type == "completion")
		local _, is_moe, active_params, total_params = get_effective_model_params(model_info)
		local display_name     = get_display_model_name(model_name)

		-- Build a human-readable power description for the dialog body
		local power_desc
		if is_completion then
			power_desc = "Profil de puissance détecté : complétion brute"
		elseif is_moe and active_params > 0 and total_params > 0 then
			power_desc = string.format("Puissance détectée (MoE) : %gB actifs / %gB total", active_params, total_params)
		elseif active_params > 0 then
			power_desc = string.format("Puissance détectée : %gB", active_params)
		else
			power_desc = "Puissance détectée : inconnue"
		end

		local cur_profile = get_normalized_active_profile_id()
		local cur_label   = get_profile_label(cur_profile)
		Logger.debug(LOG, string.format("Recommended profile: %s (currently: %s).", rec_profile, cur_profile))

		if cur_profile ~= rec_profile then
			if is_completion then
				-- Completion models have exactly one correct profile — switch silently.
				Logger.info(LOG, string.format(
					"Completion model: silently switching profile %s → %s.", cur_profile, rec_profile))
				state.llm_active_profile = rec_profile
				llm_mod.set_active_profile(rec_profile)
				save_prefs(); update_menu()
			else
				local title = type(opts.dialog_title) == "string"
					and opts.dialog_title
					or  i18n.get("menu.llm.model_change_title")
				Logger.debug(LOG, "Displaying profile suggestion dialog…")
				local msg = string.format(
					i18n.get("menu.llm.profile_change_msg"),
					display_name, power_desc, cur_label, rec_label)
				local ok, choice = pcall(dialog.block_alert,
					title, msg, i18n.get("button.confirm"), i18n.get("button.cancel"), "informational")
				Logger.debug(LOG, string.format("Dialog response: ok=%s, choice=%s.", tostring(ok), tostring(choice)))
				if ok and choice == i18n.get("button.confirm") then
					Logger.info(LOG, string.format("Profile changed to %s (accepted).", rec_profile))
					state.llm_active_profile = rec_profile
					llm_mod.set_active_profile(rec_profile)
					save_prefs(); update_menu()
				else
					Logger.info(LOG, string.format("Profile kept at %s (refused).", cur_profile))
					state.llm_active_profile = cur_profile
					llm_mod.set_active_profile(cur_profile)
				end
			end
		elseif opts.force_dialog then
			local title = type(opts.dialog_title) == "string" and opts.dialog_title or "Profil recommandé"
			local msg = string.format(
				i18n.get("menu.llm.profile_already_ok_msg"),
				display_name, power_desc, cur_label, rec_label)
			pcall(dialog.block_alert, title, msg, i18n.get("button.confirm"), i18n.get("button.cancel"), "informational")
		else
			Logger.debug(LOG, "Recommended profile already active — no action needed.")
		end
	end


	-- =====================================================
	-- ===== 1.6) Model switch =====
	-- =====================================================

	--- Changes the active model, handling the MLX server restart lock.
	--- Requirements are checked asynchronously; predictions are locked until the
	--- server confirms readiness so the user never fires against a dead port.
	--- @param new_model string Display name of the model to activate.
	local function switch_model(new_model)
		Logger.debug(LOG, string.format("Executing switch_model('%s')…", new_model or "nil"))

		-- Lock predictions during the MLX server restart — weights take 60–90 s to reload
		local mlx_was_enabled = state.llm_backend == "mlx" and state.llm_enabled
		if mlx_was_enabled and keymap and type(keymap.set_llm_enabled) == "function" then
			Logger.debug(LOG, "MLX model switch: locking predictions during server restart.")
			pcall(keymap.set_llm_enabled, false)
		end

		local function unlock_predictions()
			if mlx_was_enabled and keymap and type(keymap.set_llm_enabled) == "function" then
				Logger.debug(LOG, "MLX model switch: predictions unlocked.")
				pcall(keymap.set_llm_enabled, true)
			end
		end

		guarded_check_requirements(new_model, function()
			Logger.info(LOG, string.format("Model successfully switched to %s.", new_model))
			state.llm_model       = new_model
			state.llm_model_power = get_model_power_level(new_model)
			Logger.debug(LOG, string.format("Model power cached: %d.", state.llm_model_power))

			local actual_name = models_mgr.get_actual_model_name(new_model)
			if state.llm_backend == "mlx" then
				state.llm_model_mlx = new_model
				llm_mod.set_llm_model_mlx(actual_name)
				Logger.debug(LOG, string.format("Actual MLX model: %s -> %s.", new_model, actual_name))
			else
				state.llm_model_ollama = new_model
				llm_mod.set_llm_model_ollama(actual_name)
				Logger.debug(LOG, string.format("Actual Ollama model: %s -> %s.", new_model, actual_name))
			end

			if keymap and type(keymap.set_llm_model) == "function" then
				local ok = pcall(keymap.set_llm_model, actual_name)
				Logger.debug(LOG, string.format("keymap.set_llm_model() -> %s.", tostring(ok)))
			else
				Logger.warn(LOG, "keymap.set_llm_model is unavailable.")
			end
			if keymap and type(keymap.set_llm_display_model_name) == "function" then
				pcall(keymap.set_llm_display_model_name, new_model)
			end

			save_prefs(); update_menu()
			unlock_predictions()
			apply_recommended_prompt_profile(new_model, { dialog_title = i18n.get("menu.llm.model_change_title") })
		end, function()
			-- Requirements failed — restore predictions so the user is not left stranded
			Logger.warn(LOG, string.format("switch_model('%s') failed — restoring predictions.", tostring(new_model)))
			unlock_predictions()
		end)
	end

	return {
		switch_model                      = switch_model,
		set_llm_profile                   = set_llm_profile,
		apply_recommended_prompt_profile  = apply_recommended_prompt_profile,
		get_display_model_name            = get_display_model_name,
		get_model_power_level             = get_model_power_level,
		guarded_check_requirements        = guarded_check_requirements,
	}
end

return M
