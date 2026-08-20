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
		local check_client = get_upvalue(ApiRemote.warmup, "_check_client")
		local original_get = check_client.get
		local requests = 0
		check_client.get = function() requests = requests + 1 end

		local ok, err = pcall(function()
			ApiRemote.set_entries({ entry_a, entry_b })
			ApiRemote.set_active_entry_id("entry-a")
			ApiRemote.set_active_entry_id("")
			helpers.assert_eq(ApiRemote.get_active_entry(), nil)
			ApiRemote.warmup()
			helpers.assert_eq(requests, 0,
				"No Model must not silently warm or infer with the first configured entry")
		end)
		check_client.get = original_get
		if not ok then error(err) end
	end)

	helpers.it("(remote-identity-generation) discards an old health callback after the active entry changes", function()
		local check_client = get_upvalue(ApiRemote.warmup, "_check_client")
		local original_get = check_client.get
		local callback
		check_client.get = function(_, _, on_done) callback = on_done end

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
		check_client.get = original_get
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
end)
