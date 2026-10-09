--- tools/test/managed_ollama_cleanup_owner_test.lua
--- Real manager/adapter receiving over controlled ports, never native authority.
local root = assert(arg[1])
package.path = root .. "/static/ergopti_plus/macos/?.lua;" .. root .. "/static/ergopti_plus/macos/?/init.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local with_fixture = require("tests.support.ollama_pull_fixture").with_fixture
local Json = require("json")
local ORIGINAL = "12345678-abcd-4321-abcd-123456789abc"
local FRESH = "abcdef12-abcd-4321-abcd-123456789abc"
local assertions, cases = 0, 0
local function check(actual, expected)
	assert(actual == expected, "cleanup receiving assertion failed")
	assertions = assertions + 1
end
local function with_owned(options, run)
	options = options or {}
	local names = { "adapters.managed_ollama_pull", "adapters.file_system", "adapters.crypto" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	package.loaded["adapters.managed_ollama_pull"] = nil
	local files, sequence, cleanup_tasks, fresh_count = {}, 0, {}, 0
	local handle, adapter, input, allocation, cleanup_hook
	local directory_closes = 0
	local refused, rmdir_refused, refuse_path, retry_mode, retry_path, removal_calls = false, false, nil, nil, nil, {}
	local function write(path, raw) assert(files[path]); files[path].raw = raw end
	package.loaded["adapters.file_system"] = {
		exists = function() return true end,
		create_secure_temp_file = function()
			sequence = sequence + 1
			local path = "/private/cleanup-vector-" .. sequence
			files[path] = { raw = "", inode = sequence, uid = 501, links = 1, permissions = "rw-------" }
			if options.imprecise_anchor and sequence == 2 then files[path].inode = 9007199254740992 end
			return path
		end,
		classify_no_follow = function(path)
			local value = files[path]
			if not value or value.removed then return nil, "absent" end
			return { mode = value.mode or "file", dev = 1, ino = value.inode, uid = value.uid, nlink = value.links,
				permissions = value.permissions, size = #value.raw }, "ok"
		end,
		read_with_status = function(path)
			if path:find("proxy_policy.json", 1, true) then return '{"max_proxy_bytes":4096}', "ok" end
			if path:find("network-retry.sh", 1, true) then
				return "CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n", "ok"
			end
			if not files[path] or files[path].removed then return nil, "absent" end
			return files[path].raw, "ok"
		end,
		remove_if_unchanged = function(path, expected, _, fence)
			removal_calls[path] = (removal_calls[path] or 0) + 1
			if refused or path == refuse_path or not fence() or files[path].raw ~= expected.content then return false end
			if retry_mode and (retry_path == nil or retry_path == path) then
				local physical = retry_mode == "unlinked"
				retry_mode = nil
				local receipt = { removed = physical }
				if physical then files[path].removed = true end
				return false, nil, receipt, function() return true, nil, physical end
			end
			if cleanup_hook then local hook = cleanup_hook; cleanup_hook = nil; hook() end
			files[path].removed = true
			return true
		end,
	}
	package.loaded["adapters.crypto"] = { sha256_bytes = function(raw)
		if raw == "authority-vector\n" then return string.rep("b", 64) end
		if raw == "window-vector\n" then return string.rep("c", 64) end
		return string.rep("e", 64)
	end }
	options.network_env = { opaque_prelude = function()
		_G.hs.fs = {
			dir = function(path)
				if options.directory_refused then error("private directory refused", 0) end
				local state = { names = {}, index = 0 }
				for name, value in pairs(files) do
					local child = name:match("^" .. path:gsub("([^%w])", "%%%1") .. "/([^/]+)$")
					if child and not value.removed then state.names[#state.names + 1] = child end
				end
				return function(actual)
					assert(actual == state, "directory iterator state must be preserved")
					actual.index = actual.index + 1
					return actual.names[actual.index]
				end, state, nil, setmetatable({}, { __close = function() directory_closes = directory_closes + 1 end })
			end,
			rmdir = function(path)
				if rmdir_refused then return false end
				files[path].removed = true
				return true
			end,
		}
		_G.hs.host = { uuid = function()
			if sequence < 2 then return ORIGINAL end
			fresh_count = fresh_count + 1
			if fresh_count == 1 or options.repeated_nonce then return FRESH end
			return string.format("abcdef12-abcd-4321-abcd-%012d", fresh_count)
		end }
		adapter = require("adapters.managed_ollama_pull")
		local ready
		handle, ready = adapter.prepare_owned("owned/model:tiny", 11434, "/native/python")
		if options.imprecise_anchor then check(ready, false); return "" end
		check(ready, true)
		input = Json.decode(handle.input)
		check(input.version, 2)
		check(input.anchor.device, "1")
		check(input.anchor.inode, "2")
		local lifecycle = package.loaded["adapters.task_lifecycle"]
		local native = lifecycle.native
		lifecycle.native = function(label, ...)
			if label == "Ollama pending pull cleanup" and options.construct_cleanup == false then return nil end
			local task = native(label, ...)
			if task then
				if type(options.start_observe) == "function" then
					local original_start = task.start
					function task:start() options.start_observe(self); return original_start(self) end
				end
				function task:setInput(raw)
					self.input = raw
					if label == "Ollama pending pull cleanup" and options.bind_cleanup == false then return false end
					return self
				end
				if label == "Ollama model pull" then check(handle.bind_input(task), true) end
				if label == "Ollama pending pull cleanup" then
					cleanup_tasks[#cleanup_tasks + 1] = task
					local start = task.start
					function task:start()
						if options.throw_cleanup_start then error("native start refused", 0) end
						if options.refuse_cleanup_start then return false end
						if options.inline_cleanup then
							self.running = false
							allocation(self, options.inline_cleanup)
							self.on_done(options.inline_cleanup)
							return true
						end
						return start(self)
					end
				end
			end
			return task
		end
		return ""
	end }
	local ok, failure = xpcall(function()
		with_fixture(options, function(f)
			f.directory_closes = function() return directory_closes end
			f.start = function()
				return f.manager.pull_model("owned/model:tiny", "owned/model:tiny", function() return true end,
					function() return true end, { is_current = function() return true end, _requirement_lifecycle = options.lifecycle })
			end
			f.pending = function(changes)
				local value = { version = 1, nonce = ORIGINAL, state = "pending", worker_status = 78,
					source_admitted = true, listener_bound = true, request_reaped = true, daemon_operation_retired = false,
					operation = string.rep("a", 32), source_commit = string.rep("b", 40),
					binary_sha256 = string.rep("c", 64), asset_sha256 = string.rep("d", 64) }
				for name, changed in pairs(changes or {}) do value[name] = changed end
				write(input.receipt_path, Json.encode(value))
				local directory = input.anchor.path .. ".operation"
				files[directory] = { raw = "", inode = 90, uid = 501, links = 2, mode = "directory", permissions = "rwx------" }
				files[directory .. "/authority.json"] = { raw = "authority-vector\n", inode = 91, uid = 501, links = 1, permissions = "rw-------" }
				files[directory .. "/window.json"] = { raw = "window-vector\n", inode = 92, uid = 501, links = 1, permissions = "rw-------" }
				write(input.anchor.path, Json.encode({ version = 1, nonce = ORIGINAL, operation = string.rep("a", 32),
					directory = { path = directory, device = "1", inode = "90" },
					authority = { path = directory .. "/authority.json", device = "1", inode = "91", sha256 = string.rep("b", 64) },
					window = { path = directory .. "/window.json", device = "1", inode = "92", sha256 = string.rep("c", 64) } }))
				if not options.defer_original_callback then
					f.pulls[1].running = false
					f.pulls[1].on_done(78)
				end
			end
			f.cleanup_proof = function(task, status, changes)
				local request = Json.decode(task.input)
				local value = { version = 1, nonce = request.nonce, original_nonce = ORIGINAL, original_worker_status = 78,
					operation = string.rep("a", 32), authority_sha256 = string.rep("b", 64), window_sha256 = string.rep("c", 64),
					state = status == 78 and "pending" or "retired", worker_status = status, request_reaped = true,
					daemon_operation_retired = status ~= 78, source_admitted = true, listener_bound = true }
				for name, changed in pairs(changes or {}) do value[name] = changed end
				write(request.receipt_path, Json.encode(value))
			end
			allocation = f.cleanup_proof
			f.cleanups = cleanup_tasks
			f.original = function() return input end
			f.files = files
			f.removal_calls = removal_calls
			f.refuse_remove = function(value) refused = value end
			f.refuse_file = function(path) refuse_path = path end
			f.refuse_directory = function(value) rmdir_refused = value end
			f.retry_mode = function(value, path) retry_mode, retry_path = value, path end
			f.cleanup_hook = function(value) cleanup_hook = value end
			run(f)
		end)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
	cases = cases + 1
end
local function begin(f)
	check(f.start(), true)
	f.pending()
	check(f.active_tasks.ollama_pull, f.pulls[1])
	check(f.manager.cleanup_pending_pull(f.pulls[1]), true)
	check(f.active_tasks.ollama_pull_cleanup, f.cleanups[1])
	return f.pulls[1], f.cleanups[1]
end
with_owned({}, function(f)
	check(f.start(), true)
	check(f.manager.cleanup_pending_pull(f.pulls[1]), false)
	check(f.manager.cleanup_pending_pull({}), false)
	check(#f.cleanups, 0)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	local request = Json.decode(child.input)
	check(request.original_worker_status, 78)
	check(request.original_nonce, ORIGINAL)
	check(request.anchor.sha256, string.rep("e", 64))
	check(child.args[3], "--mode")
	check(child.args[4], "explicit-cleanup")
	check(child.args[6], "600")
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.start(), false)
	check(#f.pulls, 1)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), true)
	check(f.active_tasks.ollama_pull, nil)
	check(f.active_tasks.ollama_pull_cleanup, nil)
	check(f.http_callback(), nil)
	check(f.effects.saves, 0)
	check(f.files[f.original().anchor.path].removed, true)
	check(f.files[f.original().receipt_path].removed, true)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 0)
	check(child.on_done(0), false)
	check(f.active_tasks.ollama_pull, original)
	child.running = false
	check(child.on_done(0), true)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	child.running = false
	check(child.on_done(0), false)
	check(f.active_tasks.ollama_pull_cleanup, child)
	check(f.manager.cleanup_pending_pull(original), false)
	f.cleanup_proof(child, 0)
	check(child.on_done(0), true)
end)
for _, mutation in ipairs({ { nonce = ORIGINAL }, { authority_sha256 = string.rep("f", 64) },
	{ window_sha256 = string.rep("f", 64) }, { operation = string.rep("f", 32) },
	{ request_reaped = false }, { source_admitted = false }, { listener_bound = false },
	{ daemon_operation_retired = false } }) do
	with_owned({}, function(f)
		local original, child = begin(f)
		f.cleanup_proof(child, 0, mutation)
		child.running = false
		check(child.on_done(0), false)
		check(f.active_tasks.ollama_pull, original)
		check(f.active_tasks.ollama_pull_cleanup, child)
	end)
end
with_owned({}, function(f)
	local original, child = begin(f)
	local immutable = f.files[f.original().receipt_path].raw
	f.cleanup_proof(child, 78)
	child.running = false
	check(child.on_done(78), false)
	check(f.active_tasks.ollama_pull, original)
	check(f.active_tasks.ollama_pull_cleanup, nil)
	check(f.files[f.original().receipt_path].raw, immutable)
	check(f.manager.cleanup_pending_pull(original), true)
	check(#f.cleanups, 2)
	local second = f.cleanups[2]
	f.cleanup_proof(second, 130)
	second.running = false
	check(second.on_done(130), true)
	check(f.active_tasks.ollama_pull, nil)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 78, { daemon_operation_retired = true })
	child.running = false
	check(child.on_done(78), false)
	check(f.active_tasks.ollama_pull, original)
	check(f.active_tasks.ollama_pull_cleanup, child)
end)
with_owned({}, function(f)
	check(f.start(), true)
	f.pending()
	f.files[f.original().anchor.path].inode = 77
	check(f.manager.cleanup_pending_pull(f.pulls[1]), false)
	check(#f.cleanups, 0)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 0)
	f.files[Json.decode(child.input).receipt_path].inode = 77
	child.running = false
	check(child.on_done(0), false)
	check(f.active_tasks.ollama_pull, original)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 0)
	f.refuse_remove(true)
	child.running = false
	check(child.on_done(0), false)
	check(f.active_tasks.ollama_pull, original)
	f.refuse_remove(false)
	check(child.on_done(0), true)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 0)
	child.running = false
	f.cleanup_hook(function()
		check(f.manager.cleanup_pending_pull(original), false)
		check(child.on_done(0), false)
		check(f.active_tasks.ollama_pull, original)
	end)
	check(child.on_done(0), true)
	check(child.on_done(0), false)
end)
with_owned({ refuse_cleanup_start = true }, function(f)
	check(f.start(), true)
	f.pending()
	local original = f.pulls[1]
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.active_tasks.ollama_pull_cleanup, f.cleanups[1])
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.start(), false)
end)
with_owned({ construct_cleanup = false }, function(f)
	check(f.start(), true)
	f.pending()
	check(f.manager.cleanup_pending_pull(f.pulls[1]), false)
	check(f.active_tasks.ollama_pull, f.pulls[1])
	check(f.active_tasks.ollama_pull_cleanup, nil)
end)
with_owned({ bind_cleanup = false }, function(f)
	check(f.start(), true)
	f.pending()
	check(f.manager.cleanup_pending_pull(f.pulls[1]), false)
	check(f.active_tasks.ollama_pull, f.pulls[1])
	check(f.active_tasks.ollama_pull_cleanup, nil)
end)
with_owned({ inline_cleanup = 0 }, function(f)
	check(f.start(), true)
	f.pending()
	check(f.manager.cleanup_pending_pull(f.pulls[1]), true)
	check(f.active_tasks.ollama_pull, nil)
	check(f.active_tasks.ollama_pull_cleanup, nil)
	check(f.effects.saves, 0)
end)
with_owned({}, function(f)
	check(f.start(), true)
	f.pending({ request_reaped = false })
	check(f.manager.cleanup_pending_pull(f.pulls[1]), false)
	check(#f.cleanups, 0)
end)

with_owned({ repeated_nonce = true }, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 78)
	child.running = false
	check(child.on_done(78), false)
	check(f.manager.cleanup_pending_pull(original), false)
	check(#f.cleanups, 1)
	check(f.active_tasks.ollama_pull, original)
end)


with_owned({}, function(f)
	check(f.start(), true)
	f.pending()
	local original = f.pulls[1]
	local foreign = {}
	f.active_tasks.ollama_pull = foreign
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.active_tasks.ollama_pull, foreign)
	check(#f.cleanups, 0)
end)
local pause_owner
local lifecycle = {
	adopt = function(owner) pause_owner = owner; return true end,
	settle = function() return true end,
}
with_owned({ lifecycle = lifecycle }, function(f)
	local original, child = begin(f)
	check(pause_owner.pause_join(), false)
	check(child.terminate_calls, 1)
	check(pause_owner.pause_join(), false)
	check(child.terminate_calls, 1)
	check(f.active_tasks.ollama_pull, original)
	check(f.active_tasks.ollama_pull_cleanup, child)
	f.cleanup_proof(child, 130)
	child.running = false
	check(child.on_done(130), true)
	check(f.active_tasks.ollama_pull, nil)
end)


with_owned({}, function(f)
	local original, child = begin(f)
	local foreign = {}
	f.active_tasks.ollama_pull = foreign
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), true)
	check(f.active_tasks.ollama_pull, foreign)
	check(f.active_tasks.ollama_pull_cleanup, nil)
	check(f.effects.saves, 0)
end)


local function material_paths(f)
	local directory = f.original().anchor.path .. ".operation"
	return directory, directory .. "/authority.json", directory .. "/window.json"
end
for _, phase in ipairs({ "authority", "window", "directory" }) do
	with_owned({}, function(f)
		local original, child = begin(f)
		local directory, authority, window = material_paths(f)
		if phase == "directory" then f.refuse_directory(true)
		else f.refuse_file(phase == "authority" and authority or window) end
		f.cleanup_proof(child, 0)
		local ack = f.files[Json.decode(child.input).receipt_path].raw
		child.running = false
		check(child.on_done(0), false)
		check(f.active_tasks.ollama_pull, original)
		check(f.files[f.original().receipt_path].removed, nil)
		check(f.files[Json.decode(child.input).receipt_path].removed, nil)
		if phase ~= "authority" then check(f.files[authority].removed, true) end
		if phase == "directory" then check(f.files[window].removed, true) end
		f.refuse_file(nil); f.refuse_directory(false)
		check(f.manager.cleanup_pending_pull(original), true)
		check(#f.cleanups, 1)
		check(f.files[Json.decode(child.input).receipt_path].raw, ack)
		check(f.files[directory].removed, true)
		check(f.active_tasks.ollama_pull, nil)
	end)
end
with_owned({}, function(f)
	local original, child = begin(f)
	local _, authority = material_paths(f)
	f.retry_mode("no-unlink")
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.files[authority].removed, nil)
	check(f.active_tasks.ollama_pull, original)
	check(f.manager.cleanup_pending_pull(original), true)
	check(f.removal_calls[authority], 2)
	check(#f.cleanups, 1)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	local _, authority = material_paths(f)
	f.retry_mode("unlinked")
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.files[authority].removed, true)
	check(f.manager.cleanup_pending_pull(original), true)
	check(f.removal_calls[authority], 1)
	check(#f.cleanups, 1)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	local _, authority, window = material_paths(f)
	f.refuse_file(window)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	f.files[authority] = { raw = "foreign", inode = 900, uid = 501, links = 1, permissions = "rw-------" }
	f.refuse_file(nil)
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.files[authority].raw, "foreign")
	check(f.files[authority].removed, nil)
	check(f.removal_calls[authority], 1)
	check(f.active_tasks.ollama_pull, original)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	local directory = material_paths(f)
	f.files[directory .. "/foreign"] = { raw = "foreign", inode = 901, uid = 501, links = 1, permissions = "rw-------" }
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.files[directory .. "/foreign"].removed, nil)
	check(f.active_tasks.ollama_pull, original)
end)
for _, change in ipairs({ { inode = 901 }, { uid = 502 }, { permissions = "rwxr-xr-x" }, { mode = "link" } }) do
	with_owned({}, function(f)
		local original, child = begin(f)
		local directory = material_paths(f)
		for key, value in pairs(change) do f.files[directory][key] = value end
		f.cleanup_proof(child, 0)
		child.running = false
		check(child.on_done(0), false)
		check(f.files[directory].removed, nil)
		check(f.active_tasks.ollama_pull, original)
	end)
end
for _, change in ipairs({ { inode = 901 }, { links = 2 }, { mode = "link" }, { raw = "foreign" } }) do
	with_owned({}, function(f)
		local original, child = begin(f)
		local _, authority = material_paths(f)
		for key, value in pairs(change) do f.files[authority][key] = value end
		f.cleanup_proof(child, 0)
		child.running = false
		check(child.on_done(0), false)
		check(f.files[authority].removed, nil)
		check(f.active_tasks.ollama_pull, original)
	end)
end
with_owned({}, function(f)
	local original, child = begin(f)
	f.refuse_directory(true)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	local receipt_path = Json.decode(child.input).receipt_path
	local ack = f.files[receipt_path].raw
	f.files[receipt_path].raw = "{}"
	f.refuse_directory(false)
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.files[f.original().receipt_path].removed, nil)
	f.files[receipt_path].raw = ack
	check(f.manager.cleanup_pending_pull(original), true)
	check(#f.cleanups, 1)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	local directory = material_paths(f)
	f.refuse_directory(true)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	f.files[directory].inode = 900
	f.refuse_directory(false)
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.files[directory].removed, nil)
	check(f.active_tasks.ollama_pull, original)
end)
with_owned({ defer_original_callback = true }, function(f)
	check(f.start(), true)
	f.pending()
	local original = f.pulls[1]
	local _, authority, window = material_paths(f)
	local raw = Json.decode(f.files[f.original().receipt_path].raw)
	raw.state, raw.worker_status, raw.daemon_operation_retired = "retired", 0, true
	f.files[f.original().receipt_path].raw = Json.encode(raw)
	f.refuse_file(window)
	original.running = false
	check(original.on_done(0), false)
	check(f.files[authority].removed, true)
	check(f.files[f.original().receipt_path].removed, nil)
	f.refuse_file(nil)
	check(original.on_done(0), true)
	check(f.active_tasks.ollama_pull, nil)
	check(#f.cleanups, 0)
	check(f.http_callback(), nil)
end)
with_owned({ defer_original_callback = true }, function(f)
	check(f.start(), true)
	f.pending()
	local directory = material_paths(f)
	local raw = Json.decode(f.files[f.original().receipt_path].raw)
	raw.state, raw.worker_status, raw.daemon_operation_retired = "retired", 0, true
	f.files[f.original().receipt_path].raw = Json.encode(raw)
	f.files[f.original().anchor.path].raw = ""
	f.pulls[1].running = false
	check(f.pulls[1].on_done(0), false)
	check(f.files[directory].removed, nil)
	check(f.active_tasks.ollama_pull, f.pulls[1])
end)


for _, phase in ipairs({ "cleanup_receipt", "original_receipt", "anchor" }) do
	with_owned({}, function(f)
		local original, child = begin(f)
		local directory, authority, window = material_paths(f)
		local cleanup_receipt = Json.decode(child.input).receipt_path
		local blocked = phase == "cleanup_receipt" and cleanup_receipt
			or (phase == "original_receipt" and f.original().receipt_path or f.original().anchor.path)
		f.refuse_file(blocked)
		f.cleanup_proof(child, 0)
		child.running = false
		check(child.on_done(0), false)
		check(f.files[directory].removed, true)
		check(f.files[authority].removed, true)
		check(f.files[window].removed, true)
		check(f.active_tasks.ollama_pull, original)
		f.refuse_file(nil)
		check(f.manager.cleanup_pending_pull(original), true)
		check(#f.cleanups, 1)
		check(f.active_tasks.ollama_pull, nil)
		check(f.files[blocked].removed, true)
	end)
end
with_owned({}, function(f)
	local original, child = begin(f)
	local _, authority = material_paths(f)
	f.files[authority].raw = string.rep("p", 16385)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.files[authority].removed, nil)
	check(f.active_tasks.ollama_pull, original)
end)


for _, phase in ipairs({ "cleanup_receipt", "original_receipt", "anchor" }) do
	with_owned({}, function(f)
		local original, child = begin(f)
		local cleanup_receipt = Json.decode(child.input).receipt_path
		local target = phase == "cleanup_receipt" and cleanup_receipt
			or (phase == "original_receipt" and f.original().receipt_path or f.original().anchor.path)
		f.retry_mode("unlinked", target)
		f.cleanup_proof(child, 0)
		child.running = false
		check(child.on_done(0), false)
		check(f.files[target].removed, true)
		f.files[target] = { raw = "foreign", inode = 900, uid = 501, links = 1, permissions = "rw-------" }
		check(f.manager.cleanup_pending_pull(original), false)
		check(f.manager.cleanup_pending_pull(original), false)
		check(f.removal_calls[target], 1)
		check(f.files[target].raw, "foreign")
		check(f.active_tasks.ollama_pull, original)
		f.files[target].removed = true
		check(f.manager.cleanup_pending_pull(original), true)
		check(f.removal_calls[target], 1)
		check(#f.cleanups, 1)
	end)
end


with_owned({}, function(f)
	local original, child = begin(f)
	local directory = material_paths(f)
	local receipt = Json.decode(child.input).receipt_path
	f.refuse_file(receipt)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.files[directory].removed, true)
	f.files[directory] = { raw = "", inode = 900, uid = 501, links = 2, mode = "directory", permissions = "rwx------" }
	f.refuse_file(nil)
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.files[directory].removed, nil)
	check(f.active_tasks.ollama_pull, original)
	f.files[directory].removed = true
	check(f.manager.cleanup_pending_pull(original), true)
	check(#f.cleanups, 1)
end)

local function exact_roots(f)
	local index = 1
	while true do
		local name, value = debug.getupvalue(f.manager.pull_model, index)
		if name == nil then error("original manager root is absent", 0) end
		if name == "_active_tasks" then return value end
		index = index + 1
	end
end
local root_options = {}
with_owned(root_options, function(f)
	local roots = exact_roots(f)
	root_options.start_observe = function(task) check(roots[task], true) end
	local original, child = begin(f)
	check(roots[original], true)
	check(roots[child], true)
	collectgarbage("collect")
	check(roots[original], true)
	check(roots[child], true)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), true)
	check(roots[original], nil)
	check(roots[child], nil)
	check(f.directory_closes() > 0, true)
end)
with_owned({ directory_refused = true }, function(f)
	local original, child = begin(f)
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.active_tasks.ollama_pull, original)
	check(f.active_tasks.ollama_pull_cleanup, child)
	check(f.directory_closes(), 0)
end)
with_owned({}, function(f)
	local original, child = begin(f)
	local directory = material_paths(f)
	f.files[directory .. "/foreign.json"] = { raw = "foreign", inode = 999, uid = 501, links = 1, permissions = "rw-------" }
	f.cleanup_proof(child, 0)
	child.running = false
	check(child.on_done(0), false)
	check(f.active_tasks.ollama_pull, original)
	check(f.files[directory .. "/foreign.json"].removed, nil)
	check(f.directory_closes(), 1)
end)
with_owned({ throw_cleanup_start = true }, function(f)
	check(f.start(), true)
	f.pending()
	local original = f.pulls[1]
	check(f.manager.cleanup_pending_pull(original), false)
	check(f.active_tasks.ollama_pull, original)
	check(f.active_tasks.ollama_pull_cleanup, f.cleanups[1])
	check(exact_roots(f)[f.cleanups[1]], true)
end)

print("Managed Ollama explicit cleanup owner controls passed: " .. cases .. " cases / " .. assertions .. " assertions")
