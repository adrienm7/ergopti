--- tests/unit/modules/llm/ollama/test_ollama_owned_endpoint.lua

--- ==============================================================================
--- MODULE: Ergopti's own Ollama runtime and port
--- DESCRIPTION:
--- Issue #104: a user's own Ollama on the stock port was selected, and the pull
--- through it failed with 412 because it was older than the model needed.
--- Ergopti always uses its own pinned Ollama (maintainer decision): the
--- resolver never returns a user's installation, and Ergopti's daemon listens
--- on its own port (defaults.json llm_ollama_owned_port), never the stock one
--- the user's Ollama keeps. A former override of the stock port is dropped
--- once and logged (ollama-owned-runtime).
--- ==============================================================================

local helpers = require("tests.helpers")

local USER_APP = "/Applications/Ollama.app/Contents/Resources/ollama"

--- Reads the shared LLM defaults, the single source of both ports.
--- @return table defaults
local function shared_defaults()
	local Paths = require("infra.paths")
	local file = assert(io.open(Paths.shared_llm_path("defaults.json"), "rb"))
	local text = file:read("*a"); file:close()
	return require("json").decode(text)
end

--- Loads the endpoint owner over an in-memory Storage.
--- @param stored table Initial storage values.
--- @return table endpoint, table stored, table lines
local function endpoint_with(stored)
	local defaults = shared_defaults()
	local lines = {}
	package.loaded["modules.llm"] = { DEFAULT_STATE = {
		llm_ollama_port = defaults.llm_ollama_port, llm_ollama_owned_port = defaults.llm_ollama_owned_port } }
	package.loaded["adapters.storage"] = {
		get = function(key) return stored[key] end,
		set = function(key, value) stored[key] = value; return true end,
		delete = function(key) stored[key] = nil; return true end,
	}
	local logger = helpers.make_logger_stub()
	logger.info = function(_, fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
	package.loaded["infra.logger"] = logger
	package.loaded["modules.llm.ollama_endpoint"] = nil
	return require("modules.llm.ollama_endpoint"), stored, lines, defaults
end

local function scoped(fn)
	return function()
		helpers.with_stub_scope({ "modules.llm", "adapters.storage", "infra.logger",
			"modules.llm.ollama_endpoint", "modules.llm.ollama_binary", "adapters.managed_ollama_hint" }, fn)
	end
end

helpers.describe("Ergopti's own Ollama (ollama-owned-runtime)", function()
	helpers.it("listens on its own shared port, never the stock one", scoped(function()
		local endpoint, _, _, defaults = endpoint_with({})
		helpers.assert_true(defaults.llm_ollama_owned_port ~= defaults.llm_ollama_port,
			"the owned port must differ from the port a user's Ollama keeps")
		helpers.assert_eq(endpoint.get_port(), defaults.llm_ollama_owned_port)
		helpers.assert_eq(endpoint.get_base_url(), "http://127.0.0.1:" .. defaults.llm_ollama_owned_port)
	end))

	helpers.it("drops a former stock-port override once and logs it", scoped(function()
		local defaults = shared_defaults()
		local endpoint, stored, lines = endpoint_with({ ["llm.ollama_port"] = defaults.llm_ollama_port })
		helpers.assert_eq(endpoint.get_port(), defaults.llm_ollama_owned_port)
		helpers.assert_eq(stored["llm.ollama_port"], nil)
		helpers.assert_eq(stored["llm.ollama_owned_port"], nil, "the owned default applies, nothing is pinned")
		endpoint.get_port()
		helpers.assert_eq(#lines, 1, "the migration is logged once")
	end))

	helpers.it("moves a custom former override to the owned key", scoped(function()
		local endpoint, stored = endpoint_with({ ["llm.ollama_port"] = 11500 })
		helpers.assert_eq(endpoint.get_port(), 11500)
		helpers.assert_eq(stored["llm.ollama_owned_port"], 11500)
		helpers.assert_eq(stored["llm.ollama_port"], nil)
	end))

	helpers.it("refuses an owned override on the stock port", scoped(function()
		local defaults = shared_defaults()
		local endpoint = endpoint_with({ ["llm.ollama_owned_port"] = defaults.llm_ollama_port })
		helpers.assert_eq(endpoint.get_port(), defaults.llm_ollama_owned_port)
	end))

	helpers.it("never resolves a user's own Ollama, even when it is installed", scoped(function()
		package.loaded["adapters.managed_ollama_hint"] = { get = function() return nil, "absent" end }
		local Binary = helpers.load_with_stubs("modules.llm.ollama_binary", {
			fs = { attributes = function(path)
				if path == USER_APP then return { mode = "file", permissions = "rwxr-xr-x" } end
				return nil
			end },
		})
		local path, reason, source = Binary.resolve()
		helpers.assert_eq(path, nil, "the user's Ollama must not be selected")
		helpers.assert_eq(source, nil)
		helpers.assert_contains(reason, "Ergopti's own Ollama")
		helpers.assert_eq(Binary.find_user_installation(), USER_APP, "it is still named for diagnostics")
	end))
end)
