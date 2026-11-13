--- tests/unit/ai/engine/ollama/test_api_ollama_payload.lua

--- ==============================================================================
--- MODULE: What The Ollama Request Actually Says
--- DESCRIPTION:
--- The two fields this driver never sent, and why each absence was invisible.
---
--- keep_alive: without it Ollama applies its own default of five minutes and
--- unloads the model. A user who pauses for longer pays the full model load on
--- their next keystroke — several seconds, on a path budgeted in hundreds of
--- milliseconds. Nothing errors. It presents as "the Linux predictions are
--- sometimes very slow", which is the kind of report that never gets diagnosed.
---
--- stop: without it the model runs past its answer and into the next turn of the
--- prompt template, so the user is offered the scaffolding of their own prompt
--- as a prediction. The sequences live in the shared inference.json precisely so
--- the per-file literals in the three backends cannot drift apart.
---
--- WHY THE TRANSPORT ENVELOPE IS THE ASSERTION:
--- A callback-shaped API can still hide a blocking subprocess or malformed
--- payload. These tests inspect the exact asynchronous request before any I/O.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared folder of the Ollama policy files, under the shared root.
local POLICY = "/ai/data"

for _, name in ipairs({ "defaults.json", "inference.json" }) do
	helpers.it("Ollama payload refuses FIFO for " .. name, function()
		local uv, Paths = require("luv"), require("core.fs.engine.paths")
		require("ai.engine.prediction.engine") -- Load unrelated owners before redirecting this source root.
		local root, previous_root, previous_api = assert(Paths.shared_root()), Paths.shared_root, package.loaded["ai.engine.api.api_ollama"]
		local base = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-ollama-policy-XXXXXX"))
		local folders, at = {}, base
		for part in POLICY:gmatch("[^/]+") do
			at = at .. "/" .. part; assert(uv.fs_mkdir(at, 448)); folders[#folders + 1] = at
		end
		helpers.assert_true(#folders > 0, "the policy folders were made")
		for _, file in ipairs({ "defaults.json", "inference.json" }) do
			local path = base .. POLICY .. "/" .. file
			if file == name then
				local made = os.execute("mkfifo '" .. path .. "'")
				assert(made == true or made == 0)
			else assert(uv.fs_symlink(root .. POLICY .. "/" .. file, path)) end
		end
		local path = base .. POLICY .. "/" .. name
		local exited, code, process = false, nil, nil
		process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; cat "$2" > "$1"', "fixture", path,
			root .. POLICY .. "/" .. name } }, function(result) code, exited = result, true; process:close() end))
		Paths.shared_root = function() return base end
		package.loaded["ai.engine.api.api_ollama"] = nil
		local ok, owner = pcall(require, "ai.engine.api.api_ollama")
		Paths.shared_root, package.loaded["ai.engine.api.api_ollama"] = previous_root, previous_api
		os.remove(base .. POLICY .. "/defaults.json"); os.remove(base .. POLICY .. "/inference.json")
		for index = #folders, 1, -1 do os.remove(folders[index]) end
		os.remove(base)
		while not exited do uv.run("once") end
		assert(ok, owner)
		helpers.assert_true(code ~= 0, "the configuration reader opened the FIFO")
	end)
end

--- Captures the asynchronous request chat() dispatches, without running it.
--- @param opts table Request options.
--- @return table The composed transport request.
local function captured_request(opts)
	local previous_client = package.loaded["core.network.adapters.http_client"]
	local previous_api = package.loaded["ai.engine.api.api_ollama"]
	local seen = nil
	package.loaded["core.network.adapters.http_client"] = {
		postStream = function(url, headers, body, options, _on_chunk, on_done)
			seen = { url = url, headers = headers, body = body, options = options }
			on_done({ ok = false, error = "fixture complete" })
			return true
		end,
		cancel = function() return true end,
	}

	local ok, err = pcall(function()
		local Ollama = helpers.load_module("ai.engine.api.api_ollama")
		Ollama.chat("http://localhost:11434", "test-model",
			{ { role = "user", content = "bonjour" } }, opts,
			function() end, function() end)
	end)

	package.loaded["core.network.adapters.http_client"] = previous_client
	package.loaded["ai.engine.api.api_ollama"] = previous_api
	helpers.assert_true(ok, "the request must compose: " .. tostring(err))
	return seen
end




-- =================================================================
-- =================================================================
-- ======= 1/ The model stays loaded ===============================
-- =================================================================
-- =================================================================

helpers.describe("ollama payload: keep_alive", function()

	helpers.it("(net-003-ollama-deadline) gives a local request the shared Ollama budget, not the remote one", function()
		local request = captured_request({ stream = false })
		local Timings = require("core.timing.engine.timings")
		helpers.assert_eq(request.options.timeout_ms, Timings.ms("llm", "ollama_request_timeout_ms"),
			"a cold CPU model load outlasts the remote API budget; Windows gives Ollama the same ceiling")
		helpers.assert_true(request.options.timeout_ms > Timings.ms("llm", "request_timeout_ms"))
	end)

	helpers.it("tells Ollama how long to keep the model resident", function()
		local request = captured_request({ stream = false })
		helpers.assert_true(request.body:find("keep_alive", 1, true) ~= nil,
			"without it Ollama unloads after its own five-minute default, so a user "
				.. "who pauses longer than that pays a full model load on their next "
				.. "keystroke. Nothing errors — it just gets slow, occasionally, "
				.. "which is the hardest kind of report to act on.")
	end)

	helpers.it("takes the duration from the shared defaults rather than a literal", function()
		local request = captured_request({ stream = false })
		local Paths = helpers.load_module("core.fs.engine.paths")
		local root = Paths.shared_root()
		helpers.assert_not_nil(root, "the shared tree must be findable")
		local handle = assert(io.open(root .. "/ai/data/defaults.json", "r"))
		local defaults = handle:read("*a")
		handle:close()
		local expected = defaults:match('"llm_ollama_keep_alive"%s*:%s*"([^"]+)"')
		helpers.assert_not_nil(expected, "defaults.json must declare the duration")
		helpers.assert_true(request.body:find(expected, 1, true) ~= nil,
			"the three drivers read one file for this. A literal here would drift "
				.. "from the other two the first time it is tuned, and nothing would "
				.. "report the disagreement.")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The completion stops =================================
-- =================================================================
-- =================================================================

helpers.describe("ollama payload: stop sequences", function()

	helpers.it("sends the shared stop list", function()
		local request = captured_request({ stream = true, line_mode = true })
		helpers.assert_true(request.body:find('"stop"', 1, true) ~= nil,
			"without it the model runs past its answer into the next turn of the "
				.. "prompt template, and the user is offered the scaffolding of their "
				.. "own prompt as a prediction")
		helpers.assert_true(request.body:find("eot_id", 1, true) ~= nil,
			"and the tokens come from the shared inference.json, which exists so "
				.. "the three backends' literals cannot drift")
	end)

	helpers.it("cuts at a newline in line mode and not in batch mode", function()
		local line = captured_request({ stream = true, line_mode = true }).body
		local batch = captured_request({ stream = true, line_mode = false }).body
		helpers.assert_true(#line > 0 and #batch > 0, "both must compose")
		helpers.assert_true(line ~= batch,
			"an inline continuation must stop at the end of the line it is being "
				.. "written into; a batch request must not, or every prediction is "
				.. "truncated at the first paragraph break")
	end)

	helpers.it("encodes the list as a JSON array", function()
		local request = captured_request({ stream = true, line_mode = true })
		helpers.assert_true(request.body:find('"stop":%[') ~= nil,
			"an object with numeric string keys is what a fallback encoder that "
				.. "does not know about arrays produces, and Ollama rejects the whole "
				.. "request — so one missing module would turn into a dead feature")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The request reaches one exact endpoint ================
-- =================================================================
-- =================================================================

helpers.describe("ollama payload: endpoint composition", function()
	helpers.it("posts to /api/chat exactly once", function()
		local request = captured_request({ stream = false })
		helpers.assert_eq(request.url, "http://localhost:11434/api/chat",
			"the path-free profile origin must resolve to the exact chat operation")
		helpers.assert_true(request.url:find("/api/chat/api/chat", 1, true) == nil,
			"an operation path must never be appended to another operation endpoint")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 4/ Thinking is switched off =============================
-- =================================================================
-- =================================================================

helpers.describe("ollama payload: thinking models", function()

	helpers.it("sends think=false at the top level like the other two drivers", function()
		local body = captured_request({ stream = true, line_mode = true }).body
		helpers.assert_true(body:find('"think":false', 1, true) ~= nil,
			"without it a thinking model spends its token budget and seconds of latency on a "
				.. "reasoning trace that is stripped afterwards; Windows and macOS disable it")
	end)

	helpers.it("sends a zero thinking budget in the options", function()
		local body = captured_request({ stream = true, line_mode = false }).body
		helpers.assert_true(body:find('"thinking_budget":0', 1, true) ~= nil,
			"Windows and macOS both send options.thinking_budget=0 for servers that read it")
	end)

end)
