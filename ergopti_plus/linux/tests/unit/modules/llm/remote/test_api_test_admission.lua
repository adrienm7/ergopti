--- tests/unit/modules/llm/remote/test_api_test_admission.lua

--- ==============================================================================
--- MODULE: Remote API Probe Admission
--- DESCRIPTION:
--- Source-bound menu probes retain their exact authorization through request
--- preparation, native HTTP admission, Backboard caching and terminal delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Formats = require("llm.remote_formats")
local ENTRY = { provider = "cerebras", token = "synthetic-key" }
local BACKBOARD = { provider = "backboard", token = "synthetic-key" }
local MESSAGES = { { role = "user", content = "Synthetic probe." } }

--- Runs the actual remote module with an explicit HTTP acquisition boundary.
--- @param body function Receives the remote module and transport controls.
local function with_remote(body)
	local names = { "adapters.http_client", "logger.shim", "modules.llm.api_remote" }
	local previous, originals = {}, {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	for _, name in ipairs({ "backboard_assistant_id", "backboard_message_request" }) do
		originals[name] = Formats[name]
	end
	local state = { allowed = true, calls = {}, done = 0 }
	state.admit = function() return state.allowed end
	state.completed = function() state.done = state.done + 1 end
	package.loaded["adapters.http_client"] = {
		post = function(url, _, _, callback, options)
			if state.on_post then state.on_post() end
			if options.authorized and options.authorized() ~= true then return false end
			state.calls[#state.calls + 1] = { url = url, callback = callback, options = options }
			return true
		end,
		cancel = function() return true end,
	}
	local logger = {}
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
		logger[level] = function(_, text) if state.on_log then state.on_log(text) end end
	end
	package.loaded["logger.shim"] = logger
	package.loaded["modules.llm.api_remote"] = nil
	local remote = require("modules.llm.api_remote")
	remote._reset_for_test()
	state.answer = function(index, answer)
		state.calls[index].callback({ ok = true, status = 200, body = Json.encode(answer) })
	end
	state.answer_chat = function(index) state.answer(index, { choices = { { message = { content = "Probe reply." } } } }) end
	local ok, err = pcall(body, remote, state)
	for name, original in pairs(originals) do Formats[name] = original end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("Remote API probe exact admission", function()
	helpers.it("(api-probe-admission) sends one healthy probe and delivers its verdict once", function()
		with_remote(function(remote, state)
			helpers.assert_eq(remote.test(ENTRY, state.completed, state.admit), true)
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(type(state.calls[1].options.authorized), "function")
			state.answer_chat(1)
			state.answer_chat(1)
			helpers.assert_eq(state.done, 1)
			helpers.assert_eq(remote.is_active(), false)
		end)
	end)

	for _, refusal in ipairs({ "false", "truthy", "throw", "malformed" }) do
		helpers.it("(api-probe-admission) rejects " .. refusal .. " authorization before acquisition", function()
			with_remote(function(remote, state)
				local admission = false
				if refusal == "false" then admission = function() return false end
				elseif refusal == "truthy" then admission = function() return {} end
				elseif refusal == "throw" then admission = function() error("controlled authorization refusal") end end
				helpers.assert_eq(remote.test(ENTRY, state.completed, admission), false)
				helpers.assert_eq(remote.chat(ENTRY, nil, MESSAGES, { authorized = admission }, nil, state.completed), false)
				helpers.assert_eq(#state.calls, 0)
				helpers.assert_eq(state.done, 0)
			end)
		end)
	end

	for _, boundary in ipairs({ "spec", "logger", "native" }) do
		helpers.it("(api-probe-admission) revokes at " .. boundary .. " before the first POST", function()
			with_remote(function(remote, state)
				if boundary == "spec" then
					local spec = remote.test_request_spec
					remote.test_request_spec = function() local value = spec(); state.allowed = false; return value end
				elseif boundary == "logger" then state.on_log = function() state.allowed = false end
				else state.on_post = function() state.allowed = false end end
				remote.test(ENTRY, state.completed, state.admit)
				helpers.assert_eq(#state.calls, 0)
				helpers.assert_eq(state.done, 0)
				helpers.assert_eq(remote.is_active(), false)
			end)
		end)
	end

	helpers.it("(api-probe-admission) pins the original function before request preparation", function()
		with_remote(function(remote, state)
			local options = { authorized = state.admit }
			local build = remote.build_request
			remote.build_request = function(...)
				local request, reason = build(...)
				state.allowed, options.authorized = false, function() return true end
				return request, reason
			end
			remote.chat(ENTRY, nil, MESSAGES, options, nil, state.completed)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(state.done, 0)
		end)
	end)

	helpers.it("(api-probe-admission) preserves a successor started inside authorization", function()
		with_remote(function(remote, state)
			local entered = false
			local function admission()
				if not entered then
					entered = true
					remote.chat(ENTRY, nil, MESSAGES, {}, nil, state.completed)
				end
				return true
			end
			helpers.assert_eq(remote.test(ENTRY, function() error("stale verdict") end, admission), false)
			helpers.assert_eq(#state.calls, 1)
			state.answer_chat(1)
			helpers.assert_eq(state.done, 1)
		end)
	end)

	helpers.it("(api-probe-admission) cannot replace a successor created by the probe spec reader", function()
		with_remote(function(remote, state)
			local spec = remote.test_request_spec
			remote.test_request_spec = function()
				local value = spec()
				remote.chat(ENTRY, nil, MESSAGES, {}, nil, state.completed)
				return value
			end
			remote.test(ENTRY, function() error("stale probe verdict") end, state.admit)
			helpers.assert_eq(#state.calls, 1, "only the exact successor can reach HTTP")
			state.answer_chat(1)
			helpers.assert_eq(state.done, 1)
		end)
	end)

	helpers.it("(api-probe-admission) drops chunks and verdict after completion logging revokes", function()
		with_remote(function(remote, state)
			local chunks = 0
			remote.chat(ENTRY, nil, MESSAGES, { authorized = state.admit }, function() chunks = chunks + 1 end,
				state.completed)
			state.on_log = function(text) if text:find("completion received", 1, true) then state.allowed = false end end
			state.answer_chat(1)
			helpers.assert_eq(chunks, 0)
			helpers.assert_eq(state.done, 0)
			helpers.assert_eq(remote.is_active(), false)
		end)
	end)

	helpers.it("(api-probe-admission) drops a late native callback after source revocation", function()
		with_remote(function(remote, state)
			remote.test(ENTRY, state.completed, state.admit)
			state.allowed = false
			state.answer_chat(1)
			helpers.assert_eq(state.done, 0)
			helpers.assert_eq(remote.is_active(), false)
		end)
	end)

	helpers.it("(api-probe-admission) refuses a Jev probe revoked by its dispatch logger", function()
		with_remote(function(remote, state)
			state.on_log = function() state.allowed = false end
			remote.test({ provider = "typesafe", token = "synthetic-key" }, state.completed, state.admit)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(state.done, 0)
			helpers.assert_eq(remote.is_active(), false)
		end)
	end)

	helpers.it("(api-probe-admission) does not cache an assistant decoded after revocation", function()
		with_remote(function(remote, state)
			remote.test(BACKBOARD, state.completed, state.admit)
			local extract = Formats.backboard_assistant_id
			Formats.backboard_assistant_id = function(root) state.allowed = false; return extract(root) end
			state.answer(1, { assistant_id = "synthetic-assistant" })
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(state.done, 0)
			Formats.backboard_assistant_id, state.allowed = extract, true
			remote.test(BACKBOARD, state.completed, state.admit)
			helpers.assert_eq(#state.calls, 2)
			helpers.assert_eq(state.calls[2].url, state.calls[1].url, "a fresh assistant is still required")
			state.answer(2, { assistant_id = "fresh-assistant" })
			state.answer(3, { content = "Probe reply." })
			helpers.assert_eq(state.done, 1)
		end)
	end)

	helpers.it("(api-probe-admission) revalidates the cache-hit message before its POST", function()
		with_remote(function(remote, state)
			remote.test(BACKBOARD, state.completed, state.admit)
			state.answer(1, { assistant_id = "synthetic-assistant" })
			state.answer(2, { content = "Probe reply." })
			helpers.assert_eq(state.done, 1)
			local build = Formats.backboard_message_request
			Formats.backboard_message_request = function(...)
				local request = build(...)
				state.allowed = false
				return request
			end
			remote.test(BACKBOARD, state.completed, state.admit)
			helpers.assert_eq(#state.calls, 2, "cache reuse must not bypass the final acquisition guard")
			helpers.assert_eq(state.done, 1)
			helpers.assert_eq(remote.is_active(), false)
		end)
	end)

	helpers.it("(api-probe-admission) keeps a valid assistant but stops a revoked follow-up message", function()
		with_remote(function(remote, state)
			remote.test(BACKBOARD, state.completed, state.admit)
			state.on_log = function(text) if text:find("assistant created", 1, true) then state.allowed = false end end
			state.answer(1, { assistant_id = "synthetic-assistant" })
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(state.done, 0)
			state.on_log, state.allowed = nil, true
			remote.test(BACKBOARD, state.completed, state.admit)
			helpers.assert_eq(#state.calls, 2)
			helpers.assert_true(state.calls[2].url ~= state.calls[1].url, "valid cache publication remains usable")
			state.answer(2, { content = "Probe reply." })
			helpers.assert_eq(state.done, 1)
		end)
	end)
end)
