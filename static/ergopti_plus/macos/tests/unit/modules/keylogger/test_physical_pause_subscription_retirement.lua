--- tests/unit/modules/keylogger/test_physical_pause_subscription_retirement.lua

--- Independent async subscription controls; native pause admission stays unavailable.
local helpers = require("tests.helpers")
local function actor_for(capacity, receive, refused)
	local now = 0
	local actor = require("keylogger.physical_lifecycle_observation").new("pause", function() now = now + 1; return now end, function() end)
	local owner = {}; local token, _, scope = actor.bind(owner, capacity or 20, receive or function() return true end, refused)
	return actor, owner, token, scope
end
local function fields() return { paused = true, transition_generation = 1, admission_released = false, settled = true } end

helpers.describe("corrected pause actor callback subscription debt", function()
	helpers.it("requires exact terminal completion after async detach", function()
		local actor, owner, token, scope = actor_for()
		local ticket = actor.begin("pause"); helpers.assert_eq(type(ticket), "table")
		helpers.assert_eq(scope.detach(owner, token), true)
		helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(actor.finish({}, fields, true), false); helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(actor.finish(ticket, function() error("Detached source must not query") end, false), false)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("retains the completing fence and debt through a reentered foreign snapshot", function()
		local records = {}; local actor, owner, token, scope = actor_for(20, function(record) records[#records + 1] = record; return true end)
		local ticket = actor.begin("pause"); local nested, observed_retired, detached_ack
		local delivered = actor.finish(ticket, function()
			nested = actor.finish(ticket, fields, true); helpers.assert_eq(nested, false)
			detached_ack = scope.detach(owner, token); observed_retired = scope.retired(owner, token)
			helpers.assert_eq(detached_ack, true); helpers.assert_eq(observed_retired, false)
			return fields()
		end, false)
		helpers.assert_eq(nested, false); helpers.assert_eq(detached_ack, true); helpers.assert_eq(observed_retired, false)
		helpers.assert_eq(delivered, false); helpers.assert_eq(records[#records].complete, false)
		helpers.assert_eq(records[#records].allowed, false); helpers.assert_eq(scope.retired(owner, token), true)
	end)
	helpers.it("retains refused begin debt until its actual terminal frame finishes", function()
		local actor, owner, token, scope, refusal_token
		actor, owner, token, scope = actor_for(1, nil, function(_, exact)
			refusal_token = exact; helpers.assert_eq(scope.detach(owner, exact), true)
			helpers.assert_eq(scope.retired(owner, exact), false)
		end)
		local ticket = actor.begin("pause"); helpers.assert_true(rawequal(refusal_token, token))
		helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(actor.finish(ticket, fields, true), false)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
end)

-- Record exact refusal callback facts before checking them outside contained dispatch.
helpers.describe("async pause refusal outside observations", function()
	helpers.it("observes pending terminal debt outside its contained refusal callback", function()
		local actor, owner, token, scope, observed_token, observed_detach, observed_retired
		actor, owner, token, scope = actor_for(1, nil, function(_, exact)
			observed_token = exact
			observed_detach = scope.detach(owner, exact)
			observed_retired = scope.retired(owner, exact)
		end)
		local ticket = actor.begin("pause")
		helpers.assert_true(rawequal(observed_token, token))
		helpers.assert_eq(observed_detach, true)
		helpers.assert_eq(observed_retired, false)
		helpers.assert_eq(scope.retired(owner, token), false)
		helpers.assert_eq(actor.finish(ticket, fields, true), false)
		helpers.assert_eq(scope.retired(owner, token), true)
	end)
end)
