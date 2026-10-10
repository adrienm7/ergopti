--- tools/test/managed_ollama_serve_command_test.lua
--- Exact production metadata-hint and command composition over injected ports.
local root = assert(arg[1])
local production = assert(arg[2])
package.path = root .. "/static/ergopti_plus/macos/?.lua;" .. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. production .. "/static/ergopti_plus/macos/?.lua;" .. production .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. production .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Json = require("json")
local Hint = assert(loadfile(root .. "/tools/test/fixtures/managed_ollama_runtime_hint.lua"))()
local home = "/private/Owned O'Brien/$home"
local native = home .. "/Library/Application Support/Ergopti/ollama-native-http/ollama"
local contract = { schema_version = 1, version = "0.24.0", source_commit = string.rep("a", 40),
	capability = "ERGOPTI_OLLAMA_NATIVE_HTTP_V1", native_http_capability = 1, binary_path = "ollama" }
local cd, rd = string.rep("b", 64), string.rep("c", 64)
local asset = { version = contract.version, source_commit = contract.source_commit, capability = contract.capability,
	native_http_capability = contract.native_http_capability, sha256 = string.rep("d", 64), binary_sha256 = string.rep("e", 64) }
local catalogue = { schema_version = 1, runtime_contract_sha256 = cd, version = contract.version,
	source_commit = contract.source_commit, capability = contract.capability, native_http_capability = 1,
	assets = { ["macos-arm64"] = asset } }
local receipt = { schema_version = 1, host = "macos-arm64", runtime_contract_sha256 = cd, catalogue_sha256 = rd,
	asset_sha256 = asset.sha256, binary_sha256 = asset.binary_sha256, source_commit = asset.source_commit,
	capability = asset.capability, native_http_capability = 1 }
local checks, cases = 0, 0
local function check(actual, expected) assert(actual == expected, "managed serve receiving assertion failed"); checks = checks + 1 end
local function case(run) cases = cases + 1; run() end
local function copy(value) local result = {}; for key, item in pairs(value) do result[key] = item end; return result end
case(function()
	check(Hint.matches(contract, catalogue, receipt, "macos-arm64", cd, rd), true)
	for name in pairs(receipt) do
		local changed = copy(receipt); changed[name] = "foreign"
		check(Hint.matches(contract, catalogue, changed, "macos-arm64", cd, rd), false)
	end
	local changed = copy(receipt); changed.extra = true
	check(Hint.matches(contract, catalogue, changed, "macos-arm64", cd, rd), false)
	check(Hint.matches(contract, catalogue, receipt, "macos-amd64", cd, rd), false)
	check(Hint.matches(contract, catalogue, receipt, "macos-arm64", "", rd), false)
end)
local files, binary_present, network_calls, python = {}, true, 0, arg[4] or "/fixture/native/python"
local raw_contract, raw_catalogue = Json.encode(contract), Json.encode(catalogue)
local driver = root .. "/static/ergopti_plus/macos"
local receipt_path = native:gsub("/ollama$", "/.ergopti-managed-runtime.json")
local function seed()
	files = {
		[receipt_path] = Json.encode(receipt),
		[driver .. "/../_shared/modules/llm/managed_ollama_runtime.json"] = raw_contract,
		[driver .. "/../_shared/modules/llm/managed_ollama_release.json"] = raw_catalogue,
		[driver .. "/../_shared/modules/llm/managed_ollama_bootstrap.json"] = '{"maximum_metadata_bytes":1048576}',
		[driver .. "/modules/llm/network-retry.sh"] = "CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n",
		[driver .. "/modules/llm/managed_ollama_serve.py"] = "bundled source owner; port fixture only",
	}
end
seed()
local getenv = os.getenv
os.getenv = function(name) if name == "HOME" then return home end; return getenv(name) end
hs = { processInfo = { arch = "arm64" }, fs = { attributes = function(path)
	if (path == native and binary_present) or path == "/Applications/Ollama.app/Contents/Resources/ollama" then
		return { mode = "file", permissions = "rwxr-xr-x" }
	end
end } }
package.loaded["adapters.file_system"] = {
	exists = function(path) return files[path] ~= nil end,
	classify_no_follow = function(path)
		local raw = files[path]; return raw and { mode = "file", size = #raw } or nil, raw and "ok" or "absent"
	end,
	read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
}
package.loaded["adapters.crypto"] = { sha256_bytes = function(raw)
	if raw == raw_contract then return cd end; if raw == raw_catalogue then return rd end; return ""
end }
package.loaded["modules.llm.network_env"] = { prelude = function() network_calls = network_calls + 1; return "STATIC-PRELUDE; " end }
package.loaded["modules.llm.managed_native_python"] = { resolve = function() return python end }
package.loaded["adapters.python_interpreter"] = { resolve = function() return python end }
package.loaded["app_dirs"] = { files = { unified_prefix = "ErgoptiPlus_", extension = ".log" } }
package.loaded["adapters.managed_ollama_hint"] = { get = function(directory)
	local raw = files[receipt_path]
	if not raw or #raw > 1048576 then return nil end
	local ok, value = pcall(Json.decode, raw)
	if not ok or not files[driver .. "/../_shared/modules/llm/managed_ollama_release.json"]
		or not Hint.matches(contract, catalogue, value, "macos-arm64", cd, rd) then return nil end
	local budgets = { admission = 30, idle = 60, retirement = 600 }
	local raw_retry = files[driver .. "/modules/llm/network-retry.sh"]
	local count = 0; for _ in raw_retry:gmatch("CURL_STALL_SEC=60") do count = count + 1 end
	if count ~= 1 then budgets = nil end
	return { candidate = directory .. "/ollama", budgets = budgets }
end }
local Binary = require("modules.llm.ollama_binary")
local ActualBuilder = require("modules.llm.ollama_server_command")
-- The caller carries the explicit provisional source classification; its
-- original cases and independent expectations remain unchanged.
local Builder = { build = function(executable, log, port)
	return ActualBuilder.build(executable, log, port,
		executable == native and Binary.SOURCE_NATIVE_MANAGED or Binary.SOURCE_PATH)
end }
case(function()
	local path, err, source = Binary.resolve()
	check(path, native); check(err, nil); check(source, Binary.SOURCE_NATIVE_MANAGED)
	local command, why = Builder.build(native, "/private/logs/ErgoptiPlus_2099-01-01.log", 45678)
	check(why, nil); check(command:sub(1, 5), "exec ")
	check(command:find(" -IB ", 1, true) ~= nil, true)
	check(command:find("--port 45678 --timeout 30 --idle-timeout 60 --retirement-timeout 600", 1, true) ~= nil, true)
	check(command:find("while IFS=", 1, true), nil); check(command:find("STATIC-PRELUDE", 1, true), nil)
	check(network_calls, 0); check(command:find("OLLAMA_MODELS", 1, true), nil)
	if arg[3] == "emit" then print(command) end
end)
case(function()
	files[receipt_path] = Json.encode(copy(receipt)); files[receipt_path] = files[receipt_path]:gsub(rd, string.rep("f", 64))
	local path, err, source = Binary.resolve()
	check(path, "/Applications/Ollama.app/Contents/Resources/ollama"); check(err, nil); check(source, Binary.SOURCE_APP)
	local command = assert(Builder.build(path, "/private/logs/ErgoptiPlus_2099-01-01.log", 45678))
	check(command:find("STATIC-PRELUDE", 1, true) ~= nil, true)
	check(command:find("while IFS= read -r LINE", 1, true) ~= nil, true)
	check(command:find("%Y-%m-%d", 1, true) ~= nil, true)
	check(command:find("'127.0.0.1:45678'", 1, true) ~= nil, true)
	check(network_calls, 1); seed()
end)
case(function()
	python = nil
	local command, reason = Builder.build(native, "/private/logs/today.log", 11434)
	check(command, nil); check(reason, "managed native daemon admission is unavailable")
	python = arg[4] or "/fixture/native/python"
	files[driver .. "/modules/llm/network-retry.sh"] = files[driver .. "/modules/llm/network-retry.sh"] .. "CURL_STALL_SEC=60\n"
	command, reason = Builder.build(native, "/private/logs/today.log", 11434)
	check(command, nil); check(reason, "managed native budgets are unavailable"); seed()
end)
case(function()
	files[driver .. "/../_shared/modules/llm/managed_ollama_release.json"] = nil
	check(Binary.native_candidate(), nil)
	local command, reason = Builder.build(native, "/private/logs/today.log", 11434)
	check(command, nil); check(reason, "managed runtime selection is unavailable"); seed()
end)
case(function()
	binary_present = false
	check(Binary.native_candidate(), nil)
	check(Binary.resolve(), "/Applications/Ollama.app/Contents/Resources/ollama")
	binary_present = true
	files[receipt_path] = string.rep("x", 1048577)
	check(Binary.native_candidate(), nil); seed()
end)
case(function()
	local external = "/opt/independent/ollama-native-http/ollama"
	local command, reason = ActualBuilder.build(external, "/private/logs/today.log", 11434, Binary.SOURCE_PATH)
	check(reason, nil); check(command:find("while IFS= read -r LINE", 1, true) ~= nil, true)
	check(command:find(external, 1, true) ~= nil, true)
	local canonical_path_only = assert(ActualBuilder.build(native, "/private/logs/today.log", 11434, Binary.SOURCE_PATH))
	check(canonical_path_only:find("while IFS= read -r LINE", 1, true) ~= nil, true)
	local absent_kind = assert(ActualBuilder.build(native, "/private/logs/today.log", 11434))
	check(absent_kind:find("while IFS= read -r LINE", 1, true) ~= nil, true)
end)
os.getenv = getenv
if arg[3] ~= "emit" then print(string.format("PASS %d cases / %d assertions", cases, checks)) end
