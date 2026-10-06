--- tests/unit/modules/llm/test_api_remote_identity_generation.lua

--- ==============================================================================
--- MODULE: Regression — remote entry identity is an async generation boundary
--- DESCRIPTION:
--- Proves that selecting "No Model" is a real runtime state and that callbacks
--- owned by entry A cannot mutate readiness or publish/fail a prediction after
--- the user selects entry B.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm.api_remote"] = nil
local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

local entry_a = {
	id = "entry-a", provider = "fixture", base_url = "https://a.invalid",
	token = "token-a", model = "model-a",
}
local entry_b = {
	id = "entry-b", provider = "fixture", base_url = "https://b.invalid",
	token = "token-b", model = "model-b",
}

ApiRemote.PROVIDERS.fixture = {
	label = "Fixture", base_url = "https://default.invalid",
	default_model = "fixture-model", format = "openai",
}

helpers.describe("api_remote entry identity generation", function()
	helpers.it("(remote-identity-generation) treats an empty active id as No Model instead of selecting the first entry", function()
		local warmup_client = get_upvalue(ApiRemote.warmup, "_warmup_client")
		helpers.assert_true(warmup_client ~= nil,
			"warmup must retain its dedicated semantic HTTP owner")
		local original_get = warmup_client.get
		local requests = 0
		warmup_client.get = function() requests = requests + 1 end

		local ok, err = pcall(function()
			ApiRemote.set_entries({ entry_a, entry_b })
			ApiRemote.set_active_entry_id("entry-a")
			ApiRemote.set_active_entry_id("")
			helpers.assert_eq(ApiRemote.get_active_entry(), nil)
			ApiRemote.warmup()
			helpers.assert_eq(requests, 0,
				"No Model must not silently warm or infer with the first configured entry")
		end)
		warmup_client.get = original_get
		if not ok then error(err) end
	end)

	helpers.it("(remote-identity-generation) discards an old health callback after the active entry changes", function()
		local warmup_client = get_upvalue(ApiRemote.warmup, "_warmup_client")
		helpers.assert_true(warmup_client ~= nil,
			"warmup must retain its dedicated semantic HTTP owner")
		local original_get = warmup_client.get
		local callback
		warmup_client.get = function(_, _, on_done) callback = on_done end

		local ok, err = pcall(function()
			ApiRemote.set_entries({ entry_a, entry_b })
			ApiRemote.set_active_entry_id("entry-a")
			ApiRemote.warmup()
			helpers.assert_eq(type(callback), "function")
			ApiRemote.set_active_entry_id("entry-b")
			helpers.assert_eq(ApiRemote.is_ready(), false)
			callback({ ok = true, status = 200, body = "" })
			helpers.assert_eq(ApiRemote.is_ready(), false,
				"entry A cannot mark entry B ready")
		end)
		warmup_client.get = original_get
		if not ok then error(err) end
	end)

	helpers.it("(remote-identity-generation) discards an old inference callback after the active entry changes", function()
		local infer_client = get_upvalue(ApiRemote.cancel_streaming, "_infer_client")
		helpers.assert_true(infer_client ~= nil,
			"cancel_streaming and request dispatch must share the owned inference client")
		local original_post = infer_client.post
		local callback
		infer_client.post = function(_, _, _, on_done) callback = on_done end
		local successes, failures = 0, 0

		local ok, err = pcall(function()
			ApiRemote.set_entries({ entry_a, entry_b })
			ApiRemote.set_active_entry_id("entry-a")
			ApiRemote.fetch_batch(
				"typed context", "", "model-a", 0.2, 8, 1, { batch = false },
				function() successes = successes + 1 end,
				function() failures = failures + 1 end)
			helpers.assert_eq(type(callback), "function")
			ApiRemote.set_active_entry_id("entry-b")
			callback({ ok = false, status = 401, body = "entry A response" })
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(failures, 0,
				"entry A cannot fail or publish entry B's current request state")
		end)
		infer_client.post = original_post
		if not ok then error(err) end
	end)

	helpers.it("(config-outdated-api-provider) names once an entry whose provider this build no longer has", function()
		-- Warmup and predictions through it were off with a DEBUG line only.
		local warmup_client = get_upvalue(ApiRemote.warmup, "_warmup_client")
		local original_get = warmup_client.get
		local requests = 0
		warmup_client.get = function() requests = requests + 1 end
		local Logger = get_upvalue(ApiRemote.warmup, "Logger") or require("infra.logger")
		local real_warn, warnings = Logger.warn, {}
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local ok, err = pcall(function()
			ApiRemote.set_entries({ { id = "entry-old", provider = "retired_provider", token = "secret-token",
				model = "m", label = "Old" } })
			ApiRemote.set_active_entry_id("entry-old")
			ApiRemote.warmup()
			ApiRemote.warmup()
			helpers.assert_eq(requests, 0, "no request goes to a provider this build does not have")
			local named = {}
			for _, line in ipairs(warnings) do
				if line:find("retired_provider", 1, true) then named[#named + 1] = line end
			end
			helpers.assert_eq(#named, 1, table.concat(warnings, " | "))
			-- Named as the AI menu names it (api-entry-auto-name), never by its stored label
			helpers.assert_true(named[1]:find("retired_provider/m", 1, true) ~= nil, named[1])
			helpers.assert_true(named[1]:find("Old", 1, true) == nil, named[1])
			helpers.assert_true(named[1]:find("secret-token", 1, true) == nil, "a token never reaches a log")
		end)
		Logger.warn = real_warn
		warmup_client.get = original_get
		if not ok then error(err) end
	end)
end)


-- Real native readers consume these independent complete physical sources.
local PUBLICATION_CLOUD = [[{"provider_order":["openai"],"providers":{"openai":{"label":"Independent cloud","base_url":"https://api.openai.com/v1","default_model":"independent-model","format":"openai"}},"model_prices":{},"test_request":{"system_prompt":"Independent","user_text":"Independent","temperature":0,"max_tokens":1},"decisions_test":{"state":{"independent":true},"questions":{"one":{"type":"text","instructions":"Independent"}}}}]]
local PUBLICATION_LOCAL = [[{"server_order":["independent_local"],"servers":{"independent_local":{"label":"Independent local","base_url":"http://localhost:4321/v1","auth":"optional"}}}]]

--- Runs the actual catalogue loaders over private files; only native ports vary.
--- @param cloud string|false Cloud source, or an absent path.
--- @param local_source string|false Local source, or an absent path.
--- @param callback function Actual native owner and recorded diagnostics.
--- @param close_refused boolean|nil Inject a refused cloud close receipt.
local function with_publication_sources(cloud, local_source, callback, close_refused)
	helpers.with_stub_scope({ "modules.llm.api_remote", "modules.llm.local_servers", "infra.paths",
		"infra.logger", "llm.provider_config_policy" }, function()
		-- Establish the native ports once. A second load_with_stubs would replace
		-- the path owner and hide the source under examination.
		helpers.load_with_stubs("modules.llm.api_remote")
		local paths = require("infra.paths")
		local original_path = paths.shared_llm_path
		local logger = require("infra.logger")
		local original_warn, original_error = logger.warn, logger.error
		local original_open = io.open
		local cloud_path, local_path = os.tmpname(), os.tmpname()
		local warnings, errors = {}, {}
		local function write(path, source)
			if source == false then os.remove(path); return end
			local file = assert(original_open(path, "wb"))
			assert(file:write(source)); assert(file:close())
		end
		write(cloud_path, cloud); write(local_path, local_source)
		paths.shared_llm_path = function(name)
			if name == "api_providers.json" then return cloud_path end
			if name == "local_servers.json" then return local_path end
			return original_path(name)
		end
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		if close_refused then
			io.open = function(path, mode)
				local file, err, code = original_open(path, mode)
				if path ~= cloud_path or not file or mode ~= "r" then return file, err, code end
				return {
					read = function(_, ...) return file:read(...) end,
					close = function() assert(file:close()); return nil, "controlled close refusal" end,
				}
			end
		end
		local outcome = table.pack(xpcall(function()
			package.loaded["modules.llm.api_remote"], package.loaded["modules.llm.local_servers"] = nil, nil
			local owner = require("modules.llm.api_remote")
			callback(owner, {
				warnings = warnings, errors = errors, cloud_path = cloud_path, local_path = local_path,
				read = function(path)
					local file = assert(original_open(path, "rb"))
					local source = assert(file:read("*a")); assert(file:close()); return source
				end,
			})
		end, debug.traceback))
		io.open = original_open
		paths.shared_llm_path = original_path
		logger.warn, logger.error = original_warn, original_error
		os.remove(cloud_path); os.remove(local_path)
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

--- Exercises all three unchanged absent-provider paths without an HTTP dispatch.
--- @param owner table Actual remote owner.
--- @param observed table Native diagnostics and source ports.
--- @param expected integer Exact retirement warning count.
local function assert_missing_provider_routes(owner, observed, expected)
	local entry = { id = "independent-missing", provider = "removed_provider", token = "controlled-token",
		model = "noncatalogue-custom-model", future = { independent = false } }
	owner.set_entries({ entry })
	owner.set_active_entry_id(entry.id)
	local requests, acquired, missing, failed, delivered, cancelled = 0, {}, {}, 0, 0, 0
	for _, pair in ipairs({ { owner.warmup, "_warmup_client" }, { owner.check_availability, "_check_client" },
		{ owner.cancel_streaming, "_infer_client" } }) do
		local client = assert(get_upvalue(pair[1], pair[2]))
		client.get = function() requests = requests + 1 end
		client.post = function() requests = requests + 1 end
	end
	helpers.assert_eq(owner.warmup(nil, nil, function(value) acquired[#acquired + 1] = value end), false)
	helpers.assert_eq(owner.check_availability(nil,
		function() delivered = delivered + 1 end,
		function(value) missing[#missing + 1] = value end,
		function() cancelled = cancelled + 1 end), false)
	owner.request_raw(entry.model, "Independent", "Independent", "", 0, 1,
		function() delivered = delivered + 1 end,
		function() failed = failed + 1 end)
	owner.warmup()
	helpers.assert_eq(requests, 0)
	helpers.assert_eq(acquired, { false }, "warmup refusal keeps its exact acquisition acknowledgement")
	helpers.assert_eq(missing, { true }, "availability still terminalizes missing exactly once")
	helpers.assert_eq(failed, 1, "inference still refuses once")
	helpers.assert_eq(delivered, 0)
	helpers.assert_eq(cancelled, 0)
	helpers.assert_true(rawequal(owner.get_entries()[1], entry), "unavailable/retired classification never rewrites stored row identity")
	helpers.assert_eq(entry.future, { independent = false })
	helpers.assert_eq(entry.model, "noncatalogue-custom-model")
	local retired = {}
	for _, message in ipairs(observed.warnings) do
		if message:find("which this build no longer has", 1, true) then retired[#retired + 1] = message end
	end
	helpers.assert_eq(#retired, expected, table.concat(observed.warnings, " | "))
	for _, message in ipairs(observed.warnings) do
		helpers.assert_true(message:find(entry.token, 1, true) == nil, "private tokens stay outside diagnostics")
	end
end

helpers.describe("Actual provider catalogue publication", function()
	for _, vector in ipairs({
		{ name = "valid complete pair", cloud = PUBLICATION_CLOUD, local_source = PUBLICATION_LOCAL, expected = 1 },
		{ name = "valid empty local list", cloud = PUBLICATION_CLOUD, local_source = '{"server_order":[],"servers":{}}', expected = 1 },
		{ name = "malformed cloud", cloud = "{ malformed", local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "absent cloud", cloud = false, local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "wrong-shaped cloud order", cloud = PUBLICATION_CLOUD:gsub('%["openai"%]', '{"one":"openai"}'), local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "duplicate cloud order", cloud = PUBLICATION_CLOUD:gsub('%["openai"%]', '["openai","openai"]'), local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "missing declared cloud descriptor", cloud = PUBLICATION_CLOUD:gsub('%["openai"%]', '["openai","missing_descriptor"]'), local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "empty refused cloud list", cloud = PUBLICATION_CLOUD:gsub('%["openai"%]', '[]'), local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "native-erased cloud null slot", cloud = PUBLICATION_CLOUD:gsub('%["openai"%]', '["openai",null]'), local_source = PUBLICATION_LOCAL, expected = 0 },
		{ name = "native-erased local null slot", cloud = PUBLICATION_CLOUD, local_source = '{"server_order":[null],"servers":{}}', expected = 0 },
		{ name = "unacknowledged cloud close", cloud = PUBLICATION_CLOUD, local_source = PUBLICATION_LOCAL, close_refused = true, expected = 0 },
		{ name = "malformed local", cloud = PUBLICATION_CLOUD, local_source = "{ malformed", expected = 0 },
		{ name = "absent local", cloud = PUBLICATION_CLOUD, local_source = false, expected = 0 },
		{ name = "empty object instead of local order", cloud = PUBLICATION_CLOUD, local_source = '{"server_order":{},"servers":{}}', expected = 0 },
		{ name = "empty array instead of local descriptors", cloud = PUBLICATION_CLOUD, local_source = '{"server_order":[],"servers":[]}', expected = 0 },
		{ name = "duplicate local order", cloud = PUBLICATION_CLOUD, local_source = PUBLICATION_LOCAL:gsub('%["independent_local"%]', '["independent_local","independent_local"]'), expected = 0 },
		{ name = "cloud local collision", cloud = PUBLICATION_CLOUD, local_source = PUBLICATION_LOCAL:gsub("independent_local", "openai"), expected = 0 },
	}) do
		helpers.it("(provider-publication-route) " .. vector.name .. " cannot invent retirement authority", function()
			with_publication_sources(vector.cloud, vector.local_source, function(owner, observed)
				assert_missing_provider_routes(owner, observed, vector.expected)
				if vector.cloud ~= false then helpers.assert_eq(observed.read(observed.cloud_path), vector.cloud) end
				if vector.local_source ~= false then helpers.assert_eq(observed.read(observed.local_path), vector.local_source) end
			end, vector.close_refused)
		end)
	end

	helpers.it("(provider-publication-receipt) actual snapshots are detached from runtime map mutations", function()
		with_publication_sources(PUBLICATION_CLOUD, PUBLICATION_LOCAL, function(owner)
			local policy = require("llm.provider_config_policy")
			local first = owner.provider_config_receipt()
			helpers.assert_eq(first.published, true)
			helpers.assert_eq(policy.classify("openai", first), "known")
			helpers.assert_eq(policy.classify("independent_local", first), "known")
			helpers.assert_eq(policy.classify("removed_provider", first), "retired")
			first.ids.removed_provider = true
			owner.PROVIDERS.runtime_only = {}
			local second = owner.provider_config_receipt()
			helpers.assert_eq(policy.classify("removed_provider", second), "retired")
			helpers.assert_eq(policy.classify("runtime_only", second), "retired")
			helpers.assert_true(first ~= second and first.ids ~= second.ids)
		end)
	end)

	helpers.it("(provider-publication-route) actual known provider permits noncatalogue custom model identifiers", function()
		for _, sources in ipairs({
			{ cloud = PUBLICATION_CLOUD, local_source = PUBLICATION_LOCAL },
			{ cloud = PUBLICATION_CLOUD, local_source = "{ malformed" },
			{ cloud = PUBLICATION_CLOUD:gsub('%["openai"%]', '["openai","missing_descriptor"]'), local_source = PUBLICATION_LOCAL },
		}) do
			with_publication_sources(sources.cloud, sources.local_source, function(owner, observed)
				local entry = { id = "independent-known", provider = "openai", token = "controlled-token", model = "outside-the-shipped-model-list" }
				owner.set_entries({ entry }); owner.set_active_entry_id(entry.id)
				local client = assert(get_upvalue(owner.cancel_streaming, "_infer_client"))
				local body
				client.post = function(_, _, raw) body = raw end
				owner.request_raw(entry.model, "Independent", "Independent", "", 0, 1, function() end, function() end)
				helpers.assert_type(body, "string")
				local decoded = assert(require("adapters.json_codec").decode(body))
				helpers.assert_eq(decoded.model, entry.model)
				helpers.assert_true(rawequal(owner.get_entries()[1], entry))
				for _, message in ipairs(observed.warnings) do
					helpers.assert_true(message:find("which this build no longer has", 1, true) == nil)
				end
			end)
		end
	end)
end)
