--- ai/ui/menu/ollama_runtime.lua

--- ==============================================================================
--- MODULE: Ergopti's Ollama Submenu
--- DESCRIPTION:
--- The rows of llm_ollama_runtime_rows (OLL-11 of the 2026-11-20 managed Ollama
--- campaign) and the macOS owners behind the shared uninstall sequence
--- (_shared/ai/engine/ollama/runtime_uninstall.lua). Install runs the
--- selection's consent and download (runtime_install_offer.select_ollama);
--- start and repair run the dependency check, which starts the daemon and
--- installs again a runtime whose signature check fails; delete removes the
--- selected model through `ollama rm`. Uninstall deletes the models the last
--- `ollama list` read when the user chose so, retires the owned daemon, then
--- removes ollama-native-http/ in one `rm -R` child: rm never follows a link.
--- ==============================================================================

local Logger = require("core.logger.engine.logger")

local M = {}

local LOG = "ai.ui.menu.ollama_runtime"
local RM_BIN = "/bin/rm"





-- ==================================
-- ==================================
-- ======= 1/ Uninstall Ports =======
-- ==================================
-- ==================================

--- Builds the ports of one uninstall.
--- @param deps table { deps_checker, manager, api_ollama, install_dir, spawn } owners.
--- @return table ports For runtime_uninstall.run.
function M.ports(deps)
	return {
		busy = function()
			return deps.deps_checker.is_task_running() == true or deps.deps_checker.provisioning_idle() ~= true
		end,
		delete_models = function(done)
			local names = deps.deps_checker.is_daemon_ready() == true and deps.manager.installed_model_names() or nil
			if type(names) ~= "table" then
				Logger.error(LOG, "The models to delete are not known: Ergopti's Ollama is not running.")
				return done(false)
			end
			return require("ai.engine.ollama.runtime_uninstall").delete_each(names, deps.manager.delete_model,
				function(ok, refused)
					if ok then Logger.info(LOG, "Deleted %d model(s) of Ergopti's Ollama.", #names)
					else Logger.error(LOG, "The model '%s' could not be deleted.", tostring(refused)) end
					return done(ok)
				end)
		end,
		stop = function(done)
			local accepted, state = deps.api_ollama.retire_owned_server(function(settled)
				if settled ~= true then Logger.error(LOG, "Ergopti's Ollama did not stop; nothing is removed.") end
				done(settled == true)
			end)
			if accepted ~= true then
				Logger.error(LOG, "Ergopti's Ollama refused to stop; nothing is removed.")
				return done(false)
			end
			if state == "settled" then return done(true) end
		end,
		remove_files = function(_, done)
			local directory = deps.install_dir()
			if type(directory) ~= "string" or directory == "" then
				Logger.error(LOG, "The folder of Ergopti's Ollama could not be resolved.")
				return done(false)
			end
			local task = deps.spawn(RM_BIN, { "-R", "--", directory }, function(code, _, stderr)
				if code ~= 0 then
					Logger.error(LOG, "Ergopti's Ollama files could not be removed: %s.", tostring(stderr))
				end
				done(code == 0)
			end)
			if type(task) ~= "table" or task.start == nil or task:start() ~= true then
				Logger.error(LOG, "The removal of Ergopti's Ollama could not start.")
				return done(false)
			end
		end,
	}
end

--- The production owners of the ports.
--- @return table deps
local function production_deps()
	local ShellRunner = require("core.process.adapters.shell_runner")
	local menu = package.loaded["ai.ui.menu"]
	local models = type(menu) == "table" and type(menu.active_models_manager) == "function"
		and menu.active_models_manager() or nil
	return {
		deps_checker = require("ai.engine.ollama.deps_checker"),
		manager = {
			installed_model_names = function()
				return models and models.ollama_installed_model_names() or nil
			end,
			delete_model = function(name, on_done)
				return models ~= nil and models.delete_ollama_model(name, on_done) == true
			end,
		},
		api_ollama = require("ai.engine.api.ollama"),
		install_dir = require("ai.engine.ollama.binary").native_managed_install_dir,
		spawn = function(executable, args, on_done) return ShellRunner.spawn(executable, args, on_done) end,
	}
end





-- ==============================
-- ==============================
-- ======= 2/ Public API ========
-- ==============================
-- ==============================

--- Asks first, then whether the models go too, then runs the sequence and
--- tells its outcome.
--- @param ui table { block_alert(title, body, first, second, style) → label, notify(title, body, level), i18n_get }.
--- @param deps table|nil Port owners; the production ones when nil.
--- @param on_done function|nil Receives the sequence's result.
--- @return boolean ran True once the sequence ran.
function M.uninstall(ui, deps, on_done)
	local t = ui.i18n_get
	local confirm = t("ollama.uninstall.confirm_button")
	if ui.block_alert(t("ollama.uninstall.confirm_title"), t("ollama.uninstall.confirm_body"),
		confirm, t("button.cancel"), "warning") ~= confirm then return false end
	local remove = t("ollama.uninstall.remove_models_button")
	local remove_models = ui.block_alert(t("ollama.uninstall.models_title"), t("ollama.uninstall.models_body"),
		remove, t("ollama.uninstall.keep_models_button"), "informational") == remove
	Logger.start(LOG, "Uninstalling Ergopti's Ollama (models %s)…", remove_models and "removed" or "kept")
	require("ai.engine.ollama.runtime_uninstall").run(remove_models, M.ports(deps or production_deps()), function(result)
		if result.ok then
			Logger.success(LOG, "Ergopti's Ollama is uninstalled.")
			ui.notify(t("ollama.uninstall.done_title"), t(result.message), "success")
		else
			Logger.error(LOG, "The uninstall of Ergopti's Ollama stopped at its '%s' step.", tostring(result.step))
			ui.notify(t("ollama.uninstall.failed_title"), t(result.message), "error")
		end
		if type(on_done) == "function" then on_done(result) end
	end)
	return true
end

--- The command and getter tables of llm_ollama_runtime_rows.
--- @param owners table { install, start, delete_selected, uninstall, installed } functions.
--- @return table commands, table getters
function M.handlers(owners)
	local COMMAND = require("settings.engine.keys").COMMAND
	return {
		[COMMAND.LLM_OLLAMA_INSTALL] = owners.install,
		[COMMAND.LLM_OLLAMA_START] = owners.start,
		[COMMAND.LLM_OLLAMA_REPAIR] = owners.start,
		[COMMAND.LLM_OLLAMA_DELETE_MODEL] = owners.delete_selected,
		[COMMAND.LLM_OLLAMA_UNINSTALL] = owners.uninstall,
	}, {
		llm_ollama_installed = function() return owners.installed() == true end,
		llm_ollama_absent = function() return owners.installed() ~= true end,
	}
end

return M
