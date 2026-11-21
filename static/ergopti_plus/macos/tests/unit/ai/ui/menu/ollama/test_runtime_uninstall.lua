--- tests/unit/ai/ui/menu/ollama/test_runtime_uninstall.lua

--- ==============================================================================
--- MODULE: macOS Managed Ollama Uninstall
--- DESCRIPTION:
--- Drives the « Ergopti's Ollama » uninstall over scripted owners: the two
--- questions, the models deleted one after the other only when chosen, the
--- owned daemon retired before ollama-native-http/ goes in one rm child, and
--- each refusal ending the sequence with its message. Nothing real is stopped
--- or removed.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["ai.ui.menu.ollama_runtime"] = nil
local OllamaRuntime = require("ai.ui.menu.ollama_runtime")

--- Scripted owners of the ports.
--- @param world table Overrides.
--- @return table deps, table world
local function fixture(world)
	world = world or {}
	world.deleted, world.spawned = {}, {}
	local deps = {
		deps_checker = {
			is_task_running = function() return world.installing == true end,
			provisioning_idle = function() return world.provisioning ~= true end,
			is_daemon_ready = function() return world.daemon ~= false end,
		},
		manager = {
			installed_model_names = function() return world.models end,
			delete_model = function(name, on_done)
				world.deleted[#world.deleted + 1] = name
				on_done(name ~= world.refuse_model)
				return true
			end,
		},
		api_ollama = {
			retire_owned_server = function(on_settled)
				world.retired = true
				if world.stop == "refused" then return false, "refused" end
				if world.stop == "pending" then
					on_settled(world.stop_settles ~= false)
					return true, "pending"
				end
				return true, "settled"
			end,
		},
		install_dir = function() return "/Users/u/Library/Application Support/Ergopti/ollama-native-http" end,
		spawn = function(executable, args, on_done)
			world.spawned[#world.spawned + 1] = { executable = executable, args = args }
			return {
				start = function()
					if world.spawn_refused then return false end
					on_done(world.rm_code or 0, "", "rm: failure")
					return true
				end,
			}
		end,
	}
	return deps, world
end

--- Runs the menu action with scripted answers.
--- @param answers table Labels the two alerts return.
--- @return boolean ran, table results, table notices
local function run(deps, answers)
	local asked, results, notices = 0, {}, {}
	local ran = OllamaRuntime.uninstall({
		block_alert = function()
			asked = asked + 1
			return answers[asked]
		end,
		notify = function(title, body, level) notices[#notices + 1] = { body = body, level = level } end,
		i18n_get = function(key) return key end,
	}, deps, function(result) results[#results + 1] = result end)
	return ran, results, notices, asked
end

local CONFIRM, REMOVE, KEEP = "ollama.uninstall.confirm_button", "ollama.uninstall.remove_models_button",
	"ollama.uninstall.keep_models_button"

helpers.describe("macOS managed Ollama uninstall (oll-11)", function()
	helpers.it("(oll-11) a cancelled first question touches nothing", function()
		local deps, world = fixture({ models = { "qwen:2b" } })
		local ran, results, _, asked = run(deps, { "button.cancel" })
		helpers.assert_eq(ran, false)
		helpers.assert_eq(asked, 1)
		helpers.assert_eq(#results, 0)
		helpers.assert_nil(world.retired)
	end)

	helpers.it("(oll-11) deletes the models when chosen, retires the daemon, then removes its folder", function()
		local deps, world = fixture({ models = { "gemma:1b", "qwen:2b" }, stop = "pending" })
		local ran, results, notices = run(deps, { CONFIRM, REMOVE })
		helpers.assert_true(ran)
		helpers.assert_eq(world.deleted, { "gemma:1b", "qwen:2b" })
		helpers.assert_true(world.retired)
		helpers.assert_eq(world.spawned[1].executable, "/bin/rm")
		helpers.assert_eq(world.spawned[1].args,
			{ "-R", "--", "/Users/u/Library/Application Support/Ergopti/ollama-native-http" })
		helpers.assert_true(results[1].ok)
		helpers.assert_eq(notices[1], { body = "ollama.uninstall.done_models", level = "success" })
	end)

	helpers.it("(oll-11) keeps the models when asked", function()
		local deps, world = fixture({ models = { "qwen:2b" } })
		local _, results = run(deps, { CONFIRM, KEEP })
		helpers.assert_eq(world.deleted, {})
		helpers.assert_eq(results[1].message, "ollama.uninstall.done")
	end)

	helpers.it("(oll-11) each refusal ends the sequence with its message", function()
		for _, case in ipairs({
			{ world = { installing = true }, message = "ollama.uninstall.reason_busy" },
			{ world = { daemon = false, models = { "a:1" } }, message = "ollama.uninstall.reason_models" },
			{ world = { models = nil }, message = "ollama.uninstall.reason_models" },
			{ world = { models = { "a:1", "b:1" }, refuse_model = "a:1" }, message = "ollama.uninstall.reason_models" },
			{ world = { models = {}, stop = "refused" }, message = "ollama.uninstall.reason_stop" },
			{ world = { models = {}, stop = "pending", stop_settles = false }, message = "ollama.uninstall.reason_stop" },
			{ world = { models = {}, rm_code = 1 }, message = "ollama.uninstall.reason_files" },
			{ world = { models = {}, spawn_refused = true }, message = "ollama.uninstall.reason_files" },
		}) do
			local deps, world = fixture(case.world)
			local _, results, notices = run(deps, { CONFIRM, REMOVE })
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].ok, false)
			helpers.assert_eq(results[1].message, case.message)
			helpers.assert_eq(notices[1].level, "error")
			if case.message == "ollama.uninstall.reason_models" or case.message == "ollama.uninstall.reason_busy" then
				helpers.assert_nil(world.retired, "a refused model step stops nothing")
			end
		end
	end)

	helpers.it("(oll-11) the rows bind every declared command and grey by the managed runtime", function()
		local installed = false
		local commands, getters = OllamaRuntime.handlers({
			install = function() return "install" end, start = function() return "start" end,
			delete_selected = function() return "delete" end, uninstall = function() return "uninstall" end,
			installed = function() return installed end,
		})
		local COMMAND = require("settings.engine.keys").COMMAND
		helpers.assert_eq(commands[COMMAND.LLM_OLLAMA_INSTALL](), "install")
		helpers.assert_eq(commands[COMMAND.LLM_OLLAMA_START](), "start")
		helpers.assert_eq(commands[COMMAND.LLM_OLLAMA_REPAIR](), "start")
		helpers.assert_eq(commands[COMMAND.LLM_OLLAMA_DELETE_MODEL](), "delete")
		helpers.assert_eq(commands[COMMAND.LLM_OLLAMA_UNINSTALL](), "uninstall")
		helpers.assert_eq(getters.llm_ollama_installed(), false)
		helpers.assert_true(getters.llm_ollama_absent())
		installed = true
		helpers.assert_true(getters.llm_ollama_installed())
	end)
end)
