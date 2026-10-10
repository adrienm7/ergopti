--- tools/test/managed_ollama_legacy_cleanup_test.lua
--- Actual legacy adapter over closed native FS receipt ports; no SDK authority.
local root = assert(arg[1])
package.path = root .. "/static/ergopti_plus/macos/?.lua;" .. root .. "/static/ergopti_plus/macos/?/init.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Json = require("json")
local NONCE = "12345678-abcd-4321-abcd-123456789abc"
local assertions, cases = 0, 0
local function check(actual, expected)
	assert(actual == expected, "legacy physical cleanup assertion failed")
	assertions = assertions + 1
end
local function scenario(options, run)
	local saved_fs, saved_adapter, saved_logger, saved_hs = package.loaded["adapters.file_system"],
		package.loaded["adapters.managed_ollama_pull"], package.loaded["infra.logger"], _G.hs
	local present, inode, raw, removals, releases = true, 2, "", 0, 0
	local physical = options.physical == true
	local marker = physical
	if options.receipt_flag == false then marker = false end
	local receipt = { removed = marker }
	package.loaded["infra.logger"] = { error = function() end }
	package.loaded["adapters.managed_ollama_pull"] = nil
	package.loaded["adapters.file_system"] = {
		exists = function() return true end,
		create_secure_temp_file = function() return "/private/legacy-vector" end,
		classify_no_follow = function()
			if not present then return nil, "absent" end
			return { mode = "file", dev = 1, ino = inode, size = #raw }, "ok"
		end,
		read_with_status = function(path)
			if path:find("proxy_policy.json", 1, true) then return '{"max_proxy_bytes":4096}', "ok" end
			if path:find("network-retry.sh", 1, true) then
				return "CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n", "ok"
			end
			return raw, present and "ok" or "absent"
		end,
		remove_if_unchanged = function(_, expected, _, fence)
			removals = removals + 1
			if not fence() or expected.content ~= raw or not present then return false end
			if removals == 1 then
				if physical then present = false end
				return false, nil, receipt, function()
					releases = releases + 1
					local removed_by_owner = physical
					if options.third_flag == false then removed_by_owner = false end
					return true, nil, removed_by_owner
				end
			end
			present = false
			return true
		end,
	}
	_G.hs = { host = { uuid = function() return NONCE end } }
	local adapter = require("adapters.managed_ollama_pull")
	local handle, ready = adapter.prepare("owned/model:tiny", 11434, "/native/python")
	check(ready, true)
	local f = {
		rollback = handle.rollback,
		removals = function() return removals end,
		releases = function() return releases end,
		present = function() return present end,
		recreate = function() present, inode, raw = true, 3, "foreign" end,
		remove_foreign = function() present = false end,
		proof = function()
			local task = { setInput = function(self) return self end }
			check(handle.bind_input(task), true)
			check(handle.mark_start_attempted(), true)
			raw = Json.encode({ version = 1, nonce = NONCE, state = "retired", worker_status = 0,
				source_admitted = true, listener_bound = true, request_reaped = true, daemon_operation_retired = true,
				operation = string.rep("a", 32), source_commit = string.rep("b", 40),
				binary_sha256 = string.rep("c", 64), asset_sha256 = string.rep("d", 64) })
		end,
		settle = function() return handle.settle(0) end,
	}
	local ok, failure = xpcall(function() run(f) end, debug.traceback)
	package.loaded["adapters.file_system"], package.loaded["adapters.managed_ollama_pull"],
		package.loaded["infra.logger"], _G.hs = saved_fs, saved_adapter, saved_logger, saved_hs
	if not ok then error(failure, 0) end
	cases = cases + 1
end
scenario({}, function(f)
	check(f.rollback(), false)
	check(f.present(), true)
	check(f.rollback(), true)
	check(f.removals(), 2)
	check(f.releases(), 1)
	check(f.present(), false)
end)
scenario({ physical = true }, function(f)
	check(f.rollback(), false)
	check(f.rollback(), true)
	check(f.removals(), 1)
	check(f.releases(), 1)
end)
scenario({ physical = true, third_flag = false }, function(f)
	check(f.rollback(), false)
	check(f.rollback(), true)
	check(f.removals(), 1)
end)
scenario({ physical = true }, function(f)
	check(f.rollback(), false)
	f.recreate()
	check(f.rollback(), false)
	check(f.rollback(), false)
	check(f.removals(), 1)
	check(f.present(), true)
	f.remove_foreign()
	check(f.rollback(), true)
end)
scenario({}, function(f)
	check(f.rollback(), false)
	f.recreate()
	check(f.rollback(), false)
	check(f.removals(), 1)
	check(f.present(), true)
end)
scenario({}, function(f)
	f.proof()
	check(f.settle(), false)
	check(f.settle(), true)
	check(f.removals(), 2)
	check(f.releases(), 1)
end)
scenario({ physical = true }, function(f)
	f.proof()
	check(f.settle(), false)
	f.recreate()
	check(f.settle(), false)
	check(f.removals(), 1)
end)

scenario({ physical = true, receipt_flag = false }, function(f)
	check(f.rollback(), false)
	check(f.rollback(), true)
	check(f.removals(), 1)
end)

print("Managed Ollama legacy physical cleanup controls passed: " .. cases .. " cases / " .. assertions .. " assertions")
