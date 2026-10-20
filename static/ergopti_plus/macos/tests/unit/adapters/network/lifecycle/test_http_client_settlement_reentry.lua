--- tests/unit/adapters/network/lifecycle/test_http_client_settlement_reentry.lua

--- ==============================================================================
--- MODULE: HTTP Admission After Reentrant Settlement
--- DESCRIPTION:
--- Uses the real HTTP client and scheduler with independently running native
--- timer controls. A settlement continuation can publish a newer request while
--- an older admission is still cancelling or acquiring its timeout capability.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Owns native boundary doubles while preserving both real lifecycle adapters.
--- @param scenario function Receives client, scheduler and independent observations.
local function with_client(scenario)
	helpers.with_stub_scope({ "adapters.http_client", "adapters.timer_scheduler", "infra.logger" }, function()
		local h = { timers = {}, requests = {}, refused = {}, errors = {} }
		local function native_request(url, callback)
			h.requests[#h.requests + 1] = { url = url, callback = callback }
			-- The pinned native HTTP entry returns no cancellation handle.
		end
		_G.hs = {
			http = {
				asyncPost = function(url, _, _, callback) native_request(url, callback) end,
				asyncGet = function(url, _, callback) native_request(url, callback) end,
				doAsyncRequest = function(url, _, _, _, callback) native_request(url, callback) end,
			},
			timer = { new = function(_, callback)
				local timer = { active = false, callback = callback }
				function timer:start() self.active = true; return self end
				function timer:stop()
					if h.refused[self] then return false end
					self.active = false; return self
				end
				function timer:running() return self.active end
				h.timers[#h.timers + 1] = timer
				if h.refuse_new_index == #h.timers then h.refused[timer] = true end
				return timer
			end },
		}
		package.loaded["infra.logger"] = setmetatable({ error = function(_, message)
			h.errors[#h.errors + 1] = message
		end }, { __index = function() return function() end end })
		local scheduler = require("adapters.timer_scheduler")
		local client = require("adapters.http_client").new()
		function h.post(id, callback)
			return client.post("https://fixture.test/" .. id, {}, id, callback or function() end)
		end
		function h.complete(index) h.requests[index].callback(200, "response-" .. index, {}) end
		function h.running()
			local count = 0
			for _, timer in ipairs(h.timers) do if timer:running() then count = count + 1 end end
			return count
		end
		scenario(client, scheduler, h)
	end)
end

--- Requires agreement between the client's receipt and actual timer ownership.
--- @param client table Real HTTP client.
--- @param scheduler table Real scheduler.
--- @param h table Independent native observations.
local function settled(client, scheduler, h)
	helpers.assert_true(client.isSettled())
	helpers.assert_eq(scheduler.activeCount(), 0)
	helpers.assert_eq(h.running(), 0)
end

helpers.describe("HTTP admission respects reentrant settlement authority", function()
	helpers.it("preserves ordinary supersession and complete timeout retirement", function()
		with_client(function(client, scheduler, h)
			local old, current = 0, 0
			assert(h.post("A", function() old = old + 1 end))
			assert(h.post("C", function() current = current + 1 end))
			helpers.assert_eq(#h.requests, 2)
			h.complete(1); helpers.assert_eq(old, 0)
			h.complete(2); helpers.assert_eq(current, 1)
			settled(client, scheduler, h)
		end)
	end)

	helpers.it("permits a settlement observer to publish B after an explicit cancel", function()
		with_client(function(client, scheduler, h)
			local completed = 0
			assert(h.post("A"))
			assert(client.onSettled(function() assert(h.post("B", function() completed = completed + 1 end)) end))
			assert(client.cancel())
			helpers.assert_true(client.isActive())
			helpers.assert_eq(#h.requests, 2)
			h.complete(2); helpers.assert_eq(completed, 1)
			settled(client, scheduler, h)
		end)
	end)

	for _, method in ipairs({ "post", "get", "credentialed" }) do
		helpers.it("does not dispatch superseded outer " .. method .. " after observer B", function()
			with_client(function(client, scheduler, h)
				local a, b, c = 0, 0, 0
				assert(h.post("A", function() a = a + 1 end))
				assert(client.onSettled(function() assert(h.post("B", function() b = b + 1 end)) end))
				local callback = function() c = c + 1 end
				local accepted
				if method == "get" then accepted = client.get("https://fixture.test/C", {}, callback)
				else accepted = client.post("https://fixture.test/C",
					method == "credentialed" and { Authorization = "owned-fixture" } or {}, "C", callback) end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(#h.requests, 2, "only A and the newer observer B may reach native HTTP")
				helpers.assert_eq(h.requests[2].url, "https://fixture.test/B")
				helpers.assert_eq(scheduler.activeCount(), 1)
				h.complete(1); helpers.assert_eq(a, 0)
				h.complete(2); helpers.assert_eq(b, 1); helpers.assert_eq(c, 0)
				settled(client, scheduler, h)
			end)
		end)
	end

	helpers.it("honors cancellation issued by the settlement observer before outer dispatch", function()
		with_client(function(client, scheduler, h)
			assert(h.post("A"))
			assert(client.onSettled(function() assert(client.cancel()) end))
			helpers.assert_eq(h.post("C"), false)
			helpers.assert_eq(#h.requests, 1)
			settled(client, scheduler, h)
		end)
	end)

	helpers.it("retains B's exact timeout cleanup debt without authorizing an orphan C", function()
		with_client(function(client, scheduler, h)
			assert(h.post("A"))
			assert(client.onSettled(function() assert(h.post("B")) end))
			helpers.assert_eq(h.post("C"), false)
			local b_timer = h.timers[2]
			h.refused[b_timer] = true
			helpers.assert_eq(client.cancel(), false)
			helpers.assert_eq(client.isSettled(), false)
			helpers.assert_eq(h.post("D"), false)
			helpers.assert_eq(#h.requests, 2)
			helpers.assert_eq(h.running(), 1)
			h.refused[b_timer] = nil
			assert(client.cancel())
			settled(client, scheduler, h)
		end)
	end)

	helpers.it("retires only its uncommitted timeout when global cleanup publishes B during acquisition", function()
		with_client(function(client, scheduler, h)
			local unrelated, committed = scheduler.after(100, function() end)
			assert(committed)
			h.refused[unrelated.timer] = true
			helpers.assert_eq(scheduler.cancel(unrelated), false)
			assert(scheduler.onSettled(unrelated, function() assert(h.post("B")) end))
			h.refused[unrelated.timer] = nil
			helpers.assert_eq(h.post("C"), false)
			helpers.assert_eq(#h.requests, 1)
			helpers.assert_eq(h.requests[1].url, "https://fixture.test/B")
			helpers.assert_eq(scheduler.activeCount(), 1)
			h.complete(1)
			settled(client, scheduler, h)
		end)
	end)

	helpers.it("keeps unpublished C rollback debt observable until its exact native timer settles", function()
		with_client(function(client, scheduler, h)
			local unrelated, committed = scheduler.after(100, function() end)
			assert(committed)
			h.refused[unrelated.timer] = true
			helpers.assert_eq(scheduler.cancel(unrelated), false)
			assert(scheduler.onSettled(unrelated, function() assert(h.post("B")) end))
			h.refused[unrelated.timer] = nil
			h.refuse_new_index = 3
			helpers.assert_eq(h.post("C"), false)
			helpers.assert_eq(#h.requests, 1)
			helpers.assert_eq(scheduler.activeCount(), 2)
			h.complete(1)
			helpers.assert_eq(client.isSettled(), false)
			helpers.assert_eq(h.post("D"), false)
			helpers.assert_eq(#h.requests, 1, "unpublished cleanup debt must still block a new native dispatch")
			helpers.assert_eq(h.running(), 1)
			h.refused[h.timers[3]] = nil
			h.timers[3].callback()
			settled(client, scheduler, h)
		end)
	end)
end)
