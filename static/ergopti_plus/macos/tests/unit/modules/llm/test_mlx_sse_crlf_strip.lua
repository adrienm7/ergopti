--- tests/unit/modules/llm/test_mlx_sse_crlf_strip.lua

--- ==============================================================================
--- MODULE: Regression — MLX streaming parses complete SSE events (HS-101)
--- DESCRIPTION:
--- SSE permits `data:value` and `data: value`, joins consecutive data fields
--- with a newline, and dispatches only at a blank line. Exercise the public
--- streaming path so a source spelling cannot certify a parser that drops the
--- token, dispatches too early, or cannot reconstruct a multi-line JSON event.
--- ==============================================================================

local helpers = require("tests.helpers")

local JSON_SINGLE = '{"choices":[{"delta":{"content":"hello"}}]}'

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

local function new_ctx()
	return {
		stream = { task = nil, timeout = nil, generation = 0, has_chunks = false },
		cancel_streaming = function() return true end,
		completions_endpoint = function() return "http://127.0.0.1/v1/completions" end,
		chat_endpoint = function() return "http://127.0.0.1/v1/chat/completions" end,
		read_active_model_arg = function() return "fixture/model" end,
		server_model_id = function() return nil end,
		model_hf_path = function() return nil end,
	}
end

local function run_stream_case(case)
	package.loaded["modules.llm.api_mlx_inference"] = nil
	local inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
	local shell_runner = get_upvalue(inference.post_and_parse_streaming, "ShellRunner")
	local parser = get_upvalue(inference.post_and_parse_streaming, "Parser")
	local json_codec = get_upvalue(inference.post_and_parse_streaming, "JsonCodec")
	local scheduler = get_upvalue(inference.post_and_parse_streaming, "TimerScheduler")
	local logger = get_upvalue(inference.post_and_parse_streaming, "Logger")
	helpers.assert_true(type(shell_runner) == "table" and type(shell_runner.spawn) == "function",
		"the public stream must expose its real ShellRunner dependency")
	helpers.assert_true(type(parser) == "table" and type(parser.process_prediction) == "function",
		"the public stream must expose its real parser dependency")
	helpers.assert_true(type(json_codec) == "table" and type(json_codec.decode) == "function",
		"the public stream must expose its real JSON boundary")
	helpers.assert_true(type(scheduler) == "table" and type(scheduler.after) == "function",
		"the public stream must expose its real timer boundary")
	helpers.assert_true(type(logger) == "table" and type(logger.debug) == "function",
		"the public stream must expose its real diagnostic boundary")

	local original_spawn = shell_runner.spawn
	local original_process_prediction = parser.process_prediction
	local original_decode = json_codec.decode
	local original_after = scheduler.after
	local original_cancel = scheduler.cancel
	local original_debug = logger.debug
	local partials, successes, failures = {}, {}, 0
	local decoded_payloads = {}
	local debug_messages = {}
	local partial_count_before_blank = nil
	local starts = 0
	local stream_on_done, stream_on_chunk

	shell_runner.spawn = function(_, _, on_done, on_chunk)
		stream_on_done = on_done
		stream_on_chunk = on_chunk
		return {
			start = function()
				starts = starts + 1
				return true
			end,
			terminate = function() return true end,
		}
	end
	parser.process_prediction = function(_, _, raw) return { to_type = raw } end
	json_codec.decode = function(raw)
		decoded_payloads[#decoded_payloads + 1] = raw
		if raw ~= (case.expected_payload or JSON_SINGLE) then
			return nil, "unexpected SSE payload"
		end
		if case.has_decoded_value then return case.decoded_value, nil end
		return { choices = { { delta = { content = "hello" } } } }, nil
	end
	logger.debug = function(_, format_string, ...)
		debug_messages[#debug_messages + 1] = string.format(format_string, ...)
	end
	scheduler.after = function(_, callback)
		return { callback = callback, active = true }, true
	end
	scheduler.cancel = function(handle)
		handle.active = false
		return true
	end

	local ok, err = xpcall(function()
		inference.init(new_ctx())
		inference.post_and_parse_streaming(
			"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
			function(results) successes[#successes + 1] = results end,
			function() failures = failures + 1 end,
			{},
			function(raw) partials[#partials + 1] = raw end)
		helpers.assert_eq(type(stream_on_chunk), "function",
			"the real stream must hand its chunk callback to ShellRunner")
		helpers.assert_eq(type(stream_on_done), "function",
			"the real stream must hand its terminal callback to ShellRunner")
		for index, chunk in ipairs(case.chunks) do
			local keep_streaming = stream_on_chunk(nil, chunk, "")
			helpers.assert_eq(keep_streaming, true,
				"a valid SSE chunk must keep the transport alive")
			if index == case.observe_before_blank_at then
				partial_count_before_blank = #partials
			end
		end
		stream_on_done(0, "", "")
	end, debug.traceback)

	shell_runner.spawn = original_spawn
	parser.process_prediction = original_process_prediction
	json_codec.decode = original_decode
	scheduler.after = original_after
	scheduler.cancel = original_cancel
	logger.debug = original_debug
	if not ok then error(err) end

	helpers.assert_eq(starts, 1, "the case must traverse one real streaming request")
	if case.expect_incomplete then
		helpers.assert_eq(#decoded_payloads, 0,
			"an event without a blank-line delimiter must never reach JSON decoding")
		helpers.assert_eq(#partials, 0, "an incomplete event must not publish a partial")
		helpers.assert_eq(#successes, 0, "an incomplete event must not publish a prediction")
		helpers.assert_eq(failures, 1, "an otherwise successful empty stream must report one failure")
		helpers.assert_eq(partial_count_before_blank, 0,
			"the unterminated data field must remain pending before EOF")
		return
	end
	if case.expect_schema_rejection then
		helpers.assert_eq(#decoded_payloads, 1)
		helpers.assert_eq(#partials, 0)
		helpers.assert_eq(#successes, 0)
		helpers.assert_eq(failures, 1)
		local schema_rejections, parse_failures = 0, 0
		for _, message in ipairs(debug_messages) do
			if message:find("SSE decode fail", 1, true) then
				schema_rejections = schema_rejections + 1
			end
			if message:find("JSON parse failed", 1, true) then
				parse_failures = parse_failures + 1
			end
		end
		helpers.assert_eq(schema_rejections, 1,
			"a decoded scalar must reach the response-shape validator")
		helpers.assert_eq(parse_failures, 0,
			"a nil decode error is authoritative even for a false value")
		return
	end
	helpers.assert_eq(#decoded_payloads, 1,
		"only the completed data event may reach the JSON boundary; DONE and field lines must not")
	helpers.assert_eq(decoded_payloads[1], case.expected_payload or JSON_SINGLE,
		"consecutive data fields must reach JSON decoding with their exact SSE newline join")
	helpers.assert_eq(#successes, 1, "the completed stream must publish exactly once")
	helpers.assert_eq(#successes[1], 1, "the stream must yield exactly one prediction")
	helpers.assert_eq(successes[1][1].to_type, "hello",
		"the SSE token must reach final parsing byte-exactly")
	helpers.assert_eq(failures, 0, "valid SSE must not fall through to empty accumulation")
	helpers.assert_eq(#partials, 1, "one data event must publish one partial update")
	helpers.assert_eq(partials[1], "hello", "the partial update must carry the decoded token")
	if case.observe_before_blank_at then
		helpers.assert_eq(partial_count_before_blank, 0,
			"an SSE data field must remain pending until the event's blank-line delimiter")
	end
end

helpers.describe("MLX SSE event parser", function()
	for _, case in ipairs({
		{
			name = "accepts a CRLF event with the conventional space",
			chunks = { "data: " .. JSON_SINGLE .. "\r\n\r\n" },
		},
		{
			name = "accepts a space-less field fragmented inside the data prefix",
			chunks = { "da", "ta:" .. JSON_SINGLE .. "\n", "\n" },
			observe_before_blank_at = 2,
		},
		{
			name = "joins multiple data fields before decoding their JSON",
			chunks = {
				'data: {"choices":[\n',
				'data: {"delta":{"content":"hello"}}]}\n\n',
			},
			expected_payload = '{"choices":[\n{"delta":{"content":"hello"}}]}',
		},
		{
			name = "ignores comments and non-data fields around one event",
			chunks = {
				": keepalive\r\nid: 7\r\nevent: token\r\n",
				"data:" .. JSON_SINGLE .. "\r\nretry: 1000\r\n\r\n",
			},
		},
		{
			name = "accepts DONE markers with and without the optional space",
			chunks = {
				"data:" .. JSON_SINGLE .. "\n\n",
				"data:[DONE]\n\ndata: [DONE]\n\n",
			},
		},
		{
			name = "does not dispatch an unterminated event at EOF",
			chunks = { "data:" .. JSON_SINGLE .. "\n" },
			observe_before_blank_at = 1,
			expect_incomplete = true,
		},
		{
			name = "routes a decoded false value through schema validation",
			chunks = { "data:" .. JSON_SINGLE .. "\n\n" },
			has_decoded_value = true,
			decoded_value = false,
			expect_schema_rejection = true,
		},
	}) do
		helpers.it(case.name, function() run_stream_case(case) end)
	end
end)
