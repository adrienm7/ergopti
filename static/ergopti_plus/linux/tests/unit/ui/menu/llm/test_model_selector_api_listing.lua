--- tests/unit/ui/menu/llm/test_model_selector_api_listing.lua

--- ==============================================================================
--- MODULE: Model Selector API Listing and Ollama Install State (Linux)
--- DESCRIPTION:
--- Drives the real page rows (ui/menu/llm_backend_rows.lua api_page), the real
--- install state (modules/llm/ollama_install_state.lua) and the real listing
--- request (modules/llm/api_remote.lua list_models) with doubles at their
--- outer boundaries.
---
--- ROOT CAUSE ENCODED:
--- The Linux page listed only the configured model of an API entry while macOS
--- listed the provider's models, and it never greyed the Ollama group: there
--- was no install-state source, so a missing or failed runtime still offered
--- its models.
--- ==============================================================================

local helpers = require("tests.helpers")

local SAVED = { "modules.llm.api_remote", "modules.llm.api_entries", "ui.menu.llm_backend_rows",
	"ui.menu.local_server_rows", "modules.llm.ollama_install_state", "adapters.http_client" }

--- Runs a body with doubles of the API owners the page rows read.
--- @param opts table { model, listings }
--- @param body function Receives (Rows, calls, dialogs).
local function with_rows(opts, body)
	local saved = {}
	for _, name in ipairs(SAVED) do saved[name] = package.loaded[name] end
	local calls = { set_model = {}, set_active = {}, backend = {} }
	local entry = { id = "e1", provider = "openai", label = "x", token = "sk-secret", model = opts.model or "gpt-4o", base_url = "" }
	package.loaded["modules.llm.api_remote"] = {
		provider = function(id)
			if id ~= "openai" then return nil end
			return { id = "openai", label = "OpenAI", base_url = "https://api.openai.com/v1", default_model = "gpt-4o-mini",
				format = "openai", model_extras = { ["o-extra"] = {} } }
		end,
		providers = function() return {} end,
		serves = function() return true end,
		token_allowed = function() return true end,
	}
	package.loaded["modules.llm.api_entries"] = {
		active = function() return entry end,
		list = function() return { entry } end,
		set_active = function(id) calls.set_active[#calls.set_active + 1] = id; return true end,
		set_model = function(id, model) calls.set_model[#calls.set_model + 1] = id .. ":" .. model; return true end,
	}
	package.loaded["ui.menu.llm_backend_rows"] = nil
	local ok, err = xpcall(function()
		local Rows = require("ui.menu.llm_backend_rows")
		local dialogs = {
			prompt = function() return opts.typed or "" end,
			error = function() calls.error = true end,
			confirm = function() return true end, info = function() end,
		}
		body(Rows, calls, dialogs, entry)
	end, debug.traceback)
	for _, name in ipairs(SAVED) do package.loaded[name] = saved[name] end
	assert(ok, err)
end

local function engine(calls)
	return {
		get_backend = function() return "api" end,
		set_backend = function(id) calls.backend[#calls.backend + 1] = id; return true end,
	}
end

local function by_name(api)
	local rows = {}
	for _, row in ipairs(api.rows) do rows[row.name] = row end
	return rows
end

helpers.describe("model selector API listing on Linux", function()
	helpers.it("(model-selector-api-listing) lists one row per listed model and selects another one", function()
		with_rows({}, function(Rows, calls, dialogs)
			local api = Rows.api_page(engine(calls), dialogs, function() end, nil,
				{ e1 = { state = "listed", ids = { "gpt-4.1", "o3" } } })
			local rows = by_name(api)
			helpers.assert_not_nil(rows["openai/gpt-4o"], "the configured model")
			helpers.assert_not_nil(rows["openai/gpt-4.1"])
			helpers.assert_not_nil(rows["openai/o3"])
			helpers.assert_nil(rows["openai"], "a listed provider has no typed-id row")
			helpers.assert_nil(rows["openai/o-extra"], "a listing replaces the known models")
			helpers.assert_true(rows["openai/o3"].run())
			helpers.assert_eq(calls.backend[1], "api")
			helpers.assert_eq(calls.set_model[1], "e1:o3", "another listed model becomes the entry's model")
			helpers.assert_true(rows["openai/gpt-4o"].run())
			helpers.assert_eq(calls.set_active[1], "e1", "the configured model selects the entry")
		end)
	end)

	helpers.it("(model-selector-api-listing) falls back to the known models and a typed-id row with the reason", function()
		local cases = {
			{ listing = { state = "failed", reason = "refused" }, hint = "model_browser.hint_api_listing_refused" },
			{ listing = { state = "pending" }, hint = "model_browser.hint_api_listing_pending" },
			{ listing = nil, hint = "model_browser.hint_api_listing_unavailable" },
		}
		for _, case in ipairs(cases) do
			with_rows({ typed = " gpt-5 " }, function(Rows, calls, dialogs)
				local api = Rows.api_page(engine(calls), dialogs, function() end, nil, { e1 = case.listing })
				local rows = by_name(api)
				helpers.assert_not_nil(rows["openai/gpt-4o"])
				helpers.assert_not_nil(rows["openai/gpt-4o-mini"], "the provider's default model")
				helpers.assert_not_nil(rows["openai/o-extra"], "the catalogue's model extras")
				local typed = rows["openai"]
				helpers.assert_not_nil(typed, "the typed-id row")
				helpers.assert_eq(typed.hint_key, case.hint)
				helpers.assert_eq(typed.available, false)
				helpers.assert_nil(typed.run, "the typed-id row activates nothing")
				helpers.assert_eq(typed.actions[1].id, "other_model")
				helpers.assert_true(typed.actions[1].run())
				helpers.assert_eq(calls.set_model[1], "e1:gpt-5", "the typed id becomes the entry's model")
			end)
		end
	end)

	helpers.it("(model-selector-api-listing) list_models maps answers and keeps the key out of the log", function()
		local saved = package.loaded["adapters.http_client"]
		local saved_remote = package.loaded["modules.llm.api_remote"]
		local answers, requests = {}, {}
		package.loaded["adapters.http_client"] = setmetatable({
			get = function(url, headers, options, callback)
				requests[#requests + 1] = { url = url, headers = headers, owner = options.owner }
				callback(table.remove(answers, 1))
				return true
			end,
		}, { __index = saved })
		package.loaded["modules.llm.api_remote"] = nil
		local ok, err = xpcall(function()
			local Remote = require("modules.llm.api_remote")
			local entry = { id = "e1", provider = "openai", token = "sk-secret", model = "gpt-4o", base_url = "" }
			local got = {}
			local function done(state) got[#got + 1] = state end
			answers = {
				{ ok = true, status = 200, body = '{"data":[{"id":"o3"},{"id":"gpt-4.1"}]}' },
				{ ok = false, status = 401, error_body = "{}" },
				{ ok = false, status = 0, error = "timeout" },
				{ ok = true, status = 200, body = '{"error":{}}' },
			}
			for _ = 1, 4 do helpers.assert_true(Remote.list_models(entry, done)) end
			helpers.assert_eq(got[1].state, "listed")
			helpers.assert_eq(table.concat(got[1].ids, ","), "gpt-4.1,o3")
			helpers.assert_eq(got[2].reason, "refused")
			helpers.assert_eq(got[3].reason, "unavailable")
			helpers.assert_eq(got[4].reason, "unreadable")
			helpers.assert_eq(requests[1].url, "https://api.openai.com/v1/models")
			helpers.assert_eq(requests[1].headers.Authorization, "Bearer sk-secret", "the key rides in the header")
			helpers.assert_true(requests[1].owner ~= "llm_remote", "a listing never shares the predictions' owner")
			helpers.assert_eq(Remote.list_models({ id = "d", provider = "typesafe", token = "k", model = "jev" }, done), false)
			helpers.assert_eq(got[5].reason, "unsupported")
		end, debug.traceback)
		package.loaded["adapters.http_client"] = saved
		package.loaded["modules.llm.api_remote"] = saved_remote
		assert(ok, err)
	end)
end)

helpers.describe("Ollama install state on Linux", function()
	local function ports(fields)
		return {
			failure = function() return fields.failure end,
			managed = function() return fields.managed or "missing" end,
			system_command = function() return fields.system == true end,
			loopback = function(origin) return origin:find("127.0.0.1", 1, true) ~= nil end,
		}
	end
	local function llm(models, origin)
		return { get_cached_models = function() return models or {} end,
			get_base_url = function() return origin or "http://127.0.0.1:11435" end }
	end

	helpers.it("(linux-ollama-install-state) greys an absent or failed runtime with its reason", function()
		local State = helpers.load_module("modules.llm.ollama_install_state")
		local cases = {
			{ fields = {}, available = false, cause = "absent" },
			{ fields = { managed = "installed" }, available = true, cause = "installed" },
			-- An Ollama the user installed never counts: Ergopti runs only its own.
			{ fields = { system = true }, available = false, cause = "absent" },
			{ fields = { failure = "runtime_install_failed", managed = "installed" }, available = false, cause = "install_failed" },
			{ fields = {}, models = { "qwen3:4b" }, available = true, cause = "answering" },
			{ fields = {}, origin = "http://gpu.lan:11434", available = true, cause = "remote" },
		}
		for _, case in ipairs(cases) do
			local available, reason, cause = State.capture(llm(case.models, case.origin), ports(case.fields))
			helpers.assert_eq(available, case.available, case.cause)
			helpers.assert_eq(cause, case.cause)
			helpers.assert_eq(reason, (not case.available) and "model_browser.reason_ollama_missing" or nil, case.cause)
		end
	end)

	helpers.it("(linux-ollama-install-state) a failed repair greys Ollama until the next success", function()
		local State = helpers.load_module("modules.llm.ollama_install_state")
		State._reset()
		local live = ports({ managed = "installed" })
		live.failure = State.failure
		helpers.assert_eq(State.capture(llm(), live), true)
		State.note_repair({ ok = false, error = "runtime_install_failed" })
		helpers.assert_eq(State.failure(), "runtime_install_failed")
		helpers.assert_eq(State.capture(llm(), live), false, "the recorded failure greys an installed runtime")
		State.note_repair({ ok = false, error = "runtime_cancelled" })
		helpers.assert_eq(State.failure(), "runtime_install_failed", "a cancellation clears nothing")
		State.note_repair({ ok = true })
		helpers.assert_nil(State.failure(), "a success clears the failure")
		helpers.assert_eq(State.capture(llm(), live), true)
		State._reset()
	end)

	helpers.it("(linux-ollama-install-state) the page binding greys the Ollama group with that reason", function()
		local source = assert(io.open(helpers.driver_root() .. "/ui/model_browser/bridge.lua", "r"))
		local code = source:read("*a"); source:close()
		helpers.assert_true(code:find("_bound.ollama_state(frame.llm)", 1, true) ~= nil, "the payload reads the bound state")
		helpers.assert_true(code:find('backend_entry("ollama", { available = blocked == nil and ollama_ok, reason_key = blocked or ollama_reason', 1, true) ~= nil,
			"the Ollama group is greyed with the state's reason")
		local rows = assert(io.open(helpers.driver_root() .. "/ui/menu/llm_backend_rows.lua", "r"))
		local bind = rows:read("*a"); rows:close()
		helpers.assert_true(bind:find('require("modules.llm.ollama_install_state").capture(engine)', 1, true) ~= nil,
			"the menu binds the real install state")
		local engine_file = assert(io.open(helpers.driver_root() .. "/modules/llm/prediction_engine.lua", "r"))
		local engine_code = engine_file:read("*a"); engine_file:close()
		helpers.assert_true(engine_code:find('require("modules.llm.ollama_install_state").note_repair(result)', 1, true) ~= nil,
			"the owned repair records its result")
	end)
end)
