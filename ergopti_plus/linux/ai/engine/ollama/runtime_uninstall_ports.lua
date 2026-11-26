--- ai/engine/ollama/runtime_uninstall_ports.lua

--- ==============================================================================
--- MODULE: Linux Managed Ollama Uninstall Ports
--- DESCRIPTION:
--- The Linux owners behind each step of the shared uninstall sequence
--- (_shared/ai/engine/ollama/runtime_uninstall.lua, OLL-11 of the 2026-11-20
--- managed Ollama campaign): the engine's model removal, the stop of this
--- app's Ollama service, and the removal of runtimes/ollama/ in one
--- `rm -r --one-file-system` child under the finite process port, as the
--- retention of earlier releases does. The models live in Ollama's own store,
--- outside that folder, so only the model step can delete them.
--- ==============================================================================

local Logger = require("core.logger.engine.shim")

local M = {}

local LOG = "ai.engine.ollama.runtime_uninstall_ports"





-- ==================================
-- ==================================
-- ======= 1/ Native Defaults =======
-- ==================================
-- ==================================

--- The runtime folder of the pinned plan, from the per-user resolver.
--- @return string|nil runtime Folder holding every release.
local function runtime_folder()
	local resolver, reason = require("ai.engine.ollama.install_resolver").new()
	if not resolver then
		Logger.error(LOG, "The Ollama folder could not be resolved: %s.", tostring(reason))
		return nil
	end
	local plan = resolver.plan()
	return type(plan) == "table" and type(plan.runtime) == "string" and plan.runtime or nil
end

--- The finite process port the runtime factory builds.
--- @return table process
local function process_port()
	local native = require("luv")
	local Timings = require("core.timing.engine.timings")
	return require("ai.engine.policy.process_port").new(require("core.lifecycle.engine.native_worker_owner"),
		require("core.process.adapters.owned_process"), native, Timings.ms("llm", "poll_interval_ms"))
end





-- ==============================
-- ==============================
-- ======= 2/ Public API ========
-- ==============================
-- ==============================

--- Builds the ports of one uninstall.
--- @param llm table Prediction engine (runtime_pending, get_cached_models_status, delete_model, stop_runtime).
--- @param deps table|nil { download, retention, runtime, process, timeout_ms } (tests).
--- @return table ports For runtime_uninstall.run.
function M.new(llm, deps)
	deps = deps or {}
	local download = deps.download or require("ai.engine.local_servers.model_download")
	local retention = deps.retention or require("ai.engine.ollama.runtime_retention")
	local runtime = deps.runtime or runtime_folder
	local process = deps.process or process_port
	local timeout_ms = deps.timeout_ms
		or require("core.timing.engine.timings").ms("llm", "dependency_bootstrap_timeout_ms")
	return {
		busy = function()
			return llm.runtime_pending() == true or download.is_active() == true
		end,
		delete_models = function(done)
			local models, known = llm.get_cached_models_status()
			if known ~= true or type(models) ~= "table" then
				Logger.error(LOG, "The models to delete are not known: Ergopti's Ollama is not running.")
				return done(false)
			end
			return require("ai.engine.ollama.runtime_uninstall").delete_each(models, llm.delete_model,
				function(ok, refused)
					if ok then Logger.info(LOG, "Deleted %d model(s) of Ergopti's Ollama.", #models)
					else Logger.error(LOG, "The model '%s' could not be deleted.", tostring(refused)) end
					return done(ok)
				end)
		end,
		stop = function(done)
			local stopped = llm.stop_runtime() == true
			if not stopped then Logger.error(LOG, "Ergopti's Ollama did not stop; nothing is removed.") end
			return done(stopped)
		end,
		remove_files = function(_, done)
			local folder = runtime()
			if type(folder) ~= "string" or folder == "" then return done(false) end
			local operation = retention.remove({ folder }, process(), timeout_ms, "Ergopti's Ollama", done)
			if operation == nil then
				Logger.error(LOG, "The removal of Ergopti's Ollama could not start.")
				return done(false)
			end
		end,
	}
end

--- Tells that no model is selected for « Delete the selected model ».
--- @param notify function Receives (text, { title, level }).
--- @param i18n_get function Locale accessor.
--- @return boolean false The row did nothing.
function M.no_model_notice(notify, i18n_get)
	local caption = i18n_get("menu.llm.ollama_runtime.title")
	local ok, sent = pcall(notify, i18n_get("menu.llm.ollama_runtime.no_model"), { title = caption, level = "warning" })
	if not ok or sent ~= true then Logger.warn(LOG, "The no-model notice was not shown.") end
	return false
end

--- Runs one uninstall and tells its outcome.
--- @param llm table Prediction engine.
--- @param remove_models boolean Whether the user chose to delete the models.
--- @param notify function Receives (text, { title, level }).
--- @param i18n_get function Locale accessor.
--- @param deps table|nil Port dependencies (tests).
--- @param on_done function|nil Receives the sequence's result.
function M.uninstall(llm, remove_models, notify, i18n_get, deps, on_done)
	Logger.start(LOG, "Uninstalling Ergopti's Ollama (models %s)…", remove_models and "removed" or "kept")
	require("ai.engine.ollama.runtime_uninstall").run(remove_models, M.new(llm, deps), function(result)
		if result.ok then
			Logger.success(LOG, "Ergopti's Ollama is uninstalled.")
		else
			Logger.error(LOG, "The uninstall of Ergopti's Ollama stopped at its '%s' step.", tostring(result.step))
		end
		local title = i18n_get(result.ok and "ollama.uninstall.done_title" or "ollama.uninstall.failed_title")
		local ok, sent = pcall(notify, i18n_get(result.message), { title = title, level = result.ok and "success" or "error" })
		if not ok or sent ~= true then Logger.warn(LOG, "The uninstall notice was not shown.") end
		if type(on_done) == "function" then on_done(result) end
	end)
end

return M
