--- tests/unit/infra/test_managed_fractional_budget.lua
--- Independent literal receiving controls; no physical timer/network claims.
local helpers = require("tests.helpers")
local Managed = require("infra.managed_http")
local OWNER, URL = "fractional-owner", "http://127.0.0.1:9000/fixed"
local function fixture()
    local state = { now = 0, curls = {}, proxies = {}, timers = {}, results = {} }
    local function child(list, options, done)
        local value = { started = true, settled = false, listeners = {}, options = options, done = done }
        function value:is_settled() return self.settled end
        function value:on_settled(listener) self.listeners[#self.listeners + 1] = listener; return true end
        function value:request_cancel() return true end
        function value.cancel() return true end
        function value:ack()
            self.settled = true
            local listeners = self.listeners; self.listeners = {}
            for _, listener in ipairs(listeners) do listener() end
        end
        list[#list + 1] = value
        return value
    end
    local coordinator = assert(Managed.new({
        clock = function() return state.now end,
        environment = function() return {} end,
        report = function() end,
        policy = {
            route = function() return { mode = state.system and "system" or "direct" } end,
            selection = function() return { { kind = "direct" } } end,
            can_retry = function() return false end,
        },
        proxy = { lookup_owned = function(_, options, done) return child(state.proxies, options, done) end },
        curl = function(_, _, _, options, _, done) return child(state.curls, options, done) end,
        deadline = function(deadline, expired)
            local timer = child(state.timers, { deadline = deadline }, expired)
            function timer:cancel() self.close_requested = true; return true end
            timer.deadline, timer.expired = deadline, expired
            if state.after_arm then state.after_arm(#state.timers) end
            return timer
        end,
        prepare_headers = function(token) if state.after_headers then state.after_headers() end; return token end,
    }))
    function state.start(owned, timeout, prepared)
        local options = { owner = OWNER, method = "GET", buffered = true, owned_api = owned, timeout_ms = timeout }
        if prepared then options.prepared_headers = {} end
        local admission
        if owned then admission = { prepare = function() return options, nil, {} end } end
        return coordinator.start(URL, {}, nil, options, nil, function(result) state.results[#state.results + 1] = result end, admission)
    end
    return coordinator, state
end
helpers.describe("fractional original HTTP budget", function()
    for _, row in ipairs({ { now = 0.25, expected = 0.75 }, { now = 0.75, expected = 0.25 }, { now = 0.999, expected = 0.001 } }) do
        local literal = row
        helpers.it("admits positive residual at " .. tostring(literal.now), function()
            local _, state = fixture()
            state.after_arm = function() state.now = literal.now end
            local operation = state.start(true, 1)
            helpers.assert_true(operation.started)
            helpers.assert_eq(#state.curls, 1)
            helpers.assert_true(math.abs(state.curls[1].options.timeout_ms - literal.expected) < 0.000000001)
            helpers.assert_eq(state.timers[1].deadline, 1)
            helpers.assert_eq(#state.results, 0)
        end)
    end
    for _, instant in ipairs({ 1, 1.001 }) do
        local literal = instant
        helpers.it("refuses exact or passed original deadline at " .. tostring(literal), function()
            local _, state = fixture()
            state.after_arm = function() state.now = literal end
            local operation = state.start(true, 1)
            helpers.assert_eq(#state.curls, 0)
            helpers.assert_eq(state.timers[1].deadline, 1)
            helpers.assert_true(not operation:is_settled())
            state.timers[1]:ack()
            helpers.assert_true(operation:is_settled())
            helpers.assert_eq(#state.results, 1)
            helpers.assert_eq(state.results[1].error, "timeout")
        end)
    end
    helpers.it("rebinds headers then forwards only the positive residual", function()
        local _, state = fixture()
        state.after_headers = function() state.now = 0.75 end
        local operation = state.start(true, 1, true)
        helpers.assert_true(operation.started)
        helpers.assert_eq(state.curls[1].options.timeout_ms, 0.25)
        helpers.assert_eq(state.timers[1].deadline, 1)
    end)
    helpers.it("keeps queued successor fraction after both predecessor close ACKs", function()
        local coordinator, state = fixture()
        local predecessor = state.start(false, 100)
        helpers.assert_true(coordinator.cancel(OWNER))
        local successor = state.start(true, 1)
        helpers.assert_true(successor.started)
        helpers.assert_eq(#state.curls, 1)
        state.now = 0.75
        state.curls[1]:ack()
        helpers.assert_eq(#state.curls, 1)
        helpers.assert_true(not predecessor:is_settled())
        state.timers[1]:ack()
        helpers.assert_true(predecessor:is_settled())
        helpers.assert_eq(#state.curls, 2)
        helpers.assert_eq(state.curls[2].options.timeout_ms, 0.25)
        helpers.assert_eq(state.timers[2].deadline, 1)
    end)
    helpers.it("never resets expired queued successor budget", function()
        local coordinator, state = fixture()
        state.start(false, 100)
        helpers.assert_true(coordinator.cancel(OWNER))
        local successor = state.start(true, 1)
        state.now = 1
        state.curls[1]:ack(); state.timers[1]:ack()
        helpers.assert_eq(#state.curls, 1)
        helpers.assert_eq(state.timers[2].deadline, 1)
        state.timers[2]:ack()
        helpers.assert_true(successor:is_settled())
        helpers.assert_eq(state.results[#state.results].error, "timeout")
    end)
    helpers.it("rounds only GIO integer admission while keeping parent deadline", function()
        local _, state = fixture()
        state.system = true
        state.after_arm = function() state.now = 0.75 end
        local operation = state.start(true, 1)
        helpers.assert_true(operation.started)
        helpers.assert_eq(#state.proxies, 1)
        helpers.assert_eq(state.proxies[1].options.timeout_ms, 1)
        helpers.assert_eq(state.timers[1].deadline, 1)
        helpers.assert_eq(#state.curls, 0)
    end)
    helpers.it("allows success before exact deadline after child and timer ACKs", function()
        local _, state = fixture()
        local operation = state.start(true, 1)
        state.now = 0.75
        state.curls[1].done({ ok = true, status = 200, body = "literal" })
        state.curls[1]:ack()
        helpers.assert_true(not operation:is_settled())
        state.timers[1]:ack()
        helpers.assert_true(operation:is_settled())
        helpers.assert_eq(#state.results, 1)
        helpers.assert_true(state.results[1].ok)
        helpers.assert_eq(state.results[1].body, "literal")
    end)
    helpers.it("refuses late success at the original equal deadline", function()
        local _, state = fixture()
        local operation = state.start(true, 1)
        state.now = 1
        state.curls[1].done({ ok = true, status = 200, body = "literal" })
        state.curls[1]:ack(); state.timers[1]:ack()
        helpers.assert_true(operation:is_settled())
        helpers.assert_eq(#state.results, 1)
        helpers.assert_eq(state.results[1].error, "timeout")
        helpers.assert_eq(state.results[1].body, "")
    end)
end)
