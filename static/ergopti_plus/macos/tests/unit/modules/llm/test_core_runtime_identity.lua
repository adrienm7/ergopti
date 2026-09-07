--- tests/unit/modules/llm/test_core_runtime_identity.lua

--- ==============================================================================
--- MODULE: LLM Runtime Identity Regressions
--- DESCRIPTION:
--- Reads the configured core through its real diagnostic and configuration consumers.
--- Requiring the same init file under another name creates independent state.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads fresh real consumers while preserving the surrounding suite's aliases.
--- @param scenario function Receives the real canonical core and collector.
local function with_runtime(scenario)
	local saved, saved_hs = {}, _G.hs
	for name, module in pairs(package.loaded) do saved[name] = module end
	local ok, err = xpcall(function()
		for name in pairs(package.loaded) do
			if type(name) == "string" and name:match("^modules%.llm") then
				package.loaded[name] = nil
			end
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.keylogger"] = {}
		local healthcheck = helpers.load_with_stubs("ui.healthcheck.helpers")
		local live = helpers.load_with_stubs("modules.llm")
		-- The alternate import must stay absent: creating it would give a
		-- diagnostic or configuration reader an independent default-only core
		package.loaded["modules.llm.init"] = nil
		scenario(live, healthcheck)
	end, debug.traceback)
	-- The generic harness replaces several aliases and adapters, not just the
	-- requested module; restore the complete module map and global native stub
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, module in pairs(saved) do package.loaded[name] = module end
	_G.hs = saved_hs
	if not ok then error(err, 0) end
end

helpers.describe("llm-core-runtime-identity", function()
	helpers.it("reports the canonical live gate without loading a second core", function()
		with_runtime(function(live, healthcheck)
			helpers.assert_true(live.set_runtime_llm_enabled(true))
			helpers.assert_eq(healthcheck.collect_llm_state().enabled, "true",
				"diagnostics must read the live core, not fresh default runtime state")
			helpers.assert_nil(package.loaded["modules.llm.init"],
				"collecting diagnostics must not instantiate an alternate core owner")
			helpers.assert_true(live.set_runtime_llm_enabled(false))
			helpers.assert_eq(healthcheck.collect_llm_state().enabled, "false")
			helpers.assert_true(package.loaded["modules.llm"] == live)
		end)
	end)

	helpers.it("uses canonical word limits when parsing model output", function()
		with_runtime(function(live)
			live.DEFAULT_STATE.llm_min_words = 1
			live.DEFAULT_STATE.llm_max_words = 2
			local parsed = require("modules.llm.parser").process_prediction(
				"hello", "hello", "TAIL_CORRECTED: hello\nNEXT_WORDS: one two three four five")
			helpers.assert_not_nil(parsed)
			helpers.assert_eq(parsed.nw, " one two")
			helpers.assert_nil(package.loaded["modules.llm.init"])
		end)
	end)

	helpers.it("injects canonical word defaults into the active profile prompt", function()
		with_runtime(function(live)
			live.DEFAULT_STATE.llm_min_words = 7
			live.DEFAULT_STATE.llm_max_words = 9
			local prompt = require("modules.llm.profiles").resolve_system_prompt(
				{ system_single = "Words: {min_words}/{max_words}" }, 1)
			helpers.assert_eq(prompt, "Words: 7/9")
			helpers.assert_nil(package.loaded["modules.llm.init"])
		end)
	end)

	helpers.it("reads the loaded canonical endpoint default instead of the emergency port", function()
		with_runtime(function(live)
			live.DEFAULT_STATE.llm_ollama_port = 12456
			helpers.assert_eq(require("modules.llm.ollama_endpoint").get_default_port(), 12456)
			helpers.assert_nil(package.loaded["modules.llm.init"])
		end)
	end)
end)
