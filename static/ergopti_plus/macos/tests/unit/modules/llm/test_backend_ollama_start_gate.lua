--- tests/unit/modules/llm/test_backend_ollama_start_gate.lua

--- ==============================================================================
--- MODULE: Regression — an Ollama backend identity starts no absent daemon
--- DESCRIPTION:
--- An Intel Mac booting a config.toml written by an older release restores
--- Ollama, the platform default backend, with the AI off. set_backend started
--- the Ollama daemon anyway; since Ollama is no longer bundled, the start found
--- no executable and logged an ERROR, which opened the error window at every
--- boot (llm-backend-ollama-start-gate). The daemon now starts only when the
--- live AI gate is on and Ollama is installed; a missing Ollama is presented
--- by the boot notice, the startup check and the AI switch, with their
--- install button.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===============================
-- ===============================
-- ======= 1/ Fixture ============
-- ===============================
-- ===============================

--- Loads the real core with a spied daemon start and a chosen Ollama install.
--- @param installed boolean Whether an Ollama executable resolves.
--- @return table core
--- @return table spy { starts, errors, resolves }
--- @return function restore
local function fixture(installed, source_kind)
	local core = helpers.load_with_stubs("modules.llm")
	local api = package.loaded["modules.llm.api_ollama"]
	local binary = package.loaded["modules.llm.ollama_binary"]
	local logger = package.loaded["infra.logger"]
	local originals = { ensure = api.ensure_running, resolve = binary.resolve, error = logger.error }
	local spy = { starts = 0, errors = {}, resolves = 0 }
	api.ensure_running = function()
		spy.starts = spy.starts + 1
		return true
	end
	binary.resolve = function()
		spy.resolves = spy.resolves + 1
		if installed then
			if source_kind == binary.SOURCE_NATIVE_MANAGED then
				return "/fixture/native/ollama", nil, source_kind
			end
			return "/Applications/Ollama.app/Contents/Resources/ollama", nil, binary.SOURCE_APP
		end
		return nil, "no executable Ollama binary was found", nil
	end
	logger.error = function(tag, message, ...)
		spy.errors[#spy.errors + 1] = tostring(tag) .. " " .. string.format(tostring(message), ...)
		return originals.error(tag, message, ...)
	end
	local function restore()
		api.ensure_running = originals.ensure
		binary.resolve = originals.resolve
		logger.error = originals.error
	end
	return core, spy, restore
end

--- Runs one case and always restores the spied owners.
--- @param installed boolean
--- @param body function(core, spy)
local function with_fixture(installed, body, source_kind)
	local core, spy, restore = fixture(installed, source_kind)
	local ok, err = xpcall(body, debug.traceback, core, spy)
	restore()
	if not ok then error(err, 0) end
end




-- ===============================
-- ===============================
-- ======= 2/ Cases ==============
-- ===============================
-- ===============================

helpers.describe("llm-backend-ollama-start-gate", function()
	helpers.it("restores an Ollama identity with the AI off without starting the daemon", function()
		with_fixture(false, function(core, spy)
			helpers.assert_eq(core.get_runtime_llm_enabled(), false)
			helpers.assert_true(core.set_backend("ollama"),
				"the identity commits: the boot must not turn a restored backend into a failure")
			helpers.assert_eq(core.get_backend(), "ollama")
			helpers.assert_eq(spy.starts, 0,
				"an AI that is off must never start the Ollama daemon (the Intel boot ERROR)")
			helpers.assert_eq(#spy.errors, 0, table.concat(spy.errors, "\n"))
		end)
	end)

	helpers.it("does not start an installed Ollama either while the AI is off", function()
		with_fixture(true, function(core, spy)
			helpers.assert_true(core.set_backend("ollama"))
			helpers.assert_eq(spy.starts, 0, "only the live AI gate authorises a daemon")
		end)
	end)

	helpers.it("with the AI on and Ollama absent, commits the identity and starts nothing", function()
		with_fixture(false, function(core, spy)
			helpers.assert_true(core.set_runtime_llm_enabled(true))
			helpers.assert_true(core.set_backend("ollama"),
				"a missing Ollama is the not-installed state its offer presents, not a failed selection")
			helpers.assert_eq(core.get_backend(), "ollama")
			helpers.assert_eq(spy.starts, 0,
				"starting an Ollama that is not installed only logged a failed executable resolution")
			helpers.assert_true(spy.resolves >= 1, "the installation must be probed, not assumed")
			helpers.assert_eq(#spy.errors, 0, table.concat(spy.errors, "\n"))
		end)
	end)

	helpers.it("with the AI on, accepts the external client identity without starting its daemon", function()
		with_fixture(true, function(core, spy)
			helpers.assert_true(core.set_runtime_llm_enabled(true))
			helpers.assert_true(core.set_backend("ollama"))
			helpers.assert_eq(spy.starts, 0, "a client selection never acquires an external daemon")
		end)
	end)

	helpers.it("an MLX or API identity never probes nor starts Ollama", function()
		with_fixture(true, function(core, spy)
			helpers.assert_true(core.set_runtime_llm_enabled(true))
			helpers.assert_true(core.set_backend("mlx"))
			helpers.assert_true(core.set_backend("api"))
			helpers.assert_eq(spy.starts, 0)
			helpers.assert_eq(spy.resolves, 0)
		end)
	end)

	helpers.it("an Ollama found by auto-detection starts nothing while the AI is off", function()
		with_fixture(true, function(core, spy)
			-- Past the ten-second cache of a previous detection
			hs.timer.secondsSinceEpoch = function() return 100 end
			local mlx_url = require("modules.llm.api_mlx").get_base_url() .. "/v1/models"
			hs.http.__set_response("http://127.0.0.1:11434/api/version", 200, '{"version":"fixture"}')
			hs.http.__set_response(mlx_url, 404, "")
			local detected = nil
			core.auto_detect_backend(function(backend) detected = backend end)
			helpers.assert_eq(detected, "ollama")
			helpers.assert_eq(spy.starts, 0, "auto-detection shares the explicit selection's admission")
		end)
	end)

	helpers.it("an external Ollama found by auto-detection stays a client with the AI on", function()
		with_fixture(true, function(core, spy)
			helpers.assert_true(core.set_runtime_llm_enabled(true))
			-- Past the ten-second cache of a previous detection
			hs.timer.secondsSinceEpoch = function() return 100 end
			local mlx_url = require("modules.llm.api_mlx").get_base_url() .. "/v1/models"
			hs.http.__set_response("http://127.0.0.1:11434/api/version", 200, '{"version":"fixture"}')
			hs.http.__set_response(mlx_url, 404, "")
			core.auto_detect_backend(function() end)
			helpers.assert_eq(core.get_backend(), "ollama")
			helpers.assert_eq(spy.starts, 0, "a client selection never acquires an external daemon")
		end)
	end)
	helpers.it("(llm-backend-owned-start) admits the native foreground owner once with the AI on", function()
		with_fixture(true, function(core, spy)
			helpers.assert_true(core.set_runtime_llm_enabled(true))
			helpers.assert_true(core.set_backend("ollama"))
			helpers.assert_eq(core.get_backend(), "ollama")
			helpers.assert_eq(spy.starts, 1)
		end, "native_managed")
	end)

	helpers.it("(llm-backend-owned-off) never starts the native owner while the AI is off", function()
		with_fixture(true, function(core, spy)
			helpers.assert_true(core.set_backend("ollama"))
			helpers.assert_eq(spy.starts, 0)
		end, "native_managed")
	end)

end)
