--- tests/unit/infra/test_cancelled_boolean_successor.lua

--- ==============================================================================
--- MODULE: Positive Native Cancellation Successor Admission Controls
--- DESCRIPTION:
--- Independent owner and native ACK ports exercise the actual coordinator.
--- These modeled receipts do not establish real pipe or enterprise behavior.
--- ==============================================================================

local helpers = require("tests.helpers")
local Managed = require("infra.managed_http")
local URL = "http://127.0.0.1:9000/fixed"
local OWNER = "cancelled-boolean-owner"

local function fixture(config)
	config = config or {}
	local state = { now = 0, curls = {}, proxies = {}, timers = {}, reports = {}, metadata = 0, results = {} }
	local function child(stage, options, done)
		local value = { started = not config.prestart, settled = false, listeners = {}, options = options, done = done, cancels = 0 }
		function value:is_settled()
			if self.settlement_hook then local callback = self.settlement_hook; self.settlement_hook = nil; callback() end
			return self.settled
		end
		function value:on_settled(listener)
			if self.settled then listener() else self.listeners[#self.listeners + 1] = listener end
			return true
		end
		function value:request_cancel()
			self.cancels = self.cancels + 1
			if self.cancel_hook then local callback = self.cancel_hook; self.cancel_hook = nil; callback() end
			if config.refused then return false, config.cause end
			return true
		end
		function value.cancel() return value:request_cancel() end
		function value:ack()
			self.settled = true
			local listeners = self.listeners; self.listeners = {}
			for _, listener in ipairs(listeners) do listener() end
		end
		state[stage][#state[stage] + 1] = value
		return value
	end
	local coordinator = assert(Managed.new({
		policy = {
			route = function() return { mode = state.system and "system" or "direct" } end,
			selection = function() return { { kind = "direct" } } end,
			can_retry = function() return false end,
		},
		proxy = { lookup_owned = function(_, options, done) return child("proxies", options, done) end },
		curl = function(_, _, _, options, _, done)
			if config.unknown then error("independent unknown acquisition") end
			local value = child("curls", options, done)
			if config.prestart then options.on_native_terminal({ ok = false, status = 0, body = "", error = "curl body pipe retirement failed" }) end
			return value
		end,
		deadline = function(deadline, expired)
			local timer = { started = true, settled = false, listeners = {}, deadline = deadline, expired = expired }
			function timer:is_settled() return self.settled end
			function timer:on_settled(listener) self.listeners[#self.listeners + 1] = listener; return true end
			function timer:cancel() self.cancel_calls = (self.cancel_calls or 0) + 1; self.close_requested = true; return true end
			function timer:ack()
				self.settled = true
				local listeners = self.listeners; self.listeners = {}
				for _, listener in ipairs(listeners) do listener() end
			end
			state.timers[#state.timers + 1] = timer
			if state.arm_hook then state.arm_hook(#state.timers) end
			return timer
		end,
		clock = function()
			if state.clock_hook then local callback = state.clock_hook; state.clock_hook = nil; callback() end
			return state.now
		end,
		environment = function() return {} end,
		report = function(message) state.reports[#state.reports + 1] = message end,
	}))
	local function options(owned) return { owner = OWNER, timeout_ms = 100, owned_api = owned, method = "GET", buffered = true } end
	function state.start_boolean(override)
		local opts = override or options(false)
		local operation = coordinator.start(URL, {}, nil, opts, nil, function(result) state.results[#state.results + 1] = result end)
		return operation, opts
	end
	function state.start_owned(prepare, timeout_ms)
		local opts = options(true)
		if timeout_ms then opts.timeout_ms = timeout_ms end
		return coordinator.start(URL, {}, nil, opts, nil, function(result) state.results[#state.results + 1] = result end, {
			prepare = function()
				state.metadata = state.metadata + 1
				if prepare then return prepare(opts) end
				return opts, nil, {}
			end,
		})
	end
	function state.refuse_without_metadata()
		local operation = state.start_owned()
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(state.metadata, 0)
		helpers.assert_eq(state.results[#state.results].error, "previous request cleanup pending")
		return operation
	end
	return coordinator, state
end

helpers.describe("private positive cancelled BOOLEAN successor lineage", function()
	helpers.it("accepts one successor and waits both actual child and original timer ACKs", function()
		local coordinator, state = fixture()
		local predecessor = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		local successor = state.start_owned()
		helpers.assert_true(successor.started)
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(state.metadata, 1)
		helpers.assert_eq(state.curls[1].cancels, 1, "a positive native cancel must not be signaled twice")
		state.curls[1]:ack()
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(predecessor:is_settled(), false)
		helpers.assert_eq(successor:is_settled(), false)
		state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.curls, 2)
		helpers.assert_eq(#state.results, 0)
	end)
	helpers.it("retains the original successor total budget while predecessor ACK is withheld", function()
		local coordinator, state = fixture()
		state.start_boolean(); helpers.assert_true(coordinator.cancel(OWNER))
		local successor = state.start_owned()
		helpers.assert_true(successor.started)
		state.now = 101; state.timers[2].expired()
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(#state.results, 0)
		state.timers[2]:ack()
		helpers.assert_eq(successor:is_settled(), false)
		state.curls[1]:ack(); state.timers[1]:ack()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(#state.results, 1)
		helpers.assert_eq(state.results[1].error, "timeout")
	end)
	helpers.it("rejects a positively cancelled owned predecessor before metadata", function()
		local coordinator, state = fixture()
		state.start_owned(); state.metadata = 0
		helpers.assert_true(coordinator.cancel(OWNER))
		state.refuse_without_metadata()
		helpers.assert_eq(#state.curls, 1)
	end)
	helpers.it("does not derive curl permission from a positive GIO cancellation", function()
		local coordinator, state = fixture()
		state.system = true; state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		state.refuse_without_metadata()
		helpers.assert_eq(#state.proxies, 1)
		helpers.assert_eq(#state.curls, 0)
	end)
	helpers.it("refuses unknown native acquisition before successor metadata", function()
		local coordinator, state = fixture({ unknown = true })
		state.start_boolean()
		helpers.assert_eq(coordinator.cancel(OWNER), false)
		state.refuse_without_metadata()
		helpers.assert_eq(#state.curls, 0)
	end)
	helpers.it("failed native signaling cannot create the positive-cancel exception", function()
		local coordinator, state = fixture({ refused = true })
		state.start_boolean()
		helpers.assert_eq(coordinator.cancel(OWNER), false)
		local successor = state.start_owned()
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(state.metadata, 1, "the existing live-incumbent preparation path is preserved")
		helpers.assert_eq(#state.curls, 1)
	end)
	for _, descriptor in ipairs({ false, true }) do
		local fixed = descriptor
		helpers.it("refuses pre-start " .. (fixed and "descriptor" or "handle") .. " debt despite logical cancellation", function()
			local coordinator, state = fixture({ prestart = true, refused = fixed, cause = fixed and "body-descriptor-retirement-pending" or nil })
			state.start_boolean()
			helpers.assert_eq(coordinator.cancel(OWNER), not fixed)
			state.refuse_without_metadata()
			helpers.assert_eq(#state.curls, 1)
		end)
	end
	helpers.it("refuses expired predecessor debt before metadata", function()
		local coordinator, state = fixture()
		state.start_boolean(); state.now = 101; state.timers[1].expired()
		helpers.assert_true(coordinator.cancel(OWNER))
		state.results = {}; state.refuse_without_metadata()
		helpers.assert_eq(#state.curls, 1)
	end)
	helpers.it("refuses a logical terminal predecessor before metadata", function()
		local coordinator, state = fixture()
		state.start_boolean()
		state.curls[1].options.on_native_terminal({ ok = false, status = 404, body = "", error = "HTTP 404" })
		helpers.assert_true(coordinator.cancel(OWNER))
		state.results = {}; state.refuse_without_metadata()
	end)
	helpers.it("refuses a source-bound cancelled predecessor without probing its source", function()
		local coordinator, state = fixture()
		local _, opts = state.start_boolean()
		local source_calls = 0
		opts.authorized = function() source_calls = source_calls + 1; return false end
		helpers.assert_true(coordinator.cancel(OWNER))
		state.refuse_without_metadata()
		helpers.assert_eq(source_calls, 0)
	end)
	helpers.it("an incomplete or changed native started flag cannot reuse its cancellation receipt", function()
		local coordinator, state = fixture()
		state.start_boolean(); helpers.assert_true(coordinator.cancel(OWNER))
		state.curls[1].started = false
		state.refuse_without_metadata()
	end)
	helpers.it("source change during successor preparation invalidates the exact old receipt", function()
		local coordinator, state = fixture()
		local _, old_options = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		local successor = state.start_owned(function(opts)
			old_options.authorized = function() return false end
			return opts, nil, {}
		end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(#state.curls, 1)
		state.curls[1]:ack(); state.timers[1]:ack(); state.timers[2]:ack()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(#state.curls, 1)
	end)
	helpers.it("synchronous cancellation retirement cannot transfer receipt to a new GIO owner", function()
		local coordinator, state = fixture()
		state.start_boolean()
		state.curls[1].cancel_hook = function()
			state.curls[1]:ack(); state.timers[1]:ack()
			state.system = true; state.start_boolean()
		end
		helpers.assert_true(coordinator.cancel(OWNER))
		helpers.assert_eq(#state.proxies, 1)
		helpers.assert_true(coordinator.cancel(OWNER))
		state.refuse_without_metadata()
		helpers.assert_eq(#state.curls, 1)
	end)
	helpers.it("a later refused native cancellation invalidates the previous positive receipt", function()
		local config = {}
		local coordinator, state = fixture(config)
		state.start_boolean(); helpers.assert_true(coordinator.cancel(OWNER))
		config.refused = true
		helpers.assert_eq(coordinator.cancel(OWNER), false)
		state.refuse_without_metadata()
		helpers.assert_eq(#state.curls, 1)
	end)
	helpers.it("invalid successor preparation leaves the cancelled owner and all physical debt addressable", function()
		local coordinator, state = fixture()
		local predecessor = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		local refused = state.start_owned(function() return nil, "fixed preparation refusal" end)
		helpers.assert_eq(refused.started, false)
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(predecessor:is_settled(), false)
		helpers.assert_true(coordinator.cancel(OWNER))
		state.curls[1]:ack(); state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.curls, 1)
	end)
end)

helpers.describe("cancel attempt and original deadline reentry", function()
	helpers.it("deadline already elapsed before cancellation cannot mint a receipt without its timer tick", function()
		local coordinator, state = fixture()
		state.start_boolean(); state.now = 101
		helpers.assert_true(coordinator.cancel(OWNER))
		state.refuse_without_metadata()
	end)
	helpers.it("deadline elapsed after positive ACK refuses owned preparation without any expiry callback", function()
		local coordinator, state = fixture()
		state.start_boolean(); helpers.assert_true(coordinator.cancel(OWNER)); state.now = 101
		state.refuse_without_metadata()
	end)
	helpers.it("an ACK returned after the original deadline cannot mint cancellation authority", function()
		local coordinator, state = fixture()
		state.start_boolean()
		state.curls[1].cancel_hook = function() state.now = 101 end
		helpers.assert_true(coordinator.cancel(OWNER))
		state.refuse_without_metadata()
	end)
	helpers.it("clock source reentry after the tentative reservation refuses before owned metadata", function()
		local coordinator, state = fixture()
		local _, old_options = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		state.clock_hook = function() old_options.authorized = function() error("must not probe changed source") end end
		state.refuse_without_metadata()
	end)
	helpers.it("newer nested refused cancellation cannot be overwritten by the old outer positive ACK", function()
		local config = {}
		local coordinator, state = fixture(config)
		state.start_boolean()
		local nested
		state.curls[1].cancel_hook = function()
			config.refused = true; nested = coordinator.cancel(OWNER); config.refused = false
		end
		helpers.assert_true(coordinator.cancel(OWNER))
		helpers.assert_eq(nested, false)
		state.refuse_without_metadata()
	end)
	helpers.it("post-preparation old deadline expiry refuses despite a longer unexpired successor budget", function()
		local coordinator, state = fixture()
		state.start_boolean(); helpers.assert_true(coordinator.cancel(OWNER))
		local successor = state.start_owned(function(opts) state.now = 101; return opts, nil, {} end, 200)
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(state.metadata, 1)
		helpers.assert_eq(#state.curls, 1)
		state.timers[2]:ack()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(state.results[1].error, "previous request cleanup pending")
	end)
	helpers.it("old physical retirement during the final clock preserves standalone successor admission", function()
		local coordinator, state = fixture()
		local predecessor = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		state.arm_hook = function(index)
			if index == 2 then state.clock_hook = function() state.curls[1]:ack(); state.timers[1]:ack() end end
		end
		local successor = state.start_owned()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_true(successor.started)
		helpers.assert_eq(#state.curls, 2)
		helpers.assert_eq(#state.results, 0)
	end)
end)

helpers.describe("newer native cancellation intent survives older returns", function()
	helpers.it("older refused cancel cannot restore delivery after a newer positive cancel and actual deadline tick", function()
		local config = {}
		local coordinator, state = fixture(config)
		local predecessor = state.start_boolean()
		local nested
		state.curls[1].cancel_hook = function()
			nested = coordinator.cancel(OWNER); config.refused = true
		end
		helpers.assert_eq(coordinator.cancel(OWNER), false)
		helpers.assert_true(nested)
		state.now = 101; state.timers[1].expired()
		helpers.assert_eq(#state.results, 0, "newer positive cancellation suppresses the already armed parent timeout")
		state.curls[1]:ack(); state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.results, 0)
	end)
	helpers.it("the newer positive ACK admits a waiting successor even when its older outer call refuses", function()
		local config = {}
		local coordinator, state = fixture(config)
		local predecessor = state.start_boolean()
		local nested
		state.curls[1].cancel_hook = function()
			nested = coordinator.cancel(OWNER); config.refused = true
		end
		helpers.assert_eq(coordinator.cancel(OWNER), false)
		helpers.assert_true(nested)
		local successor = state.start_owned()
		helpers.assert_true(successor.started)
		helpers.assert_eq(#state.curls, 1)
		state.curls[1]:ack()
		helpers.assert_eq(#state.curls, 1)
		state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.curls, 2)
		helpers.assert_eq(#state.results, 0)
	end)
	helpers.it("a newer attempt inside physical observation alone owns its timer retirement request", function()
		local coordinator, state = fixture()
		local predecessor = state.start_boolean()
		local nested
		state.curls[1].settlement_hook = function()
			state.curls[1].settled = true
			nested = coordinator.cancel(OWNER)
		end
		helpers.assert_true(coordinator.cancel(OWNER))
		helpers.assert_true(nested)
		helpers.assert_eq(state.timers[1].cancel_calls, 1, "the older observer must not rewrite or retry the newer finish")
		helpers.assert_eq(predecessor:is_settled(), false)
		state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.results, 0)
	end)
end)

helpers.describe("refused replacement remains terminal through physical adoption", function()
	helpers.it("old physical ACK cannot dispatch a rejected replacement whose own timer still closes", function()
		local coordinator, state = fixture()
		local predecessor, old_options = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		local refused = state.start_owned(function(opts)
			old_options.authorized = function() return false end
			return opts, nil, {}
		end)
		helpers.assert_eq(refused.started, false)
		helpers.assert_eq(refused:is_settled(), false)
		state.curls[1]:ack(); state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.curls, 1, "retirement-only adoption cannot create a refused child")
		helpers.assert_eq(refused:is_settled(), false)
		helpers.assert_eq(#state.results, 0)
		state.timers[2]:ack()
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(#state.results, 1)
		helpers.assert_eq(state.results[1].error, "previous request cleanup pending")
		local recovery = state.start_owned()
		helpers.assert_true(recovery.started)
		helpers.assert_eq(#state.curls, 2)
	end)
	helpers.it("refused timer ACK first detaches only that refusal and preserves exact old debt", function()
		local coordinator, state = fixture()
		local predecessor, old_options = state.start_boolean()
		helpers.assert_true(coordinator.cancel(OWNER))
		local refused = state.start_owned(function(opts)
			old_options.authorized = function() return false end
			return opts, nil, {}
		end)
		state.timers[2]:ack()
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(predecessor:is_settled(), false)
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(#state.results, 1)
		helpers.assert_eq(state.results[1].error, "previous request cleanup pending")
		state.curls[1]:ack(); state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(#state.results, 1)
	end)
	helpers.it("failed signal preserves the valid old delivery while refusing a late-adopted successor", function()
		local config = { refused = true }
		local _, state = fixture(config)
		local predecessor = state.start_boolean()
		local refused = state.start_owned()
		helpers.assert_eq(refused.started, false)
		helpers.assert_eq(#state.curls, 1)
		state.curls[1].done({ ok = true, status = 200, body = "old response" })
		state.curls[1]:ack(); state.timers[1]:ack()
		helpers.assert_true(predecessor:is_settled())
		helpers.assert_eq(#state.curls, 1)
		helpers.assert_eq(refused:is_settled(), false)
		helpers.assert_eq(#state.results, 1)
		helpers.assert_true(state.results[1].ok)
		helpers.assert_eq(state.results[1].body, "old response")
		state.timers[2]:ack()
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(#state.results, 2)
		helpers.assert_eq(state.results[2].error, "previous request cancellation failed")
	end)
end)
