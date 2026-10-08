--- tests/unit/modules/llm/test_api_remote_failure_receipts.lua
--- Independent production-caller controls: actual transport evidence stays
--- private and follows only its admitted exchange. No classification is mocked
--- or reconstructed from the adapter's error string.

local helpers = require("tests.helpers")

local CHAT = { { role = "user", content = "Synthetic fixture" } }
local ENTRY = { provider = "cerebras", token = "synthetic-key" }
local DECISION = { provider = "typesafe", token = "synthetic-key" }
local BACKBOARD = { provider = "backboard", token = "synthetic-key", model = "openai/gpt-4o" }

local function with_remote(control)
	local names = { "adapters.http_client", "modules.llm.api_remote" }
	local previous, calls = {}, {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	package.loaded["adapters.http_client"] = {
		post = function(url, headers, body, done, options)
			calls[#calls + 1] = { url = url, done = done, options = options }
			return true
		end,
		get = function(url, headers, options, done)
			calls[#calls + 1] = { url = url, done = done, options = options }
			return true
		end,
		cancel = function() return true end,
	}
	local remote = helpers.load_module("modules.llm.api_remote")
	remote._reset_for_test()
	local ok, err = pcall(control, remote, calls)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

local function response(receipt)
	return { ok = false, status = 403, error_body = '{"message":"Synthetic origin refusal"}',
		failure_receipt = receipt }
end

-- Deliberately ambiguous origin evidence. The caller must not upgrade this to
-- a host-blocked or proxy diagnosis; the canonical policy owns classification.
local function receipt()
	return { stage = "http", backend = "curl", curl_exit = 22, http_status = 403 }
end

helpers.describe("Remote API private failure receipts: actual caller admission", function()
	helpers.it("preserves a failed current chat's exact native receipt once", function()
		with_remote(function(remote, calls)
			local observed, count, actual = {}, 0, receipt()
			remote.chat(ENTRY, nil, CHAT, {}, nil, function(text, err, evidence)
				count = count + 1; observed = { text = text, err = err, receipt = evidence }
			end)
			calls[1].done(response(actual)); calls[1].done(response(receipt()))
			helpers.assert_eq(count, 1)
			helpers.assert_eq(observed.text, "")
			helpers.assert_eq(observed.err, "HTTP 403: Synthetic origin refusal")
			helpers.assert_eq(observed.receipt, actual)
			helpers.assert_eq(calls[1].options.owner, "llm_remote")
		end)
	end)

	helpers.it("does not invent evidence from a transport error string", function()
		with_remote(function(remote, calls)
			local actual = "unset"
			remote.chat(ENTRY, nil, CHAT, {}, nil, function(_, _, evidence) actual = evidence end)
			calls[1].done({ ok = false, status = 0, error = "certificate proxy offline disk permission" })
			helpers.assert_nil(actual)
		end)
	end)

	helpers.it("rejects non-table evidence without changing the old error callback", function()
		with_remote(function(remote, calls)
			local actual, detail
			remote.chat(ENTRY, nil, CHAT, {}, nil, function(_, err, evidence) detail, actual = err, evidence end)
			calls[1].done(response("untrusted string"))
			helpers.assert_eq(detail, "HTTP 403: Synthetic origin refusal")
			helpers.assert_nil(actual)
		end)
	end)

	helpers.it("discards stray failure evidence on successful HTTP replies", function()
		with_remote(function(remote, calls)
			local actual, text, err
			remote.chat(ENTRY, nil, CHAT, {}, nil, function(value, failure, evidence)
				text, err, actual = value, failure, evidence
			end)
			calls[1].done({ ok = true, status = 200, body = '{"choices":[{"message":{"content":"Synthetic success"}}]}',
				failure_receipt = receipt() })
			helpers.assert_eq(text, "Synthetic success")
			helpers.assert_nil(err); helpers.assert_nil(actual)
		end)
	end)

	helpers.it("keeps an empty application reply separate from network evidence", function()
		with_remote(function(remote, calls)
			local actual, detail
			remote.chat(ENTRY, nil, CHAT, {}, nil, function(_, err, evidence) detail, actual = err, evidence end)
			calls[1].done({ ok = true, status = 200, body = '{}', failure_receipt = receipt() })
			helpers.assert_eq(detail, "empty reply"); helpers.assert_nil(actual)
		end)
	end)

	helpers.it("preserves a decisions transport failure receipt", function()
		with_remote(function(remote, calls)
			local actual, evidence = receipt()
			remote.decide(DECISION, "Synthetic state", {}, function(_, _, value) evidence = value end)
			calls[1].done(response(actual)); helpers.assert_eq(evidence, actual)
		end)
	end)

	helpers.it("preserves Backboard assistant creation transport evidence", function()
		with_remote(function(remote, calls)
			local actual, evidence, detail = receipt()
			remote.chat(BACKBOARD, nil, CHAT, {}, nil, function(_, err, value) detail, evidence = err, value end)
			calls[1].done(response(actual))
			helpers.assert_eq(evidence, actual)
			helpers.assert_true(detail:find("assistant could not be created", 1, true) ~= nil)
			helpers.assert_eq(#calls, 1)
		end)
	end)

	helpers.it("preserves Backboard message transport evidence after actual creation", function()
		with_remote(function(remote, calls)
			local actual, evidence = receipt()
			remote.chat(BACKBOARD, nil, CHAT, {}, nil, function(_, _, value) evidence = value end)
			calls[1].done({ ok = true, status = 200, body = '{"assistant_id":"synthetic-assistant"}' })
			helpers.assert_eq(#calls, 2)
			calls[2].done(response(actual)); helpers.assert_eq(evidence, actual)
		end)
	end)

	helpers.it("preserves a failed local API models probe's private receipt", function()
		with_remote(function(remote, calls)
			local actual, evidence = receipt()
			local entry = { provider = "lmstudio", base_url = "http://127.0.0.1:1234/v1", token = "" }
			remote.models(entry, function(_, _, value) evidence = value end)
			helpers.assert_eq(#calls, 1)
			calls[1].done(response(actual)); helpers.assert_eq(evidence, actual)
		end)
	end)

	for _, entry in ipairs({ ENTRY, DECISION }) do
		helpers.it("retains the " .. entry.provider .. " Test receipt as its fourth private argument", function()
			with_remote(function(remote, calls)
				local actual, evidence, succeeded, elapsed = receipt()
				remote.test(entry, function(ok, _, ms, value) succeeded, elapsed, evidence = ok, ms, value end)
				calls[1].done(response(actual))
				helpers.assert_eq(succeeded, false)
				helpers.assert_true(type(elapsed) == "number")
				helpers.assert_eq(evidence, actual)
			end)
		end)
	end

	helpers.it("cannot lend a cancelled predecessor's evidence to a successor", function()
		with_remote(function(remote, calls)
			local old_count, new_count, actual, evidence = 0, 0, receipt()
			remote.chat(ENTRY, nil, CHAT, {}, nil, function() old_count = old_count + 1 end)
			local predecessor = calls[1]
			remote.chat(ENTRY, nil, CHAT, {}, nil, function(_, _, value) new_count = new_count + 1; evidence = value end)
			predecessor.done(response(receipt()))
			helpers.assert_eq(old_count, 0); helpers.assert_eq(new_count, 0)
			calls[2].done(response(actual))
			helpers.assert_eq(new_count, 1); helpers.assert_eq(evidence, actual)
		end)
	end)

	helpers.it("keeps a successful malformed JSON reply separate from native network failure", function()
		with_remote(function(remote, calls)
			local actual, detail
			remote.decide(DECISION, "Synthetic state", {}, function(_, err, evidence) detail, actual = err, evidence end)
			calls[1].done({ ok = true, status = 200, body = "not JSON", failure_receipt = receipt() })
			helpers.assert_eq(detail, "the answer is not a JSON object"); helpers.assert_nil(actual)
		end)
	end)

	helpers.it("does not attach evidence to a pre-dispatch API-key refusal", function()
		with_remote(function(remote, calls)
			local actual, detail
			remote.chat({ provider = "cerebras", token = "" }, nil, CHAT, {}, nil,
				function(_, err, evidence) detail, actual = err, evidence end)
			helpers.assert_eq(#calls, 0)
			helpers.assert_true(type(detail) == "string" and detail ~= "")
			helpers.assert_nil(actual)
		end)
	end)

	helpers.it("preserves the changed-token models fence before forwarding evidence", function()
		with_remote(function(remote, calls)
			local actual, detail
			local entry = { provider = "lmstudio", base_url = "http://127.0.0.1:1234/v1", token = "" }
			remote.models(entry, function(_, err, evidence) detail, actual = err, evidence end)
			entry.token = "synthetic-successor-key"
			calls[1].done(response(receipt()))
			helpers.assert_eq(detail, "identity_changed"); helpers.assert_nil(actual)
		end)
	end)
end)
