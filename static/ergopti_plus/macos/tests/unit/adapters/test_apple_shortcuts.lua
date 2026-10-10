--- tests/unit/adapters/test_apple_shortcuts.lua

--- Controlled asynchronous native ports; no Hammerspoon/ScriptingBridge qualification.
local H = require("tests.helpers")
local Json = require("json")
local Adapter = require("adapters.apple_shortcuts")
local function assert_false(value) H.assert_eq(value, false) end
local ID1 = "11111111-1111-1111-1111-111111111111"
local ID2 = "22222222-2222-2222-2222-222222222222"

local function fixture()
	local f = { rows = { { id = ID1, name = "日本 e\204\129\n'$(PRIVATE)", accepts_input = false },
		{ id = ID2, name = "日本 e\204\129\n'$(PRIVATE)", accepts_input = true } }, tasks = {}, invocations = {}, token = "CLI1",
		qualifications = { discovery = true, invocation = true, cancellation = true } }
	local function handle(done, automation)
		local task = { physical = false, service = not automation, observers = {}, starts = 0, cancels = 0 }
		function task.start() task.starts = task.starts + 1; return not f.start_refused end
		function task.terminate() task.cancels = task.cancels + 1; return false end
		function task.isSettled() return task.physical end
		function task.automationSettled() return task.service end
		function task.onSettled(callback) task.observers[#task.observers + 1] = callback; return true end
		function task.finish(raw, code, errors) done(code or 0, raw, errors or "") end
		function task.retire(service)
			task.physical = true
			if service then task.service = true end
			for _, callback in ipairs(task.observers) do callback() end
		end
		return task
	end
	f.ports = {
		qualified = function(role) if f.on_qualified then f.on_qualified() end; return f.qualifications[role] end,
		identity = function() return { executable = "/usr/bin/shortcuts", token = f.token } end,
		query = function(request, done)
			H.assert_eq(request.limit, 65536); H.assert_eq(request.timeout, 20)
			local task = handle(done, false); task.request = request
			f.tasks[#f.tasks + 1] = task
			return task
		end,
		invoke = function(scalar, admitted, done)
			local task = handle(function(_, success) done(success) end, true)
			task.scalar, task.admitted = scalar, admitted
			function task.finish(success) done(success) end
			f.invocations[#f.invocations + 1] = task
			return task
		end,
	}
	f.owner = assert(Adapter.new(f.ports))
	function f.reply(task, rows, changes)
		local data = { version = 1, nonce = task.request.nonce, operation = task.request.operation,
			status = "observed", rows = Json.array(rows or f.rows), truncated = false }
		for key, value in pairs(changes or {}) do data[key] = value end
		task.finish(Json.encode(data))
	end
	function f.discover()
		local result
		H.assert_true(f.owner.discover(function(value) result = value end))
		local task = f.tasks[#f.tasks]; f.reply(task); task.retire()
		return assert(result)
	end
	return f
end

H.describe("chosen Apple Shortcut ownership", function()
	H.it("keeps duplicate Unicode/newline names separate and IDs private", function()
		local f = fixture(); local result = f.discover()
		H.assert_eq(#result.choices, 2); H.assert_eq(result.choices[1].label, result.choices[2].label)
		H.assert_true(result.choices[1].key ~= result.choices[2].key)
		H.assert_nil(result.choices[1].id)
	end)
	H.it("delivers no discovery before exact physical settlement", function()
		local f, called = fixture(), 0
		H.assert_true(f.owner.discover(function() called = called + 1 end))
		f.reply(f.tasks[1]); H.assert_eq(called, 0); H.assert_true(f.owner.pending())
		f.tasks[1].retire(); H.assert_eq(called, 1); assert_false(f.owner.pending())
	end)
	H.it("resolves chosen ID to literal existing v1 argv after revalidation", function()
		local f = fixture(); local initial = f.discover(); local scalar
		H.assert_true(f.owner.resolve(initial.choices[2].key, {}, function(value) scalar = value end))
		local task = f.tasks[2]; H.assert_eq(task.request.id, ID2)
		f.reply(task, { f.rows[2] }); task.retire()
		H.assert_eq(require("program_parameter").parse(scalar, "hs"), {
			executable = "/usr/bin/shortcuts", arguments = { "run", ID2 } })
	end)
	for _, changed in ipairs({ "id", "name", "accepts_input" }) do
		H.it("refuses equal-count chosen " .. changed .. " substitution", function()
			local f = fixture(); local initial = f.discover(); local value, reason
			H.assert_true(f.owner.resolve(initial.choices[1].key, {}, function(a, b) value, reason = a, b end))
			local row = { id = ID1, name = f.rows[1].name, accepts_input = false }
			row[changed] = changed == "id" and ID2 or changed == "name" and "renamed" or true
			f.reply(f.tasks[2], { row }); f.tasks[2].retire()
			H.assert_nil(value); H.assert_eq(reason, "stale_discovery")
		end)
	end
	H.it("rejects arguments and stale keys without native allocation", function()
		local f = fixture(); local initial = f.discover()
		assert_false(f.owner.resolve(initial.choices[1].key, { "--input-path", "/private" }, function() end))
		H.assert_true(f.owner.invalidate())
		assert_false(f.owner.resolve(initial.choices[1].key, {}, function() end)); H.assert_eq(#f.tasks, 1)
	end)
	H.it("refuses native CLI replacement before and after query", function()
		local f = fixture(); local initial = f.discover(); local reason
		f.token = "CLI2"
		assert_false(f.owner.resolve(initial.choices[1].key, {}, function() end)); H.assert_eq(#f.tasks, 1)
		f.token = "CLI1"
		H.assert_true(f.owner.resolve(initial.choices[1].key, {}, function(_, why) reason = why end))
		f.reply(f.tasks[2], { f.rows[1] }); f.token = "CLI2"; f.tasks[2].retire()
		H.assert_eq(reason, "query_refused")
	end)
	for _, fault in ipairs({ "nonce", "duplicate", "oversize", "permission", "stderr" }) do
		H.it("contains private " .. fault .. " reply without success", function()
			local f, value, reason = fixture()
			H.assert_true(f.owner.discover(function(a, b) value, reason = a, b end))
			local task = f.tasks[1]
			if fault == "nonce" then f.reply(task, nil, { nonce = 999 })
			elseif fault == "duplicate" then f.reply(task, { f.rows[1], f.rows[1] })
			elseif fault == "oversize" then task.finish(string.rep("x", 65537))
			elseif fault == "stderr" then task.finish("{}", 0, "PRIVATE")
			else task.finish(Json.encode({ version = 1, nonce = task.request.nonce, operation = "discover",
				status = "refused", reason = "automation_permission_refused" })) end
			task.retire(); H.assert_nil(value); H.assert_true(type(reason) == "string")
			assert_false(reason:find("PRIVATE", 1, true) ~= nil)
		end)
	end
	H.it("retains cancelled query debt and discards its late reply", function()
		local f, called = fixture(), 0
		H.assert_true(f.owner.discover(function() called = called + 1 end))
		assert_false(f.owner.invalidate()); assert_false(f.owner.discover(function() end))
		f.reply(f.tasks[1]); f.tasks[1].retire()
		assert_false(f.owner.pending()); H.assert_eq(called, 0)
		H.assert_true(f.owner.invalidate()); H.assert_eq(#f.discover().choices, 2)
	end)
	H.it("refuses invocation when runtime cancellation is unqualified", function()
		local f = fixture(); local initial = f.discover(); f.qualifications.cancellation = false
		local accepted, reason = f.owner.invoke(initial.choices[1].key, "keyboard", function() return true end, function() end)
		assert_false(accepted); H.assert_eq(reason, "cancellation_unqualified"); H.assert_eq(#f.invocations, 0)
	end)
	for _, consumer in ipairs({ "gesture", "keyboard", "other" }) do
		H.it("uses identical chosen argv and acknowledged retirement for " .. consumer, function()
			local f = fixture(); local initial = f.discover(); local called, success = 0, nil
			H.assert_true(f.owner.invoke(initial.choices[1].key, consumer, function(actual)
				H.assert_eq(actual, consumer); return true
			end, function(value) called, success = called + 1, value end))
			f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire()
			local task = f.invocations[1]
			H.assert_eq(Json.decode_lossless(task.scalar).arguments, { "run", ID1 })
			task.finish(true); task.retire(false); H.assert_eq(called, 0)
			assert_false(f.owner.invoke(initial.choices[1].key, "foreign", function() return true end, function() end))
			task.retire(true); H.assert_eq(called, 1); H.assert_true(success)
		end)
	end
	H.it("retains cancelled service debt after CLI closure across all consumers", function()
		local f = fixture(); local initial = f.discover(); local called = 0
		H.assert_true(f.owner.invoke(initial.choices[1].key, "gesture", function() return true end,
			function() called = called + 1 end))
		f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire(); local task = f.invocations[1]
		assert_false(f.owner.invalidate()); task.finish(true); task.retire(false)
		H.assert_true(f.owner.pending()); assert_false(f.owner.discover(function() end))
		assert_false(f.owner.invalidate()); task.retire(true)
		assert_false(f.owner.pending()); H.assert_eq(called, 0)
	end)
	H.it("rechecks consumer admission after asynchronous ID revalidation", function()
		local f = fixture(); local initial = f.discover(); local admitted, reason = true, nil
		H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function() return admitted end,
			function(_, why) reason = why end))
		admitted = false; f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire()
		H.assert_eq(#f.invocations, 0); H.assert_eq(reason, "admission_refused")
	end)
	H.it("refuses reentrant construction during capability observation", function()
		local f, nested = fixture(), 0
		f.on_qualified = function()
			nested = nested + 1
			local accepted, reason = f.owner.discover(function() end)
			assert_false(accepted); H.assert_eq(reason, "busy")
		end
		f.discover(); H.assert_true(nested > 0); H.assert_eq(#f.tasks, 1)
	end)
	H.it("retains start-refusal cleanup without admitting a successor", function()
		local f = fixture(); f.start_refused = true
		assert_false(f.owner.discover(function() error("refused operation published") end))
		H.assert_true(f.owner.pending()); assert_false(f.owner.discover(function() end))
		f.tasks[1].retire(); H.assert_true(f.owner.invalidate())
	end)
	H.it("captures nonce privately before a native transport mutates its request", function()
		local f, reason = fixture(), nil
		H.assert_true(f.owner.discover(function(_, why) reason = why end))
		f.tasks[1].request.nonce = 999
		f.reply(f.tasks[1]); f.tasks[1].retire()
		H.assert_eq(reason, "invalid_reply")
	end)
	H.it("does not resurrect a session invalidated during native capability observation", function()
		local f = fixture()
		f.on_qualified = function() f.owner.invalidate() end
		local accepted, reason = f.owner.discover(function() error("invalidated session published") end)
		assert_false(accepted); H.assert_eq(reason, "stale_discovery"); H.assert_eq(#f.tasks, 0)
	end)
	H.it("retains unknown constructor custody instead of opening a successor", function()
		local f = fixture()
		f.ports.query = function() error("PRIVATE unknown native acquisition") end
		local accepted, reason = f.owner.discover(function() end)
		assert_false(accepted); H.assert_eq(reason, "transport_refused"); H.assert_true(f.owner.pending())
		assert_false(f.owner.invalidate()); assert_false(f.owner.discover(function() end))
	end)
	H.it("suppresses terminal success after consumer admission closes", function()
		local f = fixture(); local initial = f.discover(); local admitted, success = true, nil
		H.assert_true(f.owner.invoke(initial.choices[1].key, "gesture", function() return admitted end,
			function(value) success = value end))
		f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire()
		admitted = false; f.invocations[1].finish(true); f.invocations[1].retire(true)
		assert_false(success)
	end)
end)

H.describe("Independent terminal Apple Shortcut query currency", function()
	for _, port in ipairs({ "identity", "qualified" }) do
		H.it("terminal " .. port .. " invalidation cannot resurrect discovery", function()
			local f = fixture(); local calls, result, invalidated = 0, nil, nil
			H.assert_true(f.owner.discover(function(value) calls = calls + 1; result = value end))
			local task = f.tasks[1]; f.reply(task)
			H.assert_eq(calls, 0); H.assert_true(f.owner.pending())
			if port == "identity" then
				f.ports.identity = function()
					invalidated = f.owner.invalidate()
					return { executable = "/usr/bin/shortcuts", token = f.token }
				end
			else f.on_qualified = function() invalidated = f.owner.invalidate() end end
			task.retire()
			H.assert_true(task.physical); H.assert_true(invalidated); assert_false(f.owner.pending())
			print("TERMINAL_REVOCATION", port, "calls", calls, "choices", result and #result.choices or 0)
			H.assert_eq(calls, 0, "terminal observation invalidated the original query before publication")
			H.assert_nil(result, "retired discovery never publishes fresh picker keys")
		end)
	end
end)

H.describe("Independent terminal Apple Shortcut invocation currency", function()
	for _, port in ipairs({ "identity", "invocation", "cancellation", "admitted" }) do
		H.it("terminal " .. port .. " invalidation cannot complete an invocation", function()
			local f = fixture(); local initial = f.discover(); local calls, success, invalidated = 0, nil, nil
			local task
			H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function()
				if port == "admitted" and task and task.physical and task.service then invalidated = f.owner.invalidate() end
				return true
			end, function(value) calls = calls + 1; success = value end))
			f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire(); task = f.invocations[1]
			H.assert_eq(calls, 0); H.assert_true(f.owner.pending())
			if port == "identity" then
				f.ports.identity = function()
					if task.physical and task.service then invalidated = f.owner.invalidate() end
					return { executable = "/usr/bin/shortcuts", token = f.token }
				end
			elseif port ~= "admitted" then
				f.ports.qualified = function(role)
					if role == port and task.physical and task.service then invalidated = f.owner.invalidate() end
					return f.qualifications[role]
				end
			end
			task.finish(true); task.retire(true)
			H.assert_true(task.physical); H.assert_true(task.service); H.assert_true(invalidated)
			assert_false(f.owner.pending())
			print("TERMINAL_INVOCATION_REVOCATION", port, "calls", calls, "success", tostring(success))
			H.assert_eq(calls, 0, "the invalidated invocation retains no business callback")
			H.assert_nil(success)
		end)
	end
	H.it("genuine current discovery and invocation retain terminal acknowledgements", function()
		local f = fixture(); local initial = f.discover(); local calls, success, reason = 0, nil, nil
		H.assert_eq(#initial.choices, 2); assert_false(f.owner.pending())
		H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function() return true end,
			function(value, why) calls = calls + 1; success, reason = value, why end))
		f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire()
		local task = f.invocations[1]; task.finish(true); task.retire(false)
		H.assert_eq(calls, 0); H.assert_true(f.owner.pending())
		task.retire(true); H.assert_eq(calls, 1); H.assert_true(success); H.assert_eq(reason, "completed")
		H.assert_true(task.physical); H.assert_true(task.service); assert_false(f.owner.pending())
		H.assert_eq(#f.tasks, 2); H.assert_eq(#f.invocations, 1)
	end)
end)

H.describe("terminal Apple Shortcut refusal currency", function()
	for _, port in ipairs({ "identity", "qualified" }) do
		H.it("terminal refused " .. port .. " invalidation suppresses discovery", function()
			local f, calls, value, reason, invalidated = fixture(), 0
			H.assert_true(f.owner.discover(function(result, why) calls, value, reason = calls + 1, result, why end))
			local task = f.tasks[1]; f.reply(task)
			if port == "identity" then
				f.ports.identity = function() invalidated = f.owner.invalidate(); return nil end
			else
				f.ports.qualified = function() invalidated = f.owner.invalidate(); return false end
			end
			task.retire()
			H.assert_true(task.physical); H.assert_true(invalidated); assert_false(f.owner.pending())
			H.assert_eq(calls, 0, "invalidated refusal has no current recipient")
			H.assert_nil(value); H.assert_nil(reason)
		end)
	end
	for _, port in ipairs({ "identity", "invocation", "cancellation", "admitted" }) do
		H.it("terminal refused " .. port .. " invalidation suppresses invocation", function()
			local f = fixture(); local initial = f.discover(); local task
			local calls, value, reason, invalidated = 0
			H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function()
				if port == "admitted" and task and task.physical and task.service then
					invalidated = f.owner.invalidate(); return false
				end
				return true
			end, function(result, why) calls, value, reason = calls + 1, result, why end))
			f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire(); task = f.invocations[1]
			if port == "identity" then
				f.ports.identity = function() invalidated = f.owner.invalidate(); return nil end
			elseif port ~= "admitted" then
				f.ports.qualified = function(role)
					if role == port then invalidated = f.owner.invalidate(); return false end
					return f.qualifications[role]
				end
			end
			task.finish(true); task.retire(true)
			H.assert_true(task.physical); H.assert_true(task.service); H.assert_true(invalidated)
			assert_false(f.owner.pending()); H.assert_eq(calls, 0, "invalidated refusal has no current recipient")
			H.assert_nil(value); H.assert_nil(reason)
		end)
	end
	H.it("ordinary current refusals retain exact terminal failure delivery", function()
		for _, port in ipairs({ "identity", "qualified" }) do
			local f, calls, value, reason = fixture(), 0
			H.assert_true(f.owner.discover(function(result, why) calls, value, reason = calls + 1, result, why end))
			f.reply(f.tasks[1])
			if port == "identity" then f.ports.identity = function() return nil end
			else f.ports.qualified = function() return false end end
			f.tasks[1].retire(); H.assert_true(f.tasks[1].physical); assert_false(f.owner.pending())
			H.assert_eq(calls, 1); H.assert_nil(value); H.assert_eq(reason, "query_refused")
		end
		local f = fixture(); local initial = f.discover(); local task
		local calls, value, reason = 0
		H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function()
			return not (task and task.physical and task.service)
		end, function(result, why) calls, value, reason = calls + 1, result, why end))
		f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire(); task = f.invocations[1]
		task.finish(true); task.retire(false); H.assert_eq(calls, 0); H.assert_true(f.owner.pending())
		task.retire(true); H.assert_true(task.physical); H.assert_true(task.service)
		H.assert_eq(calls, 1); assert_false(value); H.assert_eq(reason, "admission_refused")
		assert_false(f.owner.pending())
	end)
	for _, port in ipairs({ "identity", "invocation", "cancellation" }) do
		H.it("native admission observes late " .. port .. " invalidation", function()
			local f = fixture(); local initial = f.discover(); local calls, invalidated = 0
			H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function() return true end,
				function() calls = calls + 1 end))
			f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire(); local task = f.invocations[1]
			if port == "identity" then
				f.ports.identity = function()
					invalidated = f.owner.invalidate(); return { executable = "/usr/bin/shortcuts", token = f.token }
				end
			else
				f.ports.qualified = function(role)
					if role == port then invalidated = f.owner.invalidate() end
					return f.qualifications[role]
				end
			end
			local admitted_now = task.admitted()
			H.assert_true(task.cancels > 0); H.assert_true(f.owner.pending())
			task.finish(true); task.retire(false); H.assert_true(f.owner.pending()); task.retire(true)
			H.assert_true(task.physical); H.assert_true(task.service); assert_false(f.owner.pending())
			H.assert_eq(calls, 0); assert_false(invalidated)
			assert_false(admitted_now)
		end)
	end
end)

H.describe("Apple Shortcut revalidation consumer currency", function()
	for _, port in ipairs({ "identity", "invocation", "cancellation", "admitted" }) do
		for _, ready in ipairs({ true, false }) do
			H.it("revalidation " .. port .. " invalidation with " .. tostring(ready) .. " suppresses acquisition delivery", function()
				local f = fixture(); local initial = f.discover(); local query_task, observing_terminal
				local calls, value, reason, invalidated = 0
				H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function()
					if query_task and query_task.physical then
						observing_terminal = true
						if port == "admitted" then invalidated = f.owner.invalidate(); return ready end
					end
					return true
				end, function(result, why) calls, value, reason = calls + 1, result, why end))
				query_task = f.tasks[2]
				if port == "identity" then
					f.ports.identity = function()
						if observing_terminal then invalidated = f.owner.invalidate(); if not ready then return nil end end
						return { executable = "/usr/bin/shortcuts", token = f.token }
					end
				elseif port ~= "admitted" then
					f.ports.qualified = function(role)
						if observing_terminal and role == port then invalidated = f.owner.invalidate(); return ready end
						return f.qualifications[role]
					end
				end
				f.reply(query_task, { f.rows[1] }); query_task.retire()
				H.assert_true(query_task.physical); H.assert_true(invalidated)
				-- The original model may have already allocated a cancelled invocation.
				for _, task in ipairs(f.invocations) do task.finish(true); task.retire(true) end
				assert_false(f.owner.pending())
				H.assert_eq(calls, 0, "invalidated revalidation has no current invocation recipient")
				H.assert_nil(value); H.assert_nil(reason); H.assert_eq(#f.invocations, 0)
			end)
		end
	end
end)

H.describe("Apple Shortcut acquisition refusal settlement", function()
	H.it("current revalidation admission refusals deliver without invoking", function()
		for _, port in ipairs({ "identity", "invocation", "cancellation", "admitted" }) do
			local f = fixture(); local initial = f.discover(); local task, observing_terminal
			local calls, value, reason = 0
			H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function()
				if task and task.physical then observing_terminal = true; return port ~= "admitted" end
				return true
			end, function(result, why) calls, value, reason = calls + 1, result, why end))
			task = f.tasks[2]
			if port == "identity" then
				f.ports.identity = function()
					if observing_terminal then return nil end
					return { executable = "/usr/bin/shortcuts", token = f.token }
				end
			elseif port ~= "admitted" then
				f.ports.qualified = function(role)
					if observing_terminal and role == port then return false end
					return f.qualifications[role]
				end
			end
			f.reply(task, { f.rows[1] }); task.retire()
			H.assert_true(task.physical); assert_false(f.owner.pending()); H.assert_eq(#f.invocations, 0)
			H.assert_eq(calls, 1); assert_false(value); H.assert_eq(reason, "admission_refused")
		end
	end)
	for _, result in ipairs({ "throw", "missing", "malformed" }) do
		H.it("invalidated " .. result .. " invocation construction retains unknown debt without delivery", function()
			local f = fixture(); local initial = f.discover(); local invalidated
			local calls, value, reason = 0
			local original_invoke = f.ports.invoke
			f.ports.invoke = function(...)
				original_invoke(...)
				invalidated = f.owner.invalidate()
				if result == "throw" then error("private constructor failure") end
				if result == "malformed" then return {} end
				return nil
			end
			H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function() return true end,
				function(result_value, why) calls, value, reason = calls + 1, result_value, why end))
			f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire()
			H.assert_true(f.tasks[2].physical); assert_false(invalidated); H.assert_eq(#f.invocations, 1)
			local task = f.invocations[1]; H.assert_eq(task.starts, 0)
			H.assert_true(f.owner.pending()); assert_false(f.owner.invalidate())
			task.finish(true); task.retire(true)
			H.assert_true(task.physical); H.assert_true(task.service)
			H.assert_true(f.owner.pending()); H.assert_eq(task.cancels, 0)
			H.assert_eq(calls, 0, "invalidated unknown acquisition has no current recipient")
			H.assert_nil(value); H.assert_nil(reason)
		end)
	end
	H.it("current invalid invocation construction retains refusal and unknown debt", function()
		for _, result in ipairs({ "throw", "missing", "malformed" }) do
			local f = fixture(); local initial = f.discover(); local calls, value, reason = 0
			local original_invoke = f.ports.invoke
			f.ports.invoke = function(...)
				original_invoke(...)
				if result == "throw" then error("private constructor failure") end
				if result == "malformed" then return {} end
				return nil
			end
			H.assert_true(f.owner.invoke(initial.choices[1].key, "keyboard", function() return true end,
				function(result_value, why) calls, value, reason = calls + 1, result_value, why end))
			f.reply(f.tasks[2], { f.rows[1] }); f.tasks[2].retire()
			H.assert_true(f.tasks[2].physical); H.assert_eq(#f.invocations, 1); H.assert_eq(f.invocations[1].starts, 0)
			H.assert_eq(calls, 1); assert_false(value); H.assert_eq(reason, "transport_refused")
			H.assert_true(f.owner.pending()); f.invocations[1].finish(true); f.invocations[1].retire(true)
			H.assert_true(f.owner.pending()); H.assert_eq(calls, 1); assert_false(f.owner.invalidate())
		end
	end)
end)
