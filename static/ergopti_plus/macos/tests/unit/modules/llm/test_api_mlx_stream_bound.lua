--- tests/unit/modules/llm/test_api_mlx_stream_bound.lua

--- ==============================================================================
--- MODULE: Regression — MLX streaming must stay bounded (F-HIGH-2)
--- DESCRIPTION:
--- The MLX streaming curl had only --connect-timeout (no --max-time), and the
--- in-process hard-timeout watchdog was CANCELLED on the first chunk and never
--- re-armed. So a server that sent >=1 token then stalled left curl blocked
--- forever: on_done never fired, on_fail never fired, the spinner froze, and the
--- single-request MLX connection stayed held open against every later prediction.
--- The Ollama backend never had this because its curl carries --max-time.
---
--- This test pins the root cause structurally (the networked streaming path is
--- deferred to integration testing — it needs a live MLX server + hs.task):
---   1. the streaming curl argv carries --max-time (and keeps --connect-timeout),
---      so curl always exits and on_done runs;
---   2. on_chunk RE-ARMS the idle watchdog (rather than permanently cancelling
---      it), so a mid-stream stall is bounded too.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	-- The streaming path lives in the request engine.
	local path = helpers.driver_root() .. "modules/llm/api_mlx_inference.lua"
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "cannot open api_mlx_inference.lua at " .. tostring(path))
	local src = fh:read("*a"); fh:close()
	return src
end

helpers.describe("api_mlx: streaming curl is time-bounded (F-HIGH-2)", function()
	helpers.it("the streaming curl argv passes --max-time and --connect-timeout", function()
		local src = read_src()
		-- Identify the streaming spawn by its no-buffer flag (-s, -N) through the endpoint.
		local stream_args = src:match('"%-s",%s*"%-N".-endpoint,')
		helpers.assert_true(stream_args ~= nil, "streaming curl args block (-s -N … endpoint) must be present")
		helpers.assert_true(stream_args:find('"%-%-max%-time"') ~= nil,
			"streaming curl MUST pass --max-time so it always exits and on_done runs (a mid-stream stall must not block forever)")
		helpers.assert_true(stream_args:find('"%-%-connect%-timeout"') ~= nil,
			"streaming curl must keep --connect-timeout")
	end)

	helpers.it("on_chunk re-arms the idle watchdog instead of permanently cancelling it", function()
		local src = read_src()
		-- on_chunk's body is everything between its definition and the next local
		-- function definition (on_done); flush_lines/arm_stream_idle_watchdog are
		-- defined BEFORE on_chunk, so this window is on_chunk's body alone.
		local on_chunk_body = src:match("local function on_chunk%b()(.-)local function on_done")
		helpers.assert_true(on_chunk_body ~= nil, "on_chunk body must be locatable")
		helpers.assert_true(on_chunk_body:find("arm_stream_idle_watchdog()", 1, true) ~= nil,
			"on_chunk must re-arm the idle watchdog on every chunk so a mid-stream stall is bounded")
	end)
end)
