--- tests/unit/infra/test_e2e_corpus_integration.lua

--- ==============================================================================
--- MODULE: Mandatory E2E Corpus Regressions
--- DESCRIPTION:
--- Missing or invalid coverage must fail the real runner before scenarios start.
--- ==============================================================================

local helpers = require("tests.helpers")
local text_utils = require("infra.text_utils")

--- Checks the actual child verdict and receipts from the injected corpus handle.
--- @param mode string Corpus success or failure mode.
local function check_corpus(mode)
	local windows = package.config:sub(1, 1) == "\\"
	local function quote(value)
		if not windows then return text_utils.shell_quote(value) end
		assert(not value:find('"', 1, true), "Windows executable and file paths cannot contain quotes")
		return '"' .. value .. '"'
	end
	local command = quote(os.getenv("LUA") or "lua") .. " "
		.. quote(helpers.driver_root() .. "tests/support/e2e_corpus_probe.lua") .. " " .. mode .. " 2>&1"
	if windows then command = 'cmd /d /s /c "' .. command .. '"' end
	local pipe = assert(io.popen(command, "r"), "E2E probe must start")
	local output = assert(pipe:read("*a"))
	local closed, _, status = pipe:close()
	local opens, reads, closes, vector = output:match("PROBE opens=(%d+) reads=(%d+) closes=(%d+) vector=(%S+)")
	helpers.assert_eq(tonumber(opens), 1, output)
	helpers.assert_eq(closed and 0 or status, mode == "success" and 0 or 1, output)
	helpers.assert_eq(tonumber(reads), mode == "missing" and 0 or 1, output)
	helpers.assert_eq(tonumber(closes), mode == "missing" and 0 or 1, output)
	if mode == "success" then
		helpers.assert_true(output:find("PASS  e2e[" .. vector .. "]", 1, true) ~= nil, output)
		helpers.assert_true(output:find("# All E2E scenarios passed.", 1, true) ~= nil, output)
	else
		helpers.assert_true(output:find("FAIL: could not load corpus", 1, true) ~= nil, output)
		helpers.assert_true(output:find("PASS  ", 1, true) == nil, output)
		helpers.assert_true(output:find("# All E2E scenarios passed.", 1, true) == nil, output)
	end
end

helpers.describe("mandatory E2E corpus", function()
	for _, mode in ipairs({ "success", "missing", "read_failure", "read_throw", "close_failure",
		"close_throw", "invalid_json", "empty_vectors", "object_vectors" }) do
		helpers.it("(e2e-mandatory-corpus) " .. mode, function() check_corpus(mode) end)
	end
end)
