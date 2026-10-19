--- tests/unit/modules/llm/ollama/test_api_ollama_terminal_receipt.lua

--- ==============================================================================
--- MODULE: Ollama Terminal Protocol Receipt
--- DESCRIPTION:
--- Distinguishes a complete inference from HTTP EOF and retains the original
--- request through physical transport completion, protocol refusal and cancellation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the actual backend with only its asynchronous transport controlled.
--- @param body function Receives API, request callbacks and cancellation control.
local function isolated(body)
	local names = { "modules.llm.api_ollama", "adapters.http_client", "modules.llm.prediction_engine" }
	local previous, transport = {}, { refused = false }
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	package.loaded["adapters.http_client"] = {
		postStream = function(_, _, _, _, chunk, done)
			transport.chunk, transport.done = chunk, done
			return true
		end,
		cancel = function() return not transport.refused end,
	}
	local api = require("modules.llm.api_ollama")
	local ok, err = pcall(body, api, transport)
	api.cancel()
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

--- Captures actual public callbacks independently of the transport's completion.
--- @param api table Actual backend.
--- @param stream boolean|nil Public streaming option.
--- @param on_chunk function|nil Reentrant public observer.
--- @return table observed
local function begin(api, stream, on_chunk)
	local observed = { chunks = {}, terminals = {} }
	helpers.assert_true(api.chat("http://127.0.0.1:11434", "fixture-model", {}, { stream = stream },
		function(text)
			observed.chunks[#observed.chunks + 1] = text
			if on_chunk then on_chunk(text) end
		end,
		function(text, err) observed.terminals[#observed.terminals + 1] = { text = text, error = err } end))
	return observed
end

--- Requires a terminal failure without releasing the native producer early.
--- @param api table
--- @param transport table
--- @param observed table
local function refused(api, transport, observed)
	helpers.assert_eq(#observed.terminals, 0)
	helpers.assert_true(api.is_active())
	transport.done({ ok = true, status = 200 })
	helpers.assert_eq(#observed.terminals, 1)
	helpers.assert_true(type(observed.terminals[1].error) == "string" and observed.terminals[1].error ~= "")
	helpers.assert_eq(api.is_active(), false)
	transport.done({ ok = true, status = 200 })
	helpers.assert_eq(#observed.terminals, 1)
end

helpers.describe("Ollama terminal inference ownership", function()
	for _, ending in ipairs({ "\n", "" }) do
		helpers.it("refuses HTTP EOF without an inference terminal marker ending=" .. #ending, function()
			isolated(function(api, transport)
				local observed = begin(api, true)
				transport.chunk('{"message":{"content":"partial"},"done":false}' .. ending)
				refused(api, transport, observed)
			end)
		end)
	end

	for _, value in ipairs({ '"yes"', "1", "null", "missing" }) do
		helpers.it("refuses a nonboolean terminal field " .. value .. " before publishing its content", function()
			isolated(function(api, transport)
				local observed = begin(api, true)
				local suffix = value == "missing" and "" or ',"done":' .. value
				transport.chunk('{"message":{"content":"invalid"}' .. suffix .. '}\n')
				transport.chunk('{"message":{"content":"later"},"done":true}\n')
				refused(api, transport, observed)
				helpers.assert_eq(#observed.chunks, 0)
			end)
		end)
	end

	for _, trailing in ipairs({
		{ name = "content", bytes = '{"message":{"content":"injected"},"done":false}\n' },
		{ name = "duplicate terminal", bytes = '{"message":{"content":""},"done":true}' },
		{ name = "unknown envelope", bytes = '{}\n' },
	}) do
		helpers.it("refuses a subsequent record after the terminal marker " .. trailing.name, function()
			isolated(function(api, transport)
				local observed = begin(api, true)
				transport.chunk('{"message":{"content":"complete"},"done":true}\n')
				transport.chunk(trailing.bytes)
				refused(api, transport, observed)
				helpers.assert_eq(table.concat(observed.chunks), "complete")
			end)
		end)
	end


	for _, root in ipairs({ "[]", '"scalar"', "1", "true", "null" }) do
		helpers.it("refuses an unexpected JSON root after partial text " .. root, function()
			isolated(function(api, transport)
				local observed = begin(api, true)
				transport.chunk('{"message":{"content":"partial"},"done":false}\n')
				transport.chunk(root .. "\n")
				transport.chunk('{"message":{"content":"must not publish"},"done":true}\n')
				refused(api, transport, observed)
				helpers.assert_eq(table.concat(observed.chunks), "partial")
			end)
		end)
	end

	helpers.it("accepts byte-split UTF-8 and JSON records with a terminal EOF without newline", function()
		isolated(function(api, transport)
			local observed = begin(api, true)
			local bytes = '{"message":{"content":"été"},"done":false}\r\n'
				.. '{"message":{"content":" complet"},"done":true}'
			for index = 1, #bytes do transport.chunk(bytes:sub(index, index)); transport.chunk("") end
			helpers.assert_eq(#observed.terminals, 0)
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#observed.terminals, 1)
			helpers.assert_nil(observed.terminals[1].error)
			helpers.assert_eq(observed.terminals[1].text, "été complet")
		end)
	end)

	helpers.it("accepts a single completed nonstreaming envelope and whitespace after its marker", function()
		isolated(function(api, transport)
			local observed = begin(api, false)
			transport.chunk('\n {"message":{"content":"answer"},"done":true}\r\n \n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#observed.terminals, 1)
			helpers.assert_nil(observed.terminals[1].error)
			helpers.assert_eq(observed.terminals[1].text, "answer")
		end)
	end)

	for _, terminal in ipairs({ false, true }) do
		helpers.it("keeps transport failure authoritative with terminal=" .. tostring(terminal), function()
			isolated(function(api, transport)
				local observed = begin(api, true)
				transport.chunk('{"message":{"content":"partial"},"done":' .. tostring(terminal) .. '}\n')
				transport.done({ ok = false, status = 502, error = "controlled transport failure" })
				helpers.assert_eq(#observed.terminals, 1)
				helpers.assert_true(type(observed.terminals[1].error) == "string")
				helpers.assert_eq(api.is_active(), false)
			end)
		end)
	end

	helpers.it("accepted cancellation prevents a terminal success from late native callbacks", function()
		isolated(function(api, transport)
			local observed = begin(api, true)
			transport.chunk('{"message":{"content":"partial"},"done":false}\n')
			helpers.assert_true(api.cancel())
			transport.chunk('{"message":{"content":"late"},"done":true}\n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#observed.terminals, 1)
			helpers.assert_eq(observed.terminals[1].error, "cancelled")
			helpers.assert_eq(table.concat(observed.chunks), "partial")
		end)
	end)


	helpers.it("cancellation inside a chunk observer fences the rest of that native chunk and finish", function()
		isolated(function(api, transport)
			local observed = begin(api, true, function() helpers.assert_true(api.cancel()) end)
			local stale_done = transport.done
			transport.chunk('{"message":{"content":"first"},"done":false}\n'
				.. '{"message":{"content":"stale"},"done":true}\n')
			stale_done({ ok = true, status = 200 })
			helpers.assert_eq(#observed.terminals, 1)
			helpers.assert_eq(observed.terminals[1].error, "cancelled")
			helpers.assert_eq(table.concat(observed.chunks), "first")
			helpers.assert_eq(api.is_active(), false)
		end)
	end)

	helpers.it("a chunk observer successor cannot inherit old records or old transport completion", function()
		isolated(function(api, transport)
			local successor
			local old = begin(api, true, function() successor = begin(api, true) end)
			local stale_done = transport.done
			transport.chunk('{"message":{"content":"first"},"done":false}\n'
				.. '{"message":{"content":"stale"},"done":true}\n')
			helpers.assert_eq(#old.terminals, 1)
			helpers.assert_eq(old.terminals[1].error, "cancelled")
			helpers.assert_eq(table.concat(old.chunks), "first")
			helpers.assert_eq(#successor.terminals, 0)
			stale_done({ ok = true, status = 200 })
			helpers.assert_true(api.is_active())
			transport.chunk('{"message":{"content":"fresh"},"done":true}\n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#successor.terminals, 1)
			helpers.assert_nil(successor.terminals[1].error)
			helpers.assert_eq(successor.terminals[1].text, "fresh")
		end)
	end)

	helpers.it("refused cancellation retains the original producer until its completed receipt", function()
		isolated(function(api, transport)
			local observed = begin(api, true)
			transport.refused = true
			helpers.assert_eq(api.cancel(), false)
			helpers.assert_true(api.is_active())
			helpers.assert_eq(#observed.terminals, 0)
			transport.chunk('{"message":{"content":"complete"},"done":true}\n')
			transport.done({ ok = true, status = 200 })
			helpers.assert_eq(#observed.terminals, 1)
			helpers.assert_nil(observed.terminals[1].error)
			helpers.assert_eq(observed.terminals[1].text, "complete")
		end)
	end)
end)
