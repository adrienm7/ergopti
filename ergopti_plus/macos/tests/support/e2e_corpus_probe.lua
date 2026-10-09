--- tests/support/e2e_corpus_probe.lua

--- ==============================================================================
--- MODULE: E2E Corpus Failure Probe
--- DESCRIPTION:
--- Exercises the real E2E process boundary with isolated corpus I/O failures.
--- ==============================================================================

local mode = assert(arg[1], "a probe mode is required")
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = assert(source:match("^(.*)/tests/support/e2e_corpus_probe%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local corpus = assert(root:match("^(.*)/[^/]+$")) .. "/_shared/tests/corpus/hotstrings/vectors.json"
local json = require("json")
local vectors = json.decode(require("tests.support.source_file").read(corpus)).vectors
local selected
for _, vector in ipairs(vectors) do
	if vector.driver_specific == nil and vector.expected.matched then selected = vector; break end
end
assert(selected, "the real corpus must contain an applicable matching vector")
local payloads = { invalid_json = "{", empty_vectors = '{"vectors":[]}',
	object_vectors = '{"vectors":{"unexpected":{}}}' }
assert(mode == "success" or mode == "missing" or mode == "read_failure"
	or mode == "read_throw" or mode == "close_failure" or mode == "close_throw"
	or payloads[mode], "invalid probe mode")
local payload = payloads[mode] or json.encode({ vectors = { selected } })
local opens, reads, closes = 0, 0, 0
local open, exit = io.open, os.exit
io.open = function(path, access)
	if path ~= corpus then return open(path, access) end
	opens = opens + 1
	if mode == "missing" then return nil, "injected corpus open failure" end
	return {
		read = function()
			reads = reads + 1
			if mode == "read_throw" then error("injected corpus read throw") end
			if mode == "read_failure" then return nil, "injected corpus read failure" end
			return payload
		end,
		close = function()
			closes = closes + 1
			if mode == "close_throw" then error("injected corpus close throw") end
			if mode == "close_failure" then return nil, "injected corpus close failure" end
			return true
		end,
	}
end
local marker, code = {}, nil
os.exit = function(value) code = value; error(marker, 0) end
local ok, reason = pcall(dofile, root .. "/tests/e2e/run_e2e.lua")
io.open, os.exit = open, exit
assert(not ok and reason == marker, "the E2E runner must reach its terminal boundary: " .. tostring(reason))
print(string.format("PROBE opens=%d reads=%d closes=%d vector=%s", opens, reads, closes, selected.id))
exit(code)
