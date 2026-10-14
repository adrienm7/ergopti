--- tests/unit/modules/keylogger/test_physical_permission_history.lua

--- Independent retained-permission controls; native adapters remain deliberately absent.
local helpers = require("tests.helpers")
local History = require("keylogger.physical_permission_history")

local function fixture(capacity)
	local f = { capture = {}, clock = {}, observers = {}, next_revision = {}, emitted = {}, failures = {}, current = true,
		retirement = {}, retirement_calls = {}, settled = true }
	for _, name in ipairs({ "configuration", "context", "lifecycle", "pause", "capture" }) do
		f.observers[name], f.next_revision[name] = {}, 0
	end
	for _, name in ipairs({ "configuration", "context", "lifecycle", "pause", "capture", "clock" }) do
		local token = {}
		f.retirement[name] = { token = token, settled = function(candidate, owner_token)
			helpers.assert_true(rawequal(candidate, f.capture) and rawequal(owner_token, token))
			f.retirement_calls[#f.retirement_calls + 1] = name
			if f.on_settled then return f.on_settled(name) end
			return f.settled
		end }
	end
	f.owner = History.new(capacity or 64, { retirement = f.retirement, capture = f.capture, clock = f.clock, observers = f.observers,
		current = function(token)
			helpers.assert_true(rawequal(token, f.capture))
			if f.on_current then return f.on_current() end
			return f.current
		end,
		receive = function(record)
			f.emitted[#f.emitted + 1] = record
			if f.on_receive then return f.on_receive(record) end
			return true
		end,
		on_refused = function(reason) f.failures[#f.failures + 1] = reason end,
	})
	f.observe = function(name, at, fields)
		f.next_revision[name] = f.next_revision[name] + 1
		local record = fields or { complete = true, allowed = true }
		record.kind, record.revision, record.at = "physical_" .. name, f.next_revision[name], at
		return f.owner.observe(f.capture, f.clock, name, f.observers[name], record), record
	end
	f.configuration = function(at)
		return f.observe("configuration", at, { private_filter_enabled = true,
			secure_field_filter_enabled = true, system_auth_filter_enabled = true, disabled_apps = {} })
	end
	f.context = function(boundary, completion, allowed)
		local ack = f.observe("context", boundary, { stage = "boundary", source = "activation", complete = false, allowed = false })
		helpers.assert_eq(ack, true)
		return f.observe("context", completion, { stage = "complete", source = "activation", fields_complete = true,
			complete = true, correlated = true, allowed = allowed ~= false, private = false, secure = false,
			app = { name = "Original", bundle_id = "test.editor", path = "/Original.app", pid = 4242 } })
	end
	f.ready = function()
		helpers.assert_eq(f.configuration(10), true)
		helpers.assert_eq(f.context(11, 12), true)
		for index, name in ipairs({ "lifecycle", "pause", "capture" }) do
			helpers.assert_eq(f.observe(name, 12 + index), true)
		end
	end
	return f
end

local function denied(f, first, last)
	helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, first, last or first), { allowed = false })
end

helpers.describe("dormant retained physical permission history", function()
	helpers.it("requires every exact bound source before permission is admitted", function()
		local f = fixture()
		denied(f, 0)
		f.configuration(10); f.context(11, 12)
		f.observe("lifecycle", 13); f.observe("capture", 14)
		denied(f, 14)
		f.observe("pause", 15)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 15, 16).allowed, true)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 15, 16).app.name, "Original")
	end)

	helpers.it("never uses current permission for an earlier delayed event", function()
		local f = fixture(); f.ready()
		denied(f, 14)
		f.observe("pause", 20, { complete = true, allowed = false })
		f.observe("pause", 30, { complete = true, allowed = true })
		denied(f, 25)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 16, 19).allowed, true)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 31, 35).allowed, true)
	end)

	helpers.it("cancels the whole held duration across an excluded middle despite allowed endpoints", function()
		for _, lane in ipairs({ "pause", "lifecycle", "capture" }) do
			local f = fixture(); f.ready()
			f.observe(lane, 20, { complete = true, allowed = false })
			f.observe(lane, 30, { complete = true, allowed = true })
			denied(f, 16, 35); denied(f, 16, 20)
			helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 30, 35).allowed, true)
		end
	end)

	helpers.it("keeps original press attribution across allowed application changes", function()
		local f = fixture(); f.ready()
		f.observe("context", 20, { stage = "boundary", source = "activation", complete = false, allowed = false })
		f.observe("context", 21, { stage = "complete", source = "activation", complete = true, fields_complete = true,
			correlated = true, allowed = true, private = false, secure = false,
			app = { name = "New", bundle_id = "test.new", path = "/New.app", pid = 4243 } })
		denied(f, 16, 25)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 16, 19).app.name, "Original")
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 21, 25).app.name, "New")
	end)

	helpers.it("invalidates cached context after configuration until a fresh linked transaction", function()
		local f = fixture(); f.ready(); f.configuration(20)
		denied(f, 21)
		f.context(22, 23)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 23, 24).allowed, true)
		denied(f, 16, 24)
	end)

	helpers.it("denies context completion crossing an intervening configuration publication", function()
		local f = fixture(); f.ready()
		f.observe("context", 20, { stage = "boundary", source = "activation", complete = false, allowed = false })
		f.configuration(21)
		f.observe("context", 22, { stage = "complete", source = "activation", complete = true, fields_complete = true,
			correlated = true, allowed = true, private = false, secure = false,
			app = { name = "Old-config", bundle_id = "test.editor", path = "/Original.app", pid = 4242 } })
		denied(f, 22)
		f.context(23, 24)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 24).allowed, true)
	end)

	helpers.it("refuses completion without an actual matching source boundary", function()
		for _, source in ipairs({ "activation", "foreign" }) do
			local f = fixture(); f.ready()
			if source == "foreign" then
				f.observe("context", 20, { stage = "boundary", source = "activation", complete = false, allowed = false })
			end
			local result = f.observe("context", 21, { stage = "complete", source = source, complete = true,
				fields_complete = true, correlated = true, allowed = true, private = false, secure = false,
				app = { name = "Forged", bundle_id = "test.editor", path = "/Original.app", pid = 4242 } })
			helpers.assert_eq(result, false); denied(f, 16)
		end
	end)

	helpers.it("keeps incomplete or uncorrelated native context denied", function()
		for _, field in ipairs({ "complete", "fields_complete", "correlated" }) do
			local f = fixture(); f.ready()
			f.observe("context", 20, { stage = "boundary", source = "activation", complete = false, allowed = false })
			local receipt = { stage = "incomplete", source = "activation", complete = true, fields_complete = true,
				correlated = true, allowed = true, private = false, secure = false,
				app = { name = "Unproven", bundle_id = "test.editor", path = "/Original.app", pid = 4242 } }
			receipt[field] = false
			f.observe("context", 21, receipt); denied(f, 21)
		end
	end)

	helpers.it("copies context inputs and emitted receipts before retaining any permission", function()
		local f = fixture(); f.ready()
		f.observe("context", 20, { stage = "boundary", source = "activation", complete = false, allowed = false })
		local _, receipt = f.observe("context", 21, { stage = "complete", source = "activation", complete = true,
			fields_complete = true, correlated = true, allowed = true, private = false, secure = false,
			app = { name = "Copied", bundle_id = "test.copy", path = "/Copied.app", pid = 4242 } })
		receipt.app.name = "Input alias"
		f.emitted[#f.emitted].app.name = "Output alias"
		local selected = f.owner.resolve_interval(f.capture, f.clock, 21)
		helpers.assert_eq(selected.app.name, "Copied")
		selected.app.name = "Query alias"
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 21).app.name, "Copied")
	end)

	helpers.it("never emits or retains excluded application data", function()
		local f = fixture(); f.ready(); f.context(20, 21, false)
		helpers.assert_eq(f.emitted[#f.emitted], { at = 21, allowed = false })
		denied(f, 21)
	end)

	helpers.it("requires exact capture clock and observer identities without equality metamethods", function()
		for _, role in ipairs({ "capture", "clock", "observer" }) do
			local f = fixture(); f.ready()
			local foreign = setmetatable({}, { __eq = function() error("Equality must not execute") end })
			local receipt = { kind = "physical_pause", at = 20, revision = 2, complete = true, allowed = true }
			local accepted = f.owner.observe(role == "capture" and foreign or f.capture,
				role == "clock" and foreign or f.clock, "pause", role == "observer" and foreign or f.observers.pause, receipt)
			helpers.assert_eq(accepted, false); denied(f, 16)
		end
	end)

	helpers.it("retains its own observer identity after a borrowed token catalogue is mutated", function()
		local f = fixture(); f.ready()
		local original = f.observers.pause; f.observers.pause = {}
		local receipt = { kind = "physical_pause", at = 20, revision = 2, complete = true, allowed = true }
		helpers.assert_eq(f.owner.observe(f.capture, f.clock, "pause", original, receipt), true)
		helpers.assert_eq(f.owner.resolve_interval(f.capture, f.clock, 20).allowed, true)
	end)

	helpers.it("revokes capture authority after duplicate stale unordered or skipped receipts", function()
		for _, change in ipairs({ { at = 15 }, { at = 14 }, { revision = 1 }, { revision = 3 }, { at = 20.5 } }) do
			local f = fixture(); f.ready()
			local receipt = { kind = "physical_pause", at = 20, revision = 2, complete = true, allowed = true }
			for key, value in pairs(change) do receipt[key] = value end
			helpers.assert_eq(f.owner.observe(f.capture, f.clock, "pause", f.observers.pause, receipt), false)
			denied(f, 16); helpers.assert_eq(#f.failures, 1)
		end
	end)

	helpers.it("refuses callable or malformed observation records before reading fields", function()
		local f = fixture(); f.ready()
		local receipt = setmetatable({}, { __index = function() error("Must not query foreign fields") end })
		helpers.assert_eq(f.owner.observe(f.capture, f.clock, "pause", f.observers.pause, receipt), false)
		denied(f, 16); helpers.assert_eq(#f.failures, 1)
	end)

	helpers.it("requires literal current capture authority before and after subscriber delivery", function()
		for _, value in ipairs({ false, "true", 1 }) do
			local f = fixture(); f.ready(); f.current = value
			helpers.assert_eq(f.observe("pause", 20), false); denied(f, 16)
		end
		local f = fixture(); f.ready()
		f.on_receive = function() f.current = false; return true end
		helpers.assert_eq(f.observe("pause", 20), false); denied(f, 16)
	end)

	helpers.it("revokes before refused throwing or nonboolean subscriber callbacks", function()
		for _, callback in ipairs({ function() return false end, function() return "true" end, function() error("subscriber") end }) do
			local f = fixture(); f.ready(); f.on_receive = callback
			helpers.assert_eq(f.observe("pause", 20), false); denied(f, 16)
			helpers.assert_eq(#f.failures, 1)
		end
	end)

	helpers.it("fences lookup and publication reentry even when foreign callbacks catch refusal", function()
		for _, operation in ipairs({ "query", "publication", "current" }) do
			local f = fixture(); f.ready()
			local callback = function()
				if operation == "publication" then f.observe("pause", 21)
				else denied(f, 16) end
				return true
			end
			if operation == "current" then f.on_current = callback else f.on_receive = callback end
			helpers.assert_eq(f.observe("pause", 20), false); denied(f, 16)
			helpers.assert_eq(#f.failures, 1)
		end
	end)

	helpers.it("revokes before detach and retains records until exact shutdown acknowledgement", function()
		local f = fixture(); f.ready()
		helpers.assert_eq(f.owner.stop(f.capture), true); denied(f, 16)
		helpers.assert_eq(f.owner.retained_count(), 6)
		helpers.assert_eq(f.owner.retired({}), false)
		helpers.assert_eq(f.owner.retained_count(), 6)
		helpers.assert_eq(f.owner.retired(f.capture), true)
		helpers.assert_eq(f.owner.retained_count(), 0)
		helpers.assert_eq(f.owner.retired(f.capture), false)
	end)

	helpers.it("rejects premature shutdown acknowledgement and successor authority", function()
		local f = fixture(); f.ready()
		helpers.assert_eq(f.owner.retired(f.capture), false)
		helpers.assert_eq(f.owner.retained_count(), 6)
		f.owner.stop(f.capture)
		helpers.assert_eq(f.owner.observe({}, f.clock, "pause", f.observers.pause, {}), false)
		denied(f, 16)
	end)

	helpers.it("cancels all durations on a source gap and cannot resume the same history", function()
		local f = fixture(); f.ready()
		helpers.assert_eq(f.owner.gap(f.capture), true)
		denied(f, 16, 35)
		helpers.assert_eq(f.observe("capture", 40), false)
		denied(f, 16); helpers.assert_eq(f.owner.retained_count(), 6)
	end)

	helpers.it("revokes on bounded exhaustion without eviction or promotion of cached state", function()
		local f = fixture(6); f.ready()
		helpers.assert_eq(f.observe("pause", 20), false)
		denied(f, 16); helpers.assert_eq(f.owner.retained_count(), 6)
		helpers.assert_eq(#f.failures, 1)
		f.observe("pause", 21); helpers.assert_eq(#f.failures, 1)
	end)

	helpers.it("denies unknown early reversed malformed and foreign-clock query intervals", function()
		local f = fixture(); f.ready()
		for _, span in ipairs({ { 9, 16 }, { 20, 10 }, { -1, 20 }, { 15.5, 20 }, { 15, "20" } }) do
			denied(f, span[1], span[2])
		end
		helpers.assert_eq(f.owner.resolve_interval(f.capture, {}, 16), { allowed = false })
		helpers.assert_eq(f.owner.resolve_interval({}, f.clock, 16), { allowed = false })
	end)

	helpers.it("retains history until every bound native retirement owner acknowledges literal true", function()
		for _, value in ipairs({ false, "true", 1 }) do
			local f = fixture(); f.ready(); f.owner.stop(f.capture); f.settled = value
			helpers.assert_eq(f.owner.retired(f.capture), false)
			helpers.assert_eq(f.owner.retained_count(), 6)
			f.settled = true
			helpers.assert_eq(f.owner.retired(f.capture), true)
			helpers.assert_eq(f.owner.retained_count(), 0)
		end
	end)

	helpers.it("checks every native retirement source and retains after any owner refusal", function()
		for _, refused in ipairs({ "configuration", "context", "lifecycle", "pause", "capture", "clock" }) do
			local f = fixture(); f.ready(); f.owner.stop(f.capture)
			f.on_settled = function(name) return name ~= refused end
			helpers.assert_eq(f.owner.retired(f.capture), false)
			helpers.assert_eq(f.owner.retained_count(), 6)
			f.on_settled = function() return true end
			f.retirement_calls = {}
			helpers.assert_eq(f.owner.retired(f.capture), true)
			helpers.assert_eq(f.retirement_calls, { "configuration", "context", "lifecycle", "pause", "capture", "clock" })
		end
	end)

	helpers.it("retains after throwing or reentered retirement callbacks until an owned retry", function()
		for _, reentry in ipairs({ false, true }) do
			local f = fixture(); f.ready(); f.owner.stop(f.capture)
			f.on_settled = function()
				if reentry then helpers.assert_eq(f.owner.retired(f.capture), false); return true end
				error("Native retirement observation refused")
			end
			helpers.assert_eq(f.owner.retired(f.capture), false)
			helpers.assert_eq(f.owner.retained_count(), 6)
			f.on_settled = nil
			helpers.assert_eq(f.owner.retired(f.capture), true)
		end
	end)

	helpers.it("owns retirement tokens and ports independently of mutable borrowed catalogues", function()
		local f = fixture(); f.ready(); f.owner.stop(f.capture)
		for _, name in ipairs({ "configuration", "context", "lifecycle", "pause", "capture", "clock" }) do
			f.retirement[name] = { token = {}, settled = function() error("Foreign replacement must not run") end }
		end
		helpers.assert_eq(f.owner.retired(f.capture), true)
		helpers.assert_eq(#f.retirement_calls, 6)
	end)

	helpers.it("revokes permanently on an exact source detach or terminal refusal", function()
		for _, name in ipairs({ "configuration", "context", "lifecycle", "pause", "capture" }) do
			local f = fixture(); f.ready()
			helpers.assert_eq(f.owner.detach(f.capture, name, f.observers[name]), false)
			denied(f, 16); helpers.assert_eq(f.owner.retained_count(), 6)
			helpers.assert_eq(#f.failures, 1)
			helpers.assert_eq(f.observe(name, 20), false)
			f = fixture(); f.ready()
			helpers.assert_eq(f.owner.refused(f.capture, name, f.observers[name]), false)
			denied(f, 16); helpers.assert_eq(#f.failures, 1)
		end
	end)

	helpers.it("rejects unsafe numeric clock representation on each interpreter", function()
		local f = fixture(); f.ready()
		local receipt = { kind = "physical_pause", revision = 2, at = math.huge, complete = true, allowed = true }
		helpers.assert_eq(f.owner.observe(f.capture, f.clock, "pause", f.observers.pause, receipt), false)
		denied(f, 16)
		if not math.type then
			f = fixture(); f.ready(); receipt.at = 9007199254740992
			helpers.assert_eq(f.owner.observe(f.capture, f.clock, "pause", f.observers.pause, receipt), false)
			denied(f, 16)
		end
	end)


	helpers.it("keeps allocation limits owned when borrowed diagnostic constants are mutated", function()
		local f = fixture(); f.ready()
		local previous = History.MAX_SELECTORS
		History.MAX_SELECTORS = math.huge
		local apps = {}; for index = 1, 257 do apps[index] = { bundleID = "test.app" } end
		local ok, accepted = pcall(f.observe, "configuration", 20, { private_filter_enabled = true,
			secure_field_filter_enabled = true, system_auth_filter_enabled = true, disabled_apps = apps })
		History.MAX_SELECTORS = previous
		helpers.assert_eq(ok, true); helpers.assert_eq(accepted, false)
		denied(f, 16)
		previous = History.MAX_HISTORY; History.MAX_HISTORY = math.huge
		ok = pcall(fixture, 4097)
		History.MAX_HISTORY = previous
		helpers.assert_eq(ok, false)
	end)


	helpers.it("owns the retained interval policy instead of a mutable module alias", function()
		local f = fixture(); f.ready()
		f.observe("pause", 20, { complete = true, allowed = false })
		f.observe("pause", 30, { complete = true, allowed = true })
		local interval = require("keylogger.physical_interval")
		local previous = interval.permits
		interval.permits = function() return true end
		local ok, decision = pcall(f.owner.resolve_interval, f.capture, f.clock, 16, 35)
		interval.permits = previous
		helpers.assert_eq(ok, true); helpers.assert_eq(decision, { allowed = false })
	end)


	helpers.it("never exposes permission to a reentered query even if the callback suppresses all errors", function()
		for _, port in ipairs({ "receive", "current" }) do
			local f = fixture(); f.ready()
			local leaked, queried = nil, false
			local callback = function()
				if queried then return true end
				queried = true
				local ok, decision = pcall(f.owner.resolve_interval, f.capture, f.clock, 16)
				leaked = ok and decision.allowed or false
				return true
			end
			if port == "receive" then f.on_receive = callback else f.on_current = callback end
			local accepted = f.observe("pause", 20)
			helpers.assert_eq(accepted, false); helpers.assert_eq(leaked, false)
			denied(f, 16); helpers.assert_eq(#f.failures, 1)
		end
	end)

end)
