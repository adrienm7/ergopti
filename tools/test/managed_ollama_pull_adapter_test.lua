--- tools/test/managed_ollama_pull_adapter_test.lua
--- Injected task/FS boundary controls, never native Hammerspoon evidence.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/tools/test/managed_ollama_pull_adapter_test%.lua$"))
package.path = root .. "/static/ergopti_plus/macos/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
local Json = require("json")
local NONCE = "12345678-abcd-4321-abcd-123456789abc"
local raw, removed, inode = "", false, 2
local policy = "CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n"
package.loaded["infra.logger"] = { error = function() end }
package.loaded["adapters.file_system"] = {
	exists = function() return true end,
	read_with_status = function(path)
		if path:find("proxy_policy.json", 1, true) then return '{"max_proxy_bytes":123}', "ok" end
		if path:find("network-retry.sh", 1, true) then return policy, "ok" end
		return raw, "ok"
	end,
	create_secure_temp_file = function() raw, removed, inode = "", false, 2; return "/private/owned-pull-receipt" end,
	classify_no_follow = function() return { mode = "file", dev = 1, ino = inode, size = #raw }, "ok", "ok" end,
	remove_if_unchanged = function(_, expected, _, fence)
		if fence() and expected.content == raw then removed = true; return true end
		return false
	end,
}
_G.hs = { host = { uuid = function() return NONCE end } }
local Adapter = assert(loadfile(root .. "/static/ergopti_plus/macos/adapters/managed_ollama_pull.lua"))()
local assertions = 0
local function check(value, expected)
	assert(value == expected); assertions = assertions + 1
end
local function prepare()
	local handle, ready = Adapter.prepare("owned/model:tiny", 11434, "/native/python")
	check(ready, true)
	check(handle.executable, "/native/python")
	check(handle.arguments[1], "-I")
	check(handle.arguments[3], "--admission-timeout")
	check(handle.arguments[4], "30")
	check(handle.arguments[6], "60")
	check(handle.arguments[8], "600")
	check(handle.arguments[10], "123")
	local request = Json.decode(handle.input)
	check(request.model, "owned/model:tiny")
	check(request.port, 11434)
	check(request.nonce, NONCE)
	local task = { setInput = function(self, input) self.input = input; return self end }
	check(handle.bind_input(task), true)
	check(task.input, handle.input)
	check(handle.mark_start_attempted(), true)
	check(handle.rollback(), false)
	return handle
end
local function proof(changes)
	local result = { version = 1, nonce = NONCE, state = "retired", worker_status = 0,
		source_admitted = true, listener_bound = true, request_reaped = true, daemon_operation_retired = true,
		operation = string.rep("a", 32), source_commit = string.rep("b", 40),
		binary_sha256 = string.rep("c", 64), asset_sha256 = string.rep("d", 64) }
	for key, value in pairs(changes or {}) do result[key] = value end
	return Json.encode(result)
end
local handle = prepare()
check(handle.settle(0), false)
check(removed, false)
raw = proof({ daemon_operation_retired = false, state = "pending" })
check(handle.settle(0), false)
check(removed, false)
raw = proof()
check(handle.settle(1), false)
check(removed, false)
check(handle.settle(0), true)
check(removed, true)
check(handle.settle(0), true)
handle = prepare()
raw = proof(); inode = 3
check(handle.settle(0), false)
check(removed, false)
for _, bad in ipairs({ "CURL_CONNECT_TIMEOUT_SEC=0\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n",
	policy .. "CURL_CONNECT_TIMEOUT_SEC=40\n", "CURL_CONNECT_TIMEOUT_SEC=nan\n" }) do
	policy = bad
	local _, ready = Adapter.prepare("owned/model:tiny", 11434, "/native/python")
	check(ready, false)
end
check(Adapter.handles((os.getenv("HOME") or "") .. "/Library/Application Support/Ergopti/ollama-native-http/ollama"), true)
check(Adapter.handles("/external/ollama"), false)
-- A directory basename is not managed ownership; only the exact HOME path
-- enters the separate Python admission route, which still verifies its source.
check(Adapter.handles("/opt/independent/ollama-native-http/ollama"), false)
check(Adapter.handles((os.getenv("HOME") or "") .. ".independent/Library/Application Support/Ergopti/ollama-native-http/ollama"), false)
check(Adapter.handles((os.getenv("HOME") or "") .. "/Library/Application Support/Ergopti/ollama-native-http/ollama.foreign"), false)
check(Adapter.handles(nil), false)
print("Managed Ollama injected adapter controls passed: " .. assertions)
