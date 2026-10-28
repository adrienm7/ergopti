--- ui/menu/menu_llm/custom_models.lua

--- ==============================================================================
--- MODULE: Custom LLM Models
--- DESCRIPTION:
--- The models the user adds by identifier beside the curated catalogue: an
--- Ollama name or an MLX Hugging Face repository id, typed in the model
--- selector page. This module owns their persisted list.
---
--- FEATURES & RATIONALE:
--- 1. One owner: the page adds and removes these models only through here,
---    with the validation, persistence and rollback the tray's former
---    "custom model" option applied (an identifier is checked by the shared
---    llm.model_identifier rule, a failed save rolls the list back, removing
---    the active model disables it first).
--- 2. No captured closures: every dependency arrives through the ctx table.
--- ==============================================================================

local M = {}

local i18n   = require("infra.i18n")
local Logger = require("infra.logger")
local dialog = require("infra.dialog_util")
local ModelIdentifier = require("llm.model_identifier")

local LOG = "custom_models"





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Binds the custom-model operations to one driver context.
--- @param ctx table Context with fields:
---   state          table    Shared preference state (llm_user_models, llm_model, llm_backend).
---   disable_model  function Clears the active model through the tray's path.
---   save_prefs     function Persists state to disk; returns true on success.
---   update_menu    function Redraws the tray menu.
---   on_changed     function|nil Called after the list changed (page refresh).
--- @return table ops { list_for_backend, add, remove }
function M.new(ctx)
	if type(ctx) ~= "table" or type(ctx.state) ~= "table" then
		error("custom_models.new requires ctx.state")
	end
	for _, name in ipairs({ "disable_model", "save_prefs", "update_menu" }) do
		if type(ctx[name]) ~= "function" then error("custom_models.new requires ctx." .. name) end
	end
	local state         = ctx.state
	local disable_model = ctx.disable_model
	local save_prefs    = ctx.save_prefs
	local update_menu   = ctx.update_menu
	local function changed()
		if type(ctx.on_changed) == "function" then Logger.callback(LOG, "Custom model change", ctx.on_changed) end
	end
	local ops = {}

	--- Returns the user-added models that match the given backend.
	--- @param backend string Either "ollama" or "mlx".
	--- @return table List of { name = string } entries.
	function ops.list_for_backend(backend)
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
	--- @return table|nil mutation Exact reversible insertion, or nil for a duplicate.
	local function add_user_model(backend, name)
		local previous = state.llm_user_models
		if type(previous) ~= "table" then state.llm_user_models = {} end
		local models = state.llm_user_models
		for _, entry in ipairs(models) do
			if type(entry) == "table" and entry.backend == backend and entry.name == name then
				Logger.debug(LOG, string.format("User model already present (%s/%s) — no-op.", backend, name))
				return nil
			end
		end
		local entry = {backend = backend, name = name}
		table.insert(models, entry)
		Logger.info(LOG, string.format("User model added: %s/%s.", backend, name))
		return {entry = entry, list = models, previous = previous}
	end

	--- Rolls back one exact insertion without removing a pre-existing duplicate.
	--- @param mutation table|nil Mutation returned by add_user_model.
	local function rollback_user_model(mutation)
		if type(mutation) ~= "table" or state.llm_user_models ~= mutation.list then return end
		for index, entry in ipairs(mutation.list) do
			if entry == mutation.entry then
				table.remove(mutation.list, index)
				break
			end
		end
		if type(mutation.previous) ~= "table" and #mutation.list == 0 then
			state.llm_user_models = mutation.previous
		end
	end

	--- Removes a user model from the persisted list.
	--- @param backend string Either "ollama" or "mlx".
	--- @param name string Backend-native identifier.
	local function remove_user_model(backend, name)
		if type(state.llm_user_models) ~= "table" then return end
		local models = state.llm_user_models
		for i, entry in ipairs(models) do
			if type(entry) == "table" and entry.backend == backend and entry.name == name then
				table.remove(models, i)
				Logger.info(LOG, string.format("User model removed: %s/%s.", backend, name))
				return i, entry, models
			end
		end
	end

	--- Restores one exact removed entry at its original index.
	--- @param index number|nil Original list index.
	--- @param entry table|nil Exact removed entry.
	--- @param models table|nil Exact mutated list.
	--- @return boolean restored
	local function restore_user_model(index, entry, models)
		if type(index) ~= "number" or type(entry) ~= "table"
			or type(models) ~= "table" or state.llm_user_models ~= models then
			return false
		end
		for _, current in ipairs(models) do
			if current == entry then return true end
		end
		table.insert(models, math.min(index, #models + 1), entry)
		return true
	end


	--- Adds a validated identifier to the persisted list of one local backend.
	--- @param backend string "ollama" or "mlx".
	--- @param name string Identifier typed in the page.
	--- @return boolean added True once persisted (also for a name already listed).
	function ops.add(backend, name)
		if not ModelIdentifier.valid(backend, name) then
			Logger.warn(LOG, "Custom model refused: '%s' is not a valid %s identifier.", tostring(name), tostring(backend))
			return false
		end
		local mutation = add_user_model(backend, name)
		if mutation == nil then return true end
		local save_ok, save_result = xpcall(save_prefs, debug.traceback)
		if not save_ok or save_result ~= true then
			rollback_user_model(mutation)
			Logger.error(LOG, "Custom model preferences were not persisted: %s.", tostring(save_result))
			return false
		end
		update_menu()
		changed()
		return true
	end

	--- Removes one user model after confirmation; the active one is disabled first.
	--- @param backend string Backend the entry belongs to.
	--- @param m_name string Backend-native identifier.
	--- @return boolean removed
	function ops.remove(backend, m_name)
		local ok, choice = pcall(dialog.block_alert,
			i18n.get("menu.llm.remove_model_title"),
			string.format(i18n.get("menu.llm.remove_model_body"), m_name),
			i18n.get("button.remove"), i18n.get("button.cancel"), "warning")
		if not ok or choice ~= i18n.get("button.remove") then return false end
		local removed_index, removed_entry, removed_models = remove_user_model(backend, m_name)
		if removed_index == nil then return false end
		if state.llm_model == m_name then
			local disable_ok, disable_result = xpcall(disable_model, debug.traceback)
			if not disable_ok or disable_result ~= true then
				restore_user_model(removed_index, removed_entry, removed_models)
				return false
			end
			changed()
			return true
		end
		local save_ok, save_result = xpcall(save_prefs, debug.traceback)
		if not save_ok or save_result ~= true then
			restore_user_model(removed_index, removed_entry, removed_models)
			Logger.error(LOG, "Custom model removal was not persisted: %s.", tostring(save_result))
			return false
		end
		update_menu()
		changed()
		return true
	end

	return ops
end

return M
