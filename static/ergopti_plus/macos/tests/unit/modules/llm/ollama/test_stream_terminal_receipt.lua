--- tests/unit/modules/llm/ollama/test_stream_terminal_receipt.lua

--- ==============================================================================
--- MODULE: Ollama Stream Completion Receipt Tests
--- DESCRIPTION:
--- Drives the public prediction request through its real NDJSON consumer and
--- output parser. A healthy HTTP EOF closes the transport, not the generation;
--- the server's explicit boolean terminal receipt is required before publication.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN = '{"message":{"role":"assistant","content":"a complete continuation"},"done":false}\n'
local DONE = '{"message":{"role":"assistant","content":""},"done":true}\n'

--- Finds one dependency of the actual request implementation.
--- @param callback function Production closure.
--- @param target string Captured dependency name.
--- @return any value
local function upvalue(callback, target)
	local index = 1
	while true do
		local name, value = debug.getupvalue(callback, index)
		if name == nil then error("Missing actual stream dependency: " .. target) end
		if name == target then return value end
		index = index + 1
	end
end

--- Executes one response against the public backend and explicit native ports.
--- @param case table Transport chunks and expected terminal result.
local function run_case(case)
	helpers.with_stub_scope({ "modules.llm.api_ollama", "modules.llm",
		"modules.keystats", "modules.llm.api_common", "modules.llm.profiles",
		"modules.llm.ollama_endpoint", "modules.llm.progressive_reveal",
		"adapters.storage", "adapters.file_system", "infra.notifications",
		"adapters.shell_runner", "adapters.timer_scheduler", "adapters.json_codec",
		"modules.llm.parser", "infra.logger" }, function()
		-- The parser only reads the core's defaults. Keep that data port truthful
		-- without booting unrelated backends or acquiring their module lifetimes.
		local file = assert(io.open(helpers.shared("modules/llm/defaults.json"), "rb"))
		local raw = assert(file:read("*a"))
		assert(file:close())
		local defaults = assert(require("json").decode(raw))
		package.loaded["modules.llm"] = { DEFAULT_STATE = defaults }
		package.loaded["modules.keystats"] = { log_llm = function() end }
		local api = helpers.load_with_stubs("modules.llm.api_ollama")
		local stream = upvalue(api.fetch_batch, "post_and_parse_streaming")
		local shell = upvalue(stream, "ShellRunner")
		local scheduler = upvalue(stream, "TimerScheduler")
		local original_spawn, original_after = shell.spawn, scheduler.after
		local done, chunk, settled, starts = nil, nil, false, 0
		local successes, failures, partials = {}, 0, {}
		local task = {
			start = function() starts = starts + 1; return true end,
			isSettled = function() return settled end,
			terminate = function() settled = true; return true, "settled" end,
		}
		shell.spawn = function(executable, args, on_done, on_chunk)
			helpers.assert_eq(executable, "/usr/bin/curl")
			helpers.assert_true(args[#args]:match("/api/chat$") ~= nil)
			done, chunk = on_done, on_chunk
			return task
		end
		scheduler.after = function(_, callback)
			return { timer = {}, callback = callback }, true
		end
		local ok, err = xpcall(function()
			api.fetch_batch("typed context", "", "fixture-model", 0.2, 16, 1,
				{ batch = false, system_single = "Continue the context." },
				function(results) successes[#successes + 1] = results end,
				function() failures = failures + 1 end,
				function() return "current-request" end, true,
				function(raw) partials[#partials + 1] = raw end)
			helpers.assert_eq(starts, 1, "the public request must acquire one actual stream")
			helpers.assert_eq(type(done), "function")
			helpers.assert_eq(type(chunk), "function")
			for _, part in ipairs(case.chunks) do chunk(nil, part, "") end
			if case.cancelled then helpers.assert_true(api.cancel_streaming()) end
			settled = true
			done(case.exit_code or 0, case.remaining or "", "")
			helpers.assert_eq(#partials, case.partials == nil and 1 or case.partials,
				"the transport must deliver the real token before terminal classification")
			helpers.assert_eq(#successes, case.success and 1 or 0,
				"only a complete provider receipt may publish the final prediction")
			helpers.assert_eq(failures, case.cancelled and 0 or (case.success and 0 or 1),
				"an incomplete current generation must fail once; retirement stays silent")
			if case.success then
				helpers.assert_eq(#successes[1], 1, "the real parser must yield one prediction")
				helpers.assert_true(successes[1][1].to_type:find("complete continuation", 1, true) ~= nil)
			end
			helpers.assert_true(api.cancel_streaming(), "terminal cleanup must release the exact task")
		end, debug.traceback)
		settled = true
		api.cancel_streaming()
		shell.spawn, scheduler.after = original_spawn, original_after
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Ollama provider completion receipt", function()
	for _, case in ipairs({
		{ name = "rejects HTTP EOF after a nonterminal token", chunks = { TOKEN } },
		{ name = "rejects a missing done field", chunks = { (TOKEN:gsub(',"done":false', '')) }, partials = 0 },
		{ name = "rejects a string completion marker", chunks = { TOKEN, (DONE:gsub('true', '"true"')) } },
		{ name = "rejects content after the terminal record", chunks = { TOKEN, DONE, TOKEN }, partials = 1 },
		{ name = "rejects an invalid record after the terminal record", chunks = { TOKEN, DONE, "not JSON\n" } },
		{ name = "rejects provider errors after a token", chunks = { TOKEN, '{"error":"fixture failure"}\n' } },
		{ name = "rejects failed curl after a completion marker", chunks = { TOKEN, DONE }, exit_code = 28 },
		{ name = "keeps explicit cancellation silent", chunks = { TOKEN }, cancelled = true },
		{ name = "accepts the final receipt", chunks = { TOKEN, DONE }, success = true },
		{ name = "accepts the final receipt from completion output", chunks = { TOKEN }, remaining = DONE, success = true },
		{ name = "accepts the final receipt without a trailing newline", chunks = { TOKEN }, remaining = DONE:sub(1, -2), success = true },
		{ name = "accepts whitespace after the terminal receipt", chunks = { TOKEN, DONE, " \r\n\n" }, success = true },
		{ name = "accepts content in the terminal record", chunks = { (TOKEN:gsub('false', 'true')) }, success = true },
	}) do
		helpers.it(case.name .. " (ollama-stream-terminal-receipt)", function() run_case(case) end)
	end
	local split = {}
	for index = 1, #DONE do split[#split + 1] = DONE:sub(index, index) end
	table.insert(split, 1, TOKEN)
	helpers.it("accepts a terminal record split at every byte (ollama-stream-terminal-receipt)", function()
		run_case({ chunks = split, success = true })
	end)
end)
