--- _shared/lua/test/user_hotstrings_contract.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Execution Contract
--- DESCRIPTION:
--- Independent behavioral cases replay metadata admission and revocable native
--- operations without deriving expectations from production matching results.
--- ==============================================================================

local M = {}

local function fixture(Policy)
	local f = { source = "source-A", destination = "window-A", input = 1, calls = 0, outputs = {}, reports = {}, tasks = {} }
	local rule = { id = "clock", suffix = "@clock", preview = "Clock", callback = function() f.calls = f.calls + 1; return "12:34" end }
	f.rules = { rule }
	f.ports = {
		capture = function() return { destination = f.destination, input = f.input } end,
		current = function(capture, source)
			f.probes = (f.probes or 0) + 1
			return capture.destination == f.destination and capture.input == f.input and source.content == f.source
		end,
		invoke = function(selected, context, done)
			local task = { cancelled = false }
			function task.start() f.tasks[#f.tasks + 1] = task; return true end
			function task.cancel() task.cancelled = true; return f.cancel_refused ~= true end
			function task.fire()
				if task.cancelled then return false end
				if context.cancelled() then return done(false) end
				local ok, result = pcall(selected.callback, context)
				return done(ok and result or nil, not ok and result or nil)
			end
			return task
		end,
		commit = function(result) f.outputs[#f.outputs + 1] = result; return f.output_refused ~= true end,
		report = function(kind, id) f.reports[#f.reports + 1] = { kind, id }; return true end,
		retire = function() f.retire_calls = (f.retire_calls or 0) + 1; return f.retire_refused ~= true end,
	}
	f.owner = Policy.new(f.ports)
	assert(f.owner.reload(f.rules, { path = "/owned/user.lua", present = true, content = f.source }))
	assert(f.owner.set_enabled(true))
	return f
end

local function queued_publication(f)
	local pending = { settled = false, cancel_ack = true, cancel_settles = true, subscribe_ack = true, cancel_calls = 0 }
	function pending.finish(status)
		pending.settled = true
		if pending.subscriber then return pending.subscriber(status) end
		return true
	end
	pending.receipt = {
		cancel = function()
			pending.cancel_calls = pending.cancel_calls + 1
			if pending.cancel_ack ~= true then return false end
			if pending.cancel_settles then pending.finish("cancelled") end
			return true
		end,
		is_settled = function() return pending.settled end,
		on_settled = function(callback)
			if not pending.subscribe_ack then return false end
			pending.subscriber = callback
			if pending.settled then callback("complete") end
			return true
		end,
	}
	f.ports.commit = function(result, _, _, publication)
		pending.result, pending.publication = result, publication
		if pending.inline then
			f.outputs[#f.outputs + 1] = result
			pending.settled = true
		end
		return pending.commit_ack ~= false, pending.receipt
	end
	f.ports.publication_current = f.ports.current
	f.ports.publication_cached = function(capture)
		return capture.destination == f.destination and capture.input == f.input
	end
	function pending.deliver()
		if not pending.publication.current() or not pending.publication.cached() then
			pending.finish("cancelled")
			return false
		end
		f.outputs[#f.outputs + 1] = pending.result
		pending.finish("complete")
		return true
	end
	return pending
end

--- Registers literal execution and lifecycle requirements on either Lua driver.
--- @param helpers table Native behavioral test registration owner.
--- @param Policy table Shared production owner.
function M.run(helpers, Policy)
	helpers.describe("programmable dynamic hotstring contract", function()
		helpers.it("(user-hotstrings) metadata never invokes callbacks or native probes", function()
			local f = fixture(Policy)
			helpers.assert_eq(f.owner.preview("prefix @clock"), { id = "clock", suffix = "@clock", preview = "Clock" })
			helpers.assert_eq(f.owner.preview("@CLOCK"), nil)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.probes, nil)
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.probes, nil)
			helpers.assert_true(f.tasks[1].fire())
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, { "12:34" })
		end)

		for _, field in ipairs({ "source", "destination", "input" }) do
			helpers.it("(user-hotstrings) refuses changed " .. field .. " before callback", function()
				local f = fixture(Policy)
				helpers.assert_true(f.owner.request("@clock"))
				f[field] = field == "input" and 2 or "foreign"
				helpers.assert_eq(f.tasks[1].fire(), false)
				helpers.assert_eq(f.calls, 0)
				helpers.assert_eq(f.outputs, {})
			end)
			helpers.it("(user-hotstrings) refuses changed " .. field .. " after user callback", function()
				local f = fixture(Policy)
				f.rules[1].callback = function() f[field] = field == "input" and 2 or "foreign"; return "unsafe" end
				helpers.assert_true(f.owner.reload(f.rules, { path = "/owned/user.lua", present = true, content = f.source }))
				helpers.assert_true(f.owner.request("@clock"))
				helpers.assert_eq(f.tasks[1].fire(), false)
				helpers.assert_eq(f.outputs, {})
			end)
		end

		for _, method in ipairs({ "invalidate", "stop", "set_enabled", "reload" }) do
			helpers.it("(user-hotstrings) lifecycle " .. method .. " retires retained callbacks", function()
				local f = fixture(Policy)
				helpers.assert_true(f.owner.request("@clock"))
				if method == "set_enabled" then helpers.assert_true(f.owner.set_enabled(false))
				elseif method == "reload" then helpers.assert_true(f.owner.reload({}, { path = "/owned/user.lua", present = true, content = "" }))
				elseif method == "invalidate" then helpers.assert_true(f.owner.invalidate("input"))
				else helpers.assert_true(f.owner.stop()) end
				helpers.assert_true(f.tasks[1].cancelled)
				helpers.assert_eq(f.tasks[1].fire(), false)
				helpers.assert_eq(f.calls, 0)
				helpers.assert_eq(f.outputs, {})
			end)
		end

		helpers.it("(user-hotstrings) absent source refuses publication and quarantines retained metadata", function()
			local f = fixture(Policy)
			helpers.assert_eq(f.owner.admitted_count(), 1)
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_eq(f.owner.reload({}, { path = "/owned/user.lua", present = false, content = "" }), false)
			local snapshot = f.owner.scope_snapshot()
			helpers.assert_eq(snapshot.ready, false)
			helpers.assert_eq(snapshot.enabled, false)
			helpers.assert_eq(f.owner.count(), 1)
			helpers.assert_eq(f.owner.admitted_count(), 0)
			helpers.assert_true(snapshot.rules[1].callback == f.rules[1].callback)
			helpers.assert_eq(snapshot.source, { path = "/owned/user.lua", present = true, content = "source-A" })
			helpers.assert_eq(snapshot.quiescent, true)
			helpers.assert_true(f.tasks[1].cancelled)
			helpers.assert_eq(f.owner.request("@clock"), false)
			helpers.assert_eq(f.owner.preview("@clock"), nil)
			helpers.assert_eq(f.calls, 0)
			helpers.assert_eq(f.reports, { { "source-absent", "load" } })
		end)

		helpers.it("(user-hotstrings) source quarantine retains cancellation debt and exact closures through retry", function()
			local f = fixture(Policy)
			helpers.assert_true(f.owner.request("@clock"))
			f.cancel_refused = true
			helpers.assert_eq(f.owner.refuse_source(), false)
			local snapshot = f.owner.scope_snapshot()
			helpers.assert_eq(snapshot.ready, false)
			helpers.assert_eq(snapshot.enabled, false)
			helpers.assert_eq(snapshot.quiescent, false)
			helpers.assert_true(snapshot.rules[1].callback == f.rules[1].callback)
			helpers.assert_eq(f.owner.request("@clock"), false)
			f.cancel_refused = false
			helpers.assert_true(f.owner.refuse_source())
			snapshot = f.owner.scope_snapshot()
			helpers.assert_eq(snapshot.ready, false)
			helpers.assert_eq(snapshot.enabled, false)
			helpers.assert_eq(snapshot.quiescent, true)
			helpers.assert_true(snapshot.rules[1].callback == f.rules[1].callback)
			helpers.assert_eq(snapshot.source, { path = "/owned/user.lua", present = true, content = "source-A" })
			helpers.assert_eq(f.calls, 0)
		end)

		helpers.it("(user-hotstrings) present valid empty factory is an admitted publication", function()
			local f = fixture(Policy)
			helpers.assert_true(f.owner.reload({}, { path = "/owned/user.lua", present = true, content = "independent empty factory" }))
			local snapshot = f.owner.scope_snapshot()
			helpers.assert_eq(snapshot.ready, true)
			helpers.assert_eq(snapshot.enabled, true)
			helpers.assert_eq(snapshot.source, { path = "/owned/user.lua", present = true, content = "independent empty factory" })
			helpers.assert_eq(f.owner.count(), 0)
			helpers.assert_eq(f.owner.admitted_count(), 0)
			helpers.assert_eq(f.owner.request("@clock"), false)
			helpers.assert_eq(f.calls, 0)
		end)

		for _, result in ipairs({ true, false, "0", "é\nline" }) do
			helpers.it("(user-hotstrings) forwards exact result " .. tostring(result), function()
				local f = fixture(Policy)
				f.rules[1].callback = function() return result end
				helpers.assert_true(f.owner.reload(f.rules, { path = "/owned/user.lua", present = true, content = f.source }))
				helpers.assert_true(f.owner.request("@clock"))
				helpers.assert_true(f.tasks[1].fire())
				helpers.assert_eq(f.outputs[1], result)
			end)
		end

		helpers.it("(user-hotstrings) cancellation debt refuses reopening and supports exact retry", function()
			local f = fixture(Policy)
			helpers.assert_true(f.owner.request("@clock"))
			f.cancel_refused = true
			helpers.assert_eq(f.owner.set_enabled(false), false)
			helpers.assert_eq(f.owner.set_enabled(true), false)
			helpers.assert_eq(f.owner.request("@clock"), false)
			f.cancel_refused = false
			helpers.assert_true(f.owner.set_enabled(true))
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[2].fire())
		end)

		helpers.it("(user-hotstrings) accepted queued publication retains guards and native ownership after callback terminal", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[1].fire())
			helpers.assert_eq(f.calls, 1)
			helpers.assert_eq(f.outputs, {})
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false)
			helpers.assert_true(pending.publication.current(), "callback terminal must not revoke its pending native publication")
			local before = f.probes
			helpers.assert_true(pending.publication.cached())
			helpers.assert_eq(f.probes, before, "raw publication guards must never invoke the source/native full probe")
			helpers.assert_true(pending.deliver())
			helpers.assert_eq(f.outputs, { "12:34" })
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
			helpers.assert_eq(pending.publication.current(), false, "settled native output cannot publish a duplicate")
			helpers.assert_eq(pending.publication.cached(), false)
		end)

		for _, field in ipairs({ "source", "destination", "input" }) do
			helpers.it("(user-hotstrings) queued publication refuses late " .. field .. " after pure callback terminal", function()
				local f = fixture(Policy)
				local pending = queued_publication(f)
				helpers.assert_true(f.owner.request("@clock"))
				helpers.assert_true(f.tasks[1].fire())
				f[field] = field == "input" and 2 or "foreign"
				helpers.assert_eq(pending.deliver(), false)
				helpers.assert_eq(f.calls, 1)
				helpers.assert_eq(f.outputs, {})
				helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
			end)
		end

		for _, method in ipairs({ "set_enabled", "reload", "stop" }) do
			helpers.it("(user-hotstrings) queued publication " .. method .. " cancels the exact native owner after callback terminal", function()
				local f = fixture(Policy)
				local pending = queued_publication(f)
				helpers.assert_true(f.owner.request("@clock"))
				helpers.assert_true(f.tasks[1].fire())
				if method == "set_enabled" then helpers.assert_true(f.owner.set_enabled(false))
				elseif method == "reload" then helpers.assert_true(f.owner.reload({},
					{ path = "/owned/user.lua", present = true, content = "replacement empty factory" }))
				else helpers.assert_true(f.owner.stop()) end
				helpers.assert_true(pending.cancel_calls > 0, "lifecycle must reach the actual pending output receipt")
				helpers.assert_true(pending.settled)
				helpers.assert_eq(pending.publication.current(), false)
				helpers.assert_eq(pending.publication.cached(), false)
				helpers.assert_eq(f.outputs, {})
				helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
			end)
		end

		helpers.it("(user-hotstrings) queued cancel acknowledgement without native settlement retains exact debt", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			pending.cancel_settles = false
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[1].fire())
			helpers.assert_eq(f.owner.set_enabled(false), false)
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false)
			helpers.assert_eq(pending.publication.current(), false)
			helpers.assert_eq(pending.publication.cached(), false)
			helpers.assert_true(pending.finish("cancelled"))
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false, "the retained cancellation debt needs an acknowledged retry")
			local calls = pending.cancel_calls
			helpers.assert_true(f.owner.invalidate("exact native settlement retry"))
			helpers.assert_eq(pending.cancel_calls, calls, "an already retired native owner is never cancelled twice")
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
		end)

		helpers.it("(user-hotstrings) copied completion status cannot settle the original native receipt", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[1].fire())
			local copied_status = { completed = true, status = "complete" }
			helpers.assert_eq(pending.subscriber(copied_status.status), false)
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false)
			helpers.assert_true(pending.publication.current())
			helpers.assert_true(pending.deliver())
			helpers.assert_eq(f.outputs, { "12:34" })
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
		end)

		helpers.it("(user-hotstrings) already completed native receipt can settle inline after ownership adoption", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			pending.inline = true
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[1].fire())
			helpers.assert_eq(f.outputs, { "12:34" })
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
			helpers.assert_eq(pending.cancel_calls, 0)
			helpers.assert_eq(pending.publication.current(), false)
			helpers.assert_eq(pending.publication.cached(), false)
		end)

		helpers.it("(user-hotstrings) publication rechecks its generation after an off-hook probe changes lifecycle", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[1].fire())
			f.ports.publication_current = function()
				helpers.assert_true(f.owner.set_enabled(false))
				return true
			end
			helpers.assert_eq(pending.publication.current(), false)
			helpers.assert_eq(pending.publication.cached(), false)
			helpers.assert_true(pending.settled)
			helpers.assert_eq(f.outputs, {})
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
		end)

		helpers.it("(user-hotstrings) refused settlement subscription preserves native ownership and cancellation debt", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			pending.subscribe_ack, pending.cancel_settles = false, false
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_eq(f.tasks[1].fire(), false)
			helpers.assert_eq(pending.publication.current(), false)
			helpers.assert_eq(pending.publication.cached(), false)
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false)
			pending.settled = true
			helpers.assert_true(f.owner.invalidate("late owned cleanup"))
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
			helpers.assert_eq(f.outputs, {})
		end)

		helpers.it("(user-hotstrings) refused commit retains its exact adopted native cleanup receipt", function()
			local f = fixture(Policy)
			local pending = queued_publication(f)
			pending.commit_ack, pending.cancel_settles = false, false
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_eq(f.tasks[1].fire(), false)
			helpers.assert_true(pending.cancel_calls > 0)
			helpers.assert_eq(pending.publication.current(), false)
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false)
			helpers.assert_true(pending.finish("failed"))
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, false)
			helpers.assert_true(f.owner.invalidate("refused commit native cleanup retry"))
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
			helpers.assert_eq(f.outputs, {})
		end)

		helpers.it("(user-hotstrings) native commit refusal remains visible after its destination probe changes lifecycle", function()
			local f = fixture(Policy)
			f.ports.commit = function()
				helpers.assert_true(f.owner.invalidate("native destination probe"))
				return false
			end
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_eq(f.tasks[1].fire(), false)
			helpers.assert_eq(f.outputs, {})
			helpers.assert_eq(f.reports, { { "output-refused", "clock" } })
			helpers.assert_eq(f.owner.scope_snapshot().quiescent, true)
		end)

		helpers.it("(user-hotstrings) refused input retirement retains debt until exact acknowledgement", function()
			local f = fixture(Policy)
			helpers.assert_true(f.owner.request("@clock"))
			f.source, f.retire_refused = "edited", true
			helpers.assert_eq(f.tasks[1].fire(), false)
			helpers.assert_eq(f.retire_calls, 1)
			helpers.assert_eq(f.owner.preview("@clock"), nil)
			helpers.assert_eq(f.owner.set_enabled(true), false)
			helpers.assert_eq(f.retire_calls, 2)
			f.retire_refused, f.source = false, "source-A"
			helpers.assert_true(f.owner.set_enabled(true))
			helpers.assert_eq(f.retire_calls, 3)
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[2].fire())
			helpers.assert_eq(f.retire_calls, 3, "accepted retirement is never replayed twice")
		end)

		helpers.it("(user-hotstrings) malformed reload closes old metadata without publishing candidate", function()
			local f = fixture(Policy)
			helpers.assert_eq(f.owner.reload({ { id = "bad.id" } }, { path = "/owned/user.lua", present = true, content = "bad" }), false)
			helpers.assert_eq(f.owner.count(), 1)
			helpers.assert_eq(f.owner.request("@clock"), false)
			helpers.assert_eq(f.owner.preview("@clock"), nil)
			helpers.assert_eq(f.reports[1][1], "invalid-rule")
		end)

		helpers.it("(user-hotstrings) callback exception reports without publishing exception content", function()
			local f = fixture(Policy)
			f.rules[1].callback = function() error("private exception content") end
			helpers.assert_true(f.owner.reload(f.rules, { path = "/owned/user.lua", present = true, content = f.source }))
			helpers.assert_true(f.owner.request("@clock"))
			helpers.assert_true(f.tasks[1].fire())
			helpers.assert_eq(f.outputs, { false })
			helpers.assert_eq(f.reports, { { "execution-failed", "clock" } })
		end)
	end)
end

return M
