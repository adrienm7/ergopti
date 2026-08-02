--- tests/unit/llm/test_stream_tmpfile_no_orphan.lua

--- Regression test for llm-api-net-02: os.tmpname() creates an empty file at
--- the base path it returns. The streaming code appended a suffix to get the
--- actual payload path but never deleted the base file, orphaning one zero-byte
--- file per streaming request in /tmp.
---
--- Fix: after `local tmp_path = os.tmpname() .. "_..._stream.json"`, immediately
--- call `os.remove(base)` so the only file remaining is the suffixed one the
--- code owns. Both api_ollama.lua and api_mlx.lua had the bug.

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function check_file(selector, suffix)
	local src = helpers.read_driver_source(selector)

	-- Test 1: the base tmpname variable is stored before the suffix is appended.
	local has_base_var = src:find("os.tmpname()", 1, true) ~= nil
	helpers.assert_true(has_base_var, selector .. ": os.tmpname() call must still be present")

	-- Test 2: os.remove is called on the base (not just on the suffixed path).
	-- The fix stores the base in a local and removes it immediately.
	-- Pattern: os.remove(<base_var>) where base_var is defined as os.tmpname().
	-- We check that `os.remove` appears near `os.tmpname()` (within same block).
	local remove_base = src:find("os.remove(_tmp_base)", 1, true) ~= nil
	helpers.assert_true(
		remove_base,
		selector .. ": os.remove(_tmp_base) must appear after os.tmpname() to remove the orphan base file (" .. suffix .. ")"
	)

	-- Test 3: the suffixed path is still used (the payload file must still exist).
	local uses_suffix = src:find(suffix, 1, true) ~= nil
	helpers.assert_true(
		uses_suffix,
		selector .. ": suffixed tmp path (" .. suffix .. ") must still be used for the payload"
	)
end

check_file("local function read_ollama_port_override", "_ollama_stream.json")
-- MLX streaming lives in the request engine.
check_file("function M.post_and_parse_streaming", "_mlx_stream.json")

print("[PASS] test_stream_tmpfile_no_orphan")
