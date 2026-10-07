--- tests/unit/modules/gestures/test_native_app_switcher_owner.lua

--- Controlled native ports qualify software custody, not Dock or physical input.
local helpers = require("tests.helpers")
local NativeOwner = require("native_app_switcher_owner")
local eq = helpers.assert_eq

local function fixture(configure)
	local f = {
		time = 10, front = 100, source = true, ready = true, provider = true,
		post_ack = true, observe = true, release = true, input_ack = true,
		timer_ack = true, committed = true, posts = {}, cancelled = 0,
		retired = 0, timer_cancelled = 0, completed = {}, handle = {},
	}
	local ports = {
		ready = function() if f.ready_hook then f.ready_hook() end; return f.ready end,
		provider_current = function() if f.provider_hook then f.provider_hook() end; return f.provider end,
		prepare = function(cap, observed, admission)
			f.cap, f.observed, f.admission = cap, observed, admission
			f.input_live = true
			if f.prepare_hook then f.prepare_hook() end
			return f.prepare_ack ~= false
		end,
		post = function(cap, ordinal)
			eq(rawequal(cap, f.cap), true)
			f.posts[#f.posts + 1] = ordinal
			if f.post_hook then f.post_hook(cap, ordinal) end
			if f.observe then f.observed(cap, ordinal) end
			return f.post_ack
		end,
		observed = function(cap, ordinal)
			eq(rawequal(cap, f.cap), true)
			if f.observation_hook then f.observation_hook(ordinal) end
			return f.observation_ack ~= false
		end,
		released = function() return f.release end,
		cancel_input = function()
			f.cancelled = f.cancelled + 1
			if f.cancel_hook then f.cancel_hook() end
			return true
		end,
		retire_input = function()
			f.retired = f.retired + 1
			if f.retire_hook then f.retire_hook() end
			if f.input_ack == true then f.input_live = false end
			return f.input_ack
		end,
		every = function(interval, callback)
			eq(interval, 0.05)
			f.timer_callback = callback
			if f.timer_hook then f.timer_hook() end
			return f.handle, f.committed
		end,
		cancel_timer = function(handle)
			eq(rawequal(handle, f.handle), true)
			f.timer_cancelled = f.timer_cancelled + 1
			if f.timer_cancel_hook then f.timer_cancel_hook() end
			return f.timer_ack
		end,
		now = function() return f.time end,
		frontmost = function() return f.front end,
	}
	f.ports = ports
	f.publication = {
		current = function() if f.current_hook then f.current_hook() end; return f.source end,
		cached = function() return f.source end,
	}
	if configure then configure(f, ports) end
	f.owner = NativeOwner.new(ports, { deadline_sec = 2, poll_sec = 0.05 })
	f.complete = function(cap, status)
		eq(f.input_live ~= true, true)
		f.completed[#f.completed + 1] = { cap = cap, status = status }
		if f.complete_hook then f.complete_hook() end
	end
	function f:start() return self.owner.request(self.publication, self.complete) end
	function f:advance()
		for _ = 1, 4 do self.owner.tick() end
		self.front = 101
		return self.owner.tick()
	end
	return f
end

helpers.describe("native app switcher custody", function()
	helpers.it("requires explicit finite timing and all literal native ports", function()
		local f = fixture()
		eq(NativeOwner.new(f.ports, nil), nil)
		for _, value in ipairs({ 0, -1, math.huge, 0 / 0 }) do
			eq(NativeOwner.new(f.ports, { deadline_sec = value, poll_sec = 0.05 }), nil)
		end
		eq(NativeOwner.new(f.ports, { deadline_sec = 1, poll_sec = 2 }), nil)
		f.ports.observed = nil
		eq(NativeOwner.new(f.ports, { deadline_sec = 1, poll_sec = 0.05 }), nil)
	end)

	helpers.it("posts four acknowledged edges and publishes only after both retirements", function()
		local f = fixture()
		local cap, admitted = f:start()
		eq(admitted, true); eq(#f.posts, 0); eq(f.owner.status(cap), nil)
		eq(f:advance(), true)
		eq(table.concat(f.posts, ","), "1,2,3,4")
		eq(f.owner.status(cap), "switched"); eq(#f.completed, 1)
		eq(f.timer_cancelled, 1); eq(f.owner.has_pending(), false)
		eq(f.owner.tick(), false); eq(f.owner.retry(cap), false)
	end)

	helpers.it("post admission and changed PID cannot substitute for tagged observation", function()
		local f = fixture(function(x) x.observe = false end)
		local cap = f:start()
		f.front = 101
		for _ = 1, 8 do f.owner.tick() end
		eq(#f.posts, 1); eq(f.owner.status(cap), nil); eq(#f.completed, 0)
		f.time = 12
		f.owner.tick()
		eq(f.owner.status(cap), "timeout"); eq(#f.completed, 1)
	end)

	helpers.it("requires combined-session and HID release before the visible effect", function()
		local f = fixture(function(x) x.release = false end)
		local cap = f:start()
		eq(f:advance(), false); eq(f.owner.status(cap), nil)
		f.release = true
		eq(f.owner.tick(), true); eq(f.owner.status(cap), "switched")
	end)

	helpers.it("rejects foreign event capabilities without equality callbacks", function()
		local f = fixture(function(x) x.observe = false end)
		local cap = f:start()
		f.owner.tick()
		local equality = 0
		local mt = { __eq = function() equality = equality + 1; return true end }
		setmetatable(cap, mt)
		local foreign = setmetatable({}, mt)
		eq(f.observed(foreign, 1), false)
		eq(f.owner.cancel(foreign), false); eq(f.owner.retry(foreign), false)
		eq(equality, 0); eq(f.owner.has_pending(), true)
		f.owner.cancel(cap)
	end)

	helpers.it("does not emit from a prepare callback or an early timer callback", function()
		local f = fixture(function(x)
			x.prepare_hook = function()
				eq(x.owner.request(x.publication), nil)
				eq(x.observed(x.cap, 1), false)
				eq(x.owner.tick(), false)
			end
			x.timer_hook = function() eq(x.timer_callback(), false) end
		end)
		local cap, admitted = f:start()
		eq(admitted, true); eq(#f.posts, 0)
		f.owner.cancel(cap)
	end)

	helpers.it("retains exact input debt on refusal and retries before admitting a successor", function()
		local f = fixture(function(x) x.input_ack = false end)
		local cap = f:start()
		eq(f.owner.cancel(cap), false)
		eq(f.owner.has_pending(), true); eq(f.owner.status(cap), nil)
		eq(f.owner.request(f.publication), nil); eq(f.timer_cancelled, 0)
		f.input_ack = true
		eq(f.owner.retry(cap), true); eq(f.owner.status(cap), "cancelled")
		eq(#f.completed, 1)
		local next_cap, admitted = f:start()
		eq(admitted, true); eq(rawequal(next_cap, cap), false)
		f.owner.cancel(next_cap)
	end)

	helpers.it("retains exact timer debt after input retirement without repeating native cleanup", function()
		local f = fixture(function(x) x.timer_ack = false end)
		local cap = f:start()
		eq(f.owner.cancel(cap), false); eq(f.retired, 1)
		eq(f.owner.status(cap), nil); eq(f.owner.has_pending(), true)
		f.timer_ack = true
		eq(f.owner.retry(cap), true); eq(f.retired, 1); eq(f.timer_cancelled, 2)
	end)

	helpers.it("cancellation during prepare compensates the published attempt without starting a timer", function()
		local f = fixture(function(x) x.prepare_hook = function() eq(x.owner.stop(), false) end end)
		local cap, admitted = f:start()
		eq(admitted, false); eq(#f.posts, 0); eq(f.timer_callback, nil)
		eq(f.owner.status(cap), "cancelled"); eq(f.cancelled, 1)
	end)

	helpers.it("contains recursive input cancellation and delivers completion once", function()
		local f = fixture(function(x) x.cancel_hook = function() eq(x.owner.stop(), true) end end)
		local cap = f:start()
		eq(f.owner.cancel(cap), false)
		eq(f.cancelled, 1); eq(#f.completed, 1)
		eq(f.owner.status(cap), "cancelled")
	end)

	helpers.it("retains a thrown prepare's exact native attempt and never logs its exception", function()
		local f = fixture(function(x)
			x.input_ack = false
			x.prepare_hook = function() error("PRIVATE_APPLICATION_NAME") end
		end)
		local cap, admitted = f:start()
		eq(admitted, false); eq(f.owner.has_pending(), true); eq(f.owner.status(cap), nil)
		f.input_ack = true
		eq(f.owner.retry(cap), true); eq(f.owner.status(cap), "refused")
	end)

	helpers.it("retains a live uncommitted timer returned by the actual scheduler contract", function()
		local f = fixture(function(x) x.committed = false; x.timer_ack = false end)
		local cap, admitted = f:start()
		eq(admitted, false); eq(f.owner.has_pending(), true); eq(f.input_live, false)
		f.timer_ack = true
		eq(f.owner.retry(cap), true); eq(f.owner.status(cap), "refused")
	end)

	helpers.it("never turns a throwing timer constructor into an absent-handle retirement receipt", function()
		local f = fixture(function(_, ports) ports.every = function() error("PRIVATE_TIMER_PAYLOAD") end end)
		local cap, admitted = f:start()
		eq(admitted, false); eq(f.owner.has_pending(), true)
		eq(f.owner.retry(cap), false); eq(f.owner.status(cap), nil); eq(f.timer_cancelled, 0)
	end)

	helpers.it("refuses a source revoked by the native provider's last callback", function()
		local f = fixture(function(x) x.provider_hook = function() x.source = false end end)
		local cap, admitted = f:start()
		eq(admitted, false); eq(#f.posts, 0); eq(f.input_live, nil)
		eq(f.owner.status(cap), "refused")
	end)

	helpers.it("source revocation from observed callback prevents the next edge", function()
		local f = fixture(function(x) x.observation_hook = function() x.source = false end end)
		local cap = f:start()
		f.owner.tick(); f.owner.tick()
		eq(table.concat(f.posts, ","), "1"); eq(f.owner.status(cap), "refused")
	end)

	helpers.it("uses captured cleanup functions after a foreign provider replacement", function()
		local f = fixture()
		local cap = f:start()
		local foreign = 0
		f.ports.retire_input = function() foreign = foreign + 1; return true end
		f.owner.tick()
		eq(foreign, 0); eq(f.retired, 1); eq(f.owner.status(cap), "refused")
	end)

	helpers.it("refuses backward and malformed clocks without emitting a native edge", function()
		for _, value in ipairs({ 9, math.huge, 0 / 0 }) do
			local f = fixture()
			local cap = f:start()
			f.time = value
			f.owner.tick()
			eq(#f.posts, 0); eq(f.owner.status(cap), "refused")
		end
	end)

	helpers.it("readiness callbacks cannot reenter and acquire an untracked operation", function()
		local f = fixture(function(x) x.ready_hook = function() eq(x.owner.request(x.publication), nil) end end)
		eq(f.owner.available(), true); eq(f.input_live, nil); eq(#f.posts, 0)
	end)

	helpers.it("completion may start a successor only after exact physical retirement", function()
		local f = fixture()
		local next_cap
		f.complete_hook = function()
			eq(f.owner.has_pending(), false)
			next_cap = f.owner.request(f.publication)
		end
		local cap = f:start()
		eq(f:advance(), true); eq(f.owner.status(cap), "switched")
		eq(f.owner.has_pending(), true); eq(rawequal(next_cap, cap), false)
		f.complete_hook = nil
		f.owner.cancel(next_cap)
	end)
	helpers.it("refuses truthy readiness and edge receipts instead of native boolean admission", function()
		for _, value in ipairs({ 1, "ready", {} }) do
			local f = fixture(function(x) x.ready = value end)
			local cap, admitted = f:start()
			eq(admitted, false); eq(f.owner.status(cap), "refused"); eq(#f.posts, 0)
			local edge = fixture(function(x) x.post_ack = value end)
			local edge_cap = edge:start()
			edge.owner.tick()
			eq(edge.owner.status(edge_cap), "refused")
			eq(table.concat(edge.posts, ","), "1")
		end
	end)

	helpers.it("retains truthy retirement receipts and does not publish them as native ACK", function()
		for _, value in ipairs({ 1, "retired", {} }) do
			local f = fixture(function(x) x.input_ack = value end)
			local cap = f:start()
			eq(f.owner.cancel(cap), false); eq(f.owner.has_pending(), true)
			eq(f.owner.status(cap), nil); eq(#f.completed, 0)
			f.input_ack = true
			eq(f.owner.retry(cap), true); eq(f.owner.status(cap), "cancelled")
		end
	end)
end)

helpers.describe("native switcher terminal publication source", function()
	for _, boundary in ipairs({ "input", "timer" }) do
		helpers.it("refuses success after source revocation by cleanup: " .. boundary, function()
			local f = fixture(function(x)
				if boundary == "input" then x.retire_hook = function() x.source = false end
				else x.timer_cancel_hook = function() x.source = false end end
			end)
			local cap = f:start()
			eq(f:advance(), true)
			eq(f.owner.status(cap), "refused"); eq(f.owner.has_pending(), false)
			eq(#f.completed, 1); eq(f.completed[1].status, "refused")
			eq(f.retired, 1); eq(f.timer_cancelled, 1)
		end)
	end

	helpers.it("retains false cleanup ACK debt before checking the final source seal", function()
		local f = fixture(function(x)
			x.input_ack = false
			x.retire_hook = function() x.source = false end
		end)
		local cap = f:start()
		eq(f:advance(), false); eq(f.owner.status(cap), nil)
		eq(f.owner.has_pending(), true); eq(f.timer_cancelled, 0)
		eq(f.owner.request(f.publication), nil); eq(#f.completed, 0)
		f.input_ack = true
		eq(f.owner.retry(cap), true); eq(f.owner.status(cap), "refused")
		eq(f.timer_cancelled, 1); eq(#f.completed, 1)
	end)

	helpers.it("retains exact timer ACK debt after cleanup revoked the source", function()
		local f = fixture(function(x)
			x.timer_ack = false
			x.timer_cancel_hook = function() x.source = false end
		end)
		local cap = f:start()
		eq(f:advance(), false); eq(f.owner.status(cap), nil)
		eq(f.owner.has_pending(), true); eq(f.retired, 1); eq(#f.completed, 0)
		f.timer_ack = true
		eq(f.owner.retry(cap), true); eq(f.owner.status(cap), "refused")
		eq(f.retired, 1); eq(#f.completed, 1)
	end)

	helpers.it("holds the publication reservation through final current callback cancellation", function()
		local f = fixture()
		local cap = f:start()
		for _ = 1, 4 do f.owner.tick() end
		f.current_hook = function()
			if f.timer_cancelled > 0 then
				eq(f.owner.request(f.publication), nil)
				eq(f.owner.cancel(cap), false)
			end
		end
		f.front = 101
		eq(f.owner.tick(), true); eq(f.owner.status(cap), "cancelled")
		eq(#f.completed, 1); eq(f.completed[1].status, "cancelled")
		eq(f.owner.has_pending(), false); eq(f.retired, 1); eq(f.timer_cancelled, 1)
	end)

	helpers.it("seals source currency after the final native provider callback", function()
		local f = fixture()
		local cap = f:start()
		f.provider_hook = function() if f.timer_cancelled > 0 then f.source = false end end
		eq(f:advance(), true); eq(f.owner.status(cap), "refused")
		eq(#f.completed, 1); eq(f.completed[1].status, "refused")
	end)
end)

return helpers
