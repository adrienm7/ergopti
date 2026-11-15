--- tests/unit/modules/llm/streaming/test_stream_tmpfile_cleanup_after_maxtime.lua

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

	-- Test 1: the --max-time ceiling is the shared local Ollama budget (NET-003).
	helpers.assert_true(
		src:find('require("core.timing.engine.timings").sec("llm", "ollama_request_timeout_ms")', 1, true) ~= nil,
		"api_ollama.lua must read its --max-time ceiling from [llm] ollama_request_timeout_ms (NET-003)"
	)
	helpers.assert_true(src:find('"--max-time", tostring(stream_max_time_sec())', 1, true) ~= nil,
		"curl --max-time must use the registry ceiling (llm-api-net-03)")

	-- Test 2: the safety-net removal waits strictly past that ceiling.
	local margin = tonumber(src:match("local STREAM_TMPFILE_CLEANUP_MARGIN_SEC%s*=%s*(%d+)"))
	helpers.assert_true(margin ~= nil and margin > 0,
		"the payload cleanup margin past --max-time must be positive (llm-api-net-03)")
	helpers.assert_true(
		src:find("TimerScheduler.after(stream_max_time_sec() + STREAM_TMPFILE_CLEANUP_MARGIN_SEC,", 1, true) ~= nil,
		"api_ollama.lua safety-net timer must wait past the --max-time ceiling (llm-api-net-03)"
	)

	-- Test 3: no typed ceiling or delay remains.
	helpers.assert_true(src:find('"--max-time", "60"', 1, true) == nil and src:find("TimerScheduler.after(10,", 1, true) == nil,
		"api_ollama.lua must not use bare literals for --max-time or the cleanup timer (llm-api-net-03)")
	-- The registered stream-cleanup-deadline case compares actual native curl
	-- arguments with the scheduled timer; a declaration is not argument coverage.

	-- Test 6: on_done must relinquish task ownership and then settle its payload owner
	-- before any parser or user callback can fail. Assert ordering instead of a
	-- fixed source window so a transactional ownership preamble stays covered.
	local on_done_pos = src:find("local function on_done(", 1, true)
	helpers.assert_true(on_done_pos ~= nil, "api_ollama.lua must define on_done (llm-api-net-03)")
	local next_section = src:find("\n\t-- Build", on_done_pos, true) or #src
	local on_done_body = src:sub(on_done_pos, next_section)
	local ownership_pos = on_done_body:find("_active_stream_task = nil", 1, true)
	local remove_pos = on_done_body:find("retire_payload()", 1, true)
	local capture_pos = src:find("local retire_payload = _payload_cleanup.capture(tmp_path,", 1, true)
	helpers.assert_true(capture_pos ~= nil and capture_pos < on_done_pos,
		"the exact payload cleanup owner must be captured before on_done")
	local parser_pos = on_done_body:find("flush_lines()", 1, true)
	helpers.assert_true(
		ownership_pos ~= nil and remove_pos ~= nil and parser_pos ~= nil
			and ownership_pos < remove_pos and remove_pos < parser_pos,
		"api_ollama.lua on_done must release task ownership, settle its captured payload cleanup, then parse output (llm-api-net-03)"
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
	local tmp_path_decl_pos = src:find("local tmp_path[%s,=]")
	local on_done_pos       = src:find("local function on_done(", 1, true)
	helpers.assert_true(tmp_path_decl_pos ~= nil, "api_mlx_inference.lua must declare local tmp_path (F-MED-3)")
	helpers.assert_true(on_done_pos ~= nil, "api_mlx_inference.lua must define on_done (F-MED-3)")
	helpers.assert_true(
		tmp_path_decl_pos < on_done_pos,
		"api_mlx_inference.lua: tmp_path must be declared BEFORE on_done so the closure captures the real upvalue (F-MED-3)"
	)

	-- Test 4: release the completed task first, then settle its payload owner before any
	-- fallible parsing/logging/caller callback. This is the same transaction as
	-- the Ollama twin and survives harmless changes to comment length.
	local next_section = src:find("\n\t-- Build", on_done_pos, true) or #src
	local on_done_body = src:sub(on_done_pos, next_section)
	local ownership_pos = on_done_body:find("_ctx.stream.task = nil", 1, true)
	local remove_pos = on_done_body:find("retire_payload()", 1, true)
	local capture_pos = src:find("local retire_payload = _payload_cleanup.capture(tmp_path,", 1, true)
	helpers.assert_true(capture_pos ~= nil and capture_pos < on_done_pos,
		"the exact payload cleanup owner must be captured before on_done")
	local parser_pos = on_done_body:find("flush_lines()", 1, true)
	helpers.assert_true(
		ownership_pos ~= nil and remove_pos ~= nil and parser_pos ~= nil
			and ownership_pos < remove_pos and remove_pos < parser_pos,
		"api_mlx_inference.lua on_done must release task ownership, settle its captured payload cleanup, then parse output (F-MED-3)"
	)
end

print("[PASS] test_stream_tmpfile_cleanup_after_maxtime")
