--- tests/unit/modules/llm/test_api_remote_url_contract.lua

--- ==============================================================================
--- MODULE: Remote API URL contract regression tests
--- DESCRIPTION:
--- Exercises the public Remote backend so unsafe base URLs never reach a native
--- client and Gemini model resource names remain one encoded path segment.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Returns one named closure upvalue.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value Captured value.
local function get_upvalue(fn, target)
	for index = 1, 128 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end


--- Configures one Gemini-compatible entry.
--- @param api table Remote backend.
--- @param base_url string Candidate provider base URL.
--- @param model string Candidate model resource name.
--- @param format string|nil Provider wire format (defaults to Gemini).
local function configure(api, base_url, model, format)
	format = format or "gemini"
	local provider_id = "hs099_" .. format
	api.PROVIDERS[provider_id] = {
		label = "HS-099 " .. format,
		base_url = base_url,
		default_model = model,
		format = format,
	}
	api.set_entries({ {
		id = "hs099-entry",
		provider = provider_id,
		base_url = base_url,
		token = "plain-token",
		model = model,
	} })
	api.set_active_entry_id("hs099-entry")
end


--- Dispatches one public batch request and counts its failure callback.
--- @param api table Remote backend.
--- @param model string Model passed to the public request.
--- @return number failures Failure callback count.
local function dispatch_batch(api, model)
	local failures = 0
	api.fetch_batch(
		"typed context", "", model, 0.2, 8, 1, { batch = false },
		function() end,
		function() failures = failures + 1 end,
		function() return 1 end,
		false,
		nil)
	return failures
end


--- Loads a fresh production backend and exposes its three semantic clients.
--- @return table api Remote backend.
--- @return table inference Inference HTTP owner.
--- @return table availability Availability HTTP owner.
--- @return table warmup Warmup HTTP owner.
local function fresh_backend()
	local api = helpers.load_with_stubs("modules.llm.api_remote")
	local inference = get_upvalue(api.cancel_streaming, "_infer_client")
	local availability = get_upvalue(api.check_availability, "_check_client")
	local warmup = get_upvalue(api.warmup, "_warmup_client")
	helpers.assert_true(inference ~= nil and availability ~= nil and warmup ~= nil,
		"the public Remote surfaces must expose their production HTTP owners")
	return api, inference, availability, warmup
end


helpers.describe("HS-099 Remote URL contract", function()
	helpers.it("encodes Gemini model resource names as one RFC 3986 path segment", function()
		local api, inference = fresh_backend()
		local original_post = inference.post
		local urls = {}
		inference.post = function(url)
			urls[#urls + 1] = url
			return true
		end

		local utf8_e = string.char(0xC3, 0xA9)
		local cases = {
			{ model = "gemini-1.5-flash", segment = "gemini-1.5-flash" },
			{ model = "models/gemini-1.5-flash", segment = "gemini-1.5-flash" },
			{ model = "gemini pro", segment = "gemini%20pro" },
			{ model = "family/gemini", segment = "family%2Fgemini" },
			{ model = "gemini-" .. utf8_e, segment = "gemini-%C3%A9" },
			{ model = "gemini?key=INJECT", segment = "gemini%3Fkey%3DINJECT" },
		}

		local ok, err = xpcall(function()
			for index, case in ipairs(cases) do
				configure(api, "https://fixture.invalid/v1beta/", case.model)
				helpers.assert_eq(dispatch_batch(api, case.model), 0)
				helpers.assert_eq(urls[index],
					"https://fixture.invalid/v1beta/models/" .. case.segment
						.. ":generateContent?key=plain-token")
			end
			local before = #urls
			configure(api, "https://fixture.invalid/v1beta", "models/")
			helpers.assert_eq(dispatch_batch(api, "models/"), 1,
				"an empty Gemini resource name must fail exactly once")
			helpers.assert_eq(#urls, before,
				"an empty Gemini resource name must fail before native dispatch")
		end, debug.traceback)
		inference.post = original_post
		if not ok then error(err, 0) end
	end)

	helpers.it("accepts only HTTP(S) bases with a credential-free authority", function()
		local api, inference = fresh_backend()
		local original_post = inference.post
		local posts = {}
		inference.post = function(url)
			posts[#posts + 1] = url
			return true
		end

		local logger = get_upvalue(api.warmup, "Logger")
		helpers.assert_true(logger ~= nil)
		local original_error = logger.error
		local original_debug = logger.debug
		local logs = {}
		local refusal_logs = 0
		local function capture(_, format_string, ...)
			local formatted_ok, message = pcall(string.format, format_string, ...)
			local rendered = formatted_ok and message or tostring(format_string)
			logs[#logs + 1] = rendered
			if rendered:find("refused invalid endpoint configuration", 1, true) then
				refusal_logs = refusal_logs + 1
			end
		end
		logger.error = capture
		logger.debug = capture

		local ok, err = xpcall(function()
			local invalid_bases = {
				"fixture.invalid/v1",
				"ftp://fixture.invalid/v1",
				"javascript:alert(1)",
				"https://BASE_URL_SECRET@fixture.invalid/v1",
				"https://fixture.invalid/v1?route=other",
				"https://fixture.invalid/v1#fragment",
				"https://fixture.invalid/space here",
				"https://fixture.invalid/line\nbreak",
				"https://fixture.invalid/path\\other",
				"https://fixture.invalid:0/v1",
				"https://fixture.invalid:65536/v1",
			}
			local expected_refusals = #invalid_bases * 3
			for _, format in ipairs({ "openai", "anthropic", "gemini" }) do
				for _, base_url in ipairs(invalid_bases) do
					local before = #posts
					configure(api, base_url, "gemini", format)
					helpers.assert_eq(dispatch_batch(api, "gemini"), 1,
						format .. " invalid base URL must fail its request exactly once")
					helpers.assert_eq(#posts, before,
						format .. " invalid base URL must fail before native dispatch")
				end
			end

			for _, case in ipairs({
				{ base = "https://fixture.invalid/v1/", normalized = "https://fixture.invalid/v1" },
				{ base = "HTTPS://fixture.invalid/v1", normalized = "https://fixture.invalid/v1" },
				{ base = "http://127.0.0.1:8080/v1", normalized = "http://127.0.0.1:8080/v1" },
				{ base = "http://[::1]:8080/v1", normalized = "http://[::1]:8080/v1" },
			}) do
				configure(api, case.base, "gemini")
				helpers.assert_eq(dispatch_batch(api, "gemini"), 0)
				helpers.assert_eq(posts[#posts], case.normalized
					.. "/models/gemini:generateContent?key=plain-token")
			end

			local rendered = table.concat(logs, "\n")
			helpers.assert_eq(refusal_logs, expected_refusals,
				"every invalid endpoint must produce one actionable diagnostic")
			helpers.assert_true(rendered:find("BASE_URL_SECRET", 1, true) == nil,
				"invalid base URL diagnostics must never expose userinfo credentials")
		end, debug.traceback)
		logger.error = original_error
		logger.debug = original_debug
		inference.post = original_post
		if not ok then error(err, 0) end
	end)

	helpers.it("rejects an invalid base on both health-check owners", function()
		local api, _, availability, warmup = fresh_backend()
		local original_check_get = availability.get
		local original_warmup_get = warmup.get
		local check_gets, warmup_gets = 0, 0
		availability.get = function() check_gets = check_gets + 1; return true end
		warmup.get = function() warmup_gets = warmup_gets + 1; return true end

		local acquired, missing = {}, 0
		local ok, err = xpcall(function()
			configure(api, "https://secret@fixture.invalid/v1", "fixture-model", "openai")
			helpers.assert_eq(api.warmup("gemini", nil, function(value)
				acquired[#acquired + 1] = value
			end), false)
			helpers.assert_eq(api.check_availability("gemini", function() end,
				function() missing = missing + 1 end), false)
			helpers.assert_eq(warmup_gets, 0)
			helpers.assert_eq(check_gets, 0)
			helpers.assert_eq(acquired, { false })
			helpers.assert_eq(missing, 1)
		end, debug.traceback)
		availability.get = original_check_get
		warmup.get = original_warmup_get
		if not ok then error(err, 0) end
	end)
end)
