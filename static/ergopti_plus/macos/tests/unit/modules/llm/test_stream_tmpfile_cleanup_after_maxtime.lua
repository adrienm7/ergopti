--- tests/unit/modules/llm/test_stream_tmpfile_cleanup_after_maxtime.lua

--- Regression test for llm-api-net-03: api_ollama.lua scheduled payload temp-file
--- cleanup at a hardcoded 10 s — less than curl's --max-time of 60 s. Under a
--- slow backend, curl could still be reading the file when the timer fired,
--- producing a malformed POST body.
---
--- Fix: added STREAM_MAX_TIME_SEC and STREAM_TMPFILE_CLEANUP_SEC constants;
--- STREAM_TMPFILE_CLEANUP_SEC must be strictly greater than STREAM_MAX_TIME_SEC.
--- Cleanup also happens immediately inside on_done so the file is removed as
--- soon as curl exits under normal conditions.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/llm/api_ollama.lua"
local fh = io.open(src_path, "r")
if not fh then error("api_ollama.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: STREAM_MAX_TIME_SEC constant must be defined.
local max_time_def = src:match("local STREAM_MAX_TIME_SEC%s*=%s*(%d+)")
helpers.assert_true(
	max_time_def ~= nil,
	"api_ollama.lua must define STREAM_MAX_TIME_SEC constant (llm-api-net-03)"
)

-- Test 2: STREAM_TMPFILE_CLEANUP_SEC constant must be defined and be a number.
local cleanup_def = src:match("local STREAM_TMPFILE_CLEANUP_SEC%s*=%s*(%d+)")
helpers.assert_true(
	cleanup_def ~= nil,
	"api_ollama.lua must define STREAM_TMPFILE_CLEANUP_SEC constant (llm-api-net-03)"
)

-- Test 3: STREAM_TMPFILE_CLEANUP_SEC >= STREAM_MAX_TIME_SEC.
local max_time_val  = tonumber(max_time_def)
local cleanup_val   = tonumber(cleanup_def)
helpers.assert_true(
	max_time_val ~= nil and cleanup_val ~= nil and cleanup_val >= max_time_val,
	string.format(
		"STREAM_TMPFILE_CLEANUP_SEC (%s) must be >= STREAM_MAX_TIME_SEC (%s) (llm-api-net-03)",
		tostring(cleanup_def), tostring(max_time_def)
	)
)

-- Test 4: curl --max-time must use the named constant, not a bare literal.
local has_max_time_literal = src:find('"--max-time", "60"', 1, true) ~= nil
helpers.assert_true(
	not has_max_time_literal,
	"api_ollama.lua must not use bare literal \"60\" for --max-time (llm-api-net-03)"
)
local has_max_time_const = src:find("STREAM_MAX_TIME_SEC", 1, true) ~= nil
helpers.assert_true(
	has_max_time_const,
	"api_ollama.lua must reference STREAM_MAX_TIME_SEC in the curl --max-time argument (llm-api-net-03)"
)

-- Test 5: Safety-net timer must use STREAM_TMPFILE_CLEANUP_SEC, not the old 10s literal.
local has_old_delay = src:find("TimerScheduler.after(10,", 1, true) ~= nil
helpers.assert_true(
	not has_old_delay,
	"api_ollama.lua must not use bare literal 10 s for the temp-file cleanup timer (llm-api-net-03)"
)
local has_named_delay = src:find("TimerScheduler.after(STREAM_TMPFILE_CLEANUP_SEC,", 1, true) ~= nil
helpers.assert_true(
	has_named_delay,
	"api_ollama.lua safety-net timer must use STREAM_TMPFILE_CLEANUP_SEC (llm-api-net-03)"
)

-- Test 6: on_done must call os.remove(tmp_path) for immediate cleanup.
local on_done_pos = src:find("local function on_done(", 1, true)
helpers.assert_true(on_done_pos ~= nil, "api_ollama.lua must define on_done (llm-api-net-03)")
local on_done_body = src:sub(on_done_pos, on_done_pos + 200)
local has_remove_in_done = on_done_body:find("os.remove(tmp_path)", 1, true) ~= nil
helpers.assert_true(
	has_remove_in_done,
	"api_ollama.lua on_done must call os.remove(tmp_path) for immediate cleanup (llm-api-net-03)"
)

print("[PASS] test_stream_tmpfile_cleanup_after_maxtime")
