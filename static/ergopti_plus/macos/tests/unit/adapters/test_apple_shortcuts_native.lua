--- tests/unit/adapters/test_apple_shortcuts_native.lua

--- Controlled signed-role boundaries; actual SDK/C ownership is macOS CI-only.
local H = require("tests.helpers")
local Json = require("json")
local ID = "11111111-1111-1111-1111-111111111111"

local function fixture(body)
	local saved, old_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local f = { tasks = {}, inode = 12, wires = {}, decoded = 0 }
	local ok, failure = xpcall(function()
		package.loaded["adapters.apple_shortcuts_native"] = nil
		package.loaded["platform.remap.lease_helper"] = { resolve = function() return "/owned/ErgoptiPlus" end }
		package.loaded["adapters.shell_runner"] = { spawn = function(executable, args, done, chunks, environment, private, owned, limit)
			H.assert_eq(executable, "/owned/ErgoptiAutomationQuery"); H.assert_true(private); H.assert_true(owned)
			H.assert_eq(limit, 90000); H.assert_nil(environment)
			local task = { args = args, inputs = {}, physical = false, observers = {}, closes = 0 }
			function task.start() if f.on_start then f.on_start(task) end; return not f.start_refused end
			function task.set_input(value)
				task.inputs[#task.inputs + 1] = value
				if f.on_input then f.on_input(task) end
				return true
			end
			function task.close_input() task.closes = task.closes + 1; return true end
			function task.terminate() task.physical = true; return true end
			function task.isSettled() return task.physical end
			function task.onSettled(callback) task.observers[#task.observers + 1] = callback; return true end
			function task.emit(value, errors) chunks(task, value, errors or "") end
			function task.finish(code)
				task.physical = true; done(code or 0, "", "")
				for _, callback in ipairs(task.observers) do callback() end
			end
			if f.on_construct then f.on_construct(task) end
			f.tasks[#f.tasks + 1] = task
			return task
		end }
		local function metadata(path)
			if f.missing_helper and path == "/owned/ErgoptiAutomationQuery" then return nil end
			return { mode = "file", permissions = "r-xr-xr-x", dev = 1, ino = path == "/owned/ErgoptiAutomationQuery" and (f.helper_inode or f.inode) or f.inode,
				uid = 0, gid = 0, size = 40, modification = 4, change = 5 }
		end
		_G.hs = { task = { new = function() end }, base64 = { decode = function(value)
			f.decoded = f.decoded + 1; return f.wires[value]
		end }, fs = { symlinkAttributes = metadata, attributes = metadata, pathToAbsolute = function(path) return path end } }
		f.native = require("adapters.apple_shortcuts_native")
		function f.reply(task, nonce, operation, id, changes)
			local packet = { version = 1, nonce = nonce, operation = operation, status = "observed",
				rows = Json.array({ { id = id or ID, name = "日本 e\204\129\n", accepts_input = false } }), truncated = false }
			for key, value in pairs(changes or {}) do packet[key] = value end
			local token = f.wire_token or "WIRE"
			f.wires[token] = Json.encode(packet)
			task.emit("Q1 DATA " .. token .. "\nQ1 RETIRED 0\n")
		end
		body(f)
	end, debug.traceback)
	_G.hs = old_hs
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	-- Keep the shared shell-runner slot explicit for the suite ownership scanner.
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	if not ok then error(failure, 0) end
end

H.describe("shipped native Apple Shortcut transport", function()
	H.it("uses the signed bundle role and exposes no data before exact settlement", function()
		fixture(function(f)
			local result; local owner = assert(f.native.create())
			H.assert_true(owner.discover(function(value) result = value end))
			local task = f.tasks[1]; H.assert_eq(task.args, { "--automation-query-worker", "discover", "1" })
			task.emit("Q1 HELD\n"); H.assert_eq(task.inputs, { "ACTIVATE\n" })
			f.reply(task, 1, "discover"); H.assert_nil(result)
			task.finish(); H.assert_eq(result.choices[1].label, "日本 e\204\129\n")
			H.assert_nil(result.choices[1].id); H.assert_true(f.native.available())
		end)
	end)
	H.it("keeps failed cancellation owned across picker replacement", function()
		fixture(function(f)
			local called = 0; local owner = assert(f.native.create())
			H.assert_true(owner.discover(function() called = called + 1 end))
			local task = f.tasks[1]; task.emit("Q1 HELD\n")
			H.assert_eq(owner.invalidate(), false); H.assert_eq(f.native.available(), false)
			H.assert_nil(f.native.create()); H.assert_true(task.closes > 0)
			f.reply(task, 1, "discover"); task.finish()
			H.assert_eq(called, 0); H.assert_true(owner.invalidate()); H.assert_true(f.native.available())
		end)
	end)
	H.it("refuses data without retirement even after helper leader completion", function()
		fixture(function(f)
			local owner = assert(f.native.create()); H.assert_true(owner.discover(function() error("unretired payload") end))
			f.tasks[1].emit("Q1 HELD\n"); f.wires.WIRE = "{}"; f.tasks[1].emit("Q1 DATA WIRE\n")
			f.tasks[1].finish(); H.assert_true(owner.pending()); H.assert_eq(f.native.available(), false)
		end)
	end)
	H.it("preserves a structured native permission refusal rather than an empty success", function()
		fixture(function(f)
			local result, reason; local owner = assert(f.native.create())
			H.assert_true(owner.discover(function(a, b) result, reason = a, b end))
			f.tasks[1].emit("Q1 HELD\n")
			f.wires.WIRE = Json.encode({ version = 1, nonce = 1, operation = "discover",
				status = "refused", reason = "automation_permission_refused" })
			f.tasks[1].emit("Q1 DATA WIRE\nQ1 RETIRED 0\n"); f.tasks[1].finish()
			H.assert_nil(result); H.assert_eq(reason, "automation_permission_refused")
		end)
	end)
	H.it("handles synchronous native construction-frame protocol without a 512-byte false refusal", function()
		fixture(function(f)
			f.wire_token = string.rep("A", 1024)
			f.on_start = function(task) task.emit("Q1 HELD\n") end
			f.on_input = function(task) f.reply(task, 1, "discover"); task.finish() end
			local result; local owner = assert(f.native.create())
			H.assert_true(owner.discover(function(value) result = value end))
			H.assert_eq(result.choices[1].provider, "apple_shortcuts")
		end)
	end)
	for _, fault in ipairs({ "stderr", "oversize", "duplicate", "nonzero" }) do
		H.it("retains native cleanup uncertainty after " .. fault, function()
			fixture(function(f)
				local owner = assert(f.native.create()); local called = 0
				H.assert_true(owner.discover(function() called = called + 1 end))
				local task = f.tasks[1]; task.emit("Q1 HELD\n")
				if fault == "stderr" then task.emit("", "PRIVATE")
				elseif fault == "oversize" then task.emit(string.rep("x", 90001))
				elseif fault == "duplicate" then task.emit("Q1 HELD\n")
				else task.emit("Q1 RETIRED 0\n") end
				task.finish(fault == "nonzero" and 70 or 0)
				H.assert_eq(called, 0); H.assert_true(owner.pending()); H.assert_eq(f.native.available(), false)
			end)
		end)
	end
	H.it("revalidates the actual persisted UUID and refuses remote invocation", function()
		fixture(function(f)
			local terminal
			local handle = assert(f.native.revalidate_program("/usr/bin/shortcuts", { "run", ID }, function(...)
				terminal = { ... }
			end, function() return true end))
			H.assert_true(handle.start()); local task = f.tasks[1]
			H.assert_eq(task.args, { "--automation-query-worker", "revalidate", "1", ID })
			task.emit("Q1 HELD\n"); f.reply(task, 1, "revalidate"); task.finish()
			H.assert_eq(terminal[1], false); H.assert_eq(terminal[3], "service_retirement_unqualified")
		end)
	end)
	H.it("refuses stale or deleted persisted IDs and never starts invocation", function()
		fixture(function(f)
			local reason
			local handle = assert(f.native.revalidate_program("/usr/bin/shortcuts", { "run", ID }, function(_, _, why)
				reason = why
			end, function() return true end))
			H.assert_true(handle.start()); f.tasks[1].emit("Q1 HELD\n")
			f.reply(f.tasks[1], 1, "revalidate", "22222222-2222-2222-2222-222222222222"); f.tasks[1].finish()
			H.assert_eq(reason, "query_refused"); H.assert_eq(#f.tasks, 1)
		end)
	end)
	H.it("refuses malformed chosen descriptors before any native allocation", function()
		fixture(function(f)
			for _, arguments in ipairs({ { "run" }, { "run", string.rep("-", 36) }, { "run", ID, "extra" } }) do
				H.assert_nil(f.native.revalidate_program("/usr/bin/shortcuts", arguments, function() end, function() return true end))
			end
			H.assert_eq(#f.tasks, 0)
		end)
	end)
end)

H.describe("native query cross-consumer reservation", function()
	H.it("fences a persisted query while a picker query owns native custody", function()
		fixture(function(f)
			local owner = assert(f.native.create())
			H.assert_true(owner.discover(function() end))
			H.assert_nil(f.native.revalidate_program("/usr/bin/shortcuts", { "run", ID }, function() end, function() return true end))
			H.assert_eq(#f.tasks, 1)
			f.tasks[1].emit("Q1 HELD\n"); f.reply(f.tasks[1], 1, "discover"); f.tasks[1].finish()
			H.assert_true(f.native.available())
		end)
	end)
	H.it("reserves custody before raw constructor callbacks reenter another consumer", function()
		fixture(function(f)
			local nested = "unobserved"
			f.on_construct = function()
				f.on_construct = nil
				nested = f.native.revalidate_program("/usr/bin/shortcuts", { "run", ID }, function() end, function() return true end)
			end
			local owner = assert(f.native.create())
			H.assert_true(owner.discover(function() end))
			H.assert_nil(nested); H.assert_eq(#f.tasks, 1)
		end)
	end)
	H.it("rejects extra native fields when revalidating persisted descriptors", function()
		fixture(function(f)
			local reason
			local handle = assert(f.native.revalidate_program("/usr/bin/shortcuts", { "run", ID }, function(_, _, value) reason = value end, function() return true end))
			H.assert_true(handle.start()); f.tasks[1].emit("Q1 HELD\n")
			f.reply(f.tasks[1], 1, "revalidate", nil, { arbitrary = "private" }); f.tasks[1].finish()
			H.assert_eq(reason, "query_refused")
		end)
	end)
end)

H.describe("independent nested query executable", function()
	H.it("refuses a missing nested helper without falling back to the main launcher", function()
		fixture(function(f)
			f.missing_helper = true
			H.assert_eq(f.native.available(), false)
			H.assert_nil(f.native.create())
			H.assert_eq(#f.tasks, 0)
		end)
	end)
	H.it("refuses changed executable identity before held activation", function()
		fixture(function(f)
			local owner = assert(f.native.create())
			H.assert_true(owner.discover(function() error("changed executable") end))
			f.helper_inode = 13; f.tasks[1].emit("Q1 HELD\n")
			H.assert_eq(#f.tasks[1].inputs, 0)
			H.assert_true(f.tasks[1].closes > 0)
		end)
	end)
	H.it("drops a completed packet when the nested executable changed", function()
		fixture(function(f)
			local result; local owner = assert(f.native.create())
			H.assert_true(owner.discover(function(value) result = value end))
			local task = f.tasks[1]; task.emit("Q1 HELD\n")
			f.reply(task, 1, "discover"); f.helper_inode = 13; task.finish()
			H.assert_nil(result)
		end)
	end)
end)
