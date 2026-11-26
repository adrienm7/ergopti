--- tests/unit/ai/engine/ollama/test_runtime_uninstall.lua

--- ==============================================================================
--- MODULE: Managed Ollama Uninstall Sequence
--- DESCRIPTION:
--- Replays the uninstall vectors through the shared sequence this driver and
--- macOS run; Windows replays the same vectors through its port. Then drives
--- the Linux ports over a scripted engine: nothing real is stopped or removed.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.ai.ollama_uninstall_contract").register(helpers, require("core.fs.engine.paths").shared)

local Ports = require("ai.engine.ollama.runtime_uninstall_ports")

--- A scripted engine and the dependencies of the Linux ports.
--- @param world table Overrides.
--- @return table llm, table deps, table world
local function fixture(world)
	world = world or {}
	world.deleted, world.removed = {}, {}
	local llm = {
		runtime_pending = function() return world.pending == true end,
		get_cached_models_status = function() return world.models or {}, world.known ~= false end,
		delete_model = function(tag, on_done)
			world.deleted[#world.deleted + 1] = tag
			on_done(tag ~= world.refuse_model, tag)
			return true
		end,
		stop_runtime = function() world.stopped = true; return world.stop ~= false end,
	}
	local deps = {
		download = { is_active = function() return world.downloading == true end },
		runtime = function() return "/home/u/.local/share/ergopti/runtimes/ollama" end,
		process = function() return { start = true } end,
		timeout_ms = 1000,
		retention = {
			remove = function(paths, _, _, _, done)
				world.removed[#world.removed + 1] = paths[1]
				if world.no_removal then return nil end
				done(world.files ~= false)
				return {}
			end,
		},
	}
	return llm, deps, world
end

--- Runs one uninstall over the fixture.
--- @return table results, table notices
local function uninstall(llm, deps, remove_models)
	local results, notices = {}, {}
	Ports.uninstall(llm, remove_models, function(text, options)
		notices[#notices + 1] = { text = text, level = options.level }
		return true
	end, function(key) return key end, deps, function(result) results[#results + 1] = result end)
	return results, notices
end

helpers.describe("Linux managed Ollama uninstall ports (oll-11)", function()
	helpers.it("(oll-11) deletes every listed model, stops the service, then removes runtimes/ollama", function()
		local llm, deps, world = fixture({ models = { "qwen:2b", "gemma:1b" } })
		local results, notices = uninstall(llm, deps, true)
		helpers.assert_eq(world.deleted, { "qwen:2b", "gemma:1b" })
		helpers.assert_true(world.stopped)
		helpers.assert_eq(world.removed, { "/home/u/.local/share/ergopti/runtimes/ollama" })
		helpers.assert_true(results[1].ok)
		helpers.assert_eq(notices[1], { text = "ollama.uninstall.done_models", level = "success" })
	end)

	helpers.it("(oll-11) keeps the models when asked, and refuses while a pull runs", function()
		local llm, deps, world = fixture({ models = { "qwen:2b" } })
		local results = uninstall(llm, deps, false)
		helpers.assert_eq(world.deleted, {})
		helpers.assert_eq(results[1].message, "ollama.uninstall.done")
		local busy_llm, busy_deps, busy_world = fixture({ downloading = true })
		local busy = uninstall(busy_llm, busy_deps, true)
		helpers.assert_eq(busy[1].message, "ollama.uninstall.reason_busy")
		helpers.assert_nil(busy_world.stopped)
	end)

	helpers.it("(oll-11) an unknown model list, a refused model or a refused removal fails fast", function()
		for _, case in ipairs({
			{ world = { known = false }, message = "ollama.uninstall.reason_models" },
			{ world = { models = { "a:1", "b:1" }, refuse_model = "a:1" }, message = "ollama.uninstall.reason_models",
				deleted = { "a:1" } },
			{ world = { stop = false }, message = "ollama.uninstall.reason_stop" },
			{ world = { no_removal = true }, message = "ollama.uninstall.reason_files" },
			{ world = { files = false }, message = "ollama.uninstall.reason_files" },
		}) do
			local llm, deps, world = fixture(case.world)
			local results, notices = uninstall(llm, deps, true)
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].ok, false)
			helpers.assert_eq(results[1].message, case.message)
			helpers.assert_eq(notices[1].level, "error")
			if case.deleted then helpers.assert_eq(world.deleted, case.deleted) end
			if case.message == "ollama.uninstall.reason_models" then helpers.assert_nil(world.stopped) end
		end
	end)

	helpers.it("(oll-11) the menu greys its rows by the managed status", function()
		local InstallState = require("ai.engine.ollama.install_state")
		helpers.assert_true(InstallState.managed_installed(function() return "installed" end))
		helpers.assert_eq(InstallState.managed_installed(function() return "missing" end), false)
	end)
end)
