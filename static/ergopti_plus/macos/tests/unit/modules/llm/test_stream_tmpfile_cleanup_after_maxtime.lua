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
---
--- F-MED-3: api_mlx_inference.lua (the MLX streaming twin) never got this fix —
--- its payload temp file was removed ONLY via the hardcoded 10 s fallback timer,
--- never as the first statement of its own on_done, so files accumulated under
--- load whenever the fallback window elapsed before on_done happened to run
--- first. Sections 2 below cover the MLX file with the equivalent checks
--- (its constant is STREAM_HARD_TIMEOUT_SEC, not STREAM_MAX_TIME_SEC, and the
--- curl flag pairing differs slightly, so the checks are parameterised rather
--- than reusing check_file() verbatim).

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local src = helpers.read_driver_source(selector)
	return src
end





-- ====================================================================
-- ====================================================================
-- ======= 1/ api_ollama.lua — original llm-api-net-03 coverage =======
-- ====================================================================
-- ====================================================================

do
	local src = read_src("local function read_ollama_port_override") -- modules/llm/api_ollama.lua

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
end





-- =======================================================================
-- =======================================================================
-- ======= 2/ api_mlx_inference.lua — MLX streaming twin (F-MED-3) =======
-- =======================================================================
-- =======================================================================

do
	local src = read_src("function M.post_and_parse_streaming") -- modules/llm/api_mlx_inference.lua

	-- Test 1: STREAM_TMPFILE_CLEANUP_SEC constant must be defined, derived from
	-- (not a bare literal duplicating) STREAM_HARD_TIMEOUT_SEC.
	local has_cleanup_const = src:find("local STREAM_TMPFILE_CLEANUP_SEC", 1, true) ~= nil
	helpers.assert_true(
		has_cleanup_const,
		"api_mlx_inference.lua must define STREAM_TMPFILE_CLEANUP_SEC constant (F-MED-3)"
	)
	helpers.assert_true(
		src:find("STREAM_TMPFILE_CLEANUP_SEC = STREAM_HARD_TIMEOUT_SEC", 1, true) ~= nil,
		"api_mlx_inference.lua's STREAM_TMPFILE_CLEANUP_SEC must be derived from STREAM_HARD_TIMEOUT_SEC, not a bare literal (F-MED-3)"
	)

	-- Test 2: the old bare-10-second fallback timer literal must be gone.
	local has_old_delay = src:find("TimerScheduler.after(10,", 1, true) ~= nil
	helpers.assert_true(
		not has_old_delay,
		"api_mlx_inference.lua must not use bare literal 10 s for the temp-file cleanup timer (F-MED-3)"
	)
	local has_named_delay = src:find("TimerScheduler.after(STREAM_TMPFILE_CLEANUP_SEC,", 1, true) ~= nil
	helpers.assert_true(
		has_named_delay,
		"api_mlx_inference.lua safety-net timer must use STREAM_TMPFILE_CLEANUP_SEC (F-MED-3)"
	)

	-- Test 3: tmp_path must be declared BEFORE on_done in source order — the
	-- exact same Lua lexical-scoping gotcha the Ollama twin's comment warns
	-- about: a local declared AFTER a closure is defined resolves to the nil
	-- global inside that closure, so os.remove(tmp_path) would throw.
	local tmp_path_decl_pos = src:find("local tmp_path =", 1, true)
	local on_done_pos       = src:find("local function on_done(", 1, true)
	helpers.assert_true(tmp_path_decl_pos ~= nil, "api_mlx_inference.lua must declare local tmp_path (F-MED-3)")
	helpers.assert_true(on_done_pos ~= nil, "api_mlx_inference.lua must define on_done (F-MED-3)")
	helpers.assert_true(
		tmp_path_decl_pos < on_done_pos,
		"api_mlx_inference.lua: tmp_path must be declared BEFORE on_done so the closure captures the real upvalue (F-MED-3)"
	)

	-- Test 4: on_done must call os.remove(tmp_path) for immediate cleanup, as
	-- its FIRST statement (matching the Ollama twin's fix shape exactly).
	local on_done_body = src:sub(on_done_pos, on_done_pos + 300)
	local has_remove_in_done = on_done_body:find("os.remove(tmp_path)", 1, true) ~= nil
	helpers.assert_true(
		has_remove_in_done,
		"api_mlx_inference.lua on_done must call os.remove(tmp_path) for immediate cleanup (F-MED-3)"
	)
end

print("[PASS] test_stream_tmpfile_cleanup_after_maxtime")
