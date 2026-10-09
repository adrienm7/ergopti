--- tools/test/managed_ollama_cleanup_receipt_test.lua
--- Literal portable receiving vectors; no native daemon or SDK authority.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/tools/test/managed_ollama_cleanup_receipt_test%.lua$"))
package.path = root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
local Json = require("json")
local Receipt = require("core.llm.managed_ollama_cleanup_receipt")
local expected = {
	nonce = "abcdef12-abcd-4321-abcd-123456789abc",
	original_nonce = "12345678-abcd-4321-abcd-123456789abc",
	operation = string.rep("a", 32), authority_sha256 = string.rep("b", 64), window_sha256 = string.rep("c", 64),
}
local assertions = 0
local function proof(changes)
	local value = { version = 1, nonce = expected.nonce, original_nonce = expected.original_nonce,
		original_worker_status = 78, operation = expected.operation, authority_sha256 = expected.authority_sha256,
		window_sha256 = expected.window_sha256, state = "retired", worker_status = 0,
		request_reaped = true, daemon_operation_retired = true, source_admitted = true, listener_bound = true }
	for name, changed in pairs(changes or {}) do value[name] = changed end
	return Json.encode(value)
end
local function check(raw, status, result, binding)
	assert(Receipt.receive(raw, Json.decode, binding or expected, status) == result)
	assertions = assertions + 1
end
check(proof(), 0, "retired")
check(proof({ worker_status = 130 }), 130, "retired")
check(proof({ state = "pending", worker_status = 78, daemon_operation_retired = false }), 78, "pending")
check(proof({ worker_status = 78 }), 78, nil)
for _, name in ipairs({ "request_reaped", "source_admitted", "listener_bound" }) do
	for _, value in ipairs({ false, 1, "true" }) do check(proof({ [name] = value }), 0, nil) end
end
for _, name in ipairs({ "nonce", "original_nonce", "operation", "authority_sha256", "window_sha256" }) do
	for _, value in ipairs({ "", "foreign", false }) do check(proof({ [name] = value }), 0, nil) end
	local binding = {}
	for key, value in pairs(expected) do binding[key] = value end
	binding[name] = name:find("nonce", 1, true) and "ffffffff-abcd-4321-abcd-123456789abc" or string.rep("f", #expected[name])
	check(proof(), 0, nil, binding)
end
for _, change in ipairs({ { unknown = true }, { version = 2 }, { original_worker_status = 0 },
	{ worker_status = 130 }, { worker_status = "0" }, { daemon_operation_retired = false },
	{ daemon_operation_retired = "true" }, { state = "pending" }, { state = "complete" } }) do check(proof(change), 0, nil) end
for _, status in ipairs({ 1, 256, -1, 0.5, "0" }) do check(proof(), status, nil) end
check(proof():gsub('"version":1', '"version":1,"version":1'), 0, nil)
check(proof():gsub('"version"', '"\\u0076ersion"'), 0, nil)
check(proof() .. "{}", 0, nil)
check(string.rep(" ", 4097), 0, nil)
local same_nonce = {}
for key, value in pairs(expected) do same_nonce[key] = value end
same_nonce.nonce = same_nonce.original_nonce
check(proof(), 0, nil, same_nonce)

local anchor_path = "/private/owned-anchor"
local directory_path = anchor_path .. ".operation"
local function anchor(changes)
	local value = { version = 1, nonce = expected.original_nonce, operation = expected.operation,
		directory = { path = directory_path, device = "1", inode = "2" },
		authority = { path = directory_path .. "/authority.json", device = "1", inode = "3", sha256 = string.rep("b", 64) },
		window = { path = directory_path .. "/window.json", device = "1", inode = "4", sha256 = string.rep("c", 64) } }
	for field, changed in pairs(changes or {}) do value[field] = changed end
	return value
end
local function anchor_check(value, result)
	assert((Receipt.anchor(type(value) == "string" and value or Json.encode(value), Json.decode,
		expected.original_nonce, expected.operation, anchor_path) ~= nil) == result)
	assertions = assertions + 1
end
anchor_check(anchor(), true)
for _, change in ipairs({ { version = 2 }, { nonce = expected.nonce }, { operation = string.rep("f", 32) },
	{ unknown = true }, { directory = false }, { authority = false }, { window = false } }) do anchor_check(anchor(change), false) end
for _, name in ipairs({ "directory", "authority", "window" }) do
	for _, change in ipairs({ { path = "/foreign/file" }, { device = "01" }, { inode = "0" },
		{ inode = "01" }, { device = 1 }, { inode = "-1" }, { unknown = true } }) do
		local value = anchor()
		for key, changed in pairs(change) do value[name][key] = changed end
		anchor_check(value, false)
	end
end
for _, name in ipairs({ "authority", "window" }) do
	for _, hash in ipairs({ "", string.rep("B", 64), false }) do
		local value = anchor(); value[name].sha256 = hash; anchor_check(value, false)
	end
end
anchor_check(Json.encode(anchor()):gsub('"version":1', '"version":1,"version":1'), false)
anchor_check(Json.encode(anchor()):gsub('"inode":"3"', '"inode":"3","inode":"3"'), false)
anchor_check(Json.encode(anchor()) .. "{}", false)
local original = { version = 1, nonce = expected.original_nonce, state = "pending", worker_status = 78,
	source_admitted = true, listener_bound = true, request_reaped = true, daemon_operation_retired = false,
	operation = expected.operation, source_commit = string.rep("d", 40), binary_sha256 = string.rep("e", 64), asset_sha256 = string.rep("f", 64) }
assert(Receipt.original_pending(Json.encode(original), Json.decode, expected.original_nonce) ~= nil)
assertions = assertions + 1
for _, change in ipairs({ { state = "retired" }, { worker_status = 0 }, { daemon_operation_retired = true },
	{ nonce = expected.nonce }, { request_reaped = false }, { source_admitted = false }, { listener_bound = false },
	{ source_commit = "" }, { asset_sha256 = "" }, { operation = "" }, { unknown = true } }) do
	local value = {}; for key, original_value in pairs(original) do value[key] = original_value end
	for key, changed in pairs(change) do value[key] = changed end
	assert(Receipt.original_pending(Json.encode(value), Json.decode, expected.original_nonce) == nil)
	assertions = assertions + 1
end

print("Managed Ollama explicit cleanup receipt controls passed: " .. assertions)
