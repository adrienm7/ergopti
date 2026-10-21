--- tests/unit/modules/llm/remote/test_nonchat_probe_isolation.lua

--- ==============================================================================
--- MODULE: Independent Non-Chat Connectivity Probe Ownership
--- DESCRIPTION:
--- Runs actual remote producers over explicit HTTP admission and settlement
--- ports. A non-chat Test action must not cancel chat or agent inference, while
--- explicit cancellation still retires every originally captured exchange.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
require("modules.llm.api_remote")

local CHAT = { provider = "openai_compat", model = "owned-model", token = "owned-fixture-token",
	base_url = "http://127.0.0.1:1234/chat" }
local PROBE = { provider = "typesafe", model = "jev-latest", token = "owned-fixture-token",
	base_url = "http://127.0.0.1:1234/decision" }

local function isolated(body)
	local names = { "modules.llm.api_remote", "adapters.http_client", "logger.shim" }
	local saved, world = {}, { calls = {}, cancels = {}, refuse = {} }
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	package.loaded["adapters.http_client"] = {
		post = function(url, _, payload, callback, options)
			world.calls[#world.calls + 1] = { url = url, payload = Json.decode(payload), callback = callback, options = options }
			return true
		end,
		cancel = function(owner)
			world.cancels[#world.cancels + 1] = owner
			if world.on_cancel then world.on_cancel(owner) end
			return world.refuse[owner] ~= true
		end,
	}
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	local ok, detail = xpcall(function()
		world.remote = helpers.load_module("modules.llm.api_remote")
		world.remote._reset_for_test()
		function world.answer(index, receipt)
			world.calls[index].callback(receipt or { ok = true, status = 200,
				body = world.calls[index].payload.questions and '{"answers":{"ok":true}}'
					or '{"choices":[{"message":{"content":"owned reply"}}]}' })
		end
		body(world)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

local function chat(world, seen)
	return world.remote.chat(CHAT, nil, { { role = "user", content = "owned context" } }, {},
		function(text) seen.chunks = (seen.chunks or 0) + 1; seen.chunk = text end,
		function(text, err) seen.done = (seen.done or 0) + 1; seen.text, seen.error = text, err end)
end
local function probe(world, seen, admit, entry)
	return world.remote.test(entry or PROBE, function(ok, detail)
		seen.done = (seen.done or 0) + 1; seen.ok, seen.detail = ok, detail
	end, admit)
end

helpers.describe("non-chat probe isolation", function()
	for _, order in ipairs({ "chat-first", "probe-first" }) do
		helpers.it("preserves both native owners in " .. order .. " order", function()
			isolated(function(w)
				local completion, verdict = {}, {}
				if order == "chat-first" then helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, verdict))
				else helpers.assert_true(probe(w, verdict)); helpers.assert_true(chat(w, completion)) end
				helpers.assert_eq(#w.calls, 2)
				helpers.assert_eq(w.cancels, {})
				helpers.assert_true(w.calls[1].options.owner ~= w.calls[2].options.owner)
				w.answer(1); w.answer(2)
				helpers.assert_eq(completion.done, 1)
				helpers.assert_eq(completion.text, "owned reply")
				helpers.assert_nil(completion.error)
				helpers.assert_eq(verdict.done, 1)
				helpers.assert_eq(verdict.ok, true)
				helpers.assert_eq(w.remote.is_active(), false)
			end)
		end)
	end
	for _, provider in ipairs({ "typesafe", "openrouter_jev" }) do
		helpers.it("replaces only the older " .. provider .. " probe and fences its late reply", function()
			isolated(function(w)
				local completion, previous, next_verdict = {}, {}, {}
				helpers.assert_true(chat(w, completion))
				helpers.assert_true(probe(w, previous))
				local entry = {}; for key, value in pairs(PROBE) do entry[key] = value end; entry.provider = provider
				helpers.assert_true(probe(w, next_verdict, nil, entry))
				helpers.assert_eq(w.cancels, { w.calls[2].options.owner })
				w.answer(2); w.answer(3); w.answer(1)
				helpers.assert_nil(previous.done)
				helpers.assert_eq(next_verdict.done, 1)
				helpers.assert_eq(next_verdict.ok, true)
				helpers.assert_eq(completion.done, 1)
			end)
		end)
	end
	helpers.it("keeps a direct agent decision in the inference scope", function()
		isolated(function(w)
			local previous, verdict, decisions = {}, {}, 0
			helpers.assert_true(chat(w, previous)); helpers.assert_true(probe(w, verdict))
			helpers.assert_true(w.remote.decide(PROBE, "owned state", { ok = { type = "noul" } }, function() decisions = decisions + 1 end))
			helpers.assert_eq(w.cancels, { w.calls[1].options.owner })
			w.answer(1); w.answer(2); w.answer(3)
			helpers.assert_nil(previous.done)
			helpers.assert_eq(verdict.done, 1)
			helpers.assert_eq(decisions, 1)
		end)
	end)
	helpers.it("retains the ordinary chat-provider Test supersession contract", function()
		isolated(function(w)
			local completion, verdict = {}, {}
			helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, verdict, nil, CHAT))
			helpers.assert_eq(w.cancels, { "llm_remote" })
			w.answer(1); w.answer(2)
			helpers.assert_nil(completion.done)
			helpers.assert_eq(verdict.done, 1)
			helpers.assert_eq(verdict.ok, true)
		end)
	end)
	for _, refusal in ipairs({ "none", "inference", "probe" }) do
		helpers.it("explicit cancellation visits both scopes when refusal is " .. refusal, function()
			isolated(function(w)
				local completion, verdict = {}, {}
				helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, verdict))
				local inference, test_owner = w.calls[1].options.owner, w.calls[2].options.owner
				if refusal ~= "none" then w.refuse[refusal == "inference" and inference or test_owner] = true end
				helpers.assert_eq(w.remote.cancel(), refusal == "none")
				helpers.assert_eq(w.cancels, { inference, test_owner })
				if refusal == "none" then
					w.answer(1); w.answer(2)
					helpers.assert_nil(completion.done); helpers.assert_nil(verdict.done)
					helpers.assert_eq(w.remote.is_active(), false)
				else
					w.refuse = {}; helpers.assert_true(w.remote.cancel())
					helpers.assert_eq(w.remote.is_active(), false)
				end
			end)
		end)
	end
	helpers.it("does not cancel a successor probe created by the first cancellation callback", function()
		isolated(function(w)
			local completion, previous, successor = {}, {}, {}
			helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, previous))
			local owner = w.calls[1].options.owner
			w.on_cancel = function(name)
				if name == owner then w.on_cancel = nil; helpers.assert_true(probe(w, successor)) end
			end
			helpers.assert_true(w.remote.cancel())
			helpers.assert_eq(#w.calls, 3)
			helpers.assert_eq(#w.cancels, 2, "old probe retirement belongs only to the nested successor admission")
			w.answer(1); w.answer(2); w.answer(3)
			helpers.assert_nil(completion.done); helpers.assert_nil(previous.done)
			helpers.assert_eq(successor.done, 1)
			helpers.assert_eq(successor.ok, true)
		end)
	end)
	helpers.it("does not cancel a first-ever probe created during inference retirement", function()
		isolated(function(w)
			local completion, successor = {}, {}
			helpers.assert_true(chat(w, completion))
			w.on_cancel = function() w.on_cancel = nil; helpers.assert_true(probe(w, successor)) end
			helpers.assert_true(w.remote.cancel())
			helpers.assert_eq(#w.cancels, 1)
			w.answer(1); w.answer(2)
			helpers.assert_nil(completion.done)
			helpers.assert_eq(successor.done, 1)
		end)
	end)
	helpers.it("preserves a successor probe even when the first cancellation refuses", function()
		isolated(function(w)
			local completion, previous, successor = {}, {}, {}
			helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, previous))
			local owner = w.calls[1].options.owner
			w.refuse[owner] = true
			w.on_cancel = function(name)
				if name == owner then w.on_cancel = nil; helpers.assert_true(probe(w, successor)) end
			end
			helpers.assert_eq(w.remote.cancel(), false)
			helpers.assert_eq(#w.cancels, 2)
			w.answer(2); w.answer(3)
			helpers.assert_nil(previous.done)
			helpers.assert_eq(successor.done, 1)
			w.refuse = {}; helpers.assert_true(w.remote.cancel())
		end)
	end)
	helpers.it("visits the probe HTTP owner after its logical terminal cleared activity", function()
		isolated(function(w)
			local verdict = {}
			helpers.assert_true(probe(w, verdict)); w.answer(1)
			helpers.assert_eq(verdict.done, 1)
			helpers.assert_eq(w.remote.is_active(), false)
			helpers.assert_true(w.remote.cancel())
			helpers.assert_eq(w.cancels, { "llm_remote", w.calls[1].options.owner },
				"a boolean terminal callback does not prove physical HTTP settlement")
		end)
	end)
	helpers.it("fences both old callback lifetimes when the test-only state resets", function()
		isolated(function(w)
			local completion, verdict = {}, {}
			helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, verdict))
			w.remote._reset_for_test()
			w.answer(1); w.answer(2)
			helpers.assert_nil(completion.done); helpers.assert_nil(verdict.done)
			helpers.assert_eq(w.remote.is_active(), false)
		end)
	end)
	for _, phase in ipairs({ "inference", "probe" }) do
		helpers.it("preserves inference admitted during the " .. phase .. " cancellation callback", function()
			isolated(function(w)
				local previous, verdict, successor = {}, {}, {}
				helpers.assert_true(chat(w, previous)); helpers.assert_true(probe(w, verdict))
				local observed = w.calls[phase == "inference" and 1 or 2].options.owner
				w.on_cancel = function(name)
					if name == observed then w.on_cancel = nil; helpers.assert_true(chat(w, successor)) end
				end
				helpers.assert_true(w.remote.cancel())
				w.answer(1); w.answer(2); w.answer(3)
				helpers.assert_nil(previous.done); helpers.assert_nil(verdict.done)
				helpers.assert_eq(successor.done, 1)
				helpers.assert_eq(successor.text, "owned reply")
			end)
		end)
	end
	helpers.it("cannot replace a newer probe admitted by its source callback", function()
		isolated(function(w)
			local completion, previous, successor = {}, {}, {}
			helpers.assert_true(chat(w, completion))
			local nested, started = false, false
			local outer = probe(w, previous, function()
				if not nested then nested = true; started = probe(w, successor) end
				return true
			end)
			helpers.assert_eq(outer, false); helpers.assert_eq(started, true)
			helpers.assert_eq(w.cancels, {})
			w.answer(1); w.answer(2)
			helpers.assert_eq(completion.done, 1)
			helpers.assert_eq(successor.done, 1)
			helpers.assert_nil(previous.done)
		end)
	end)
	for _, failure in ipairs({ "http", "provider" }) do
		helpers.it("retains inference when a probe has a terminal " .. failure .. " refusal", function()
			isolated(function(w)
				local completion, verdict = {}, {}
				helpers.assert_true(chat(w, completion)); helpers.assert_true(probe(w, verdict))
				w.answer(2, failure == "http" and { ok = false, status = 401, error_body = '{"error":"owned refusal"}' }
					or { ok = true, status = 200, body = '{"answers":{"ok":true},"error":null}' })
				helpers.assert_eq(verdict.done, 1); helpers.assert_eq(verdict.ok, false)
				helpers.assert_true(w.remote.is_active())
				w.answer(1)
				helpers.assert_eq(completion.done, 1)
			end)
		end)
	end
	helpers.it("refuses stale probe admission without retiring inference", function()
		isolated(function(w)
			local completion, verdict = {}, {}
			helpers.assert_true(chat(w, completion))
			helpers.assert_eq(probe(w, verdict, function() return false end), false)
			helpers.assert_eq(#w.calls, 1); helpers.assert_eq(w.cancels, {})
			w.answer(1); helpers.assert_eq(completion.done, 1); helpers.assert_nil(verdict.done)
		end)
	end)
end)
