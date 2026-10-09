--- tools/test/managed_ollama_pull_receipt_test.lua
--- Portable exact receipt vectors; these do not execute the native SDK worker.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/tools/test/managed_ollama_pull_receipt_test%.lua$"))
local shared = root .. "/static/ergopti_plus/_shared/lua/"
package.path = shared .. "?.lua;" .. package.path
local Json = require("json")
local Receipt = require("core.llm.managed_ollama_pull_receipt")
local NONCE = "12345678-abcd-4321-abcd-123456789abc"
local count = 0
local function proof(changes)
	local value = {
		version = 1, nonce = NONCE, state = "retired", worker_status = 0,
		source_admitted = true, listener_bound = true, request_reaped = true, daemon_operation_retired = true,
		operation = string.rep("a", 32), source_commit = string.rep("b", 40),
		binary_sha256 = string.rep("c", 64), asset_sha256 = string.rep("d", 64),
	}
	for key, change in pairs(changes or {}) do value[key] = change end
	return Json.encode(value)
end
local function check(raw, status, expected, nonce)
	assert(Receipt.retired(raw, Json.decode, nonce or NONCE, status) == expected)
	count = count + 1
end
check(proof(), 0, true)
check(proof({ worker_status = 130 }), 130, true)
check(proof({ worker_status = 78, source_admitted = false, listener_bound = false,
	operation = "", source_commit = "", binary_sha256 = "", asset_sha256 = "" }), 78, true)
for _, name in ipairs({ "request_reaped", "daemon_operation_retired", "source_admitted", "listener_bound" }) do
	for _, value in ipairs({ false, "true", 1 }) do check(proof({ [name] = value }), 0, false) end
end
for _, name in ipairs({ "operation", "source_commit", "binary_sha256", "asset_sha256" }) do
	for _, value in ipairs({ "", "A", "foreign", false }) do check(proof({ [name] = value }), 0, false) end
end
check(proof(), 1, false)
check(proof(), 0, false, "ffffffff-abcd-4321-abcd-123456789abc")
check(proof({ worker_status = 256 }), 256, false)
check(proof({ worker_status = 0.5 }), 0.5, false)
check(proof({ state = "pending" }), 0, false)
check(proof({ unknown = true }), 0, false)
check(proof():gsub('"version":1', '"version":1,"version":1'), 0, false)
check(proof():gsub('"version"', '"\\u0076ersion"'), 0, false)
check(proof() .. "{}", 0, false)
check(string.rep(" ", 4097), 0, false)
print("Managed Ollama pull receipt controls passed: " .. count)
